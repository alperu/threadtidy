import Foundation

// Heuristic parser for Apple Mail "Print…" PDFs.
//
// Structure (from docs/MULTI_FORMAT_AND_MLX.md §2):
//
//     <sender> – <subject>                     ← chrome header band
//     From:    <Name> <email>                  ← stacked top-of-thread block
//     Subject: <subject>                       ← Subject row is inside the block
//     Date:    On April 30, 2026 at 8:38:00 AM PDT
//     To:      <Name> <email>
//     Cc:      <addrs>                         ← optional
//     <blank>
//     <body of newest message>
//     │ On April 29, 2026, at 7:37 AM,
//     │ Jane <jane.doe@example.com> wrote:
//     │
//     │ <body of prior message>
//     │ ...
//     Page N of M                              ← optional chrome footer
//
// Prior messages live inline as Gmail/Outlook-style "On … wrote:"
// blocks, often visually indented behind a vertical bar (PDFTextExtractor
// reflows the text; the bar itself is a vector graphic and is
// invisible to the text stream). We treat both `On <date> ... wrote:`
// reply-style and `From:/Sent:/To:/Subject:` forwarded-style blocks as
// boundaries.
//
// Apple Mail has no reliable footer URL, so chrome stripping leans on
// `Page N of M` and the leading `<sender> – <subject>` header line.
public struct AppleMailThreadParser: ThreadParsing {

    public init() {}

    // MARK: - Regex bank

    // Stacked header rows. Apple Mail uses colon-terminated labels.
    private static let fromRow = try! NSRegularExpression(
        pattern: #"^From:\s+(.+?)\s+<([^>]+)>\s*$"#
    )
    // Tolerate "From: Name" with no angle-bracketed email — Apple Mail
    // sometimes prints just the display name when the address book
    // has a contact. We try the email-bearing form first.
    private static let fromRowNameOnly = try! NSRegularExpression(
        pattern: #"^From:\s+(.+?)\s*$"#
    )
    private static let subjectRow = try! NSRegularExpression(
        pattern: #"^Subject:\s+(.+?)\s*$"#
    )
    private static let dateRow = try! NSRegularExpression(
        pattern: #"^Date:\s+(.+?)\s*$"#
    )
    private static let toRow = try! NSRegularExpression(
        pattern: #"^To:\s+(.+?)\s*$"#
    )
    private static let ccRow = try! NSRegularExpression(
        pattern: #"^Cc:\s+(.+?)\s*$"#
    )
    private static let bccRow = try! NSRegularExpression(
        pattern: #"^Bcc:\s+(.+?)\s*$"#
    )

    // Inline reply boundary — Apple Mail variants observed:
    //   "On April 30, 2026 at 8:38:00 AM, Name <email> wrote:"
    //   "On April 30, 2026, at 8:38 AM, Name <email> wrote:"
    //   "On Apr 30, 2026, at 8:38 AM, Name <email> wrote:"
    // We accept either comma- or space-separated date/time, with or
    // without seconds, and with or without timezone abbreviation.
    private static let inlineReplyBoundary = try! NSRegularExpression(
        pattern: #"^On\s+.+?,?\s+at\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?(?:\s+[A-Z]{2,5})?,?\s+.+?<[^>]+>\s+wrote:\s*$"#
    )
    // Greedy reply-boundary capture for name/email/date split.
    private static let replyBoundaryParts = try! NSRegularExpression(
        pattern: #"^On\s+(.+?wrote)\b"#
    )
    // Tight capture: pulls the "<date>", "<name>", "<email>" pieces
    // out of a known-good reply-boundary line. Apple Mail dates carry
    // their own internal commas ("On April 30, 2026, at 7:37 AM,
    // Name <email> wrote:") so we anchor the date capture all the way
    // through the time portion (with optional seconds and timezone)
    // before letting the name match.
    private static let replyBoundaryCapture = try! NSRegularExpression(
        pattern: #"^On\s+(.+?\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?(?:\s+[A-Z]{2,5})?),\s+(.+?)\s+<([^>]+)>\s+wrote:\s*$"#
    )

    // Inline forwarded-style boundary: "From: Name <email>" with a
    // companion Subject:/Date:/To: row in the next few lines. Matches
    // exactly the inline-header pattern used by Outlook, so the
    // detection is shared in spirit.
    private static let inlineForwardedFrom = try! NSRegularExpression(
        pattern: #"^From:\s+(.+?)\s+<([^>]+)>\s*$"#
    )
    private static let inlineForwardedSent = try! NSRegularExpression(
        pattern: #"^(?:Sent|Date):\s+(.+?)\s*$"#
    )
    private static let inlineForwardedTo = try! NSRegularExpression(
        pattern: #"^To:\s+(.+?)\s*$"#
    )
    private static let inlineForwardedSubject = try! NSRegularExpression(
        pattern: #"^Subject:\s+(.+?)\s*$"#
    )

    // Apple Mail chrome that may slip past PDFTextExtractor.
    private static let chromePatterns: [NSRegularExpression] = {
        [
            #"^Page\s+\d+\s+of\s+\d+\s*$"#,
            #"^\d+\s*/\s*\d+\s*$"#,                   // bare "1/3" page indicator
            // "<sender> – <subject>" / "<sender> - <subject>" chrome.
            // We can't recognise it reliably without knowing the sender
            // name a priori, so we only strip the *common* page-band
            // formats that PDFKit might leak through: lines that are a
            // pure separator dash. Real chrome with names is identical
            // to body prose and best left to subject inference.
            #"^[\s\u{2013}\u{2014}-]+$"#,             // line that is only dashes / whitespace
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // MARK: - Entry point

    public func parse(lines linesIn: [StyledLine]) throws -> Thread {
        let lines = stripChrome(linesIn)
        // Locate the top-of-thread stacked header. We look for a `From:`
        // row that is part of a multi-row block (Subject:/Date:/To:
        // within a small window) — this disambiguates from inline
        // forwarded `From:` lines that may also appear later.
        guard let headerStart = findTopHeaderIndex(in: lines) else {
            throw AppleMailParseError.noStackedHeaderFound
        }
        let (header, subjectFromBlock, headerEnd) =
            parseStackedHeader(in: lines, from: headerStart)
        let subject = !subjectFromBlock.isEmpty
            ? subjectFromBlock
            : inferSubject(from: lines, before: headerStart)
        let bodyLines = Array(lines.suffix(from: headerEnd))
        let messages = splitInline(
            bodyLines: bodyLines,
            primary: header,
            startIndex: 1
        )
        return Thread(
            subject: subject,
            dateRange: dateRange(from: messages),
            messages: messages
        )
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

    // MARK: - Stacked-header location

    // Returns the index of a `From:` row whose neighbourhood (next 6
    // lines) contains at least one of Subject:/Date:/To: — the
    // signature of the top-of-thread block.
    private func findTopHeaderIndex(in lines: [StyledLine]) -> Int? {
        for (i, line) in lines.enumerated() {
            let text = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = text as NSString
            let r = NSRange(location: 0, length: ns.length)
            if Self.fromRow.firstMatch(in: text, range: r) != nil
                || Self.fromRowNameOnly.firstMatch(in: text, range: r) != nil {
                if hasCompanionRow(after: i, in: lines) {
                    return i
                }
            }
        }
        return nil
    }

    private func hasCompanionRow(after idx: Int, in lines: [StyledLine]) -> Bool {
        let window = lines[(idx + 1) ..< min(idx + 6, lines.count)]
        for line in window {
            let t = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = t as NSString
            let r = NSRange(location: 0, length: ns.length)
            if Self.subjectRow.firstMatch(in: t, range: r) != nil
                || Self.dateRow.firstMatch(in: t, range: r) != nil
                || Self.toRow.firstMatch(in: t, range: r) != nil {
                return true
            }
        }
        return false
    }

    // Fallback: if Subject: row is missing from the block, take the
    // last non-empty bold line above the From row, or the last
    // non-empty line.
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

    // Parses the stacked block starting at `start`. Returns the
    // primary Email, the subject string discovered inside the block
    // (may be empty if Subject: row was absent), and the line index
    // just past the block.
    private func parseStackedHeader(in lines: [StyledLine], from start: Int)
        -> (Email, String, Int)
    {
        var fromName = ""
        var fromEmail = ""
        var subject = ""
        var date = ""
        var to = ""
        var cc: String?
        var bcc: String?
        var i = start
        let limit = min(start + 8, lines.count)
        while i < limit {
            let text = lines[i].plain.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { i += 1; break }
            if let m = match(Self.fromRow, text) {
                fromName = m[1]; fromEmail = m[2]
            } else if let m = match(Self.subjectRow, text) {
                subject = m[1]
            } else if let m = match(Self.dateRow, text) {
                date = m[1]
            } else if let m = match(Self.toRow, text) {
                to = m[1]
            } else if let m = match(Self.ccRow, text) {
                cc = m[1]
            } else if let m = match(Self.bccRow, text) {
                bcc = m[1]
            } else if fromName.isEmpty,
                      let m = match(Self.fromRowNameOnly, text) {
                fromName = m[1]
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
            bcc: bcc,
            bodyLines: []
        )
        return (email, subject, i)
    }

    // MARK: - Inline boundary splitting

    private enum BoundaryKind { case reply, forwarded }

    private func splitInline(bodyLines: [StyledLine],
                             primary: Email,
                             startIndex: Int) -> [Email] {
        var boundaries: [(idx: Int, kind: BoundaryKind)] = []
        var i = 0
        while i < bodyLines.count {
            let text = bodyLines[i].plain.trimmingCharacters(in: .whitespaces)
            let ns = text as NSString
            let r = NSRange(location: 0, length: ns.length)
            if Self.inlineReplyBoundary.firstMatch(in: text, range: r) != nil {
                boundaries.append((i, .reply))
            } else if Self.inlineForwardedFrom.firstMatch(in: text, range: r) != nil,
                      isForwardedHeaderBlock(at: i, in: bodyLines) {
                boundaries.append((i, .forwarded))
            }
            i += 1
        }

        var emails: [Email] = []
        let firstBoundary = boundaries.first?.idx ?? bodyLines.count
        let primaryBody = Array(bodyLines.prefix(firstBoundary))
        emails.append(primary.replacing(bodyLines: primaryBody))

        for (b, next) in zip(boundaries, boundaries.dropFirst() + [(bodyLines.count, .reply)]) {
            let chunk = Array(bodyLines[b.idx..<next.idx])
            let parsed = parseInlineBlock(chunk: chunk,
                                          kind: b.kind,
                                          index: emails.count + startIndex)
            emails.append(parsed)
        }
        return emails
    }

    // Forwarded `From:` only counts as a boundary if it has a
    // companion Sent/Date/To/Subject row within the next 5 lines.
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
            var name = "", email = "", date = "", to = ""
            var bodyStart = 0
            for (j, line) in chunk.enumerated() {
                let t = line.plain.trimmingCharacters(in: .whitespaces)
                if let m = match(Self.inlineForwardedFrom, t) {
                    name = m[1]; email = m[2]
                } else if let m = match(Self.inlineForwardedSent, t) {
                    date = m[1]
                } else if let m = match(Self.inlineForwardedTo, t) {
                    to = m[1]
                } else if match(Self.inlineForwardedSubject, t) != nil {
                    bodyStart = j + 1
                    break
                }
            }
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

    private func parseReplyBoundary(_ text: String) -> (name: String, email: String, date: String) {
        // Try the tight capture first — handles the common case where
        // the boundary lives on one line.
        if let m = match(Self.replyBoundaryCapture, text) {
            return (name: m[2], email: m[3], date: m[1])
        }
        // Otherwise extract just the date portion before "wrote" so
        // we don't strand it.
        if let m = match(Self.replyBoundaryParts, text) {
            // m[1] is "<date>, Name <email> wrote" — best-effort.
            return (name: "", email: "", date: m[1])
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

public enum AppleMailParseError: Error, LocalizedError {
    case noStackedHeaderFound
    public var errorDescription: String? {
        switch self {
        case .noStackedHeaderFound:
            return "Could not locate Apple Mail stacked header (From:/Subject:/Date:/To:)."
        }
    }
}

private extension Email {
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
