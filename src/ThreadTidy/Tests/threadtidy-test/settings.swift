import Foundation
import ThreadTidyKit

// Self-contained unit tests for Settings.outputDestination. Invoked via:
//
//   threadtidy-test settings-test
//
// Covers:
//   * OutputDestination Codable round-trip for each case
//   * Settings JSON roundtrip with a custom URL
//   * resolve(for:) returns expected directories per case (no FS touch
//     needed for .downloads/.sameAsSource; .custom uses /tmp which
//     exists and is writable on every macOS host).

func runSettingsUnitTests() -> Int32 {
    var failures: [String] = []

    func assertEqual<T: Equatable>(_ got: T, _ want: T, _ msg: String) {
        if got != want { failures.append("\(msg): got \(got), want \(want)") }
    }

    // --- 1. OutputDestination Codable round-trip ---
    let cases: [OutputDestination] = [
        .downloads,
        .sameAsSource,
        .custom(url: URL(fileURLWithPath: "/tmp/threadtidy-test-dest")),
    ]
    let enc = JSONEncoder()
    let dec = JSONDecoder()
    for c in cases {
        do {
            let data = try enc.encode(c)
            let back = try dec.decode(OutputDestination.self, from: data)
            assertEqual(back, c, "OutputDestination round-trip [\(c.tag)]")
        } catch {
            failures.append("OutputDestination encode/decode threw for \(c.tag): \(error)")
        }
    }

    // --- 2. Settings JSON roundtrip with .custom ---
    var s = Settings.defaults
    s.outputDestination = .custom(url: URL(fileURLWithPath: "/tmp/foo"))
    do {
        let data = try enc.encode(s)
        let back = try dec.decode(Settings.self, from: data)
        assertEqual(back, s, "Settings round-trip (custom)")
        if case .custom(let url) = back.outputDestination {
            assertEqual(url.path, "/tmp/foo", "custom URL path preserved")
        } else {
            failures.append("Decoded outputDestination wasn't .custom")
        }
    } catch {
        failures.append("Settings encode/decode threw: \(error)")
    }

    // --- 3. Legacy payload (no outputDestination key) defaults to .downloads ---
    let legacyJSON = """
    {
      "defaultEngine": "auto",
      "differentialMode": {"kind": "off"},
      "preferredAIModel": "Llama-3.2-1B-Instruct-4bit",
      "includeQuotedText": false,
      "renderEngineFooter": false,
      "modelDownloadOnFirstNeed": true
    }
    """.data(using: .utf8)!
    do {
        let legacy = try dec.decode(Settings.self, from: legacyJSON)
        assertEqual(legacy.outputDestination, .downloads,
                    "Legacy Settings payload defaults to .downloads")
    } catch {
        failures.append("Legacy Settings decode threw: \(error)")
    }

    // --- 4. resolve(for:) per case ---
    let input = URL(fileURLWithPath: "/Users/test/inbox/source.pdf")

    // .sameAsSource → input.deletingLastPathComponent()
    let resolvedSame = OutputDestination.sameAsSource.resolve(for: input)
    assertEqual(resolvedSame.path, "/Users/test/inbox",
                "sameAsSource resolves to input's parent dir")

    // .downloads → ~/Downloads (or temp). At minimum, non-empty path.
    let resolvedDownloads = OutputDestination.downloads.resolve(for: input)
    if resolvedDownloads.path.isEmpty {
        failures.append(".downloads resolved to empty path")
    }

    // .custom with /tmp (exists & writable) → /tmp
    let tmp = URL(fileURLWithPath: "/tmp")
    let resolvedCustom = OutputDestination.custom(url: tmp).resolve(for: input)
    // /tmp may symlink to /private/tmp on macOS; accept either.
    if resolvedCustom.path != "/tmp" && resolvedCustom.path != "/private/tmp" {
        failures.append("custom(/tmp) resolved to unexpected path: \(resolvedCustom.path)")
    }

    // .custom with stale path → falls back to Downloads (not the stale path)
    let stale = URL(fileURLWithPath: "/var/empty/__threadtidy_does_not_exist__")
    let resolvedStale = OutputDestination.custom(url: stale).resolve(for: input)
    if resolvedStale.path == stale.path {
        failures.append("stale custom path was not rejected by resolve()")
    }

    // --- 5. sameAsSource temp-dir guard: a stable-copy input under
    // /tmp/ThreadTidy-input must NOT resolve to that temp folder — it
    // should fall back to Downloads when no originalLocation is given.
    let stableCopy = URL(fileURLWithPath:
        "/private/var/folders/gg/x/T/ThreadTidy-input/abc-source.pdf")
    let resolvedStable = OutputDestination.sameAsSource.resolve(for: stableCopy)
    if resolvedStable.path.contains("ThreadTidy-input") {
        failures.append("sameAsSource leaked the ThreadTidy-input temp dir: \(resolvedStable.path)")
    }

    // --- 6. sameAsSource with originalLocation prefers the user's
    // real folder over the stable temp copy.
    let original = URL(fileURLWithPath: "/Users/test/Documents/source.pdf")
    let resolvedOriginal = OutputDestination.sameAsSource.resolve(
        for: stableCopy, originalLocation: original
    )
    assertEqual(resolvedOriginal.path, "/Users/test/Documents",
                "sameAsSource uses originalLocation when provided")

    if failures.isEmpty {
        print("settings-test: all assertions passed")
        return 0
    } else {
        for f in failures { FileHandle.standardError.write(Data("FAIL: \(f)\n".utf8)) }
        return 1
    }
}
