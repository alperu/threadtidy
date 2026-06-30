import Foundation

// Field-level diff between two Thread parses (typically heuristic vs
// AI). Per spec 06 in docs/specs/06-differential-validator.md.
//
// Severity ladder:
//   error   — message-count mismatch, from_email mismatch, body sim < 0.85
//   warning — date >1min off, to-set mismatch, body sim 0.85–0.95,
//             subject mismatch (post-normalisation)
//   ok      — everything within tolerance
public struct ThreadDiff: Codable, Equatable {
    public let messageCountDelta: Int
    public let perMessageDiffs: [MessageDiff]
    public let subjectMismatch: Bool
    public let severity: IntegritySeverity
    public let humanSummary: String
}

public struct MessageDiff: Codable, Equatable {
    public let index: Int
    public let fromMatches: Bool
    public let dateMatches: Bool
    public let toMatches: Bool
    public let ccMatches: Bool
    public let bodySimilarity: Double
    public let bodyMissingFromHeuristic: [String]
    public let bodyAddedByHeuristic: [String]
    public let notes: [String]
}

extension IntegritySeverity: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "ok":      self = .ok
        case "warning": self = .warning
        case "error":   self = .error
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown severity \(raw)"
            )
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .ok: try c.encode("ok")
        case .warning: try c.encode("warning")
        case .error: try c.encode("error")
        }
    }
}

public enum DifferentialValidator {

    // Entry point. `heuristic` and `ai` are the two parses to compare.
    public static func diff(heuristic h: Thread, ai a: Thread) -> ThreadDiff {
        let subjectMismatch = !subjectsEqual(h.subject, a.subject)
        let countDelta = a.messages.count - h.messages.count

        let pairs = pairMessages(heuristic: h.messages, ai: a.messages)
        var perMessage: [MessageDiff] = []
        var maxSeverity: IntegritySeverity = .ok

        for (idx, pair) in pairs.enumerated() {
            let d = compareMessages(heur: pair.heur, ai: pair.ai, index: idx + 1)
            perMessage.append(d)
            let sev = severityForMessageDiff(d)
            maxSeverity = max(maxSeverity, sev)
        }

        // Roll up thread-level severities.
        if abs(countDelta) > 0 { maxSeverity = max(maxSeverity, .error) }
        if subjectMismatch     { maxSeverity = max(maxSeverity, .warning) }

        let summary = formatHumanSummary(
            countDelta: countDelta,
            subjectMismatch: subjectMismatch,
            perMessage: perMessage,
            severity: maxSeverity
        )

        return ThreadDiff(
            messageCountDelta: countDelta,
            perMessageDiffs: perMessage,
            subjectMismatch: subjectMismatch,
            severity: maxSeverity,
            humanSummary: summary
        )
    }

    // MARK: - Subject

    private static func subjectsEqual(_ a: String, _ b: String) -> Bool {
        normaliseSubject(a) == normaliseSubject(b)
    }

    private static func normaliseSubject(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces).lowercased()
        // Strip Re:/Fw:/Fwd: prefixes (one or more, possibly stacked).
        let prefixRX = try! NSRegularExpression(
            pattern: #"^((re|fw|fwd)\s*:\s*)+"#,
            options: [.caseInsensitive]
        )
        let r = NSRange(location: 0, length: (out as NSString).length)
        out = prefixRX.stringByReplacingMatches(in: out, range: r, withTemplate: "")
        // Collapse whitespace.
        out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return out
    }

    // MARK: - Message pairing

    private struct Pair { let heur: Email?; let ai: Email? }

    // Pairing strategy:
    //   1. (from_email, date-equal-to-1-min) exact match if both
    //      sides have those fields populated.
    //   2. fall back to from_email + position-in-thread.
    //   3. fall back to position-in-thread only.
    // Unpaired messages produce a Pair with one side nil — handled
    // as a count-delta diff at the thread level.
    private static func pairMessages(heuristic: [Email], ai: [Email]) -> [Pair] {
        var heurRem = heuristic
        var aiRem = ai
        var pairs: [Pair] = []

        // Pass 1: (email + date) exact-ish.
        var i = 0
        while i < heurRem.count {
            let h = heurRem[i]
            if let j = aiRem.firstIndex(where: { aiMsg in
                normEmail(h.fromEmail) == normEmail(aiMsg.fromEmail)
                    && datesWithinOneMinute(h.date, aiMsg.date)
            }) {
                pairs.append(Pair(heur: h, ai: aiRem[j]))
                heurRem.remove(at: i)
                aiRem.remove(at: j)
                continue
            }
            i += 1
        }

        // Pass 2: email-only + position.
        i = 0
        while i < heurRem.count {
            let h = heurRem[i]
            if let j = aiRem.firstIndex(where: { normEmail(h.fromEmail) == normEmail($0.fromEmail) }) {
                pairs.append(Pair(heur: h, ai: aiRem[j]))
                heurRem.remove(at: i)
                aiRem.remove(at: j)
                continue
            }
            i += 1
        }

        // Pass 3: positional pairing of remaining.
        let rem = max(heurRem.count, aiRem.count)
        for k in 0..<rem {
            let h = k < heurRem.count ? heurRem[k] : nil
            let a = k < aiRem.count ? aiRem[k] : nil
            pairs.append(Pair(heur: h, ai: a))
        }
        // Sort pairs by the lower-of-two-message-index when present.
        return pairs.sorted { p, q in
            let pi = p.heur?.index ?? p.ai?.index ?? Int.max
            let qi = q.heur?.index ?? q.ai?.index ?? Int.max
            return pi < qi
        }
    }

    // MARK: - Per-message comparison

    private static func compareMessages(heur: Email?, ai: Email?, index: Int) -> MessageDiff {
        guard let h = heur, let a = ai else {
            return MessageDiff(
                index: index,
                fromMatches: false, dateMatches: false,
                toMatches: false, ccMatches: false,
                bodySimilarity: 0,
                bodyMissingFromHeuristic: [],
                bodyAddedByHeuristic: [],
                notes: ["unpaired (\(heur == nil ? "missing from heuristic" : "missing from AI"))"]
            )
        }

        let fromMatches = normEmail(h.fromEmail) == normEmail(a.fromEmail)
            && normName(h.fromName) == normName(a.fromName)
        let dateMatches = datesWithinOneMinute(h.date, a.date)
        let toMatches = addressSet(h.to) == addressSet(a.to)
        let ccMatches = addressSet(h.cc ?? "") == addressSet(a.cc ?? "")

        let hBody = bodyText(h.bodyLines)
        let aBody = bodyText(a.bodyLines)
        let sim = jaroWinkler(hBody, aBody)

        var missing: [String] = []
        var added: [String] = []
        if sim < 0.95 {
            (missing, added) = lineLevelDiff(
                heuristic: h.bodyLines.map { $0.plain },
                ai:        a.bodyLines.map { $0.plain }
            )
        }

        var notes: [String] = []
        if !fromMatches {
            notes.append("from: heur='\(h.fromName) <\(h.fromEmail)>' ai='\(a.fromName) <\(a.fromEmail)>'")
        }
        if !dateMatches {
            notes.append("date: heur='\(h.date)' ai='\(a.date)'")
        }

        return MessageDiff(
            index: index,
            fromMatches: fromMatches,
            dateMatches: dateMatches,
            toMatches: toMatches,
            ccMatches: ccMatches,
            bodySimilarity: sim,
            bodyMissingFromHeuristic: missing,
            bodyAddedByHeuristic: added,
            notes: notes
        )
    }

    private static func severityForMessageDiff(_ d: MessageDiff) -> IntegritySeverity {
        var s: IntegritySeverity = .ok
        if d.notes.contains(where: { $0.hasPrefix("unpaired") }) { return .error }
        if !d.fromMatches { s = max(s, .error) }
        if d.bodySimilarity < 0.85 { s = max(s, .error) }
        if !d.dateMatches { s = max(s, .warning) }
        if !d.toMatches { s = max(s, .warning) }
        if d.bodySimilarity >= 0.85 && d.bodySimilarity < 0.95 { s = max(s, .warning) }
        return s
    }

    // MARK: - Normalisation

    private static func normEmail(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        // Strip surrounding <...> if present.
        if t.hasPrefix("<") { t = String(t.dropFirst()) }
        if t.hasSuffix(">") { t = String(t.dropLast()) }
        return t
    }

    private static func normName(_ s: String) -> String {
        // Strip any embedded "<...@...>" address so a name like
        // "Sarah Lee <sarah.lee@example.com>" (heuristic) compares equal
        // to "Sarah Lee" (cleaned AI output). Also strip any trailing
        // bare email address. Whitespace is collapsed so spacing
        // differences (e.g. "Name<email>" vs "Name <email>") don't
        // matter once the address has been removed.
        var t = s
        let bracketed = try! NSRegularExpression(pattern: #"<[^>]*@[^>]*>"#)
        let bareTail = try! NSRegularExpression(
            pattern: #"\s*[\w._%+-]+@[\w.-]+\.[A-Za-z]{2,}\s*$"#
        )
        let ns1 = t as NSString
        t = bracketed.stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: ns1.length), withTemplate: ""
        )
        let ns2 = t as NSString
        t = bareTail.stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: ns2.length), withTemplate: ""
        )
        t = t.trimmingCharacters(in: .whitespaces).lowercased()
        // Collapse internal whitespace.
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t
    }

    private static func addressSet(_ s: String) -> Set<String> {
        let rx = try! NSRegularExpression(pattern: #"<([^>]+)>|([\w._%+-]+@[\w.-]+\.[A-Za-z]{2,})"#)
        let ns = s as NSString
        let matches = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out: Set<String> = []
        for m in matches {
            for i in 1...2 {
                let r = m.range(at: i)
                if r.location != NSNotFound {
                    out.insert(normEmail(ns.substring(with: r)))
                    break
                }
            }
        }
        return out
    }

    // MARK: - Date comparison

    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "EEE, MMM d, yyyy 'at' h:mm a",   // Gmail
            "EEE M/d/yyyy h:mm a",            // Outlook web
            "M/d/yyyy h:mm a",                // Outlook desktop
            "MMMM d, yyyy 'at' h:mm:ss a zzz",// Apple Mail
            "MMMM d, yyyy 'at' h:mm a zzz",
        ]
        return patterns.map { p in
            let f = DateFormatter()
            f.dateFormat = p
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for f in dateFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    private static func datesWithinOneMinute(_ a: String, _ b: String) -> Bool {
        // Verbatim equal?
        let an = a.trimmingCharacters(in: .whitespaces)
        let bn = b.trimmingCharacters(in: .whitespaces)
        if an.lowercased() == bn.lowercased() { return true }
        // Try parsed.
        guard let pa = parseDate(an), let pb = parseDate(bn) else { return false }
        return abs(pa.timeIntervalSince(pb)) <= 60
    }

    // MARK: - Body similarity

    private static func bodyText(_ lines: [StyledLine]) -> String {
        let raw = lines.map(\.plain).joined(separator: " ")
        // Collapse all whitespace runs to single space, normalise bullets.
        var out = ""
        var lastWasSpace = false
        for ch in raw {
            if ch.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else if ch == "•" || ch == "·" || ch == "-" || ch == "*" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // Jaro-Winkler similarity in [0, 1]. Cheap, O(N*M), good enough
    // for body-prose comparison in our N ~ 4000 char range.
    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        let a = Array(s1)
        let b = Array(s2)
        let matchDistance = max(a.count, b.count) / 2 - 1
        var aMatches = [Bool](repeating: false, count: a.count)
        var bMatches = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in 0..<a.count {
            let lo = max(0, i - matchDistance)
            let hi = min(b.count - 1, i + matchDistance)
            if lo > hi { continue }
            for j in lo...hi {
                if bMatches[j] { continue }
                if a[i] != b[j] { continue }
                aMatches[i] = true
                bMatches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }
        var t = 0
        var k = 0
        for i in 0..<a.count {
            if !aMatches[i] { continue }
            while !bMatches[k] { k += 1 }
            if a[i] != b[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count)
                    + m / Double(b.count)
                    + (m - Double(t) / 2) / m) / 3.0
        // Winkler boost for shared prefix up to 4 chars.
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) {
            if a[i] == b[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    // Line-level diff returning lines present in `ai` but not in
    // `heuristic` (missing) and vice versa (added). Naïve set-diff
    // after whitespace-trim normalisation; good enough for journal
    // entries and integrity-report bullet lists.
    private static func lineLevelDiff(heuristic: [String], ai: [String])
        -> (missing: [String], added: [String])
    {
        let hSet = Set(heuristic.map { normLine($0) })
        let aSet = Set(ai.map { normLine($0) })
        let missing = ai.filter { !hSet.contains(normLine($0)) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let added = heuristic.filter { !aSet.contains(normLine($0)) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (missing: missing, added: added)
    }

    private static func normLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Human summary

    private static func formatHumanSummary(
        countDelta: Int,
        subjectMismatch: Bool,
        perMessage: [MessageDiff],
        severity: IntegritySeverity
    ) -> String {
        var parts: [String] = []
        switch severity {
        case .ok:      parts.append("heuristic and AI agree")
        case .warning: parts.append("minor disagreement")
        case .error:   parts.append("major disagreement")
        }
        if countDelta != 0 {
            parts.append("message count Δ \(countDelta > 0 ? "+" : "")\(countDelta)")
        }
        if subjectMismatch { parts.append("subject mismatch") }
        let badMsgs = perMessage.filter {
            !$0.fromMatches || !$0.dateMatches
                || !$0.toMatches || $0.bodySimilarity < 0.95
        }
        if !badMsgs.isEmpty {
            parts.append("\(badMsgs.count) of \(perMessage.count) message(s) differ")
        }
        return parts.joined(separator: "; ")
    }
}

// max(IntegritySeverity, IntegritySeverity) — promotion ladder.
private extension IntegritySeverity {
    var rank: Int {
        switch self {
        case .ok: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
}
private func max(_ a: IntegritySeverity, _ b: IntegritySeverity) -> IntegritySeverity {
    a.rank >= b.rank ? a : b
}
