import Foundation
import AppKit
import PDFKit
import CoreGraphics

// Post-render pass: draws thin (~0.3pt) underline lines beneath every
// run that the parser flagged as underline=true. The TPPDF renderer
// deliberately omits the NSAttributedString .underlineStyle attribute
// for body runs because Core Text uses the font's intrinsic underline
// thickness (~0.6-1.0pt at 12pt body) which is heavier than Gmail's
// CSS text-decoration rendering and can't be overridden via public
// macOS APIs.
//
// Implementation: PDFAnnotation .line is unreliable here — Preview and
// some PDF viewers enforce a minimum stroke width on annotations,
// rendering even a 0.3pt-bordered line annotation visibly heavy. To
// guarantee a thin line across viewers we redraw each affected page
// via CGContext, blitting the original page's vector content and then
// stroking the thin underlines as part of the page's content stream.
//
// Run-to-page resolution: we constrain text searches to each message's
// page range (same heading-locator pattern as PDFNavigationAnnotator)
// so short underlined fragments don't get false-matched against quoted
// occurrences elsewhere in the thread.
public enum PDFUnderlineAnnotator {

    private static let lineWidth: CGFloat = 0.3
    // Vertical offset of the underline above the baseline of the
    // selection bounds. Selection bounds typically wrap glyph
    // cap-to-descender, so a small +y from minY drops the line
    // cleanly under the descenders.
    private static let baselineDrop: CGFloat = 1.0

    public static func annotate(url: URL, thread: Thread) {
        guard let doc = PDFDocument(url: url) else { return }

        // Per-message page ranges via heading lookup.
        var headingPage: [Int: Int] = [:]
        for m in thread.messages {
            let needle = "\(m.index). \(m.fromName)"
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                if (p.string ?? "").contains(needle) {
                    headingPage[m.index] = i
                    break
                }
            }
        }

        // Collect underline rects per page index.
        let debug = ProcessInfo.processInfo.environment["DEBUG_UNDERLINE"] == "1"
        var rectsByPage: [Int: [CGRect]] = [:]
        for m in thread.messages {
            guard let startPage = headingPage[m.index] else { continue }
            let endPage: Int = headingPage[m.index + 1] ?? doc.pageCount
            for line in m.bodyLines {
                let fragments = collectUnderlineFragments(in: line.runs)
                for fragment in fragments {
                    if debug {
                        print("[underline] msg \(m.index) (\(fragment.count) chars) fragment: '\(fragment)'")
                    }
                    let matches = findRectsRecursive(
                        fragment, in: doc,
                        startPage: startPage, endPage: endPage
                    )
                    if debug { print("  → matches: \(matches.count)") }
                    for (pIdx, b) in matches {
                        rectsByPage[pIdx, default: []].append(b)
                    }
                }
            }
        }
        if debug { print("[underline] total rects: \(rectsByPage.values.reduce(0) { $0 + $1.count })") }
        if rectsByPage.isEmpty { return }

        // Redraw each affected page into a new CGContext PDF and then
        // splice the rebuilt pages back into the document.
        for (pageIdx, rects) in rectsByPage {
            guard let original = doc.page(at: pageIdx),
                  let rebuilt = redraw(page: original, addingUnderlines: rects)
            else { continue }
            doc.removePage(at: pageIdx)
            doc.insert(rebuilt, at: pageIdx)
        }

        _ = doc.write(to: url)
    }

    // Walk runs, group consecutive underline=true runs into one merged
    // text fragment so we search for the longest possible string.
    // findString won't match across rendered line wraps. When a long
    // fragment fails, bisect at the middle space and recurse on each
    // half, so a fragment that wraps at "...to Remove | Listing
    // Agent..." is found as two separate selections. The minimum
    // chunk length guards against false matches on short common words.
    private static let minFragmentLen = 6
    private static func findRectsRecursive(
        _ raw: String, in doc: PDFDocument,
        startPage: Int, endPage: Int
    ) -> [(Int, CGRect)] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < minFragmentLen { return [] }
        var result: [(Int, CGRect)] = []
        var found = false
        for sel in doc.findString(text, withOptions: .literal) {
            for page in sel.pages {
                let pIdx = doc.index(for: page)
                guard pIdx >= startPage && pIdx < endPage else { continue }
                let b = sel.bounds(for: page)
                if b.isNull || b.isEmpty { continue }
                result.append((pIdx, b))
                found = true
            }
        }
        if found { return result }
        // Bisect at the space closest to the middle.
        let midOffset = text.count / 2
        var splitIdx: String.Index? = nil
        var bestDist = Int.max
        var offset = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == " " {
                let dist = abs(offset - midOffset)
                if dist < bestDist { bestDist = dist; splitIdx = i }
            }
            offset += 1
            i = text.index(after: i)
        }
        guard let s = splitIdx else { return [] }
        let left = String(text[..<s])
        let right = String(text[text.index(after: s)...])
        return findRectsRecursive(left, in: doc, startPage: startPage, endPage: endPage)
            + findRectsRecursive(right, in: doc, startPage: startPage, endPage: endPage)
    }

    private static func collectUnderlineFragments(in runs: [StyledRun]) -> [String] {
        var out: [String] = []
        var buf = ""
        for r in runs {
            if r.underline {
                buf.append(r.text)
            } else if !buf.isEmpty {
                out.append(buf)
                buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Redraw a PDF page into a new single-page PDF that has the
    // original content plus thin underline strokes, return it as a
    // PDFPage suitable for splicing back via PDFDocument.insert.
    private static func redraw(page: PDFPage, addingUnderlines rects: [CGRect]) -> PDFPage? {
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        ctx.beginPDFPage(nil)
        // Draw the original page's content (vectors + text + images).
        page.draw(with: .mediaBox, to: ctx)

        // Stroke thin underlines on top.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.butt)
        for r in rects {
            let y = r.minY + baselineDrop
            ctx.move(to: CGPoint(x: r.minX, y: y))
            ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.endPDFPage()
        ctx.closePDF()

        // Wrap the rebuilt single-page PDF and return its only page.
        guard let rebuiltDoc = PDFDocument(data: data as Data),
              let newPage = rebuiltDoc.page(at: 0)
        else { return nil }
        return newPage
    }
}
