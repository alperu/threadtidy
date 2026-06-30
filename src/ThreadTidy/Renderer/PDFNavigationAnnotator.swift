import Foundation
import PDFKit
import CryptoKit

// Post-render pass: walks the produced PDF and adds clickable link
// annotations on every ordinal occurrence ("[14]", "14.", "Message 14
// of 28") so a court reader can jump from the Index page or strip
// indicator to the corresponding email's page.
//
// We also stamp a per-thread UID into the PDF's metadata
// (PDFDocumentAttribute.subject) so multiple cleaned threads can be
// embedded into the same composite court filing without collision.
public enum PDFNavigationAnnotator {

    public static func annotate(url: URL, thread: Thread) {
        guard let doc = PDFDocument(url: url) else { return }
        let uid = threadUID(thread: thread)

        // Stamp UID into PDF metadata.
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.subjectAttribute] = "thread:\(uid)"
        doc.documentAttributes = attrs

        // Map message ordinal → page index of the email's heading.
        // We locate the "N. SenderName" string and use the FIRST page
        // where that exact string appears (the others are quoted
        // mentions in the index/strip).
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

        // 1) Bracketed "[N]" (current-marker on the strip) — link
        //    everywhere it appears, jumping to email N's page.
        // 2) "N." (row leader on the Index of Communications table) —
        //    link to email N's page (skip the heading page itself).
        for m in thread.messages {
            guard let target = headingPage[m.index],
                  let dest = makeDestination(doc: doc, pageIndex: target) else { continue }
            for needle in ["[\(m.index)]", "\(m.index)."] {
                for sel in doc.findString(needle, withOptions: .literal) {
                    for page in sel.pages {
                        if doc.index(for: page) == target,
                           needle == "\(m.index)." { continue }
                        let bounds = sel.bounds(for: page)
                        if bounds.isNull || bounds.isEmpty { continue }
                        let padded = bounds.insetBy(dx: -1.5, dy: -1.5)
                        let ann = PDFAnnotation(
                            bounds: padded, forType: .link, withProperties: nil
                        )
                        ann.action = PDFActionGoTo(destination: dest)
                        page.addAnnotation(ann)
                    }
                }
            }
        }

        // 4) "Index" jump-back at the head of every strip indicator
        //    (links to page 1, the Index of Communications page).
        if let indexDest = makeDestination(doc: doc, pageIndex: 0) {
            for sel in doc.findString("Index", withOptions: .literal) {
                guard let p = sel.pages.first else { continue }
                let idx = doc.index(for: p)
                if idx == 0 { continue }   // don't self-link the heading on page 1
                let b = sel.bounds(for: p)
                if b.minY < 700 { continue }       // only top-of-page strip occurrences
                if b.height > 14 { continue }      // skip the full "Index of..." heading
                let padded = b.insetBy(dx: -2, dy: -2)
                let ann = PDFAnnotation(bounds: padded, forType: .link, withProperties: nil)
                ann.action = PDFActionGoTo(destination: indexDest)
                p.addAnnotation(ann)
            }
        }

        // 3a) Index page bare ordinals — the Index of Communications
        //     table shows "N" (no period) in the leftmost No. column.
        //     We detect Index pages by looking for the section heading,
        //     then restrict bare-number matches to the leftmost column
        //     (x < 120pt) of those pages.
        var indexPages: Set<Int> = []
        for sel in doc.findString("Index of Communications", withOptions: .literal) {
            for p in sel.pages { indexPages.insert(doc.index(for: p)) }
        }
        // The Index table can span past its heading page; include any
        // following pages until we hit the first email's heading.
        if let firstIdx = indexPages.min() {
            let firstEmailPage = headingPage[1] ?? doc.pageCount
            for p in firstIdx..<firstEmailPage { indexPages.insert(p) }
        }
        for m in thread.messages {
            guard let target = headingPage[m.index],
                  let dest = makeDestination(doc: doc, pageIndex: target) else { continue }
            for sel in doc.findString("\(m.index)", withOptions: .literal) {
                guard let p = sel.pages.first else { continue }
                let idx = doc.index(for: p)
                guard indexPages.contains(idx) else { continue }
                let b = sel.bounds(for: p)
                // The Index table's No. column ends around x=68pt
                // (6% of ~540pt content, plus the page's left margin
                // of 36pt). 70pt cleanly excludes Date column digits
                // like "1" inside "8:12 AM" that would otherwise
                // pile up overlapping links and override the row-1
                // No. cell click target.
                if b.minX > 70 { continue }
                // Single-cell digits are ~14pt tall; row 1's "1" is
                // slightly taller (14.96pt). Title-band matches at the
                // top of the page are ~28pt tall — well above this.
                // 18pt cleanly separates table digits from the title.
                if b.height > 18 { continue }
                let padded = b.insetBy(dx: -2, dy: -2)
                let ann = PDFAnnotation(
                    bounds: padded, forType: .link, withProperties: nil
                )
                ann.action = PDFActionGoTo(destination: dest)
                p.addAnnotation(ann)
            }
        }

        // 3b) UNBRACKETED ordinals on the strip indicator — every
        //    "1 · 2 · 3 · …" number should be clickable. We restrict
        //    detection to the strip's y-band on each page (located by
        //    finding the "Message N of M" trailer) so we don't link
        //    every digit elsewhere on the page.
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx) else { continue }
            let total = thread.messages.count
            let trailerRegex = "Message \\d+ of \(total)"
            // Find the trailer's bounds → that's the strip's y-band.
            let trailerSels = doc.findString("of \(total)", withOptions: .literal)
            var stripBounds: CGRect = .null
            for sel in trailerSels {
                if let p = sel.pages.first, doc.index(for: p) == pageIdx {
                    let b = sel.bounds(for: page)
                    if !b.isNull { stripBounds = b; break }
                }
            }
            guard !stripBounds.isNull else { continue }
            // Expand the y-band to cover the entire strip horizontally
            // (from page left edge to right edge, at the strip's y).
            let pageBounds = page.bounds(for: .mediaBox)
            let stripBand = CGRect(
                x: pageBounds.minX,
                y: stripBounds.minY - 2,
                width: pageBounds.width,
                height: stripBounds.height + 4
            )
            _ = trailerRegex
            // Find the trailer's left edge ("Message" word) on this
            // page so we can exclude any digit hyperlink that falls
            // inside the "Message N of M" suffix — we don't want the
            // page-number "N" or total-count "M" inside the trailer
            // text to become click targets.
            var trailerLeftX: CGFloat = .greatestFiniteMagnitude
            for sel in doc.findString("Message", withOptions: .literal) {
                if let p = sel.pages.first, doc.index(for: p) == pageIdx {
                    let b = sel.bounds(for: page)
                    if !b.isNull && stripBand.intersects(b) {
                        trailerLeftX = min(trailerLeftX, b.minX)
                    }
                }
            }
            // For each message ordinal N, find its plain "N" occurrence
            // ON THIS PAGE within the strip band. We collect candidates
            // first (rather than adding annotations directly), then
            // dedupe by spatial overlap below — `findString("1")` also
            // matches the "1" inside "10", "11", …, "19", and "21",
            // creating overlapping link annotations on the same digit.
            // Desktop PDFKit usually picks the larger annotation, but
            // mobile viewers (iOS PDFKit, Quick Look on iPad) sometimes
            // hit-test the substring annotation and jump to the wrong
            // email (tapping "21" lands on email 1).
            struct Candidate { let bounds: CGRect; let dest: PDFDestination; let msg: Int }
            var candidates: [Candidate] = []
            for m in thread.messages {
                guard let target = headingPage[m.index],
                      let dest = makeDestination(doc: doc, pageIndex: target) else { continue }
                if target == pageIdx { continue }   // don't self-link
                let needle = "\(m.index)"
                for sel in doc.findString(needle, withOptions: .literal) {
                    guard let p = sel.pages.first, doc.index(for: p) == pageIdx else { continue }
                    let b = sel.bounds(for: page)
                    if !stripBand.intersects(b) { continue }
                    if b.minX >= trailerLeftX - 1 { continue }
                    if b.height > 12 { continue }
                    candidates.append(Candidate(bounds: b, dest: dest, msg: m.index))
                }
            }

            // Dedupe by overlap. Sort widest-first so multi-digit
            // matches ("21") are accepted before any of their digit
            // substrings ("2", "1"). For each candidate, drop it if
            // it sits mostly inside an already-accepted rect — that
            // rect IS the more specific multi-digit match, and the
            // candidate is its substring. Threshold 50% of the
            // candidate's area covered by the existing rect is
            // enough to catch substrings while permitting the
            // legitimate standalone "1"…"9" elsewhere on the strip.
            candidates.sort { $0.bounds.width > $1.bounds.width }
            var kept: [Candidate] = []
            for c in candidates {
                let cArea = max(1, c.bounds.width * c.bounds.height)
                let dominated = kept.contains { existing in
                    let inter = existing.bounds.intersection(c.bounds)
                    if inter.isNull || inter.isEmpty { return false }
                    return (inter.width * inter.height) / cArea > 0.5
                }
                if !dominated { kept.append(c) }
            }
            for c in kept {
                let padded = c.bounds.insetBy(dx: -1.5, dy: -1.5)
                let ann = PDFAnnotation(
                    bounds: padded, forType: .link, withProperties: nil
                )
                ann.action = PDFActionGoTo(destination: c.dest)
                page.addAnnotation(ann)
            }
        }

        // Persist.
        _ = doc.write(to: url)
    }

    // 8-character base36 UID, stable per (subject, first message date).
    public static func threadUID(thread: Thread) -> String {
        let subject = thread.subject
        let date = thread.messages.first?.date ?? ""
        let input = "\(subject)|\(date)"
        let hash = SHA256.hash(data: Data(input.utf8))
        // Take the first 5 bytes (40 bits) → base36 → up to 8 chars.
        var n: UInt64 = 0
        for byte in hash.prefix(5) {
            n = (n << 8) | UInt64(byte)
        }
        var s = ""
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if n == 0 { return String(repeating: "0", count: 8) }
        var x = n
        while x > 0 {
            s = String(alphabet[Int(x % 36)]) + s
            x /= 36
        }
        // Pad/trim to exactly 8 chars.
        while s.count < 8 { s = "0" + s }
        if s.count > 8 { s = String(s.suffix(8)) }
        return s
    }

    private static func makeDestination(doc: PDFDocument, pageIndex: Int) -> PDFDestination? {
        guard let page = doc.page(at: pageIndex) else { return nil }
        // Top of page in PDF coords (y grows upward). Use a y just
        // below the page top so the heading sits at the TOP of the
        // viewer's window when navigated.
        let bounds = page.bounds(for: .mediaBox)
        let topY = bounds.maxY - 4
        return PDFDestination(page: page, at: CGPoint(x: 0, y: topY))
    }
}
