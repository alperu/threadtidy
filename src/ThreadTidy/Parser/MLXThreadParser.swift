import Foundation
#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
#endif

// Universal-fallback parser using a local MLX-quantized LLM.
//
// Phase-2 STUB: prompt builder, response-JSON schema, response→Thread
// mapping, and chunker boundary detection are all real and tested.
// The actual MLX inference call (`generate`) throws .modelNotInstalled
// until mlx-swift is vendored. Once vendored, only `runGeneration` and
// the `init` model-load step need filling in — the rest of the
// pipeline (parse, chunk, reconcile) is ready.
public final class MLXThreadParser: ThreadParsing {

    public let model: AIModel
    public let modelStore: ModelStore

    public init(model: AIModel = .llama1B,
                modelStore: ModelStore = .default) {
        self.model = model
        self.modelStore = modelStore
    }

    // ThreadParsing conformance — sync façade that drives the async
    // pipeline. Pipeline.run will gain an async variant in spec 07
    // Phase 2; for now this lets the parser slot in next to the
    // heuristics under the same protocol.
    public func parse(lines: [StyledLine]) throws -> Thread {
        // Run the async impl on a dedicated queue, blocking the caller.
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Thread, Error>!
        Task.detached { [self] in
            do {
                let t = try await parseAsync(lines: lines)
                result = .success(t)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .success(let t): return t
        case .failure(let e): throw e
        }
    }

    public func parseAsync(lines: [StyledLine]) async throws -> Thread {
        guard modelStore.isInstalled(model) else {
            throw MLXError.modelNotInstalled(model)
        }
        let raw = lines.map(\.plain).joined(separator: "\n")
        // Chunker (Phase-2 task #3): if the input plausibly exceeds the
        // model's token budget, split at message boundaries, generate
        // per chunk, and reconcile. Single-chunk path remains identical
        // to the original implementation.
        let chunks = chunkIfNeeded(lines: lines, raw: raw)
        if chunks.count > 1 {
            var payloads: [Payload] = []
            for chunk in chunks {
                let chunkRaw = chunk.map(\.plain).joined(separator: "\n")
                let payload = try await generateAndParse(raw: chunkRaw)
                payloads.append(payload)
            }
            let merged = reconcilePayloads(payloads)
            let enforced = Self.enforceBoundariesPostHoc(merged)
            return mapToThread(enforced, sourceLines: lines)
        }
        let payload = try await generateAndParse(raw: raw)
        let enforced = Self.enforceBoundariesPostHoc(payload)
        return mapToThread(enforced, sourceLines: lines)
    }

    // Defensive post-processor: small quantized models will occasionally
    // ignore the prompt's "treat these as message boundaries" rule and
    // bury an entire reply inside the preceding message's body. Walk
    // each message body for unprocessed boundary markers; if we find
    // one, split that message in two.
    //
    // Two patterns matched, mirroring OutlookThreadParser:
    //   (a) inline reply preface: a line starting with
    //       "On <date> <name> <email> wrote:"
    //   (b) stacked forwarded block: a "From:" line followed within the
    //       next few lines by "Sent:", "To:", "Subject:" rows.
    //
    // Each split produces a new message whose to: field is left empty —
    // the chronological derivation runs separately in mapToThread (TODO)
    // or via the heuristic; we don't fabricate it here.
    public static func enforceBoundariesPostHoc(_ p: Payload) -> Payload {
        var out: [Payload.Message] = []
        for msg in p.messages {
            out.append(contentsOf: splitOnEmbeddedBoundaries(msg))
        }
        // Backfill to: for any message whose to is empty using the
        // PREVIOUS sender's "Name <email>" — same chain rule as the
        // Outlook heuristic. Index 0 (top-of-thread) is exempt.
        for i in 1..<out.count {
            guard (out[i].to.isEmpty
                   || out[i].to.trimmingCharacters(in: .whitespaces).isEmpty)
            else { continue }
            let prev = out[i - 1]
            let pn = prev.from_name.trimmingCharacters(in: .whitespaces)
            let pe = prev.from_email.trimmingCharacters(in: .whitespaces)
            let derived: String
            if !pn.isEmpty && !pe.isEmpty { derived = "\(pn) <\(pe)>" }
            else if !pe.isEmpty { derived = pe }
            else { continue }
            out[i] = Payload.Message(
                from_name: out[i].from_name,
                from_email: out[i].from_email,
                date: out[i].date,
                to: derived,
                cc: out[i].cc,
                bcc: out[i].bcc,
                body: out[i].body
            )
        }
        return Payload(subject: p.subject, messages: out)
    }

    private static let replyPrefaceRX = try! NSRegularExpression(
        pattern: #"^On\s+(.+?\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM|am|pm)?(?:\s+[A-Z]{2,5})?),?\s+(.+?)\s+<([^>]+)>\s+wrote:\s*$"#
    )
    private static let fromRowRX = try! NSRegularExpression(
        pattern: #"^From:\s*(.+?)\s*<([^>]+)>\s*$"#
    )
    private static let sentRowRX    = try! NSRegularExpression(pattern: #"^Sent:\s*(.+)$"#)
    private static let toRowRX      = try! NSRegularExpression(pattern: #"^To:\s*(.+)$"#)
    private static let subjectRowRX = try! NSRegularExpression(pattern: #"^Subject:\s*(.+)$"#)

    private static func splitOnEmbeddedBoundaries(
        _ msg: Payload.Message
    ) -> [Payload.Message] {
        let lines = msg.body.components(separatedBy: "\n")
        // Find boundary indices in this body. We DON'T split at index 0
        // — if the very first line is a boundary marker, the message
        // already legitimately starts with one; the model just included
        // the marker in the body. We strip it instead.
        var splits: [(idx: Int, kind: BoundaryKind, captured: ParsedBoundary)] = []
        var i = 0
        while i < lines.count {
            let raw = lines[i].trimmingCharacters(in: .whitespaces)
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = replyPrefaceRX.firstMatch(in: raw, range: range) {
                let pb = ParsedBoundary(
                    fromName: ns.substring(with: m.range(at: 2)),
                    fromEmail: ns.substring(with: m.range(at: 3)),
                    date: ns.substring(with: m.range(at: 1)),
                    to: ""
                )
                splits.append((i, .reply, pb))
            } else if let m = fromRowRX.firstMatch(in: raw, range: range),
                      isStackedForwardedHeader(at: i, in: lines) {
                let pb = parseStackedBlock(startingAt: i, in: lines, fromMatch: m, rawLine: raw)
                splits.append((i, .forwarded, pb))
                // Skip past the consumed block so we don't re-detect
                // its inner rows as boundaries.
                i += pb.blockSize
                continue
            }
            i += 1
        }
        if splits.isEmpty {
            return [msg]
        }
        var out: [Payload.Message] = []
        // First slice = lines BEFORE the first boundary (the original
        // message's true body). Skip if the boundary is at line 0.
        if splits[0].idx > 0 {
            let body = lines[0..<splits[0].idx].joined(separator: "\n")
            out.append(Payload.Message(
                from_name: msg.from_name, from_email: msg.from_email,
                date: msg.date, to: msg.to,
                cc: msg.cc, bcc: msg.bcc, body: body
            ))
        } else {
            // No prior body — keep the original metadata but with empty
            // body so the chain isn't reordered.
            out.append(Payload.Message(
                from_name: msg.from_name, from_email: msg.from_email,
                date: msg.date, to: msg.to,
                cc: msg.cc, bcc: msg.bcc, body: ""
            ))
        }
        // Each boundary => new message with body = lines between this
        // boundary's end and the next boundary (or end of body).
        for (k, s) in splits.enumerated() {
            let bodyStart = s.idx + (s.kind == .forwarded ? s.captured.blockSize : 1)
            let bodyEnd = (k + 1 < splits.count) ? splits[k + 1].idx : lines.count
            let body = bodyStart <= bodyEnd
                ? lines[bodyStart..<bodyEnd].joined(separator: "\n")
                : ""
            out.append(Payload.Message(
                from_name: s.captured.fromName,
                from_email: s.captured.fromEmail,
                date: s.captured.date,
                to: s.captured.to,
                cc: nil, bcc: nil,
                body: body
            ))
        }
        return out
    }

    private enum BoundaryKind { case reply, forwarded }

    private struct ParsedBoundary {
        let fromName: String
        let fromEmail: String
        let date: String
        let to: String
        var blockSize: Int = 1   // how many source lines the boundary consumed
    }

    private static func isStackedForwardedHeader(
        at idx: Int, in lines: [String]
    ) -> Bool {
        // Require at least one of Sent: / To: / Subject: within the
        // next 5 lines so a stray "From:" in body prose doesn't trigger.
        let end = min(idx + 5, lines.count)
        for j in (idx + 1)..<end {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            let ns = t as NSString
            let r = NSRange(location: 0, length: ns.length)
            if sentRowRX.firstMatch(in: t, range: r) != nil
                || toRowRX.firstMatch(in: t, range: r) != nil
                || subjectRowRX.firstMatch(in: t, range: r) != nil {
                return true
            }
        }
        return false
    }

    private static func parseStackedBlock(
        startingAt idx: Int, in lines: [String],
        fromMatch m: NSTextCheckingResult, rawLine: String
    ) -> ParsedBoundary {
        let ns = rawLine as NSString
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let email = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        var date = "", to = "", consumed = 1
        let end = min(idx + 6, lines.count)
        for j in (idx + 1)..<end {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            let tns = t as NSString
            let r = NSRange(location: 0, length: tns.length)
            if let mm = sentRowRX.firstMatch(in: t, range: r) {
                date = tns.substring(with: mm.range(at: 1)).trimmingCharacters(in: .whitespaces)
                consumed = (j - idx) + 1
            } else if let mm = toRowRX.firstMatch(in: t, range: r) {
                to = tns.substring(with: mm.range(at: 1)).trimmingCharacters(in: .whitespaces)
                consumed = (j - idx) + 1
            } else if subjectRowRX.firstMatch(in: t, range: r) != nil {
                consumed = (j - idx) + 1
                break
            } else if !t.isEmpty {
                break
            }
        }
        _ = name; _ = email
        return ParsedBoundary(
            fromName: name, fromEmail: email, date: date, to: to,
            blockSize: consumed
        )
    }

    // Runs one generation with a single JSON-retry on parse failure.
    // The first attempt uses the standard prompt; the second appends a
    // corrective suffix that includes the failure reason so the model
    // has context about what went wrong.
    func generateAndParse(raw: String) async throws -> Payload {
        let firstPrompt = buildPrompt(raw: raw)
        let firstResponse = try await runGeneration(prompt: firstPrompt)
        Self.logRawOutput(raw: raw, response: firstResponse, attempt: 1)
        do {
            return try parseJSON(firstResponse, retry: false, raw: raw)
        } catch let MLXError.jsonParseFailure(reason, _) {
            let retryPrompt = buildRetryPrompt(raw: raw, failureReason: reason)
            let retryResponse = try await runGeneration(prompt: retryPrompt)
            Self.logRawOutput(raw: raw, response: retryResponse, attempt: 2)
            return try parseJSON(retryResponse, retry: true, raw: raw)
        }
    }

    // Append the raw prompt-input excerpt and raw model output to a
    // debug log file. One JSON object per line, same place as the
    // differential journal. Lets you `tail -f` the file while testing
    // and see exactly what the model is producing — including whether
    // it dropped message boundaries, hallucinated phantom messages, or
    // packed everything into from_name. Truncated to keep the file
    // manageable; the differential journal already retains the full
    // first 1k of raw input alongside.
    private static let mlxLogQueue = DispatchQueue(
        label: "net.basservices.ThreadTidy.mlxLog"
    )
    private static func logRawOutput(raw: String, response: String, attempt: Int) {
        mlxLogQueue.async {
            let url = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("ThreadTidy/mlx-raw.jsonl")
            guard let url else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let entry: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "attempt": attempt,
                "input_chars": raw.count,
                "input_excerpt": String(raw.prefix(500)),
                "output_chars": response.count,
                "output": String(response.prefix(8000)),
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys]
            ) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.write(Data("\n".utf8))
                try? handle.close()
            } else {
                try? (data + Data("\n".utf8)).write(to: url)
            }
        }
    }

    func buildRetryPrompt(raw: String, failureReason: String) -> String {
        """
        \(buildPrompt(raw: raw))

        ---
        Your previous output was not valid JSON (\(failureReason)). Output only the JSON object, no prose.
        """
    }

    // MARK: - Prompt

    public func buildPrompt(raw: String) -> String {
        """
        \(Self.systemPrompt)

        ---
        Email thread to extract:
        \(raw)
        """
    }

    static let systemPrompt = """
    You are an email-thread extractor. Output ONLY valid JSON matching the
    schema below — no prose, no Markdown, no commentary. Do not summarize,
    paraphrase, or alter body content. Preserve every character of each
    email body verbatim.

    Schema:
    {
      "subject": "<thread subject>",
      "messages": [
        {
          "from_name":  "<sender display name ONLY — no email, no angle brackets>",
          "from_email": "<sender email address ONLY — bare, no angle brackets, no name>",
          "date":       "<verbatim date string>",
          "to":         "<verbatim To header value>",
          "cc":         "<verbatim Cc header value, or empty>",
          "bcc":        "<verbatim Bcc header value, or empty>",
          "body":       "<verbatim author text only — no signatures collapsed,
                         no quotes, no forwarded blocks>"
        }
      ]
    }

    Field rules — these are strict, the renderer treats name and email as
    separate fields and will display each one in its own place:
    - from_name contains the human display name and NOTHING else.
      Correct:   "Sarah Lee"
      Wrong:     "Sarah Lee <sarah.lee@example.com>"
      Wrong:     "Sarah Lee<sarah.lee@example.com>"
    - from_email contains the bare email address and NOTHING else.
      Correct:   "sarah.lee@example.com"
      Wrong:     "<sarah.lee@example.com>"
      Wrong:     "Sarah Lee <sarah.lee@example.com>"
    - The same rule applies inside the "to", "cc", and "bcc" header
      values: preserve them verbatim from the source.

    Message boundaries — emit a NEW message object whenever ANY of these
    patterns appears in the source. They mark the start of a new email
    in the thread; they are NEVER content to strip:
      (a) A Gmail-style one-line header:
          "Sarah Lee <sarah.lee@example.com> Tue, May 12, 2026 at 6:37 PM"
          (display name + bracketed email + date on a single line).
      (b) An inline reply preface:
          "On Thu, Apr 30, 2026 at 7:37 AM Jane Doe <jane.doe@example.com> wrote:"
          The body that FOLLOWS this line belongs to the new message.
          Extract the sender name, email, and date from inside this
          preface — they are all present.
      (c) An Outlook-style stacked block of consecutive rows:
          From: <name> <email>
          Sent: <date>
          To:   <recipient(s)>
          Subject: <subject>
          The body that follows the Subject row belongs to the new
          message. (The very first message at the top of an Outlook
          print uses this format.)

    Message-count rule:
    - If the source begins with a preamble like "N messages" or "5 messages",
      your output MUST contain EXACTLY N message objects — no more, no fewer.
    - If there is no such preamble, emit one message object per boundary
      from the list above.
    - Attachment listings (a line like "2 attachments" followed by
      "filename.pdf  237K") belong to the PRECEDING message's body and
      are NOT a separate message.
    - Email signatures, confidentiality notices, "Sent from my iPhone"
      footers, and "--" separator lines belong to the PRECEDING message's
      body and are NOT separate messages.

    Filling missing recipients:
    - Inline reply prefaces (pattern b) have no To: row. For those
      messages, fill "to" with the sender of the IMMEDIATELY NEWER
      message in the thread (the one that quoted this reply), formatted
      as "<name> <<email>>". That older message was written TO that
      newer sender — derive it from the chain.

    Strip from body content (these are NOT message boundaries — they
    are noise inside an already-identified message's body):
    - page-header banners (timestamps, app name, footer URLs like
      "outlook.live.com/...", "mail.google.com/...")
    - "[Quoted text hidden]" placeholder markers (Gmail's collapsed
      quote stub — no surrounding content to strip; just remove the
      marker line itself).

    Output JSON only.
    """

    // MARK: - JSON parsing

    public struct Payload: Decodable {
        public let subject: String
        public let messages: [Message]
        public struct Message: Decodable {
            public let from_name: String
            public let from_email: String
            public let date: String
            public let to: String
            public let cc: String?
            public let bcc: String?
            public let body: String
            public init(from_name: String, from_email: String, date: String,
                        to: String, cc: String?, bcc: String?, body: String) {
                self.from_name = from_name
                self.from_email = from_email
                self.date = date
                self.to = to
                self.cc = cc
                self.bcc = bcc
                self.body = body
            }
        }
        public init(subject: String, messages: [Message]) {
            self.subject = subject
            self.messages = messages
        }
    }

    public func parseJSON(_ raw: String, retry: Bool, raw rawSource: String) throws -> Payload {
        // Strip any non-JSON preamble — quantized models occasionally
        // emit a stray newline or "{" prefix.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            throw MLXError.jsonParseFailure(reason: "no JSON object found", attempt: retry ? 2 : 1)
        }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else {
            throw MLXError.jsonParseFailure(reason: "non-utf8 bytes", attempt: retry ? 2 : 1)
        }
        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MLXError.jsonParseFailure(
                reason: "decode: \(error.localizedDescription)",
                attempt: retry ? 2 : 1
            )
        }
    }

    // MARK: - Mapping to Thread

    public func mapToThread(_ p: Payload, sourceLines: [StyledLine]) -> Thread {
        // Build a flat per-character styling table from the source
        // lines. The LCS pass below maps each character of the model's
        // body output to a source character (where one exists) and
        // copies that source character's StyledRun attributes back onto
        // the output. Characters with no source match get default
        // styling.
        let sourceRuns: [StyledRun] = sourceLines.flatMap(\.runs)

        let emails: [Email] = p.messages.enumerated().map { (i, m) in
            let bodyLines = Self.replayStyles(body: m.body, sourceRuns: sourceRuns)
            let (cleanName, cleanEmail) = Self.normalizeSenderFields(
                fromName: m.from_name, fromEmail: m.from_email
            )
            return Email(
                index: i + 1,
                fromName: cleanName,
                fromEmail: cleanEmail,
                date: m.date,
                to: m.to,
                cc: m.cc,
                bcc: m.bcc,
                bodyLines: bodyLines
            )
        }
        let dateRange: String = {
            guard let first = emails.first else { return "" }
            if emails.count == 1 { return first.date }
            return "\(first.date) – \(emails.last!.date)"
        }()
        return Thread(
            subject: p.subject,
            dateRange: dateRange,
            messages: emails
        )
    }

    // Defensive cleanup: quantized models sometimes ignore the schema
    // and pack the whole "Name <email>" header into from_name (and/or
    // wrap from_email in angle brackets). Strip any "<…@…>" tail from
    // from_name and any surrounding "<>" from from_email so the
    // renderer's per-field display ("N. <name>" heading + "From: <email>"
    // row) doesn't end up duplicating the email.
    //
    // If the model packed an email into from_name but left from_email
    // empty, lift the email out into from_email rather than dropping it
    // (the email address is a court-required field).
    public static func normalizeSenderFields(
        fromName: String, fromEmail: String
    ) -> (name: String, email: String) {
        var name = fromName.trimmingCharacters(in: .whitespaces)
        var email = fromEmail.trimmingCharacters(in: .whitespaces)

        // Pull a bracketed email out of from_name if present.
        // Matches the LAST <…@…> in the string so multi-bracket cases
        // like "Name<a@b> <a@b>" collapse cleanly.
        if let lt = name.lastIndex(of: "<"),
           let gt = name.lastIndex(of: ">"),
           lt < gt {
            let candidate = String(name[name.index(after: lt)..<gt])
                .trimmingCharacters(in: .whitespaces)
            if candidate.contains("@") {
                if email.isEmpty { email = candidate }
                name = String(name[..<lt]).trimmingCharacters(in: .whitespaces)
            }
        }

        // If from_name still has a trailing bare email (no brackets), strip it.
        let bareEmailTail = try! NSRegularExpression(
            pattern: #"\s+[\w._%+-]+@[\w.-]+\.[A-Za-z]{2,}\s*$"#
        )
        let nameNS = name as NSString
        let r = NSRange(location: 0, length: nameNS.length)
        if let m = bareEmailTail.firstMatch(in: name, range: r) {
            let tail = nameNS.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            if email.isEmpty { email = tail }
            name = nameNS.replacingCharacters(in: m.range, with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        // Strip surrounding angle brackets from from_email.
        if email.hasPrefix("<") { email = String(email.dropFirst()) }
        if email.hasSuffix(">") { email = String(email.dropLast()) }
        email = email.trimmingCharacters(in: .whitespaces)

        return (name, email)
    }

    // MARK: - Styled-run LCS replay

    // A per-character record of the source: the character itself, plus
    // the StyledRun attributes (bold/italic/underline/link/fontSize)
    // that apply to it.
    struct SourceChar {
        let ch: Character
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let link: URL?
        let fontSize: CGFloat
    }

    // Walks source StyledRuns, emitting one SourceChar per character.
    static func flattenSourceChars(_ runs: [StyledRun]) -> [SourceChar] {
        var out: [SourceChar] = []
        for r in runs {
            for c in r.text {
                out.append(SourceChar(
                    ch: c,
                    bold: r.bold,
                    italic: r.italic,
                    underline: r.underline,
                    link: r.link,
                    fontSize: r.fontSize
                ))
            }
        }
        return out
    }

    // For each character of `body`, returns the matched source index
    // (or -1 if unmatched) via longest-common-subsequence over the
    // body's characters and the source's characters. The LCS is bounded
    // to keep cost tractable; for very long inputs we fall back to a
    // greedy linear scan that still yields good alignment quality for
    // typical email-thread sizes.
    static func lcsAlign(body: [Character], source: [SourceChar]) -> [Int] {
        let n = body.count
        let m = source.count
        if n == 0 || m == 0 {
            return Array(repeating: -1, count: n)
        }
        // Cap the DP table to ~4M cells (≈16MB Int32). Threads bigger
        // than that should use the greedy fallback — quality stays
        // high because LLM output is char-for-char close to source.
        if n * m > 4_000_000 {
            return greedyAlign(body: body, source: source)
        }
        // dp[i][j] = LCS length of body[0..<i], source[0..<j]
        var dp = Array(repeating: Array(repeating: Int32(0), count: m + 1), count: n + 1)
        for i in 1...n {
            let bc = body[i - 1]
            for j in 1...m {
                if bc == source[j - 1].ch {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // Backtrack to recover alignment.
        var matches = Array(repeating: -1, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if body[i - 1] == source[j - 1].ch {
                matches[i - 1] = j - 1
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches
    }

    // O(n+m) fallback aligner — walks both sequences once, advancing
    // the source pointer until it finds the current body char (within
    // a small lookahead window). Good enough when the LLM faithfully
    // echoes the source body.
    static func greedyAlign(body: [Character], source: [SourceChar]) -> [Int] {
        var matches = Array(repeating: -1, count: body.count)
        var sIdx = 0
        let lookahead = 64
        for (bIdx, bc) in body.enumerated() {
            let end = min(sIdx + lookahead, source.count)
            if sIdx < source.count {
                if let found = (sIdx..<end).first(where: { source[$0].ch == bc }) {
                    matches[bIdx] = found
                    sIdx = found + 1
                }
            }
        }
        return matches
    }

    // Replays per-character source styling onto the model's body
    // string, splitting on '\n' into StyledLines. Runs that share the
    // same style flags are coalesced so the renderer doesn't see
    // single-character runs everywhere.
    static func replayStyles(body: String, sourceRuns: [StyledRun]) -> [StyledLine] {
        let sourceChars = flattenSourceChars(sourceRuns)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [StyledLine] = []
        // We feed the LCS the whole body at once (so a match found late
        // in one source line still works), then carve back by line.
        let bodyChars = Array(body)
        let alignment = lcsAlign(body: bodyChars, source: sourceChars)
        var globalIdx = 0
        for line in lines {
            let lineChars = Array(line)
            var runs: [StyledRun] = []
            var cur = StyledRun(text: "")
            for c in lineChars {
                let sIdx = alignment[globalIdx]
                let styled: StyledRun
                if sIdx >= 0 {
                    let sc = sourceChars[sIdx]
                    styled = StyledRun(
                        text: String(c),
                        bold: sc.bold,
                        italic: sc.italic,
                        underline: sc.underline,
                        link: sc.link,
                        fontSize: sc.fontSize
                    )
                } else {
                    styled = StyledRun(text: String(c))
                }
                if runs.isEmpty && cur.text.isEmpty {
                    cur = styled
                } else if styled.bold == cur.bold
                    && styled.italic == cur.italic
                    && styled.underline == cur.underline
                    && styled.link == cur.link
                    && styled.fontSize == cur.fontSize {
                    cur.text.append(c)
                } else {
                    runs.append(cur)
                    cur = styled
                }
                globalIdx += 1
            }
            if !cur.text.isEmpty { runs.append(cur) }
            // Consume the '\n' that split() omitted (advance globalIdx).
            globalIdx += 1
            out.append(StyledLine(runs: runs.isEmpty ? [StyledRun(text: "")] : runs))
        }
        return out
    }

    // MARK: - Chunker

    // Splits `lines` at message-header boundaries when the input
    // exceeds the model's tokenBudget. Boundary detection uses the
    // same Gmail-style "<name> <email> <timestamp>" pattern that
    // GmailThreadParser uses — it also matches the start of inline
    // quoted blocks ("On <date> <name> <email> wrote:"), which is
    // exactly where we'd want to split anyway. Returns the original
    // line list as a single chunk if no split is needed.
    func chunkIfNeeded(lines: [StyledLine], raw: String) -> [[StyledLine]] {
        // Approximation: ~4 chars per token. We add a fixed prompt
        // overhead estimate for the system prompt + JSON schema.
        let promptOverheadTokens = 400
        let estimatedTokens = raw.count / 4 + promptOverheadTokens
        if estimatedTokens <= model.tokenBudget {
            return [lines]
        }
        // Find boundary line indices.
        var boundaryIdxs: [Int] = []
        for (i, line) in lines.enumerated() {
            if Self.isMessageBoundary(line) { boundaryIdxs.append(i) }
        }
        // If there are no boundaries, we can't safely split — return
        // a single chunk and let the model do its best.
        guard !boundaryIdxs.isEmpty else { return [lines] }

        // Greedy pack: accumulate lines into chunks, starting a new
        // chunk at a boundary whenever the running char count would
        // exceed budget.
        let charBudget = max(1024, (model.tokenBudget - promptOverheadTokens) * 4)
        var chunks: [[StyledLine]] = []
        var current: [StyledLine] = []
        var currentChars = 0
        // We split only AT boundaries. Walk lines; if we hit a
        // boundary and current chunk is non-empty and over half-budget,
        // flush before adding.
        for (i, line) in lines.enumerated() {
            let isBoundary = boundaryIdxs.contains(i)
            let lineChars = line.plain.count + 1
            if isBoundary && !current.isEmpty && currentChars + lineChars > charBudget {
                chunks.append(current)
                current = []
                currentChars = 0
            }
            current.append(line)
            currentChars += lineChars
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // Gmail-style message header detector — mirrors the regex in
    // ThreadParser. Also catches "On <date> <name> <email> wrote:"
    // reply quote headers, which are valid split points for chunking
    // purposes even though the heuristic parser discards them.
    static let messageHeaderRegex = try! NSRegularExpression(
        pattern: #"\s+\w{3},\s\w{3}\s\d{1,2},\s\d{4}\sat\s\d{1,2}:\d{2}\s(?:AM|PM)\s*$"#
    )
    static let nameEmailRegex = try! NSRegularExpression(
        pattern: #"^(.+?)\s+<([^>]+)>"#
    )
    static let replyQuoteRegex = try! NSRegularExpression(
        pattern: #"^On\s+\w{3},?\s+.+?<.+@.+>\s+wrote:\s*$"#
    )

    public static func isMessageBoundary(_ line: StyledLine) -> Bool {
        let s = line.plain.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        if replyQuoteRegex.firstMatch(in: s, range: full) != nil { return true }
        guard let m = messageHeaderRegex.firstMatch(in: s, range: full) else {
            return false
        }
        let leadEnd = m.range.location
        guard leadEnd > 0 else { return false }
        let lead = ns.substring(with: NSRange(location: 0, length: leadEnd))
        let leadNS = lead as NSString
        return nameEmailRegex.firstMatch(in: lead, range: NSRange(location: 0, length: leadNS.length)) != nil
    }

    // Merges multiple per-chunk Payloads into a single Payload:
    //   * subject = first chunk's subject (it has the page-1 preamble)
    //   * messages = concatenation of all chunks' messages, re-indexed
    //     by position. We do NOT re-index in Payload itself — Payload
    //     has no index field — mapToThread assigns indices in order.
    func reconcilePayloads(_ payloads: [Payload]) -> Payload {
        let subject = payloads.first?.subject ?? ""
        let allMessages = payloads.flatMap(\.messages)
        return Payload(subject: subject, messages: allMessages)
    }

    // MARK: - Generation (stub)

    // Real implementation: loads the local MLX-quantized weights via
    // MLXLMCommon's directory-based ModelConfiguration, prepares the
    // prompt as a UserInput, and streams tokens with temperature=0
    // (argmax) until EOS, a hard token cap, or a ~32k-char safety
    // ceiling. Returns the accumulated decoded text.
    //
    // Loading is gated on isRuntimeAvailable so an Intel build (where
    // MLX isn't usable) fails gracefully with .modelNotInstalled.
    func runGeneration(prompt: String) async throws -> String {
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        guard ModelStore.isRuntimeAvailable else {
            throw MLXError.modelNotInstalled(model)
        }
        // Modest GPU cache cap to keep RSS bounded on the 1B model.
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)

        let dir = modelStore.modelURL(model)
        let configuration = ModelConfiguration(
            directory: dir,
            extraEOSTokens: []
        )

        // maxTokens budget: roughly half the model's context window,
        // since the prompt + raw thread already consumes the other
        // half. The chunker upstream guarantees we don't blow past the
        // window.
        let maxOutTokens = max(1024, model.tokenBudget / 2)
        let params = GenerateParameters(
            maxTokens: maxOutTokens,
            temperature: 0.0,
            topP: 1.0
        )

        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        )

        return try await container.perform { (context: ModelContext) -> String in
            let userInput = UserInput(prompt: prompt)
            let lmInput = try await context.processor.prepare(input: userInput)
            var output = ""
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: context
            )
            for await event in stream {
                if let chunk = event.chunk {
                    output += chunk
                    if output.count > 32_000 { break }
                }
            }
            return output
        }
        #else
        throw MLXError.modelNotInstalled(model)
        #endif
    }
}

public enum MLXError: Error, LocalizedError {
    case modelNotInstalled(AIModel)
    case generationTimeout
    case jsonParseFailure(reason: String, attempt: Int)
    case bodyAlignmentFailed

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let m):
            return "MLX model not installed: \(m.rawValue). Install via Settings."
        case .generationTimeout:
            return "MLX generation timed out."
        case .jsonParseFailure(let r, let a):
            return "MLX response was not valid JSON (attempt \(a)): \(r)"
        case .bodyAlignmentFailed:
            return "MLX body output could not be aligned to source styled runs."
        }
    }
}
