import Foundation

// Email-client format produced by FormatDetector. Pipeline picks a
// heuristic parser per case; .unknown routes to MLXThreadParser.
public enum Format: String, Codable, Equatable {
    case gmail
    case outlook
    case appleMail
    case protonMail
    case yahoo
    case unknown
}

// A single span of text with its style. Style flags are the union of every
// trait we want to preserve in the output. `link` is non-nil for runs that
// are clickable in the source PDF (mailto: or https://).
public struct StyledRun: Equatable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var link: URL?
    // Source-PDF font size in points. 0 = "use renderer default body size".
    // Captured from PDFKit's NSFont.pointSize so signature/disclaimer
    // blocks render at their original (smaller) size.
    public var fontSize: CGFloat

    public init(text: String,
                bold: Bool = false,
                italic: Bool = false,
                underline: Bool = false,
                link: URL? = nil,
                fontSize: CGFloat = 0) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.link = link
        self.fontSize = fontSize
    }
}

// A logical line is a sequence of runs followed by a hard break.
// Lines are the unit segmentation works on — Gmail's per-message header
// always lives on one line.
public struct StyledLine {
    public var runs: [StyledRun]
    // Horizontal offset of this line in PDF points relative to the
    // body's leftmost line. 0 means flush with the left margin; >0
    // means visually indented (sub-bullet, quoted block, etc).
    public var indent: CGFloat
    // True when BulletDetector found a small filled disc to the left
    // of this line in the source PDF — i.e. this line was a Gmail
    // bullet item whose marker was a vector graphic, not a text glyph.
    public var isBullet: Bool
    public init(runs: [StyledRun], indent: CGFloat = 0, isBullet: Bool = false) {
        self.runs = runs
        self.indent = indent
        self.isBullet = isBullet
    }
    public var plain: String { runs.map(\.text).joined() }

    // Returns a copy with leading whitespace removed from the first run
    // and trailing whitespace removed from the last run. Used when
    // joining wrapped lines back into a single paragraph: `"abc " + " def"`
    // would otherwise produce `"abc  def"` with a double space.
    public func trimmedEdges() -> StyledLine {
        guard !runs.isEmpty else { return self }
        var newRuns = runs
        let first = newRuns[0]
        var firstText = first.text
        while firstText.first?.isWhitespace == true { firstText.removeFirst() }
        newRuns[0] = StyledRun(
            text: firstText,
            bold: first.bold, italic: first.italic, underline: first.underline,
            link: first.link
        )
        let lastIdx = newRuns.count - 1
        let last = newRuns[lastIdx]
        var lastText = last.text
        while lastText.last?.isWhitespace == true { lastText.removeLast() }
        newRuns[lastIdx] = StyledRun(
            text: lastText,
            bold: last.bold, italic: last.italic, underline: last.underline,
            link: last.link
        )
        return StyledLine(
            runs: newRuns.filter { !$0.text.isEmpty },
            indent: indent,
            isBullet: isBullet
        )
    }
}

public struct Thread {
    public var subject: String
    public var dateRange: String
    public var messages: [Email]

    public init(subject: String, dateRange: String, messages: [Email]) {
        self.subject = subject
        self.dateRange = dateRange
        self.messages = messages
    }
}

public enum IntegritySeverity: Equatable {
    case ok
    case warning
    case error
}

public struct IntegrityReport {
    public var severity: IntegritySeverity
    public var messageCount: Int
    public var expectedCount: Int?
    public var warnings: [String]
    public var errors: [String]
    public var summary: String
    // Phase 3 additions — provenance + differential diff.
    public var parsedBy: ParserKind?
    public var differential: ThreadDiff?

    public init(severity: IntegritySeverity,
                messageCount: Int,
                expectedCount: Int?,
                warnings: [String],
                errors: [String],
                summary: String,
                parsedBy: ParserKind? = nil,
                differential: ThreadDiff? = nil) {
        self.severity = severity
        self.messageCount = messageCount
        self.expectedCount = expectedCount
        self.warnings = warnings
        self.errors = errors
        self.summary = summary
        self.parsedBy = parsedBy
        self.differential = differential
    }
}

// Shared entry point for every per-format heuristic parser. MLX
// fallback (Phase 2) conforms separately and is async.
public protocol ThreadParsing {
    func parse(lines: [StyledLine]) throws -> Thread
}

public struct Email {
    public var index: Int
    public var fromName: String
    public var fromEmail: String
    public var date: String
    public var to: String
    public var cc: String?
    public var bcc: String?
    public var bodyLines: [StyledLine]

    public init(index: Int, fromName: String, fromEmail: String, date: String,
                to: String, cc: String?, bcc: String?, bodyLines: [StyledLine]) {
        self.index = index
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.date = date
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.bodyLines = bodyLines
    }
}
