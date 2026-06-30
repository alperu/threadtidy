import Foundation
import PDFKit

// Decides which heuristic parser to dispatch to. Operates on the raw
// page-1 text BEFORE PDFTextExtractor's chrome filter strips
// format-identifying URLs/banners — that's the whole point: chrome
// IS the signal here.
//
// Detection is intentionally generous on each format's primary
// signature (footer URL > top-band logo > date format) and falls back
// to .unknown so Pipeline can route to MLX. Confidence ties → .unknown.
public enum FormatDetector {

    public static func detect(url: URL) -> Format {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0),
              let raw = page.string else {
            return .unknown
        }
        return detect(firstPageText: raw)
    }

    // Pure-string entry point for unit tests.
    public static func detect(firstPageText raw: String) -> Format {
        var scores: [Format: Int] = [:]

        // Pass 1: footer URL — strongest signal. 3 points.
        for (rx, fmt) in footerPatterns {
            if rx.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil {
                scores[fmt, default: 0] += 3
            }
        }

        // Pass 2: top-band signature. 2 points.
        let head = String(raw.prefix(400))
        for (rx, fmt) in topBandPatterns {
            if rx.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil {
                scores[fmt, default: 0] += 2
            }
        }

        // Pass 3: date-format probe. 1 point.
        for (rx, fmt) in datePatterns {
            if rx.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil {
                scores[fmt, default: 0] += 1
            }
        }

        guard let best = scores.max(by: { $0.value < $1.value }), best.value > 0 else {
            return .unknown
        }
        // Tie check: more than one format at top score → unknown.
        let top = scores.filter { $0.value == best.value }
        if top.count > 1 { return .unknown }
        return best.key
    }

    // MARK: - Pattern tables

    private static let footerPatterns: [(NSRegularExpression, Format)] = compile([
        (#"mail\.google\.com"#,                .gmail),
        (#"outlook\.(live|office)\.com"#,      .outlook),
        (#"mail\.proton\.me"#,                 .protonMail),
        (#"mail\.yahoo\.com"#,                 .yahoo),
    ])

    private static let topBandPatterns: [(NSRegularExpression, Format)] = compile([
        (#"\bGmail\s*[-–]\s*"#,                .gmail),
        (#"\bOutlook\b"#,                      .outlook),
        (#"Yahoo\s+Mail"#,                     .yahoo),
        (#"Proton\s*Mail"#,                    .protonMail),
    ])

    private static let datePatterns: [(NSRegularExpression, Format)] = compile([
        // Gmail: "Wed, Apr 29, 2026 at 8:12 AM"
        (#"\b\w{3},\s+\w{3}\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}\s*(AM|PM)"#, .gmail),
        // Outlook web: "Thu 4/30/2026 8:38 AM"
        (#"\b\w{3}\s+\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}\s*(AM|PM)"#,         .outlook),
        // Apple Mail: "On April 30, 2026 at 8:38:00 AM PDT"
        (#"\b\w+\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}(:\d{2})?\s*(AM|PM)"#,  .appleMail),
    ])

    private static func compile(_ pairs: [(String, Format)]) -> [(NSRegularExpression, Format)] {
        pairs.compactMap { pat, fmt in
            (try? NSRegularExpression(pattern: pat)).map { ($0, fmt) }
        }
    }
}
