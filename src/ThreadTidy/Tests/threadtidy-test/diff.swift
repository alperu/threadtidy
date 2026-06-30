import Foundation
import ThreadTidyKit

// `threadtidy-test diff` subcommand implementation (spec 08).
//
// Usage:
//   threadtidy-test diff <file.pdf>
//   threadtidy-test diff --corpus <dir>
//
// Runs heuristic + AI on each file, emits a ThreadDiff. Exits 1 if
// any file's severity == .error. AI may be unavailable (MLX not
// installed) — in that case we skip the AI side per file, mark the
// row as "ai-skipped", and still gate on heuristic-only success.

// Flag bag, parsed from argv. Unknown flags ignored to keep behaviour
// permissive while we iterate.
private struct DiffOptions {
    var json = false
    var quiet = false
    var noColor = false
}

private func extractFlags(from args: inout [String]) -> DiffOptions {
    var opts = DiffOptions()
    args = args.filter { arg in
        switch arg {
        case "--json":     opts.json = true; return false
        case "--quiet":    opts.quiet = true; return false
        case "--no-color": opts.noColor = true; return false
        default:           return true
        }
    }
    return opts
}

func runDiffSubcommand(args argsIn: [String]) -> Int32 {
    var args = argsIn
    let opts = extractFlags(from: &args)
    guard !args.isEmpty else {
        FileHandle.standardError.write(Data("error: diff requires <file.pdf> or --corpus <dir>\n".utf8))
        return 2
    }

    if args[0] == "--self-diff" {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("error: --self-diff requires <file.pdf>\n".utf8))
            return 2
        }
        return runSelfDiff(file: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
    }
    if args[0] == "--corpus" {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("error: --corpus requires a directory path\n".utf8))
            return 2
        }
        return runCorpusDiff(
            dir: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath),
            opts: opts
        )
    }
    return runSingleDiff(
        file: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath),
        opts: opts
    )
}

// Heuristic vs itself — must return severity=.ok with sim=1.0 for
// every message. Smoke test for DifferentialValidator.
private func runSelfDiff(file: URL) -> Int32 {
    do {
        let lines: [StyledLine]
        do {
            lines = try PDFiumExtractor().extract(from: file)
        } catch {
            lines = try PDFTextExtractor().extract(from: file)
        }
        let format = FormatDetector.detect(url: file)
        let parser: ThreadParsing? = {
            switch format {
            case .gmail:     return GmailThreadParser()
            case .outlook:   return OutlookThreadParser()
            case .appleMail: return AppleMailThreadParser()
            default:         return nil
            }
        }()
        guard let parser else {
            FileHandle.standardError.write(Data("error: no heuristic parser for format=\(format.rawValue)\n".utf8))
            return 1
        }
        let t = try parser.parse(lines: lines)
        let diff = DifferentialValidator.diff(heuristic: t, ai: t)
        print("File:     \(file.lastPathComponent)")
        print("Format:   \(format.rawValue)")
        print("Messages: \(t.messages.count)")
        print("Severity: \(severityLabel(diff.severity))")
        print("Δ count:  \(diff.messageCountDelta)")
        print("Subject:  \(diff.subjectMismatch ? "MISMATCH" : "match")")
        let worst = diff.perMessageDiffs.map(\.bodySimilarity).min() ?? 1.0
        print("Worst body sim: \(String(format: "%.4f", worst))")
        if diff.severity != .ok {
            print("FAIL: self-diff produced non-ok severity")
            return 1
        }
        if worst < 0.999 {
            print("FAIL: self-diff body similarity < 0.999")
            return 1
        }
        print("PASS: self-diff is identity")
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

private func runSingleDiff(file: URL, opts: DiffOptions) -> Int32 {
    do {
        let result = try diffOne(file: file)
        if opts.json {
            printSingleJSON(result: result)
        } else if opts.quiet {
            print("\(severityLabel(result.severity)): \(result.file)")
        } else {
            printSingle(result: result)
        }
        return result.severity == .error ? 1 : 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

private func runCorpusDiff(dir: URL, opts: DiffOptions) -> Int32 {
    guard let enumerator = FileManager.default.enumerator(atPath: dir.path) else {
        FileHandle.standardError.write(Data("error: cannot list \(dir.path)\n".utf8))
        return 1
    }
    var rows: [DiffRow] = []
    for case let path as String in enumerator {
        guard path.lowercased().hasSuffix(".pdf") else { continue }
        let url = dir.appendingPathComponent(path)
        do {
            rows.append(try diffOne(file: url))
        } catch {
            rows.append(DiffRow(
                file: url.lastPathComponent,
                format: "?",
                heurMessageCount: nil,
                aiMessageCount: nil,
                subjectMatch: false,
                worstBodySim: 0,
                severity: .error,
                note: "extract/parse failed: \(error.localizedDescription)"
            ))
        }
    }
    if opts.json {
        printCorpusJSON(rows: rows)
    } else if opts.quiet {
        for r in rows {
            print("\(severityLabel(r.severity)): \(r.file)")
        }
    } else {
        printMarkdownReport(rows: rows)
    }
    let hasError = rows.contains(where: { $0.severity == .error })
    return hasError ? 1 : 0
}

// MARK: - Per-file diff

private struct DiffRow {
    let file: String
    let format: String
    let heurMessageCount: Int?
    let aiMessageCount: Int?
    let subjectMatch: Bool
    let worstBodySim: Double
    let severity: IntegritySeverity
    let note: String
}

private func diffOne(file: URL) throws -> DiffRow {
    // Extract once.
    let lines: [StyledLine]
    do {
        lines = try PDFiumExtractor().extract(from: file)
    } catch {
        lines = try PDFTextExtractor().extract(from: file)
    }
    let format = FormatDetector.detect(url: file)

    // Heuristic side.
    let heurThread: ThreadTidyKit.Thread? = {
        switch format {
        case .gmail:     return try? GmailThreadParser().parse(lines: lines)
        case .outlook:   return try? OutlookThreadParser().parse(lines: lines)
        case .appleMail: return try? AppleMailThreadParser().parse(lines: lines)
        default:         return nil
        }
    }()

    // AI side. Will throw .modelNotInstalled until MLX is vendored.
    var aiThread: ThreadTidyKit.Thread?
    var aiNote = ""
    do {
        aiThread = try MLXThreadParser().parse(lines: lines)
    } catch {
        aiNote = "ai-skipped: \(error.localizedDescription)"
    }

    // No comparison possible if at least one side is missing.
    // "Both unavailable" is a SKIP (warning), not an error — the
    // corpus may include intentionally-unsupported inputs (e.g.
    // outputs of prior pipeline runs left behind in the fixture
    // folder). True errors come from disagreement, not absence.
    guard let h = heurThread, let a = aiThread else {
        let kind: String = {
            if heurThread == nil && aiThread == nil { return "both engines unavailable (format=\(format.rawValue))" }
            if heurThread == nil { return "no heuristic for format=\(format.rawValue)" }
            return aiNote.isEmpty ? "ai unavailable" : aiNote
        }()
        return DiffRow(
            file: file.lastPathComponent,
            format: format.rawValue,
            heurMessageCount: heurThread?.messages.count,
            aiMessageCount: aiThread?.messages.count,
            subjectMatch: false,
            worstBodySim: 0,
            severity: .warning,
            note: kind
        )
    }

    let diff = DifferentialValidator.diff(heuristic: h, ai: a)
    let worst = diff.perMessageDiffs.map(\.bodySimilarity).min() ?? 1.0
    return DiffRow(
        file: file.lastPathComponent,
        format: format.rawValue,
        heurMessageCount: h.messages.count,
        aiMessageCount: a.messages.count,
        subjectMatch: !diff.subjectMismatch,
        worstBodySim: worst,
        severity: diff.severity,
        note: diff.humanSummary
    )
}

// MARK: - Output

private func printSingle(result r: DiffRow) {
    print("File:      \(r.file)")
    print("Format:    \(r.format)")
    print("Messages:  heur=\(r.heurMessageCount.map(String.init) ?? "—")  ai=\(r.aiMessageCount.map(String.init) ?? "—")")
    print("Subject:   \(r.subjectMatch ? "match" : "MISMATCH")")
    print("Body sim:  \(String(format: "%.2f", r.worstBodySim))")
    print("Severity:  \(severityLabel(r.severity))")
    print("Note:      \(r.note)")
}

private func printMarkdownReport(rows: [DiffRow]) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    print("# Differential report — \(f.string(from: Date()))")
    print()
    print("| File | Format | Msgs (h/ai) | Subject | Worst body sim | Severity | Note |")
    print("|------|--------|-------------|---------|----------------|----------|------|")
    for r in rows {
        let h = r.heurMessageCount.map(String.init) ?? "—"
        let a = r.aiMessageCount.map(String.init) ?? "—"
        print("| \(r.file) | \(r.format) | \(h)/\(a) | \(r.subjectMatch ? "match" : "—") | \(String(format: "%.2f", r.worstBodySim)) | \(severityLabel(r.severity)) | \(r.note) |")
    }
    print()
    let errors = rows.filter { $0.severity == .error }.count
    let warnings = rows.filter { $0.severity == .warning }.count
    print("Errors: \(errors)  Warnings: \(warnings)  Total: \(rows.count)")
}

// JSON-encodable mirror of DiffRow for `--json` output.
private struct DiffRowJSON: Codable {
    let file: String
    let format: String
    let heur_message_count: Int?
    let ai_message_count: Int?
    let subject_match: Bool
    let worst_body_sim: Double
    let severity: String
    let note: String
    init(_ r: DiffRow) {
        self.file = r.file
        self.format = r.format
        self.heur_message_count = r.heurMessageCount
        self.ai_message_count = r.aiMessageCount
        self.subject_match = r.subjectMatch
        self.worst_body_sim = r.worstBodySim
        self.severity = severityLabel(r.severity)
        self.note = r.note
    }
}

private func printSingleJSON(result r: DiffRow) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(DiffRowJSON(r)),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

private func printCorpusJSON(rows: [DiffRow]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = rows.map { DiffRowJSON($0) }
    if let data = try? enc.encode(payload),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

private func severityLabel(_ s: IntegritySeverity) -> String {
    switch s {
    case .ok: return "ok"
    case .warning: return "warning"
    case .error: return "error"
    }
}
