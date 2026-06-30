import Foundation
import CoreGraphics
import Quartz

// Walks each PDF page's content stream via CGPDFScanner. Returns BOTH:
//   - bullet-circle positions (Gmail print emits "•" as a vector disc),
//   - per-text-show positions (font name, x, y) so we can derive line
//     indents authoritatively from the content stream rather than from
//     PDFKit's high-level selection bounds, which sometimes round.
public final class BulletDetector {

    public struct Bullet: Equatable {
        public let pageIndex: Int       // 0-indexed
        public let x: CGFloat
        public let y: CGFloat
        public let radius: CGFloat
    }

    public struct TextChunk {
        public let pageIndex: Int
        public let x: CGFloat           // PDF-space; origin bottom-left
        public let y: CGFloat
        public let fontName: String
        public let text: String
    }

    // A short, thin, near-horizontal stroked path — almost always a
    // text underline drawn below a glyph run by the source PDF
    // (Gmail/web print pipelines emit underlines this way rather than
    // as a font attribute).
    public struct Underline: Equatable {
        public let pageIndex: Int
        public let xLeft: CGFloat
        public let xRight: CGFloat
        public let y: CGFloat
    }

    public struct PageScan {
        public let bullets: [Bullet]
        public let chunks: [TextChunk]
        public let underlines: [Underline]
    }

    public init() {}

    public func scan(_ url: URL) -> [PageScan] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        var pages: [PageScan] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else {
                pages.append(PageScan(bullets: [], chunks: [], underlines: []))
                continue
            }
            pages.append(scanPage(page, pageIndex: i - 1))
        }
        return pages
    }

    // Convenience: just the bullets (used by callers that don't need
    // the text chunks).
    public func detect(in url: URL) -> [Bullet] {
        scan(url).flatMap(\.bullets)
    }

    // MARK: - Per-page scanning

    private func scanPage(_ page: CGPDFPage, pageIndex: Int) -> PageScan {
        let stream = CGPDFContentStreamCreateWithPage(page)
        guard let table = CGPDFOperatorTableCreate() else {
            return PageScan(bullets: [], chunks: [], underlines: [])
        }
        let context = ScanContext(pageIndex: pageIndex)
        // Resolve Tf font resource aliases (like "F124") to their
        // PostScript BaseFont names ("Helvetica-Bold"). PDFKit's
        // attributedString aggressively normalizes fonts and drops the
        // -Bold / -Italic suffixes, so this is the only reliable way
        // to know whether a glyph is bold or italic in source.
        context.aliasToBaseFont = loadBaseFontMap(for: page)
        let infoPtr = Unmanaged.passUnretained(context).toOpaque()
        installCallbacks(on: table)
        let scanner = CGPDFScannerCreate(stream, table, infoPtr)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
        return PageScan(
            bullets: context.bullets,
            chunks: context.chunks,
            underlines: context.underlines
        )
    }

    private func loadBaseFontMap(for page: CGPDFPage) -> [String: String] {
        guard let pageDict = page.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef? = nil
        CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources)
        guard let resDict = resources else { return [:] }
        var fonts: CGPDFDictionaryRef? = nil
        CGPDFDictionaryGetDictionary(resDict, "Font", &fonts)
        guard let fontsDict = fonts else { return [:] }

        final class Box { var map: [String: String] = [:] }
        let box = Box()
        let info = Unmanaged.passUnretained(box).toOpaque()
        CGPDFDictionaryApplyFunction(fontsDict, { keyPtr, valuePtr, infoPtr in
            guard let infoPtr = infoPtr else { return }
            let alias = String(cString: keyPtr)
            var fontDict: CGPDFDictionaryRef? = nil
            if !CGPDFObjectGetValue(valuePtr, .dictionary, &fontDict) { return }
            guard let fd = fontDict else { return }
            var baseFont: UnsafePointer<Int8>? = nil
            if CGPDFDictionaryGetName(fd, "BaseFont", &baseFont), let bf = baseFont {
                let raw = String(cString: bf)
                // BaseFont names are often prefixed with "ABCDEF+"
                // (PDF font subset tag) — strip it.
                let plain: String
                if let plus = raw.firstIndex(of: "+") {
                    plain = String(raw[raw.index(after: plus)...])
                } else {
                    plain = raw
                }
                let box = Unmanaged<Box>.fromOpaque(infoPtr).takeUnretainedValue()
                box.map[alias] = plain
            }
        }, info)
        return box.map
    }

    // MARK: - Operator callbacks

    private func installCallbacks(on table: CGPDFOperatorTableRef) {
        // ---- Path construction ----
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let info = info,
                  let y = scanPopNumber(scanner),
                  let x = scanPopNumber(scanner) else { return }
            ScanContext.from(info).beginPath(at: CGPoint(x: x, y: y))
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let info = info,
                  let y = scanPopNumber(scanner),
                  let x = scanPopNumber(scanner) else { return }
            ScanContext.from(info).addLine(to: CGPoint(x: x, y: y))
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let info = info,
                  let y3 = scanPopNumber(scanner),
                  let x3 = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner) else { return }
            ScanContext.from(info).addLine(to: CGPoint(x: x3, y: y3))
        }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            guard let info = info,
                  let y3 = scanPopNumber(scanner),
                  let x3 = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner) else { return }
            ScanContext.from(info).addLine(to: CGPoint(x: x3, y: y3))
        }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            guard let info = info,
                  let y3 = scanPopNumber(scanner),
                  let x3 = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner),
                  let _  = scanPopNumber(scanner) else { return }
            ScanContext.from(info).addLine(to: CGPoint(x: x3, y: y3))
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let info = info,
                  let h = scanPopNumber(scanner),
                  let w = scanPopNumber(scanner),
                  let y = scanPopNumber(scanner),
                  let x = scanPopNumber(scanner) else { return }
            ScanContext.from(info).addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).closePath()
        }
        for op in ["f", "F", "f*", "B", "b", "B*", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let info = info else { return }
                ScanContext.from(info).finishPath(filled: true)
            }
        }
        // S/s: stroke path (potential underline). n: end path no-op
        // (must clear accumulator without detection).
        for op in ["s", "S"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let info = info else { return }
                ScanContext.from(info).finishPath(filled: false)
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).discardPath()
        }

        // ---- Graphics-state matrix tracking ----
        // cm: concat current transformation matrix (a b c d e f cm)
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info = info,
                  let f = scanPopNumber(scanner),
                  let e = scanPopNumber(scanner),
                  let d = scanPopNumber(scanner),
                  let c = scanPopNumber(scanner),
                  let b = scanPopNumber(scanner),
                  let a = scanPopNumber(scanner) else { return }
            let m = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
            ScanContext.from(info).concatCTM(m)
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).pushGState()
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).popGState()
        }

        // ---- Text-state tracking ----
        // BT/ET: begin/end text object (resets text matrix)
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).beginText()
        }
        CGPDFOperatorTableSetCallback(table, "ET") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).endText()
        }
        // Tf: font + size (font size_in_user_units Tf)
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let info = info,
                  let size = scanPopNumber(scanner) else { return }
            // The font operand is a name token; CGPDFScanner exposes
            // names via CGPDFScannerPopName.
            var rawName: UnsafePointer<Int8>? = nil
            if CGPDFScannerPopName(scanner, &rawName), let r = rawName {
                let name = String(cString: r)
                ScanContext.from(info).setFont(name: name, size: size)
            } else {
                ScanContext.from(info).setFont(name: "", size: size)
            }
        }
        // Tm: set text matrix (a b c d e f Tm)
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let info = info,
                  let f = scanPopNumber(scanner),
                  let e = scanPopNumber(scanner),
                  let d = scanPopNumber(scanner),
                  let c = scanPopNumber(scanner),
                  let b = scanPopNumber(scanner),
                  let a = scanPopNumber(scanner) else { return }
            ScanContext.from(info).setTextMatrix(
                CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
            )
        }
        // Td: move text position (tx ty Td)
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let info = info,
                  let ty = scanPopNumber(scanner),
                  let tx = scanPopNumber(scanner) else { return }
            ScanContext.from(info).moveText(tx: tx, ty: ty, setLeading: false)
        }
        // TD: like Td but also sets text leading
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let info = info,
                  let ty = scanPopNumber(scanner),
                  let tx = scanPopNumber(scanner) else { return }
            ScanContext.from(info).moveText(tx: tx, ty: ty, setLeading: true)
        }
        // T*: move to start of next line
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let info = info else { return }
            ScanContext.from(info).nextLine()
        }
        // TL: set text leading
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let info = info,
                  let l = scanPopNumber(scanner) else { return }
            ScanContext.from(info).setLeading(l)
        }
        // Tj: show text (string Tj)
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let info = info else { return }
            if let s = scanPopString(scanner) {
                ScanContext.from(info).showText(s)
            }
        }
        // TJ: show text array; alternates strings and number adjustments
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let info = info else { return }
            var arrayRef: CGPDFArrayRef? = nil
            if CGPDFScannerPopArray(scanner, &arrayRef), let arr = arrayRef {
                let n = CGPDFArrayGetCount(arr)
                var combined = ""
                for idx in 0..<n {
                    var stringRef: CGPDFStringRef? = nil
                    if CGPDFArrayGetString(arr, idx, &stringRef), let sref = stringRef {
                        combined += scanString(from: sref)
                    }
                }
                if !combined.isEmpty {
                    ScanContext.from(info).showText(combined)
                }
            }
        }
        // ' (apostrophe): move to next line and show string (string ')
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let info = info else { return }
            ScanContext.from(info).nextLine()
            if let s = scanPopString(scanner) {
                ScanContext.from(info).showText(s)
            }
        }
        // " : a_w a_c string  → set word/char spacing, next line, show
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let info = info,
                  let _ = scanPopNumber(scanner),
                  let _ = scanPopNumber(scanner) else { return }
            ScanContext.from(info).nextLine()
            if let s = scanPopString(scanner) {
                ScanContext.from(info).showText(s)
            }
        }
    }

}

// MARK: - File-scope C-callable helpers

// These live at file scope so the @convention(c) closures inside
// `installCallbacks(on:)` can resolve them without trying to capture
// `self`.
private func scanPopNumber(_ scanner: CGPDFScannerRef) -> CGFloat? {
    var v: CGPDFReal = 0
    if CGPDFScannerPopNumber(scanner, &v) { return CGFloat(v) }
    var i: CGPDFInteger = 0
    if CGPDFScannerPopInteger(scanner, &i) { return CGFloat(i) }
    return nil
}
private func scanPopString(_ scanner: CGPDFScannerRef) -> String? {
    var sref: CGPDFStringRef? = nil
    guard CGPDFScannerPopString(scanner, &sref), let s = sref else { return nil }
    return scanString(from: s)
}
private func scanString(from s: CGPDFStringRef) -> String {
    if let cf = CGPDFStringCopyTextString(s) { return cf as String }
    let len = CGPDFStringGetLength(s)
    if let bytes = CGPDFStringGetBytePtr(s) {
        let data = Data(bytes: bytes, count: len)
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
    return ""
}

// MARK: - ScanContext

private final class ScanContext {
    let pageIndex: Int
    var aliasToBaseFont: [String: String] = [:]

    // Output
    var bullets: [BulletDetector.Bullet] = []
    var chunks: [BulletDetector.TextChunk] = []
    var underlines: [BulletDetector.Underline] = []

    // Path accumulator
    var pathPoints: [CGPoint] = []
    var pathStart: CGPoint?

    // Graphics state (CTM stack)
    var ctmStack: [CGAffineTransform] = [.identity]
    var ctm: CGAffineTransform { ctmStack.last ?? .identity }

    // Text state
    var inText: Bool = false
    var textMatrix: CGAffineTransform = .identity
    var lineMatrix: CGAffineTransform = .identity
    var leading: CGFloat = 0
    var fontName: String = ""
    var fontSize: CGFloat = 0

    init(pageIndex: Int) { self.pageIndex = pageIndex }

    static func from(_ info: UnsafeMutableRawPointer) -> ScanContext {
        Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
    }

    // ---- Path operators ----
    func beginPath(at p: CGPoint) { pathPoints = [p]; pathStart = p }
    func addLine(to p: CGPoint) {
        if pathPoints.isEmpty, let s = pathStart { pathPoints.append(s) }
        pathPoints.append(p)
    }
    func addRect(_ r: CGRect) {
        pathPoints = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY),
        ]
    }
    func closePath() { if let s = pathStart { pathPoints.append(s) } }
    func discardPath() { pathPoints = []; pathStart = nil }

    func finishPath(filled: Bool) {
        defer { pathPoints = []; pathStart = nil }
        guard !pathPoints.isEmpty else { return }
        // Apply current CTM to path points before measuring.
        let userPts = pathPoints.map { $0.applying(ctm) }
        let xs = userPts.map(\.x); let ys = userPts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        let w = maxX - minX, h = maxY - minY

        // ---- Bullet circle: small, square-ish, FILLED ----
        if filled, w > 0.5, w < 14, h > 0.5, h < 14 {
            let aspect = max(w, h) / max(0.001, min(w, h))
            if aspect < 1.7 {
                let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
                let r = max(w, h) / 2
                bullets.append(.init(pageIndex: pageIndex, x: cx, y: cy, radius: r))
                return
            }
        }

        // ---- Underline: thin horizontal stroked line ----
        // Source PDFs emit underlines as a `m x1 y  l x2 y  S` sequence:
        // path points are 2 (start + end), they share y, and the span
        // is wide. Filled rectangles (used as decorative thin bands)
        // also qualify if their height is < 1.5pt and width > 4pt.
        let isThinHorizontal = h < 1.5 && w > 4
        let twoPointStroke = !filled && pathPoints.count == 2
        if isThinHorizontal && (twoPointStroke || filled) {
            underlines.append(.init(
                pageIndex: pageIndex,
                xLeft: minX, xRight: maxX,
                y: (minY + maxY) / 2
            ))
        }
    }

    // ---- Graphics state ----
    func pushGState() { ctmStack.append(ctm) }
    func popGState() { if ctmStack.count > 1 { ctmStack.removeLast() } }
    func concatCTM(_ m: CGAffineTransform) {
        ctmStack[ctmStack.count - 1] = m.concatenating(ctm)
    }

    // ---- Text state ----
    func beginText() {
        inText = true
        textMatrix = .identity
        lineMatrix = .identity
    }
    func endText() { inText = false }
    func setFont(name: String, size: CGFloat) {
        // Resolve the Tf alias (like "F124") to its PostScript BaseFont
        // ("Helvetica-Bold") so downstream chunks carry the truth about
        // bold/italic, not the alias.
        fontName = aliasToBaseFont[name] ?? name
        fontSize = size
    }
    func setTextMatrix(_ m: CGAffineTransform) {
        textMatrix = m
        lineMatrix = m
    }
    func setLeading(_ l: CGFloat) { leading = l }
    func moveText(tx: CGFloat, ty: CGFloat, setLeading: Bool) {
        if setLeading { leading = -ty }
        let m = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        lineMatrix = m
        textMatrix = m
    }
    func nextLine() {
        moveText(tx: 0, ty: -leading, setLeading: false)
    }
    func showText(_ s: String) {
        // Position of this text show in user space:
        //   userPos = textMatrix * ctm * (0,0)
        let userPos = CGPoint(x: 0, y: 0)
            .applying(textMatrix)
            .applying(ctm)
        chunks.append(.init(
            pageIndex: pageIndex,
            x: userPos.x,
            y: userPos.y,
            fontName: fontName,
            text: s
        ))
    }
}
