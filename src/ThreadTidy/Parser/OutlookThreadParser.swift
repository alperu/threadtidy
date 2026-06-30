import Foundation

// Parses Outlook web ("outlook.live.com", "outlook.office.com") print
// PDFs into a Thread.
//
// Layout (verified against `resource/dirtyPdf/dirtyOutlook.pdf`):
//
//     Outlook                                  ← logo line
//     Re: Test email hotmail print             ← subject (bold)
//     From <Name> <email>                      ← stacked header start
//     Date <Date>
//     To   <Name> <email>
//     Cc   <email>                             ← optional
//     <blank>
//     <body of newest message>
//     On <date> <name> <email> wrote:          ← inline boundary
//     <body of message N-1>
//     From: <Name> <email>                     ← forwarded boundary
//     Sent: <date>
//     To:   <addrs>
//     Subject: <subj>
//     <body of message N-2>
//     ...
//
// Only ONE stacked header exists. Prior messages live inline. We
// parse the top block as message #1, then scan its body for inline
// boundaries to recover history.
public struct OutlookThreadParser: ThreadParsing {

    public init() {}

    // MARK: - Regex bank

    private static let fromRow = try! NSRegularExpression(
        pattern: #"^From\s+(.+?)\s+<([^>]+)>\s*$"#
    )
    private static let dateRow = try! NSRegularExpression(
        pattern: #"^(?:Sent|Date)\s+(.+?)\s*$"#
    )
    private static let toRow = try! NSRegularExpression(
        pattern: #"^To\s+(.+?)\s*$"#
    )
    private static let ccRow = try! NSRegularExpression(
        pattern: #"^Cc\s+(.+?)\s*$"#
    )
    // Inline Gmail-style reply boundary.
    private static let inlineReplyBoundary = try! NSRegularExpression(
        pattern: #"^On\s+.+?<.+@.+>\s+wrote:\s*$"#
    )
    // Inline forwarded boundary — `From: <name> <email>` (note colon).
    private static let inlineForwardedFrom = try! NSRegularExpression(
        pattern: #"^From:\s+(.+?)\s+<([^>]+)>\s*$"#
    )
    private static let inlineForwardedSent = try! NSRegularExpression(
        pattern: #"^Sent:\s+(.+?)\s*$"#
    )
    private static let inlineForwardedTo = try! NSRegularExpression(
        pattern: #"^To:\s+(.+?)\s*$"#
    )
    private static let inlineForwardedSubject = try! NSRegularExpression(
        pattern: #"^Subject:\s+(.+?)\s*$"#
    )
    // Outlook chrome lines that may slip past PDFTextExtractor.
    private static let chromePatterns: [NSRegularExpression] = {
        [
            #"^\d{1,2}/\d{1,2}/\d{2,4},?\s*\d{1,2}:\d{2}\s*(AM|PM)\s+Mail\s*-\s*.+\s*-\s*Outlook$"#,
            #"^https?://outlook\.(live|office)\.com/.*"#,
            #"^Outlook\s*$"#,
            #"^\d+/\d+\s*$"#,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // MARK: - Entry point

    public func parse(lines linesIn: [StyledLine]) throws -> Thread {
        let lines = stripChrome(linesIn)
        guard let headerStart = findFromRowIndex(in: lines) else {
            // No stacked header found at all. Surface a typed error
            // so Pipeline can log + fall through to MLX in Phase 2.
            throw OutlookParseError.noStackedHeaderFound
        }
        let subject = inferSubject(from: lines, before: headerStart)
        let (header, headerEnd) = parseStackedHeader(in: lines, from: headerStart)
        let bodyLines = Array(lines.suffix(from: headerEnd))
        let split = splitInline(
            bodyLines: bodyLines,
            primary: header,
            startIndex: 1
        )
        // Outlook inline reply boundaries ("On <date> <name> <email>
        // wrote:") carry no To: field — that recipient is implicit:
        // each older message was written TO the sender of the message
        // that quoted it. Derive: emails[i].to = "<previous sender
        // name> <<previous sender email>>" for i >= 1. The primary
        // message (i==0) is parsed from the stacked header and keeps
        // its real To:.
        let messages = backfillImplicitTo(split)
        return Thread(
            subject: subject,
            dateRange: dateRange(from: messages),
            messages: messages
        )
    }

    private func backfillImplicitTo(_ emails: [Email]) -> [Email] {
        var out = emails
        for i in 1..<out.count {
            guard out[i].to.isEmpty else { continue }
            let prev = out[i - 1]
            let prevName = prev.fromName.trimmingCharacters(in: .whitespaces)
            let prevEmail = prev.fromEmail.trimmingCharacters(in: .whitespaces)
            let derived: String
            if !prevName.isEmpty && !prevEmail.isEmpty {
                derived = "\(prevName) <\(prevEmail)>"
            } else if !prevEmail.isEmpty {
                derived = prevEmail
            } else {
                continue
            }
            out[i] = out[i].replacing(to: derived)
        }
        return out
    }

    // MARK: - Chrome stripping

    private func stripChrome(_ lines: [StyledLine]) -> [StyledLine] {
        lines.filter { line in
            let text = line.plain.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return true }
            let ns = text as NSString
            for rx in Self.chromePatterns {
                if rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Stacked-header parsing

    private func findFromRowIndex(in lines: [StyledLine]) -> Int? {
        for (i, line) in lines.enumerated() {
            let text = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = text as NSString
            if Self.fromRow.firstMatch(
                in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                return i
            }
        }
        return nil
    }

    // Subject = the first non-empty line above the From row. We
    // prefer a bold line; if no bold line exists, take the last
    // non-empty line above the header.
    private func inferSubject(from lines: [StyledLine], before idx: Int) -> String {
        let preamble = Array(lines.prefix(idx))
        if let bold = preamble.last(where: { line in
            !line.plain.trimmingCharacters(in: .whitespaces).isEmpty
                && line.runs.contains(where: \.bold)
        }) {
            return bold.plain.trimmingCharacters(in: .whitespaces)
        }
        if let last = preamble.reversed().first(where: {
            !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            return last.plain.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    // Returns the parsed top-of-thread Email plus the line index
    // immediately AFTER the header block.
    private func parseStackedHeader(in lines: [StyledLine], from start: Int)
        -> (Email, Int)
    {
        var fromName = ""
        var fromEmail = ""
        var date = ""
        var to = ""
        var cc: String?
        var i = start
        let limit = min(start + 6, lines.count)  // header is at most 4 rows + slack
        while i < limit {
            let text = lines[i].plain.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { i += 1; break }
            if let m = match(Self.fromRow, text) {
                fromName = m[1]; fromEmail = m[2]
            } else if let m = match(Self.dateRow, text) {
                date = m[1]
            } else if let m = match(Self.toRow, text) {
                to = m[1]
            } else if let m = match(Self.ccRow, text) {
                cc = m[1]
            } else {
                break  // first non-header row → end of stacked block
            }
            i += 1
        }
        let email = Email(
            index: 1,
            fromName: fromName,
            fromEmail: fromEmail,
            date: date,
            to: to,
            cc: cc,
            bcc: nil,
            bodyLines: []  // body is filled in by splitInline
        )
        return (email, i)
    }

    // MARK: - Inline boundary detection

    // Walks bodyLines, splitting at inline boundaries. Each split
    // produces a new Email; lines preceding the first boundary become
    // the primary message's body.
    private func splitInline(bodyLines: [StyledLine],
                             primary: Email,
                             startIndex: Int) -> [Email] {
        // Phase A: locate boundary indices.
        var boundaries: [(idx: Int, kind: BoundaryKind)] = []
        var i = 0
        while i < bodyLines.count {
            let text = bodyLines[i].plain.trimmingCharacters(in: .whitespaces)
            let ns = text as NSString
            if Self.inlineReplyBoundary.firstMatch(
                in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                boundaries.append((i, .reply))
            } else if Self.inlineForwardedFrom.firstMatch(
                in: text, range: NSRange(location: 0, length: ns.length)) != nil,
                isForwardedHeaderBlock(at: i, in: bodyLines) {
                boundaries.append((i, .forwarded))
            }
            i += 1
        }

        // Phase B: slice. First slice = primary's body.
        var emails: [Email] = []
        let firstBoundary = boundaries.first?.idx ?? bodyLines.count
        let primaryBody = Array(bodyLines.prefix(firstBoundary))
        emails.append(primary.replacing(bodyLines: primaryBody))

        // Phase C: each subsequent boundary becomes its own Email.
        for (b, next) in zip(boundaries, boundaries.dropFirst() + [(bodyLines.count, .reply)]) {
            let chunk = Array(bodyLines[b.idx..<next.idx])
            let parsed = parseInlineBlock(chunk: chunk,
                                          kind: b.kind,
                                          index: emails.count + startIndex)
            emails.append(parsed)
        }
        return emails
    }

    private enum BoundaryKind { case reply, forwarded }

    // For a forwarded-style boundary, we require at least one of the
    // companion rows (Sent / To / Subject) within the next 5 lines —
    // otherwise it's a stray "From:" inside body prose.
    private func isForwardedHeaderBlock(at idx: Int, in lines: [StyledLine]) -> Bool {
        let window = lines[idx ..< min(idx + 5, lines.count)]
        for line in window.dropFirst() {
            let t = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = t as NSString
            let r = NSRange(location: 0, length: ns.length)
            if Self.inlineForwardedSent.firstMatch(in: t, range: r) != nil
                || Self.inlineForwardedTo.firstMatch(in: t, range: r) != nil
                || Self.inlineForwardedSubject.firstMatch(in: t, range: r) != nil {
                return true
            }
        }
        return false
    }

    private func parseInlineBlock(chunk: [StyledLine],
                                  kind: BoundaryKind,
                                  index: Int) -> Email {
        switch kind {
        case .reply:
            // First line: "On <date> <name> <email> wrote:"
            // Extract name/email/date via a single greedy regex.
            let head = chunk.first?.plain.trimmingCharacters(in: .whitespaces) ?? ""
            let (name, email, date) = parseReplyBoundary(head)
            return Email(
                index: index,
                fromName: name,
                fromEmail: email,
                date: date,
                to: "",
                cc: nil,
                bcc: nil,
                bodyLines: Array(chunk.dropFirst())
            )
        case .forwarded:
            var name = "", email = "", date = "", to = "", subject = ""
            var bodyStart = 0
            for (j, line) in chunk.enumerated() {
                let t = line.plain.trimmingCharacters(in: .whitespaces)
                if let m = match(Self.inlineForwardedFrom, t) {
                    name = m[1]; email = m[2]
                } else if let m = match(Self.inlineForwardedSent, t) {
                    date = m[1]
                } else if let m = match(Self.inlineForwardedTo, t) {
                    to = m[1]
                } else if let m = match(Self.inlineForwardedSubject, t) {
                    subject = m[1]
                    bodyStart = j + 1
                    break
                }
            }
            _ = subject  // stored on Thread.subject if first-discovered; per-Email subject not modeled
            return Email(
                index: index,
                fromName: name,
                fromEmail: email,
                date: date,
                to: to,
                cc: nil,
                bcc: nil,
                bodyLines: Array(chunk.suffix(from: max(bodyStart, 1)))
            )
        }
    }

    // Outlook reply-boundary variants observed in real prints:
    //   "On Thu, Apr 30, 2026 at 7:37 AM Jane Doe <jane.doe@example.com> wrote:"
    //   "On Thu, Apr 30, 2026 at 7:37AM Jane Doe <jane.doe@example.com> wrote:"   ← no space before AM
    //   "On Thu, Apr 30, 2026, at 7:37 AM, Jane Doe <jane.doe@example.com> wrote:"
    //
    // Naïve `(.+?)\s+(.+?)\s+<email>` splits the date and name at the
    // first whitespace, collapsing date→"Thu," and dumping the rest of
    // the date into the name. Anchor group 1 through the time
    // component so the non-greedy boundary lands AFTER the date.
    private static let replyBoundaryParts = try! NSRegularExpression(
        pattern: #"^On\s+(.+?\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM|am|pm)?(?:\s+[A-Z]{2,5})?),?\s+(.+?)\s+<([^>]+)>\s+wrote:\s*$"#
    )

    private func parseReplyBoundary(_ text: String) -> (name: String, email: String, date: String) {
        if let m = match(Self.replyBoundaryParts, text) {
            return (name: m[2], email: m[3], date: m[1])
        }
        return (name: "", email: "", date: "")
    }

    // MARK: - Helpers

    private func match(_ rx: NSRegularExpression, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    private func dateRange(from emails: [Email]) -> String {
        let firstDate = emails.last?.date ?? ""
        let lastDate = emails.first?.date ?? ""
        if firstDate.isEmpty && lastDate.isEmpty { return "" }
        if firstDate == lastDate { return lastDate }
        return "\(firstDate) — \(lastDate)"
    }
}

public enum OutlookParseError: Error, LocalizedError {
    case noStackedHeaderFound
    public var errorDescription: String? {
        switch self {
        case .noStackedHeaderFound:
            return "Could not locate Outlook stacked header (From/Date/To)."
        }
    }
}

private extension Email {
    func replacing(to newTo: String) -> Email {
        Email(
            index: index,
            fromName: fromName,
            fromEmail: fromEmail,
            date: date,
            to: newTo,
            cc: cc,
            bcc: bcc,
            bodyLines: bodyLines
        )
    }

    func replacing(bodyLines: [StyledLine]) -> Email {
        Email(
            index: index,
            fromName: fromName,
            fromEmail: fromEmail,
            date: date,
            to: to,
            cc: cc,
            bcc: bcc,
            bodyLines: bodyLines
        )
    }
}
