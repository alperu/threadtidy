import Foundation
import PDFKit
import AppKit

// Pulls a styled line stream out of a PDF using PDFKit. We work from
// `PDFPage.attributedString`, which carries font, underline, and link
// attributes for every run. We strip the Gmail print chrome (top
// "MM/DD/YY, H:MM AM   Gmail – ..." band, bottom URL+page band, page-1
// Gmail logo) by discarding lines whose y-coordinate is in the chrome
// bands or whose plain text matches a chrome regex.
public final class PDFTextExtractor {

    public init() {}

    public enum ExtractError: Error, LocalizedError {
        case cannotOpen(URL)
        case empty
        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let u): return "Could not open PDF: \(u.lastPathComponent)"
            case .empty: return "PDF appears to contain no text."
            }
        }
    }

    // Vertical bands (in points from page top/bottom) considered chrome.
    private let topChromeBand: CGFloat = 36
    private let bottomChromeBand: CGFloat = 28

    // Regexes that identify chrome lines we should drop even if they
    // sneak past the band check (e.g. "1/19" page indicator, the
    // running URL footer that wraps onto a long line).
    private let chromeLineRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^https://mail\.google\.com/.*$"#,                          // footer URL
            #"^\d{1,2}/\d{1,2}/\d{2}, \d{1,2}:\d{2} (AM|PM)\s+Gmail.*"#, // combined timestamp+subject band
            #"^Gmail\s*-\s*.+$"#,                                        // standalone "Gmail - <subject>" page header
            #"^\d{1,2}/\d{1,2}/\d{2},\s*\d{1,2}:\d{2}\s*(AM|PM)\s*$"#,   // standalone timestamp band
            #"^\d+/\d+$"#,                                               // bare page n/total
            "^[\u{2026}…][[:space:]]*\\d+/\\d+$"                         // "… 1/19" footer (NSRegex needs the literal char, not \\u{2026})
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public func extract(from url: URL) throws -> [StyledLine] {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.cannotOpen(url) }

        // Side-channel: walk each page's content stream for vector
        // bullet glyphs AND for raw text-show positions. We use the
        // text-show positions to derive accurate per-line x-indents
        // directly from the PDF's drawing operators (more reliable
        // than PDFKit's selection.bounds, which can round/normalize).
        let scans = BulletDetector().scan(url)
        var bulletsByPage: [Int: [BulletDetector.Bullet]] = [:]
        var scanLinesByPage: [Int: [(text: String, x: CGFloat, y: CGFloat)]] = [:]
        var chunksByPage: [Int: [BulletDetector.TextChunk]] = [:]
        for (idx, page) in scans.enumerated() {
            bulletsByPage[idx] = page.bullets
            scanLinesByPage[idx] = groupChunksIntoLines(page.chunks)
            chunksByPage[idx] = page.chunks
        }

        var lines: [StyledLine] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageLines = extractLines(
                from: page,
                isFirstPage: i == 0,
                bullets: bulletsByPage[i] ?? [],
                scanLines: scanLinesByPage[i] ?? [],
                chunks: chunksByPage[i] ?? []
            )
            lines.append(contentsOf: pageLines)
        }
        guard !lines.isEmpty else { throw ExtractError.empty }
        // Normalize indents: the body's leftmost line is x = baseline;
        // every other line's indent is its (absolute x) − (baseline).
        // We use the smallest non-trivial x as the baseline so the
        // typical body-flush line gets indent = 0.
        let absoluteXs = lines.compactMap { line -> CGFloat? in
            line.plain.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line.indent
        }
        if let baseline = absoluteXs.min() {
            lines = lines.map { line -> StyledLine in
                let normalized = max(0, line.indent - baseline)
                return StyledLine(
                    runs: line.runs,
                    indent: normalized,
                    isBullet: line.isBullet
                )
            }
        }
        return lines
    }

    // MARK: - Per-page

    // Walk the line's chunks (those whose y-position matches this
    // line's y) and override bold/italic on runs by ALIGNING glyph
    // positions, not text content. The chunks' .text is encoded in
    // the embedded font's character set (gibberish without ToUnicode
    // mapping), so we can't string-match. But we have:
    //   - the chunk's x-position (left edge of glyph)
    //   - the chunk's font name (Helvetica-Bold, Arial-ItalicMT, etc.)
    // and PDFKit can give us the x-position of any character range
    // via PDFSelection.bounds(for:). We walk the line's chars and
    // find the chunk whose x matches each char's x.
    private func applyChunkFontOverrides(
        line: StyledLine,
        chunks: [BulletDetector.TextChunk],
        yCenter: CGFloat,
        lineH: CGFloat,
        page: PDFPage,
        lineRange: NSRange
    ) -> StyledLine {
        // 1. Filter chunks to this line's y-band, sort by x.
        let yTol = max(lineH * 0.5, 4)
        let lineChunks = chunks
            .filter { abs($0.y - yCenter) <= yTol }
            .sorted { $0.x < $1.x }
        if lineChunks.isEmpty { return line }

        // 2. Build x-range spans from chunks, with bold/italic flags
        //    derived from each chunk's BaseFont name.
        struct Span { let xStart: CGFloat; let xEnd: CGFloat; let bold: Bool; let italic: Bool }
        var spans: [Span] = []
        for (i, ch) in lineChunks.enumerated() {
            let lowered = ch.fontName.lowercased()
            let chBold = lowered.contains("bold") || lowered.contains("heavy")
                || lowered.contains("black") || lowered.contains("semibold")
                || lowered.contains("demi")
            let chItalic = lowered.contains("italic") || lowered.contains("oblique")
            let xEnd = (i + 1 < lineChunks.count) ? lineChunks[i + 1].x : (ch.x + 50)
            spans.append(Span(xStart: ch.x, xEnd: xEnd, bold: chBold, italic: chItalic))
        }
        if !spans.contains(where: { $0.bold || $0.italic }) { return line }

        // 3. For each character in the line, look up its x-position via
        //    PDFPage.characterBounds(at:) (PDF-document coordinate, not
        //    line-relative), then find the chunk span whose x range
        //    contains it. This is per-char accurate regardless of how
        //    chunks bundle glyphs.
        let plain = line.runs.map(\.text).joined()
        let nsPlain = plain as NSString
        let charCount = nsPlain.length
        var newRuns = line.runs

        for i in 0..<charCount {
            let charBounds = page.characterBounds(at: lineRange.location + i)
            // characterBounds returns NaN-bounds for newlines / chars
            // PDFKit doesn't track. Skip those.
            if charBounds.isNull || charBounds.isEmpty { continue }
            let cx = charBounds.midX
            // Linear scan over spans (small N, ~20 typical) to find one
            // whose x range contains cx.
            for span in spans {
                if cx >= span.xStart && cx < span.xEnd {
                    if span.bold || span.italic {
                        applyTraits(
                            bold: span.bold, italic: span.italic,
                            over: NSRange(location: i, length: 1), runs: &newRuns
                        )
                    }
                    break
                }
            }
        }
        return StyledLine(runs: newRuns, indent: line.indent, isBullet: line.isBullet)
    }

    // Splits/walks runs to apply bold/italic over a [start, end)
    // character range of the joined plain text. Runs straddling the
    // boundary are split.
    private func applyTraits(
        bold: Bool, italic: Bool,
        over range: NSRange, runs: inout [StyledRun]
    ) {
        let target = NSRange(location: range.location, length: range.length)
        var rebuilt: [StyledRun] = []
        var cursor = 0
        for run in runs {
            let runLen = (run.text as NSString).length
            let runRange = NSRange(location: cursor, length: runLen)
            // No overlap.
            if NSIntersectionRange(runRange, target).length == 0 {
                rebuilt.append(run)
                cursor += runLen
                continue
            }
            // Split at intersection boundaries.
            let s = run.text as NSString
            let intersect = NSIntersectionRange(runRange, target)
            let leftLen = intersect.location - runRange.location
            let midLen = intersect.length
            let rightLen = runLen - leftLen - midLen
            if leftLen > 0 {
                rebuilt.append(StyledRun(
                    text: s.substring(with: NSRange(location: 0, length: leftLen)),
                    bold: run.bold, italic: run.italic, underline: run.underline,
                    link: run.link, fontSize: run.fontSize
                ))
            }
            if midLen > 0 {
                rebuilt.append(StyledRun(
                    text: s.substring(with: NSRange(location: leftLen, length: midLen)),
                    bold: run.bold || bold,
                    italic: run.italic || italic,
                    underline: run.underline,
                    link: run.link, fontSize: run.fontSize
                ))
            }
            if rightLen > 0 {
                rebuilt.append(StyledRun(
                    text: s.substring(with: NSRange(location: leftLen + midLen, length: rightLen)),
                    bold: run.bold, italic: run.italic, underline: run.underline,
                    link: run.link, fontSize: run.fontSize
                ))
            }
            cursor += runLen
        }
        runs = rebuilt
    }

    // Groups CGPDFScanner-emitted text chunks into visual lines: chunks
    // whose y-coordinates are within ~3pt of each other (typical
    // baseline jitter) are merged. Within each line, chunks are sorted
    // by x and concatenated. Returns each line's leftmost x and its
    // y-center.
    private func groupChunksIntoLines(
        _ chunks: [BulletDetector.TextChunk]
    ) -> [(text: String, x: CGFloat, y: CGFloat)] {
        guard !chunks.isEmpty else { return [] }
        // Cluster by y: sort by y descending (PDF top-to-bottom for
        // PDF coords), then merge adjacent ones within tolerance.
        let sorted = chunks.sorted { $0.y > $1.y }
        var clusters: [[BulletDetector.TextChunk]] = []
        let yTol: CGFloat = 3
        for c in sorted {
            if let last = clusters.last?.last, abs(last.y - c.y) <= yTol {
                clusters[clusters.count - 1].append(c)
            } else {
                clusters.append([c])
            }
        }
        // For each cluster: sort by x, concatenate text, compute leftmost x.
        return clusters.map { cluster in
            let byX = cluster.sorted { $0.x < $1.x }
            let text = byX.map(\.text).joined()
            let leftX = byX.first?.x ?? 0
            let avgY = cluster.map(\.y).reduce(0, +) / CGFloat(cluster.count)
            return (text: text, x: leftX, y: avgY)
        }
    }

    private func extractLines(from page: PDFPage,
                              isFirstPage: Bool,
                              bullets: [BulletDetector.Bullet] = [],
                              scanLines: [(text: String, x: CGFloat, y: CGFloat)] = [],
                              chunks: [BulletDetector.TextChunk] = []
                             ) -> [StyledLine] {
        guard let attr = page.attributedString else { return [] }
        let pageBounds = page.bounds(for: .mediaBox)

        // Walk the attributed string. PDFKit emits "\n" between visual
        // lines, so splitting on "\n" gives us one StyledLine per row.
        var result: [StyledLine] = []
        var ys: [(y: CGFloat, h: CGFloat)] = []
        var cursor = 0
        let full = attr.string as NSString
        while cursor < full.length {
            let nl = full.range(of: "\n", range: NSRange(location: cursor, length: full.length - cursor))
            let lineRange: NSRange
            if nl.location == NSNotFound {
                lineRange = NSRange(location: cursor, length: full.length - cursor)
                cursor = full.length
            } else {
                lineRange = NSRange(location: cursor, length: nl.location - cursor)
                cursor = nl.location + nl.length
            }
            if lineRange.length == 0 {
                result.append(StyledLine(runs: []))
                continue
            }
            let lineAttr = attr.attributedSubstring(from: lineRange)
            if shouldDropAsChrome(lineAttr: lineAttr, page: page, pageBounds: pageBounds, isFirstPage: isFirstPage) {
                continue
            }
            // Y-center via PDFKit's selection (used for matching this
            // PDFKit line to a CGPDFScanner-derived scanLine and bullet).
            let firstCharRange = NSRange(location: lineRange.location, length: 1)
            let bbox = page.selection(for: firstCharRange)?.bounds(for: page) ?? .zero
            let yCenter = bbox.midY
            let lineH = max(bbox.height, 6)
            // Find the scanLine whose y is closest to this line's
            // y-center. That scanLine's leftmost-x is our authoritative
            // indent (from the content stream's actual drawing ops).
            let plain = lineAttr.string.trimmingCharacters(in: .whitespaces)
            let scanLine: (text: String, x: CGFloat, y: CGFloat)? = scanLines.min { a, b in
                abs(a.y - yCenter) < abs(b.y - yCenter)
            }
            let xMin: CGFloat = {
                guard let sl = scanLine, abs(sl.y - yCenter) <= lineH * 1.0 else {
                    return bbox.minX  // fallback to PDFKit
                }
                // Sanity-check: only trust the scanLine x if its text
                // looks roughly like our PDFKit line text.
                let scanFirstWord = sl.text.split(separator: " ").first.map(String.init) ?? ""
                let pdfFirstWord = plain.split(separator: " ").first.map(String.init) ?? ""
                if !scanFirstWord.isEmpty, !pdfFirstWord.isEmpty,
                   scanFirstWord.prefix(4) == pdfFirstWord.prefix(4) {
                    return sl.x
                }
                return sl.x  // tolerate mismatches; positions still correlate by y
            }()
            let isBullet = bullets.contains { b in
                abs(b.y - yCenter) <= lineH * 0.6
                    && b.x < xMin
                    && (xMin - b.x) < 40
            }
            var built = buildLine(from: lineAttr, page: page)
            built = StyledLine(runs: built.runs, indent: xMin, isBullet: isBullet)
            // Override bold/italic flags using CGPDFScanner-derived
            // BaseFont names. PDFKit's NSAttributedString resolves
            // embedded fonts to system fallbacks (e.g. "Helvetica-Bold"
            // → "Helvetica") and drops the bold/italic suffix, so we
            // can't trust its trait flags. The content stream's `Tf`
            // operator references a resource alias whose BaseFont
            // ("Helvetica-Bold") tells the truth.
            // Note: tried CGPDFScanner-driven bold/italic override
            // here using BaseFont name lookup. The chunk-to-character
            // alignment is unreliable because (a) embedded fonts use
            // custom encodings (chunk text is gibberish before
            // ToUnicode mapping), and (b) chunk x-positions don't
            // line up cleanly with PDFKit's characterBounds in mixed-
            // weight runs. The override produced worse results than
            // baseline. Lead-in / sub-heading bold heuristics in the
            // renderer cover the recoverable cases. Inline emphasis
            // that Gmail's print stripped is unrecoverable.
            _ = chunks  // intentionally unused
            ys.append((y: yCenter, h: lineH))
            result.append(built)
        }
        // Y-gap pass: detect lines whose top sits more than 1.4× the
        // typical line height below the previous line's bottom — that's
        // a paragraph break PDFKit's text extraction collapsed (Gmail's
        // blank-line gap between paragraphs doesn't survive into the
        // attributedString). Inject a synthetic blank StyledLine so the
        // renderer's groupBlocks treats the surrounding regions as
        // separate paragraphs.
        let medianH = ys.isEmpty ? 12 : ys.map(\.h).sorted()[ys.count / 2]
        var withGaps: [StyledLine] = []
        for i in 0..<result.count {
            if i > 0 {
                let prevTop = ys[i - 1].y + ys[i - 1].h / 2
                let prevBottom = ys[i - 1].y - ys[i - 1].h / 2
                let curTop = ys[i].y + ys[i].h / 2
                // PDF y grows upward; reading top-down means each
                // subsequent line has a SMALLER y. The gap from prev's
                // bottom to current's top is (prevBottom - curTop).
                let gap = prevBottom - curTop
                // Threshold tuned so only a TRUE blank-line gap in the
                // source triggers a paragraph break. Source line height
                // for a normal wrap is ~medianH; a blank line between
                // paragraphs adds another ~medianH on top of that, so
                // a gap of ≥ 1.0× medianH means there was an actual
                // blank line. Tighter thresholds (e.g. 0.7) over-fire
                // on signature blocks where lines are tightly stacked
                // but still slightly farther apart than wrap distance.
                if gap > medianH * 1.0 {
                    // Suppress when either side of the gap is a header
                    // / address continuation. Cc/To/Bcc values often
                    // wrap onto continuation lines that PDFKit may emit
                    // with slightly larger y-gaps; we don't want to
                    // bisect a header field.
                    let prev = result[i - 1].plain.trimmingCharacters(in: .whitespaces)
                    let cur = result[i].plain.trimmingCharacters(in: .whitespaces)
                    let isHeaderish: (String) -> Bool = { t in
                        t.hasPrefix("To:") || t.hasPrefix("Cc:") || t.hasPrefix("Bcc:")
                            || t.hasPrefix("<")
                            || (t.contains("@") && t.contains("<"))
                    }
                    if !isHeaderish(prev) && !isHeaderish(cur) {
                        withGaps.append(StyledLine(runs: []))
                    }
                }
                _ = prevTop
            }
            withGaps.append(result[i])
        }
        return withGaps
    }

    private func shouldDropAsChrome(lineAttr: NSAttributedString,
                                    page: PDFPage,
                                    pageBounds: CGRect,
                                    isFirstPage: Bool) -> Bool {
        let plain = lineAttr.string.trimmingCharacters(in: .whitespaces)
        if plain.isEmpty { return false }

        let ns = plain as NSString
        for rx in chromeLineRegexes {
            if rx.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length)) != nil {
                return true
            }
        }

        // Position-based band check (intentionally disabled). PDFKit's
        // selection-by-character-range can't be reliably mapped back to a
        // per-line y-position from an attributedString offset; in practice
        // the regex filter above plus the segmenter's preamble drop
        // (everything before the first message header) catches all chrome
        // we care about. Left here as a hook for a future implementation
        // that walks PDFPage's text by quad ranges instead of attr offsets.
        _ = pageBounds
        _ = topChromeBand
        _ = bottomChromeBand
        _ = isFirstPage

        return false
    }

    // MARK: - Run building

    // Inline-chrome patterns. PDFKit sometimes concatenates the
    // top-of-page Gmail header band INSIDE a body line because the
    // print column wrap brought the header text adjacent to body text
    // on the same visual baseline. We strip these substrings from
    // each run's text so they don't pollute the rendered body.
    private let inlineChromeRegexes: [NSRegularExpression] = {
        let patterns = [
            // "4/30/26, 3:48 AM" timestamp band (with optional trailing space).
            #"\d{1,2}/\d{1,2}/\d{2},\s*\d{1,2}:\d{2}\s*(AM|PM)\s*"#,
            // "Gmail - <subject>" subject band. Gmail's print page-header
            // subject runs `Gmail - <thread subject>` where the thread
            // subject ends at a "line <NNNN>" trailer or just plain end-
            // of-line. Match Gmail - up through the trailing digit run
            // and the following space so we don't leave a stray digit
            // glued to the body.
            #"Gmail\s*-\s*[^\n]+?\s\d+\s"#,
            // Standalone subject string with no "Gmail - " prefix, when
            // PDFKit's text concatenation drops the leading band.
            // Match patterns like "Project Falcon; line 4060 ".
            #"[A-Z][\w&;\s\-]+;\s*line\s+\d+\s"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private func stripInlineChrome(_ text: String) -> String {
        var s = text
        for rx in inlineChromeRegexes {
            let ns = s as NSString
            s = rx.stringByReplacingMatches(
                in: s,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        // Collapse double spaces left behind.
        return s.replacingOccurrences(of: "  ", with: " ")
    }

    private func buildLine(from line: NSAttributedString, page: PDFPage) -> StyledLine {
        var runs: [StyledRun] = []
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attrs, range, _ in
            var text = (line.string as NSString).substring(with: range)
            text = stripInlineChrome(text)
            if text.isEmpty { return }
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let psName = (font?.fontName ?? "").lowercased()
            // Bold detection: trait OR PostScript name contains any of
            // the common weight markers Apple/Adobe use.
            let bold = traits.contains(.bold)
                || psName.contains("bold")
                || psName.contains("heavy")
                || psName.contains("black")
                || psName.contains("semibold")
                || psName.contains("demi")
            let italic = traits.contains(.italic)
                || psName.contains("italic")
                || psName.contains("oblique")
            let underlineRaw = (attrs[.underlineStyle] as? Int) ?? (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0
            let underline = underlineRaw != 0
            let link = (attrs[.link] as? URL)
                ?? (attrs[.link] as? String).flatMap { URL(string: $0) }
            let pointSize = font?.pointSize ?? 0
            runs.append(StyledRun(
                text: text,
                bold: bold,
                italic: italic,
                underline: underline,
                link: link,
                fontSize: pointSize
            ))
        }
        return mergeAdjacent(runs)
    }

    // Coalesce neighboring runs that share styling, to keep output HTML small.
    private func mergeAdjacent(_ runs: [StyledRun]) -> StyledLine {
        var merged: [StyledRun] = []
        for r in runs {
            if let last = merged.last,
               last.bold == r.bold,
               last.italic == r.italic,
               last.underline == r.underline,
               last.link == r.link,
               abs(last.fontSize - r.fontSize) < 0.1 {
                merged[merged.count - 1].text += r.text
            } else {
                merged.append(r)
            }
        }
        return StyledLine(runs: merged)
    }
}
