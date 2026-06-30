import Foundation
import AppKit
import ThreadTidyKit

// CLI test driver.
//
// Usage:
//   threadtidy-test <input.pdf> [<output.pdf>]
//
// Runs the FULL pipeline including the WKWebView → PDF export. We boot
// a minimal NSApplication (accessory policy, no Dock icon) so WKWebView
// has a live AppKit runloop, then dispatch the pipeline onto a
// background queue. On completion the app's runloop is stopped.
//
// Output rules:
//   * If <output.pdf> is a directory or omitted, the file is written
//     using the spec'd name (Filenames.makeOutputName) so the user can
//     see exactly what the GUI would produce.
//   * If <output.pdf> is a file path, that exact path is used.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data(
        "usage:\n  threadtidy-test <input.pdf> [<output.pdf-or-dir>]\n  threadtidy-test diff <input.pdf>\n  threadtidy-test diff --corpus <dir>\n".utf8
    ))
    exit(2)
}

// `diff` subcommand — runs heuristic + AI on a file or corpus and
// prints a ThreadDiff report (spec 08). Exits non-zero on any
// error-severity disagreement.
if args[1] == "diff" {
    exit(runDiffSubcommand(args: Array(args.dropFirst(2))))
}

// `applemail-test` — runs the synthetic AppleMailThreadParser unit
// test. No PDF input required; the test fabricates StyledLines.
if args[1] == "applemail-test" {
    exit(runAppleMailUnitTest())
}

// `outlook-test` — runs the synthetic OutlookThreadParser unit test.
// Regression coverage for the inline reply-boundary capture
// (the "On … 7:37AM Name <email> wrote:" failure mode).
if args[1] == "outlook-test" {
    exit(runOutlookUnitTest())
}

// `mlx-test` — runs synthetic MLXThreadParser unit tests. Exercises
// the prompt builder, JSON parser, body-style replay, and
// chunker/dateRange logic without touching real MLX inference.
if args[1] == "mlx-test" {
    exit(runMLXUnitTests())
}

// `settings-test` — Codable + resolver tests for the
// Settings.outputDestination user-configurable output path.
if args[1] == "settings-test" {
    exit(runSettingsUnitTests())
}

let inputURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
let outputArg: String = args.count >= 3
    ? (args[2] as NSString).expandingTildeInPath
    : FileManager.default.temporaryDirectory.path

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    FileHandle.standardError.write(Data("error: input PDF does not exist: \(inputURL.path)\n".utf8))
    exit(1)
}

// MARK: - NSApplication boot

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var exitCode: Int32 = 0

DispatchQueue.global(qos: .userInitiated).async {
    exitCode = runPipeline(input: inputURL, outputArg: outputArg)
    DispatchQueue.main.async {
        NSApp.stop(nil)
        let evt = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let evt = evt { NSApp.postEvent(evt, atStart: false) }
    }
}

app.run()
exit(exitCode)

// MARK: - Pipeline

func runPipeline(input: URL, outputArg: String) -> Int32 {
    print("• input:  \(input.path)")

    // Extract via PDFium (Google Chrome's PDF engine) — surfaces
    // embedded font weights / italics that PDFKit normalizes away.
    // Falls back to PDFKit-based extractor if PDFium dylib can't load.
    let lines: [StyledLine]
    do {
        lines = try PDFiumExtractor().extract(from: input)
        print("• extractor: PDFium")
    } catch {
        print("• extractor: PDFKit (PDFium unavailable: \(error.localizedDescription))")
        do {
            lines = try PDFTextExtractor().extract(from: input)
        } catch let e2 {
            printError("both extractors failed; PDFKit: \(e2.localizedDescription)")
            return 1
        }
    }

    if ProcessInfo.processInfo.environment["DEBUG_PDFIUM_LINES"] == "1" {
        for (i, l) in lines.enumerated() {
            let p = l.plain.replacingOccurrences(of: "\n", with: "⏎")
            print(String(format: "%4d: indent=%5.1f bullet=%@ '%@'",
                         i, l.indent, l.isBullet ? "Y" : "n",
                         p.prefix(120) as CVarArg))
        }
        return 0
    }
    if ProcessInfo.processInfo.environment["DEBUG_CHUNKS"] == "1" {
        let scans = BulletDetector().scan(input)
        for (idx, p) in scans.enumerated() {
            print("=== Page \(idx + 1) ===")
            for ch in p.chunks {
                let txt = ch.text.replacingOccurrences(of: "\n", with: "⏎")
                if txt.isEmpty { continue }
                let f = ch.fontName
                let lower = f.lowercased()
                let mark = (lower.contains("bold") || lower.contains("italic") || lower.contains("oblique")) ? " ★" : ""
                print(String(format: "  y=%4.0f x=%4.0f '%@' [%@]%@",
                             ch.y, ch.x, txt as CVarArg, f as CVarArg, mark as CVarArg))
            }
        }
        return 0
    }
    if ProcessInfo.processInfo.environment["DEBUG_LINES"] == "1" {
        for (i, line) in lines.enumerated() {
            var escaped = ""
            for u in line.plain.unicodeScalars {
                if u.value < 0x20 || u.value > 0x7E { escaped += String(format: "<U+%04X>", u.value) }
                else { escaped += String(u) }
            }
            print(String(format: "%4d  %3d  %@", i, line.plain.count, escaped))
        }
        return 0
    }

    // Parse. DEBUG_PIPELINE=1 routes through the new format-aware
    // Pipeline (FormatDetector → per-format parser); otherwise legacy
    // direct Gmail-only parse path is used to keep existing flows
    // unchanged until Pipeline reaches feature parity.
    let thread: ThreadTidyKit.Thread
    if ProcessInfo.processInfo.environment["DEBUG_PIPELINE"] == "1" {
        do {
            let out = try Pipeline.run(
                input: Pipeline.Input(url: input),
                prelinedLines: lines
            )
            print("• format-detect: \(out.format.rawValue) (parsedBy: \(out.parsedBy.rawValue))")
            thread = out.thread
        } catch {
            printError("pipeline failed: \(error.localizedDescription)")
            return 1
        }
    } else {
        thread = ThreadParser().parse(tokens: lines)
    }

    if ProcessInfo.processInfo.environment["DEBUG_BLOCKS"] == "1" {
        for m in thread.messages {
            print("--- message \(m.index): \(m.fromName) <\(m.fromEmail)> @ \(m.date)")
            print("    To: \(m.to)")
            if let cc = m.cc { print("    Cc: \(cc)") }
            if m.bodyLines.isEmpty { print("    [EMPTY BODY]") }
            else {
                for (i, l) in m.bodyLines.prefix(3).enumerated() {
                    print("    body[\(i)]: \(l.plain.prefix(100))")
                }
                if m.bodyLines.count > 3 { print("    … (\(m.bodyLines.count - 3) more lines)") }
            }
        }
        return 0
    }

    // Resolve output URL: directory → use spec'd filename; file → use path verbatim.
    // For repeated test runs we OVERWRITE rather than creating " (2)" copies —
    // the runtime app uses Filenames.uniqueURL, but for debugging we want the
    // same path each time so the user can keep the file open in Preview.
    let resolvedOutput: URL = {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputArg, isDirectory: &isDir)
        if exists && isDir.boolValue {
            let dir = URL(fileURLWithPath: outputArg)
            return dir.appendingPathComponent(Filenames.makeOutputName(thread: thread))
        }
        if outputArg.hasSuffix("/") {
            let dir = URL(fileURLWithPath: outputArg)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(Filenames.makeOutputName(thread: thread))
        }
        return URL(fileURLWithPath: outputArg)
    }()

    print("• output: \(resolvedOutput.path)")

    // PDF export via TPPDF (synchronous, no WKWebView/runloop).
    do {
        try TPPDFRenderer().render(thread: thread, to: resolvedOutput)
    } catch {
        printError("PDF render failed: \(error.localizedDescription)")
        return 1
    }
    PDFUnderlineAnnotator.annotate(url: resolvedOutput, thread: thread)
    PDFNavigationAnnotator.annotate(url: resolvedOutput, thread: thread)
    print("• uid:    \(PDFNavigationAnnotator.threadUID(thread: thread))")

    // MARK: - Assertions

    var failures: [String] = []
    func check(_ ok: Bool, _ description: String) {
        if ok { print("  ✓ \(description)") }
        else { print("  ✗ \(description)"); failures.append(description) }
    }

    let attrs = (try? FileManager.default.attributesOfItem(atPath: resolvedOutput.path)) ?? [:]
    let pdfSize = (attrs[.size] as? Int) ?? 0
    check(pdfSize > 1_000, "PDF written and ≥ 1 KB (got \(pdfSize) bytes)")

    check(!thread.messages.isEmpty, "parser found ≥ 1 message (got \(thread.messages.count))")
    check(!thread.subject.isEmpty, "thread has a subject")

    for m in thread.messages {
        check(!m.fromName.isEmpty, "message #\(m.index) has fromName")
        check(m.fromEmail.contains("@"), "message #\(m.index) has fromEmail with '@'")
        check(!m.date.isEmpty, "message #\(m.index) has date")
        check(!m.to.isEmpty, "message #\(m.index) has To header")
    }

    // Concatenate every parsed body line as plain text — replacement
    // for the old HTML-scan that the integrity check used to do.
    let outText: String = thread.messages
        .flatMap { $0.bodyLines.map(\.plain) }
        .joined(separator: "\n")
    check(!outText.contains("[Quoted text hidden]"), "output has no '[Quoted text hidden]' markers")
    check(!outText.contains("https://mail.google.com"), "output has no Gmail URL footer")
    for phrase in ["Good morning", "I will be at docket call all morning"] {
        check(outText.contains(phrase), "output preserves author phrase: \(phrase.prefix(40))…")
    }
    let hasBoldRun = thread.messages.contains { $0.bodyLines.contains { $0.runs.contains { $0.bold } } }
    check(hasBoldRun, "parser captured at least one bold run")
    // Header values include @ tokens; the renderer will turn them into
    // mailto links. The body of GmailPrint.pdf doesn't actually carry
    // raw URLs/links in its content stream, so we don't assert link
    // runs in body — assert at the metadata level instead.
    let hasAddrInHeader = thread.messages.contains { $0.fromEmail.contains("@") }
    check(hasAddrInHeader, "parser captured at least one email address in headers")
    let anyCc = thread.messages.contains { $0.cc != nil && !($0.cc!.isEmpty) }
    check(anyCc, "at least one message has a Cc header")

    // Filename spec + cross-platform safety.
    let generated = Filenames.makeOutputName(thread: thread)
    let nameRX = try! NSRegularExpression(
        pattern: #"^\S+@\S+ .+ - \d{4}\.\d{2}\.\d{2} \d{2}_\d{2}\.pdf$"#
    )
    let nameMatched = nameRX.firstMatch(in: generated, range: NSRange(location: 0, length: (generated as NSString).length)) != nil
    check(nameMatched, "generated filename matches spec: \(generated)")
    check(generated.utf8.count <= 200, "filename ≤ 200 UTF-8 bytes (got \(generated.utf8.count))")
    let forbidden: [Character] = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
    let stemOnly = (generated as NSString).deletingPathExtension
    check(!stemOnly.contains(where: { forbidden.contains($0) }), "filename stem has no forbidden Windows chars")
    check(!stemOnly.hasSuffix(".") && !stemOnly.hasSuffix(" "), "filename stem has no trailing dot/space")

    let bad1 = Filenames.safeFilename(stem: #"foo<>:"|?*\\bar"#, extension: "pdf")
    check(!bad1.contains(where: { forbidden.contains($0) }), "safeFilename strips forbidden chars (got '\(bad1)')")
    let conName = Filenames.safeFilename(stem: "CON", extension: "pdf")
    check(conName.uppercased() != "CON.PDF", "safeFilename guards reserved CON (got '\(conName)')")
    let longName = Filenames.safeFilename(stem: String(repeating: "a", count: 300), extension: "pdf")
    check(longName.utf8.count <= 200, "safeFilename truncates long stem ≤200 bytes (got \(longName.utf8.count))")
    let trailing = Filenames.safeFilename(stem: "ends with dot.", extension: "pdf")
    check(!trailing.replacingOccurrences(of: ".pdf", with: "").hasSuffix("."),
          "safeFilename strips trailing dot")

    // Integrity report.
    let report = IntegrityChecker().check(sourceLines: lines, thread: thread)
    check(report.errors.isEmpty, "integrity check has no errors")
    check(report.severity != .error, "integrity severity is not 'error'")
    print("  → integrity: \(report.summary)")
    if !report.warnings.isEmpty {
        print("    warnings:")
        for w in report.warnings { print("      • \(w)") }
    }
    if !report.errors.isEmpty {
        print("    errors:")
        for e in report.errors { print("      • \(e)") }
    }

    if failures.isEmpty {
        print("\nAll \(thread.messages.count)-message thread checks passed.")
        print("PDF:  \(resolvedOutput.path)")
        return 0
    } else {
        print("\n\(failures.count) check(s) failed:")
        for f in failures { print("  - \(f)") }
        return 1
    }
}

@Sendable
func printError(_ message: String) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
}
