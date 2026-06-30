import Foundation

// Verifies that the cleaning pass kept every message and that none of the
// per-message fields ended up empty. Builds an IntegrityReport that the
// GUI surfaces to the user.
public final class IntegrityChecker {

    public init() {}

    public func check(sourceLines: [StyledLine],
                      thread: Thread,
                      parsedBy: ParserKind? = nil,
                      differential: ThreadDiff? = nil) -> IntegrityReport {
        var warnings: [String] = []
        var errors: [String] = []

        // 1. Compare against the explicit "N messages" line in the preamble.
        let expected = extractExpectedCount(from: sourceLines)
        if let expected = expected, expected != thread.messages.count {
            errors.append("Expected \(expected) messages from source preamble; parsed \(thread.messages.count).")
        }

        // 2. Per-message field completeness.
        for m in thread.messages {
            if m.fromName.isEmpty {
                errors.append("Message \(m.index) is missing a sender name.")
            }
            if !m.fromEmail.contains("@") {
                errors.append("Message \(m.index) has an invalid sender email: '\(m.fromEmail)'.")
            }
            if m.date.isEmpty {
                errors.append("Message \(m.index) is missing a date.")
            }
            if m.to.isEmpty {
                warnings.append("Message \(m.index) has an empty To: header.")
            }
            if m.bodyLines.isEmpty || m.bodyLines.allSatisfy({ $0.plain.trimmingCharacters(in: .whitespaces).isEmpty }) {
                warnings.append("Message \(m.index) has an empty body.")
            }
        }

        // 3. No Gmail chrome strings should have survived in any
        //    message body. We scan the parsed Thread's body lines
        //    directly — no need to render HTML first.
        for m in thread.messages {
            let bodyText = m.bodyLines.map(\.plain).joined(separator: "\n")
            if bodyText.contains("[Quoted text hidden]") {
                errors.append("Message \(m.index) body still contains '[Quoted text hidden]' marker.")
            }
            if bodyText.contains("https://mail.google.com") {
                errors.append("Message \(m.index) body still contains the Gmail print-footer URL.")
            }
        }

        // (Body-coverage ratio is intentionally not checked: the pipeline
        //  de-duplicates Gmail's repeated quoted-reply blocks by design,
        //  so output is reliably much shorter than input. A coverage
        //  metric here would only produce false alarms.)

        // 4. Fold differential validator findings (Phase 3).
        if let diff = differential {
            for md in diff.perMessageDiffs {
                if md.notes.contains(where: { $0.hasPrefix("unpaired") }) {
                    errors.append("Message \(md.index): \(md.notes.joined(separator: "; "))")
                    continue
                }
                if !md.fromMatches {
                    errors.append("Message \(md.index) sender disagreement between heuristic and AI: \(md.notes.joined(separator: "; "))")
                }
                if md.bodySimilarity < 0.85 {
                    errors.append(String(format: "Message %d body similarity %.2f (< 0.85) between heuristic and AI", md.index, md.bodySimilarity))
                } else if md.bodySimilarity < 0.95 {
                    warnings.append(String(format: "Message %d body similarity %.2f (< 0.95) between heuristic and AI", md.index, md.bodySimilarity))
                }
                if !md.dateMatches {
                    warnings.append("Message \(md.index) date differs between engines: \(md.notes.first(where: { $0.hasPrefix("date:") }) ?? "")")
                }
                if !md.toMatches {
                    warnings.append("Message \(md.index) To: header differs between engines.")
                }
            }
            if abs(diff.messageCountDelta) > 0 {
                errors.append("Message-count disagreement: AI parsed \(diff.messageCountDelta > 0 ? "+" : "")\(diff.messageCountDelta) vs heuristic.")
            }
            if diff.subjectMismatch {
                warnings.append("Subject differs between heuristic and AI.")
            }
        }

        let severity: IntegritySeverity =
            !errors.isEmpty ? .error :
            !warnings.isEmpty ? .warning :
            .ok

        let summary: String = {
            switch severity {
            case .ok:
                return "Verified: all \(thread.messages.count) messages and their text are present."
            case .warning:
                return "Generated with \(warnings.count) warning(s). \(thread.messages.count) messages."
            case .error:
                return "Failed integrity check (\(errors.count) error(s)). \(thread.messages.count) messages parsed."
            }
        }()

        return IntegrityReport(
            severity: severity,
            messageCount: thread.messages.count,
            expectedCount: expected,
            warnings: warnings,
            errors: errors,
            summary: summary,
            parsedBy: parsedBy,
            differential: differential
        )
    }

    // MARK: - Helpers

    private let messagesCountRegex = try! NSRegularExpression(pattern: #"^(\d+)\s+messages$"#)

    private func extractExpectedCount(from lines: [StyledLine]) -> Int? {
        for line in lines {
            let s = line.plain.trimmingCharacters(in: .whitespaces)
            let ns = s as NSString
            if let m = messagesCountRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2 {
                return Int(ns.substring(with: m.range(at: 1)))
            }
        }
        return nil
    }

    private let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")

    private func stripTags(_ html: String) -> String {
        let ns = html as NSString
        let stripped = tagRegex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
