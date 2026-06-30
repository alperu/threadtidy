import Foundation
import Darwin
import CoreGraphics

// PDF text+style extractor using PDFium (Google Chrome's PDF engine).
//
// Why this exists: PDFKit's `attributedString` normalizes embedded fonts,
// dropping `-Bold` / `-Italic` suffixes from font names and not surfacing
// font weight at all. The result is plain "Helvetica" for both regular
// and bold runs in Gmail's print PDF, making it impossible to recover
// inline styling. PDFium's per-character API (`FPDFText_GetFontWeight`,
// `FPDFText_GetFontInfo`, `FPDFText_GetCharBox`) returns the truth and
// gives us correct Unicode in one indexed glyph stream — eliminating
// the chunk-to-character alignment problem we hit with CGPDFScanner.
//
// Distribution: we ship `libpdfium.dylib` (universal arm64+x86_64,
// Apache 2.0 / BSD) inside `src/libs/pdfium-mac/lib/`. Loaded at
// runtime via `dlopen` — no bridging header needed for the SwiftPM
// build path. The .app bundle build copies the dylib into
// `Contents/Frameworks/` and links runpath accordingly.
public final class PDFiumExtractor {

    public init() {}

    public enum ExtractError: Error, LocalizedError {
        case dylibNotFound
        case symbolMissing(String)
        case cannotOpen(URL)
        case empty
        public var errorDescription: String? {
            switch self {
            case .dylibNotFound: return "Could not load libpdfium.dylib"
            case .symbolMissing(let s): return "PDFium symbol missing: \(s)"
            case .cannotOpen(let u): return "PDFium failed to open PDF: \(u.lastPathComponent)"
            case .empty: return "PDF appears to contain no text"
            }
        }
    }

    public func extract(from url: URL) throws -> [StyledLine] {
        let pdfium = try PDFium.shared()

        guard let doc = url.path.withCString({ pdfium.loadDocument($0, nil) }) else {
            throw ExtractError.cannotOpen(url)
        }
        defer { pdfium.closeDocument(doc) }

        let pageCount = Int(pdfium.getPageCount(doc))

        // Side-channel: bullet circles AND underline strokes via
        // CGPDFScanner. PDFium's text API doesn't expose path drawings,
        // so vector primitives like bullets and drawn underlines still
        // come from this side-channel walker.
        let scans = BulletDetector().scan(url)
        var bulletsByPage: [Int: [BulletDetector.Bullet]] = [:]
        var underlinesByPage: [Int: [BulletDetector.Underline]] = [:]
        for (idx, page) in scans.enumerated() {
            bulletsByPage[idx] = page.bullets
            underlinesByPage[idx] = page.underlines
        }

        var allLines: [StyledLine] = []
        for pIdx in 0..<pageCount {
            let pageLines = extractPage(
                doc: doc, pageIndex: pIdx, pdfium: pdfium,
                bullets: bulletsByPage[pIdx] ?? [],
                underlines: underlinesByPage[pIdx] ?? []
            )
            allLines.append(contentsOf: pageLines)
        }
        guard !allLines.isEmpty else { throw ExtractError.empty }

        // Normalize indents: shift each line's indent relative to the
        // body's leftmost line (so flush-left body text gets indent 0).
        let xs = allLines.compactMap { line -> CGFloat? in
            line.plain.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line.indent
        }
        if let baseline = xs.min() {
            allLines = allLines.map { line in
                StyledLine(
                    runs: line.runs,
                    indent: max(0, line.indent - baseline),
                    isBullet: line.isBullet
                )
            }
        }

        // Normalize per-run font sizes against the document's dominant
        // body size. PDFium's `FPDFText_GetFontSize` returns the
        // intrinsic font size (pre-text-matrix-scale), which for Gmail
        // print PDFs is ~14 even though the rendered visual is 10.5pt.
        // We compute the most common size across non-empty runs and
        // map that to our target body size (TPPDFRenderer's bodyFontSize
        // = 12pt). Smaller/larger runs scale proportionally so relative
        // emphasis is preserved.
        let allSizes = allLines.flatMap { line in
            line.runs.compactMap { r -> CGFloat? in
                guard r.fontSize > 0, !r.text.isEmpty else { return nil }
                return r.fontSize
            }
        }
        if !allSizes.isEmpty {
            // Median-ish dominant size: use mode (most-frequent rounded).
            var counts: [Int: Int] = [:]
            for s in allSizes {
                counts[Int(s.rounded()), default: 0] += 1
            }
            let dominantInt = counts.max(by: { $0.value < $1.value })?.key ?? 14
            let dominant = CGFloat(dominantInt)
            let targetBody: CGFloat = 12
            let scale = targetBody / dominant
            allLines = allLines.map { line in
                let scaledRuns = line.runs.map { r -> StyledRun in
                    let newSize = r.fontSize > 0 ? r.fontSize * scale : 0
                    return StyledRun(
                        text: r.text, bold: r.bold, italic: r.italic,
                        underline: r.underline, link: r.link,
                        fontSize: newSize
                    )
                }
                return StyledLine(
                    runs: scaledRuns, indent: line.indent, isBullet: line.isBullet
                )
            }
        }

        return allLines
    }

    // MARK: - Per-page

    // Inline-chrome patterns. Same set we used in the PDFKit-based
    // extractor: Gmail print sometimes concatenates the page-header
    // band into the body text mid-line.
    private let inlineChromeRegexes: [NSRegularExpression] = {
        let patterns = [
            #"\d{1,2}/\d{1,2}/\d{2},\s*\d{1,2}:\d{2}\s*(AM|PM)\s*"#,
            #"Gmail\s*-\s*[^\n]+?\s\d+\s"#,
            #"[A-Z][\w&;\s\-]+;\s*line\s+\d+\s"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private let chromeLineRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^https://mail\.google\.com/.*$"#,
            #"^\d{1,2}/\d{1,2}/\d{2}, \d{1,2}:\d{2} (AM|PM)\s+Gmail.*"#,
            #"^Gmail\s*-\s*.+$"#,
            #"^\d{1,2}/\d{1,2}/\d{2},\s*\d{1,2}:\d{2}\s*(AM|PM)\s*$"#,
            #"^\d+/\d+$"#,
            "^[\u{2026}…][[:space:]]*\\d+/\\d+$",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // One per-character record extracted from PDFium.
    private struct CharRec {
        var unicode: UInt32
        var weight: Int32
        var italic: Bool
        var fontName: String
        var fontSize: CGFloat
        var x: CGFloat
        var y: CGFloat
        var height: CGFloat
    }

    private func extractPage(
        doc: PDFium.Document, pageIndex: Int, pdfium: PDFium,
        bullets: [BulletDetector.Bullet],
        underlines: [BulletDetector.Underline]
    ) -> [StyledLine] {
        guard let page = pdfium.loadPage(doc, Int32(pageIndex)) else { return [] }
        defer { pdfium.closePage(page) }
        guard let textPage = pdfium.textLoadPage(page) else { return [] }
        defer { pdfium.textClosePage(textPage) }

        let n = pdfium.textCountChars(textPage)
        if n <= 0 { return [] }

        // Walk chars; collect per-char metadata.
        var chars: [CharRec] = []
        chars.reserveCapacity(Int(n))
        var nameBuf = [UInt8](repeating: 0, count: 256)
        for i in 0..<n {
            let u = pdfium.textGetUnicode(textPage, i)
            // PDFium emits the literal "\r" / "\n" between visual lines
            // as separate chars. We use them as line breaks in the
            // grouping pass below, so don't drop them yet.
            let weight = pdfium.textGetFontWeight(textPage, i)
            var flags: Int32 = 0
            let nameLen = nameBuf.withUnsafeMutableBufferPointer { bp -> UInt in
                pdfium.textGetFontInfo(textPage, i, bp.baseAddress, UInt(bp.count), &flags)
            }
            var name = ""
            if nameLen > 0 {
                let used = min(Int(nameLen) - 1, nameBuf.count - 1)
                if used > 0 {
                    name = String(decoding: nameBuf[0..<used], as: UTF8.self)
                }
            }
            // Strip the "ABCDEF+" subset prefix that BaseFont names carry.
            if let plus = name.firstIndex(of: "+") {
                name = String(name[name.index(after: plus)...])
            }
            // Italic: PDF spec 1.7 §9.8.2 — bit 7 of font flags.
            let italic = (flags & 0x40) != 0
                || name.lowercased().contains("italic")
                || name.lowercased().contains("oblique")

            var left: Double = 0, right: Double = 0, bottom: Double = 0, top: Double = 0
            let _ = pdfium.textGetCharBox(textPage, i, &left, &right, &bottom, &top)

            var fontSize: Double = 0
            if let getSize = pdfium.textGetFontSize {
                fontSize = getSize(textPage, i)
            }

            chars.append(CharRec(
                unicode: u,
                weight: weight,
                italic: italic,
                fontName: name,
                fontSize: CGFloat(fontSize),
                x: CGFloat(left),
                y: CGFloat((bottom + top) / 2),
                height: CGFloat(top - bottom)
            ))
        }

        // Group chars into visual lines by y-position. PDFium emits
        // chars in reading order; chars on the same line share a y
        // baseline within a few pt.
        let lineGroups = groupCharsIntoLines(chars)

        // Build StyledLines with bullet matching, chrome filtering,
        // and y-gap paragraph break injection.
        var pageLines: [StyledLine] = []
        var prevYCenter: CGFloat? = nil
        // We need the typical *baseline-to-baseline* gap (NOT the
        // glyph cap-height) to know when a gap is a real blank line.
        // Cap height varies per glyph and is unreliable. Walk the
        // line groups in reading order, compute consecutive yCenter
        // deltas, take the median: that's "1 line's worth" of leading.
        // A blank line shows up as ≈ 2× that.
        let yCenters = lineGroups.compactMap { group -> CGFloat? in
            guard !group.isEmpty else { return nil }
            return group.map { ($0.y) }.reduce(0, +) / CGFloat(group.count)
        }
        var gaps: [CGFloat] = []
        for i in 1..<yCenters.count {
            let g = yCenters[i - 1] - yCenters[i]
            if g > 1 { gaps.append(g) }
        }
        gaps.sort()
        let medianGap: CGFloat = gaps.isEmpty ? 14 : gaps[gaps.count / 2]

        for group in lineGroups {
            let line = buildLine(from: group)
            let plain = line.plain.trimmingCharacters(in: .whitespaces)
            if plain.isEmpty {
                pageLines.append(StyledLine(runs: []))
                prevYCenter = nil
                continue
            }
            // Drop chrome lines.
            let plainNS = plain as NSString
            var dropped = false
            for rx in chromeLineRegexes {
                if rx.firstMatch(in: plain, range: NSRange(location: 0, length: plainNS.length)) != nil {
                    dropped = true
                    break
                }
            }
            if dropped { continue }

            // Bullet match: any detected bullet at the same y, to the left.
            let yCenter = line.runs.first.flatMap { _ in group.first?.y } ?? 0
            let lineH = group.first?.height ?? 12
            let isBullet = bullets.contains { b in
                abs(b.y - yCenter) <= max(lineH * 0.6, 4)
                    && b.x < line.indent
                    && (line.indent - b.x) < 40
            }

            // Y-gap paragraph break injection. PDF coords have y growing
            // upward; reading top-down means each subsequent line has a
            // smaller y. We compare baseline-to-baseline (yCenter delta)
            // against the page's *median* baseline-to-baseline gap. A
            // blank line shows up as ≈ 2× the median; we require ≥1.55×
            // so noisy wraps with slightly extended leading don't get
            // split mid-sentence (Gmail's web print sometimes nudges
            // line spacing on hard-broken short lines like
            // "assigned for" / "your hearing.").
            if let py = prevYCenter {
                let baselineGap = py - yCenter
                let prevText = pageLines.last?.plain.trimmingCharacters(in: .whitespaces) ?? ""
                let isHeaderish: (String) -> Bool = { t in
                    t.hasPrefix("To:") || t.hasPrefix("Cc:") || t.hasPrefix("Bcc:")
                        || t.hasPrefix("<")
                        || (t.contains("@") && t.contains("<"))
                }
                // Suppress the break when the *next* line starts with
                // a lowercase letter — that's a mid-sentence wrap
                // ("...will be / assigned for / your hearing.") and
                // joining it back into one paragraph reads correctly.
                let nextStartsLower = plain.first?.isLowercase == true
                if baselineGap > medianGap * 1.55
                    && !isHeaderish(prevText) && !isHeaderish(plain)
                    && !nextStartsLower
                {
                    pageLines.append(StyledLine(runs: []))
                }
            }
            prevYCenter = yCenter

            // Apply underline detection: any drawn underline whose y
            // sits just below this line's baseline (within ~3pt) and
            // whose x range overlaps a char's x maps to underline=true
            // for the runs covering that char range.
            let underlinedRuns = applyUnderlines(
                runs: line.runs,
                chars: group,
                lineY: yCenter,
                lineH: lineH,
                underlines: underlines
            )

            let withBullet = StyledLine(
                runs: underlinedRuns, indent: line.indent, isBullet: isBullet
            )
            pageLines.append(withBullet)
        }
        return pageLines
    }

    // For each detected underline path on this page, find the chars
    // (and therefore runs) at the line's y whose x falls inside the
    // underline's [xLeft, xRight]. Underlines sit just BELOW the text
    // baseline (a pt or two below the bottom of the glyph), so we
    // accept underlines whose y is up to ~3pt below the line's center.
    private func applyUnderlines(
        runs: [StyledRun],
        chars: [CharRec],
        lineY: CGFloat,
        lineH: CGFloat,
        underlines: [BulletDetector.Underline]
    ) -> [StyledRun] {
        if runs.isEmpty || chars.isEmpty || underlines.isEmpty { return runs }
        let yMin = lineY - lineH * 1.2     // underline can sit a bit below
        let yMax = lineY                   // not above mid-line
        let active = underlines.filter { $0.y >= yMin && $0.y <= yMax }
        if active.isEmpty { return runs }

        // For each char, decide if it's underlined based on x and on
        // any active underline span.
        let underlinedFlags: [Bool] = chars.map { c in
            for u in active {
                if c.x >= u.xLeft - 1 && c.x <= u.xRight + 1 {
                    return true
                }
            }
            return false
        }
        // The chars[] and runs[] don't share an index 1:1 because
        // build/strip-chrome may have removed some chars. Map by
        // walking forward through both: each run's text length pulls
        // that many chars from the front of `underlinedFlags`.
        var newRuns: [StyledRun] = []
        var cursor = 0
        for r in runs {
            let len = r.text.count
            if cursor >= underlinedFlags.count {
                newRuns.append(r)
                cursor += len
                continue
            }
            let end = min(cursor + len, underlinedFlags.count)
            // Split this run wherever the underlined flag flips so we
            // don't end up underlining whole bold runs when the source
            // only underlined part.
            var subStart = cursor
            var subFlag = underlinedFlags[cursor]
            var subText = ""
            let runChars = Array(r.text)
            for i in 0..<(end - cursor) {
                let flag = underlinedFlags[cursor + i]
                if flag == subFlag {
                    subText.append(runChars[i])
                } else {
                    if !subText.isEmpty {
                        newRuns.append(StyledRun(
                            text: subText, bold: r.bold, italic: r.italic,
                            underline: subFlag, link: r.link, fontSize: r.fontSize
                        ))
                    }
                    subStart = cursor + i
                    subFlag = flag
                    subText = String(runChars[i])
                }
            }
            if !subText.isEmpty {
                newRuns.append(StyledRun(
                    text: subText, bold: r.bold, italic: r.italic,
                    underline: subFlag, link: r.link, fontSize: r.fontSize
                ))
            }
            // Tail of run beyond chars[]: emit verbatim.
            if end < cursor + len {
                let tail = String(runChars[(end - cursor)...])
                newRuns.append(StyledRun(
                    text: tail, bold: r.bold, italic: r.italic,
                    underline: false, link: r.link, fontSize: r.fontSize
                ))
            }
            cursor += len
            _ = subStart
        }
        return newRuns
    }

    // MARK: - Char grouping

    private func groupCharsIntoLines(_ chars: [CharRec]) -> [[CharRec]] {
        var lines: [[CharRec]] = []
        var current: [CharRec] = []
        for c in chars {
            // Hard newlines from PDFium (\r, \n) close the current line.
            if c.unicode == 10 || c.unicode == 13 {
                if !current.isEmpty { lines.append(current); current = [] }
                continue
            }
            // Skip null / control codepoints below space, except tab.
            if c.unicode != 9 && c.unicode < 0x20 { continue }
            current.append(c)
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func buildLine(from chars: [CharRec]) -> StyledLine {
        // Strip leading inline-chrome substrings before run-grouping.
        // We rebuild a simple Unicode string, run inline-chrome regex,
        // then rebuild a chars[] aligned to the cleaned string.
        let plain = chars.compactMap {
            Unicode.Scalar($0.unicode).map { String($0) }
        }.joined()
        let cleaned = stripInlineChrome(plain)
        // If chrome was stripped, drop the chars accordingly.
        let trimmedChars: [CharRec]
        if cleaned.count == chars.count {
            trimmedChars = chars
        } else {
            // Conservative: re-emit chars only for the cleaned text by
            // matching the cleaned string against the original chars.
            // Walk both; advance original on match, advance cleaned on
            // each char.
            var result: [CharRec] = []
            var ci = cleaned.startIndex
            for c in chars {
                if ci >= cleaned.endIndex { break }
                let scalar = Unicode.Scalar(c.unicode)
                let cleanedChar = cleaned[ci]
                if let s = scalar, String(s) == String(cleanedChar) {
                    result.append(c)
                    ci = cleaned.index(after: ci)
                }
            }
            trimmedChars = result.isEmpty ? chars : result
        }

        // Group consecutive chars with the same styling into runs.
        var runs: [StyledRun] = []
        var run: (text: String, bold: Bool, italic: Bool, font: String, size: CGFloat)? = nil
        for c in trimmedChars {
            guard let scalar = Unicode.Scalar(c.unicode) else { continue }
            // Style detection: trust the font NAME when it announces
            // Bold or Italic — the name is authoritative. Only fall
            // back to the weight threshold when the name says neither
            // (some fonts encode weight without a -Bold suffix).
            // PDFium's `FPDFText_GetFontWeight` is unreliable on Gmail
            // PDFs: Arial-Italic returns weight 1088 (between regular
            // 435 and bold 1296), which would falsely trip a >= 600
            // bold threshold for italic-only spans like "Family Docket
            // Manager".
            let nameLower = c.fontName.lowercased()
            let nameBold = nameLower.contains("bold")
                || nameLower.contains("heavy")
                || nameLower.contains("black")
                || nameLower.contains("semibold")
                || nameLower.contains("demi")
            let nameItalic = nameLower.contains("italic")
                || nameLower.contains("oblique")
            let bold: Bool
            let italic: Bool
            if nameBold || nameItalic {
                bold = nameBold
                italic = nameItalic
            } else {
                bold = c.weight >= 600
                italic = c.italic
            }
            let key = (bold, italic, c.fontName, c.fontSize)
            if var current = run {
                let curKey = (current.bold, current.italic, current.font, current.size)
                if curKey == key {
                    current.text.append(Character(scalar))
                    run = current
                    continue
                } else {
                    runs.append(StyledRun(
                        text: current.text,
                        bold: current.bold, italic: current.italic,
                        underline: false, link: nil,
                        fontSize: current.size
                    ))
                }
            }
            run = (text: String(Character(scalar)), bold: bold, italic: italic,
                   font: c.fontName, size: c.fontSize)
        }
        if let r = run {
            runs.append(StyledRun(
                text: r.text, bold: r.bold, italic: r.italic,
                underline: false, link: nil, fontSize: r.size
            ))
        }
        let indent = trimmedChars.first?.x ?? 0
        return StyledLine(runs: runs, indent: indent)
    }

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
        return s.replacingOccurrences(of: "  ", with: " ")
    }
}

// MARK: - PDFium dynamic-link wrapper

private final class PDFium {
    public typealias Document = OpaquePointer
    public typealias Page = OpaquePointer
    public typealias TextPage = OpaquePointer

    typealias Init_t = @convention(c) () -> Void
    typealias LoadDocument_t = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Document?
    typealias CloseDocument_t = @convention(c) (Document) -> Void
    typealias GetPageCount_t = @convention(c) (Document) -> Int32
    typealias LoadPage_t = @convention(c) (Document, Int32) -> Page?
    typealias ClosePage_t = @convention(c) (Page) -> Void
    typealias TextLoadPage_t = @convention(c) (Page) -> TextPage?
    typealias TextClosePage_t = @convention(c) (TextPage) -> Void
    typealias TextCountChars_t = @convention(c) (TextPage) -> Int32
    typealias TextGetUnicode_t = @convention(c) (TextPage, Int32) -> UInt32
    typealias TextGetFontWeight_t = @convention(c) (TextPage, Int32) -> Int32
    typealias TextGetFontInfo_t = @convention(c) (TextPage, Int32, UnsafeMutableRawPointer?, UInt, UnsafeMutablePointer<Int32>?) -> UInt
    typealias TextGetCharBox_t = @convention(c) (TextPage, Int32, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Int32
    typealias TextGetFontSize_t = @convention(c) (TextPage, Int32) -> Double

    private let handle: UnsafeMutableRawPointer
    let initLibrary: Init_t
    let loadDocument: LoadDocument_t
    let closeDocument: CloseDocument_t
    let getPageCount: GetPageCount_t
    let loadPage: LoadPage_t
    let closePage: ClosePage_t
    let textLoadPage: TextLoadPage_t
    let textClosePage: TextClosePage_t
    let textCountChars: TextCountChars_t
    let textGetUnicode: TextGetUnicode_t
    let textGetFontWeight: TextGetFontWeight_t
    let textGetFontInfo: TextGetFontInfo_t
    let textGetCharBox: TextGetCharBox_t
    let textGetFontSize: TextGetFontSize_t?

    private init(handle: UnsafeMutableRawPointer) throws {
        func bind<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else {
                throw PDFiumExtractor.ExtractError.symbolMissing(name)
            }
            return unsafeBitCast(p, to: type)
        }
        self.handle = handle
        self.initLibrary = try bind("FPDF_InitLibrary", Init_t.self)
        self.loadDocument = try bind("FPDF_LoadDocument", LoadDocument_t.self)
        self.closeDocument = try bind("FPDF_CloseDocument", CloseDocument_t.self)
        self.getPageCount = try bind("FPDF_GetPageCount", GetPageCount_t.self)
        self.loadPage = try bind("FPDF_LoadPage", LoadPage_t.self)
        self.closePage = try bind("FPDF_ClosePage", ClosePage_t.self)
        self.textLoadPage = try bind("FPDFText_LoadPage", TextLoadPage_t.self)
        self.textClosePage = try bind("FPDFText_ClosePage", TextClosePage_t.self)
        self.textCountChars = try bind("FPDFText_CountChars", TextCountChars_t.self)
        self.textGetUnicode = try bind("FPDFText_GetUnicode", TextGetUnicode_t.self)
        self.textGetFontWeight = try bind("FPDFText_GetFontWeight", TextGetFontWeight_t.self)
        self.textGetFontInfo = try bind("FPDFText_GetFontInfo", TextGetFontInfo_t.self)
        self.textGetCharBox = try bind("FPDFText_GetCharBox", TextGetCharBox_t.self)
        // Optional symbol; older builds may not have it.
        if let p = dlsym(handle, "FPDFText_GetFontSize") {
            self.textGetFontSize = unsafeBitCast(p, to: TextGetFontSize_t.self)
        } else {
            self.textGetFontSize = nil
        }
        self.initLibrary()
    }

    private static var instance: PDFium?

    static func shared() throws -> PDFium {
        if let i = instance { return i }
        // Search candidates: bundled framework, repo path (for SwiftPM
        // tests / development), and DYLD-resolvable name.
        let candidates: [String] = [
            // Repo path used during development & by the SwiftPM test driver.
            "/Users/alper/Code/ThreadTidy/src/libs/pdfium-mac/lib/libpdfium.dylib",
            // .app-bundle path: Contents/Frameworks/libpdfium.dylib.
            Bundle.main.bundlePath + "/Contents/Frameworks/libpdfium.dylib",
            // DYLD resolution.
            "libpdfium.dylib",
        ]
        for path in candidates {
            if let h = dlopen(path, RTLD_NOW) {
                let p = try PDFium(handle: h)
                instance = p
                return p
            }
        }
        throw PDFiumExtractor.ExtractError.dylibNotFound
    }
}
