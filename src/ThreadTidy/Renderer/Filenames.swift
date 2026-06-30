import Foundation

// Builds the output filename from a parsed Thread:
//   "<first-sender-email> <subject> - <YYYY.MM.dd HH_mm>.pdf"
// Example:
//   "jane.doe@example.com Project Kickoff Notes - 2026.04.29 08_12.pdf"
public enum Filenames {

    public static func makeOutputName(thread: Thread, fallbackDate: Date = Date()) -> String {
        let email = sanitizeComponent(thread.messages.first?.fromEmail ?? "thread")
        let title = sanitizeComponent(thread.subject)
        let stamp = formatStamp(thread.messages.first?.date) ?? formatStamp(fallbackDate)
        let stem = "\(email) \(title) - \(stamp)"
        return safeFilename(stem: stem, extension: "pdf")
    }

    // Resolves a non-colliding URL inside `dir` for the given filename. If
    // a file with the same name already exists, appends " (2)", " (3)", …
    // before the extension.
    public static func uniqueURL(in dir: URL, filename: String) -> URL {
        let candidate = dir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var n = 2
        while true {
            let next = "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let url = dir.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
            if n > 999 {
                return dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
            }
        }
    }

    // MARK: - Sanitization

    // Cross-platform forbidden chars: Windows disallows < > : " / \ | ? *
    // and ASCII control chars. macOS only blocks '/' and NUL but we apply
    // the stricter set so files round-trip cleanly between systems and
    // through cloud sync targets (OneDrive, Dropbox, Google Drive).
    private static let illegal: Set<Character> = [
        "<", ">", ":", "\"", "/", "\\", "|", "?", "*", "\0"
    ]

    // Reserved Windows base names — any file with one of these stems
    // (case-insensitive) is unopenable on Windows even with a valid
    // extension. Prefix with '_' to dodge.
    private static let reservedWindowsNames: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        return s
    }()

    // Per-component cleanup: drop forbidden chars, replace runs with
    // a single underscore, collapse whitespace runs.
    private static func sanitizeComponent(_ s: String) -> String {
        var out = ""
        for ch in s {
            if illegal.contains(ch) {
                out.append("_")
            } else if let v = ch.asciiValue, v < 0x20 {
                out.append("_")
            } else {
                out.append(ch)
            }
        }
        // Collapse runs of '_' and whitespace.
        out = collapseRuns(of: "_", in: out)
        out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return out
    }

    private static func collapseRuns(of c: Character, in s: String) -> String {
        var out = ""
        var prev: Character? = nil
        for ch in s {
            if ch == c && prev == c { continue }
            out.append(ch)
            prev = ch
        }
        return out
    }

    // Builds the final filename from a sanitized stem + extension,
    // enforcing: reserved-name avoidance, no trailing '.' / space, and a
    // total UTF-8 byte cap of 200 (covers macOS APFS, NTFS, exFAT, and
    // common cloud-sync-tool limits with margin).
    public static func safeFilename(stem: String, extension ext: String) -> String {
        var s = sanitizeComponent(stem)

        // Strip trailing dots and spaces (illegal on Windows).
        while let last = s.last, last == "." || last == " " {
            s.removeLast()
        }

        // Reserved-name guard.
        if reservedWindowsNames.contains(s.uppercased()) {
            s = "_" + s
        }

        if s.isEmpty { s = "Email_Thread" }

        // Length cap. 200 bytes UTF-8 leaves headroom for ".pdf" (4) and
        // a possible " (NN)" suffix added later by uniqueURL.
        let extPart = ext.isEmpty ? "" : "." + ext
        let extBytes = extPart.utf8.count
        let suffixReserve = 8                     // " (999)" worst case
        let budget = 200 - extBytes - suffixReserve
        s = truncateToUTF8Bytes(s, max: budget)

        // After truncation, re-strip trailing dot/space.
        while let last = s.last, last == "." || last == " " {
            s.removeLast()
        }
        if s.isEmpty { s = "Email_Thread" }

        return s + extPart
    }

    private static func truncateToUTF8Bytes(_ s: String, max: Int) -> String {
        if s.utf8.count <= max { return s }
        var out = ""
        var bytes = 0
        for ch in s {
            let chBytes = String(ch).utf8.count
            if bytes + chBytes > max { break }
            out.append(ch)
            bytes += chBytes
        }
        return out
    }

    // MARK: - Date parsing

    // Parses the verbatim Gmail date string "Wed, Apr 29, 2026 at 8:12 AM"
    // and reformats to "2026.04.29 08_12".
    private static let inputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return f
    }()

    private static let outputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd HH_mm"
        return f
    }()

    private static func formatStamp(_ raw: String?) -> String? {
        guard let raw = raw, let date = inputFormatter.date(from: raw) else { return nil }
        return outputFormatter.string(from: date)
    }

    private static func formatStamp(_ date: Date) -> String {
        outputFormatter.string(from: date)
    }
}
