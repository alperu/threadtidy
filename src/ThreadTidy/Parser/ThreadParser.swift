import Foundation

// Turns the styled line stream into a Thread of unique Email entries.
// Constraints:
//   * Do not delete or alter any text within email bodies.
//   * Preserve To/Cc/Bcc/Date and inline styling (bold/italic/underline/links).
//   * Strip ONLY:
//       - the page-1 Gmail preamble (logo + account + bold subject + "N messages")
//         which sits above the first message header;
//       - "[Quoted text hidden]" placeholders;
//       - the duplicated forwarded tail block under each reply
//         ("From: / Sent: / To: / Cc: / Subject:" + the prior message's body).
//         The prior message already appears earlier as its own entry, so this
//         strip removes only duplication of author text, never unique text.
public final class ThreadParser {

    public init() {}

    // Header line shape: "<Display Name> <email@host>     <Day, Mon DD, YYYY at H:MM AM/PM>"
    // The timestamp is anchored at end-of-line. We extract the timestamp first,
    // then split the remainder into name + email.
    private let dateAtEndRegex = try! NSRegularExpression(
        pattern: #"\s+(\w{3},\s\w{3}\s\d{1,2},\s\d{4}\sat\s\d{1,2}:\d{2}\s(?:AM|PM))\s*$"#
    )
    // Anchor on the FIRST email in the line — needed because the lead
    // portion may already contain an inline "To: <other@host>" that
    // PDFKit packed onto the same visual line as the message header.
    private let nameEmailRegex = try! NSRegularExpression(
        pattern: #"^(.+?)\s+<([^>]+)>"#
    )
    private let bareDateRegex = try! NSRegularExpression(
        pattern: #"^\w{3},\s\w{3}\s\d{1,2},\s\d{4}\sat\s\d{1,2}:\d{2}\s(?:AM|PM)$"#
    )
    // Forwarded tail: a line that is bold-prefixed "From:" followed by bold
    // "Sent:" / "To:" / "Subject:" within the next handful of lines.
    private let forwardedFromRegex = try! NSRegularExpression(
        pattern: #"^From:\s+.+<.+@.+>"#
    )
    // Gmail-style reply quote header:
    //   "On Wed, Apr 29, 2026 at 11:17 AM Anna Brown <anna.brown@example.com> wrote:"
    // Everything from this line to end-of-block is a duplicate of an
    // earlier message in the same thread.
    private let gmailReplyQuoteRegex = try! NSRegularExpression(
        pattern: #"^On\s+\w{3},?\s+.+?<.+@.+>\s+wrote:\s*$"#
    )

    public func parse(tokens linesIn: [StyledLine]) -> Thread {
        // Pre-pass: fold split message headers. PDFKit sometimes emits the
        // sender's name+email on one line and the right-aligned timestamp
        // on the next line when the page breaks them. If we see a line
        // ending with "<email@host>" and the next line is a bare Gmail
        // timestamp, merge them into a single header line.
        let lines = foldSplitHeaders(linesIn)

        // Step 1: locate the start of the first message. Everything before
        // it is the Gmail print preamble. The bold subject just above the
        // first header is captured for the title.
        let firstIdx = lines.firstIndex(where: { isMessageHeader($0) }) ?? 0
        let subject = inferSubject(from: Array(lines.prefix(firstIdx)))

        // Step 2: split the remainder into per-message blocks.
        var blocks: [[StyledLine]] = []
        var current: [StyledLine] = []
        for line in lines.suffix(from: firstIdx) {
            if isMessageHeader(line) && !current.isEmpty {
                blocks.append(current)
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        // Step 3: parse each block.
        var emails: [Email] = []
        for (i, block) in blocks.enumerated() {
            if let email = parseBlock(block, index: i + 1) {
                emails.append(email)
            }
        }

        let dateRange = computeDateRange(emails)
        return Thread(subject: subject, dateRange: dateRange, messages: emails)
    }

    // MARK: - Split-header fold

    // Pattern for a line that LOOKS like the start of a message header
    // (display name + <email>) but lacks the timestamp at the end —
    // possibly because PDFKit broke the line. Trailing content after the
    // closing '>' (e.g. "To: ..." that wraps onto the same visual line)
    // is allowed; we just need the email to be present and no Gmail
    // timestamp at the end.
    private let nameEmailLooseRegex = try! NSRegularExpression(
        pattern: #"^.+?\s+<[^>]+@[^>]+>"#
    )

    private func foldSplitHeaders(_ lines: [StyledLine]) -> [StyledLine] {
        var out: [StyledLine] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if !isMessageHeader(line) && looksLikeOpenerWithoutDate(line),
               let dateOffset = nextBareDateOffset(from: i, in: lines, maxLook: 6) {
                var merged = line.runs
                merged.append(StyledRun(text: " "))
                merged.append(contentsOf: lines[i + dateOffset].runs)
                out.append(StyledLine(runs: merged))
                // Re-emit any intervening lines (rare; e.g. chrome) so we
                // never silently drop data.
                if dateOffset > 1 {
                    for k in (i + 1)..<(i + dateOffset) { out.append(lines[k]) }
                }
                i += dateOffset + 1
            } else {
                out.append(line)
                i += 1
            }
        }
        return out
    }

    private func looksLikeOpenerWithoutDate(_ line: StyledLine) -> Bool {
        let s = line.plain.trimmingCharacters(in: .whitespaces)
        let ns = s as NSString
        return nameEmailLooseRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func nextBareDateOffset(from i: Int, in lines: [StyledLine], maxLook: Int) -> Int? {
        // Allow header to span several lines (To: + Cc: continuations).
        // Treat header-continuation lines (start with a header keyword,
        // are bare email continuations like "<email@host>", or look like
        // address-list fragments) as part of the header. Stop only when
        // we hit something that clearly isn't header content.
        for offset in 1...maxLook {
            guard i + offset < lines.count else { return nil }
            let s = lines[i + offset].plain.trimmingCharacters(in: .whitespaces)
            let ns = s as NSString
            if bareDateRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
                return offset
            }
            if s.isEmpty { continue }
            if isHeaderContinuation(s) { continue }
            return nil
        }
        return nil
    }

    private func isBareAddressContinuation(_ s: String) -> Bool {
        // A line that's purely an email-address fragment continuing the
        // previous header value: starts with "<", contains "@", ends with ">".
        guard s.hasPrefix("<") else { return false }
        guard s.contains("@") else { return false }
        return s.hasSuffix(">")
    }

    private func isHeaderContinuation(_ s: String) -> Bool {
        if s.hasPrefix("To:") || s.hasPrefix("Cc:") || s.hasPrefix("Bcc:") { return true }
        // Bare-email continuation: "<addr@host>" possibly followed by a comma + name fragment.
        if s.hasPrefix("<") { return true }
        // Address-list continuation: contains '@' and ends without sentence punctuation.
        if s.contains("@") && !s.hasSuffix(".") && !s.hasSuffix(":") { return true }
        return false
    }

    // MARK: - Header detection

    private func isMessageHeader(_ line: StyledLine) -> Bool {
        let s = line.plain.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        let ns = s as NSString
        // Must end with a Gmail-style timestamp.
        guard let m = dateAtEndRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        // The leading portion must contain "<email@host>".
        let leadEnd = m.range.location
        guard leadEnd > 0 else { return false }
        let lead = ns.substring(with: NSRange(location: 0, length: leadEnd))
        return nameEmailRegex.firstMatch(in: lead, range: NSRange(location: 0, length: (lead as NSString).length)) != nil
    }

    // MARK: - Block → Email

    private func parseBlock(_ block: [StyledLine], index: Int) -> Email? {
        guard let header = block.first else { return nil }
        let headerText = header.plain.trimmingCharacters(in: .whitespaces)
        let ns = headerText as NSString

        guard let dm = dateAtEndRegex.firstMatch(in: headerText, range: NSRange(location: 0, length: ns.length)),
              dm.numberOfRanges >= 2 else {
            return nil
        }
        let date = ns.substring(with: dm.range(at: 1))
        let lead = ns.substring(with: NSRange(location: 0, length: dm.range.location))
            .trimmingCharacters(in: .whitespaces)
        let leadNS = lead as NSString
        guard let nm = nameEmailRegex.firstMatch(in: lead, range: NSRange(location: 0, length: leadNS.length)),
              nm.numberOfRanges >= 3 else {
            return nil
        }
        let fromName = leadNS.substring(with: nm.range(at: 1))
        let fromEmail = leadNS.substring(with: nm.range(at: 2))

        // If anything followed the first <email> on the lead, it's
        // probably an inline "To: ..." that PDFKit packed onto the same
        // visual line. Capture it so we don't lose that header value.
        let firstEmailEnd = nm.range.location + nm.range.length  // position after '>'
        var inlineRest = ""
        if firstEmailEnd < leadNS.length {
            inlineRest = leadNS.substring(from: firstEmailEnd).trimmingCharacters(in: .whitespaces)
        }

        // To / Cc / Bcc lines follow, then a blank line, then the body.
        var to = ""
        var cc: String? = nil
        var bcc: String? = nil
        if inlineRest.hasPrefix("To:") {
            to = String(inlineRest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if !inlineRest.isEmpty {
            // Some other inline content; preserve it as the To value
            // rather than dropping it, since the constraint forbids
            // deleting any author-relevant text.
            to = inlineRest
        }
        var bodyStart = 1
        var i = 1
        // If we already have an inline `to`, eagerly fold bare-email
        // continuation lines (lines like "<addr@host>") into it.
        while i < block.count && !to.isEmpty {
            let trimmed = block[i].plain.trimmingCharacters(in: .whitespaces)
            if isBareAddressContinuation(trimmed) {
                to += " " + trimmed
                i += 1
            } else { break }
        }
        bodyStart = i
        while i < block.count {
            let trimmed = block[i].plain.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("To:") {
                to = collectFolded(block, startIndex: i, prefix: "To:", advanceTo: &i)
            } else if trimmed.hasPrefix("Cc:") {
                cc = collectFolded(block, startIndex: i, prefix: "Cc:", advanceTo: &i)
            } else if trimmed.hasPrefix("Bcc:") {
                bcc = collectFolded(block, startIndex: i, prefix: "Bcc:", advanceTo: &i)
            } else {
                bodyStart = i
                break
            }
            bodyStart = i
        }

        var bodyLines = Array(block.suffix(from: bodyStart))
        bodyLines = stripForwardedTail(bodyLines)
        bodyLines = stripQuotedHiddenMarkers(bodyLines)
        bodyLines = trimLeadingTrailingBlank(bodyLines)

        return Email(
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

    // Headers can wrap onto continuation lines (recipients that don't fit one
    // line). We fold continuations into a single value until we hit the next
    // header or a blank line.
    private func collectFolded(_ block: [StyledLine], startIndex: Int, prefix: String, advanceTo i: inout Int) -> String {
        var value = block[startIndex].plain.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        i = startIndex + 1
        while i < block.count {
            let p = block[i].plain
            let t = p.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if t.hasPrefix("To:") || t.hasPrefix("Cc:") || t.hasPrefix("Bcc:") { break }
            if t == "[Quoted text hidden]" { break }
            // Only fold lines that contain an email address-shaped token
            // ('<' or '@'). The trailing-comma heuristic was unsafe —
            // prose body lines like "Good morning," end with a comma and
            // were being vacuumed into the previous Cc field.
            if !(t.contains("<") || t.contains("@")) { break }
            value += " " + t
            i += 1
        }
        return value
    }

    // MARK: - Body cleanups (chrome-only, no author text removed)

    private func stripQuotedHiddenMarkers(_ lines: [StyledLine]) -> [StyledLine] {
        lines.filter { $0.plain.trimmingCharacters(in: .whitespaces) != "[Quoted text hidden]" }
    }

    // The forwarded tail starts at a line beginning with "From: <name> <email>".
    // Once we see that, everything from there to end of block is a duplicated
    // copy of an earlier message and is stripped.
    private func stripForwardedTail(_ lines: [StyledLine]) -> [StyledLine] {
        for (idx, line) in lines.enumerated() {
            let p = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = p as NSString
            let r = NSRange(location: 0, length: ns.length)
            // Gmail-style "On <date> <name> <email> wrote:" preamble.
            if gmailReplyQuoteRegex.firstMatch(in: p, range: r) != nil {
                return Array(lines.prefix(idx))
            }
            // Outlook-style "From: <name> <email>" + "Sent:" header.
            if forwardedFromRegex.firstMatch(in: p, range: r) != nil {
                let lookahead = lines[idx..<min(idx + 5, lines.count)]
                if lookahead.contains(where: { $0.plain.trimmingCharacters(in: .whitespaces).hasPrefix("Sent:") }) {
                    return Array(lines.prefix(idx))
                }
            }
        }
        return lines
    }

    private func trimLeadingTrailingBlank(_ lines: [StyledLine]) -> [StyledLine] {
        var s = 0, e = lines.count
        while s < e && lines[s].plain.trimmingCharacters(in: .whitespaces).isEmpty { s += 1 }
        while e > s && lines[e - 1].plain.trimmingCharacters(in: .whitespaces).isEmpty { e -= 1 }
        return Array(lines[s..<e])
    }

    // MARK: - Subject + date range

    // The Gmail print preamble typically contains the bold thread subject as
    // the largest text on page 1. We pick the longest non-empty line in the
    // preamble that is not "N messages" or the user's own header.
    private func inferSubject(from preamble: [StyledLine]) -> String {
        let candidates = preamble
            .map { $0.plain.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.lowercased().hasSuffix("messages") }
            .filter { !$0.contains("@") }
        return candidates.max(by: { $0.count < $1.count }) ?? "Email Thread"
    }

    private func computeDateRange(_ emails: [Email]) -> String {
        guard let first = emails.first else { return "" }
        if emails.count == 1 { return first.date }
        // Render as a single-line range using the first and last date strings.
        return "\(first.date) – \(emails.last!.date)"
    }
}
