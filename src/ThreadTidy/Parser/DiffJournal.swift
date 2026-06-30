import Foundation
import CryptoKit

// Append-only journal of differential disagreements at
// ~/Library/Application Support/ThreadTidy/diff-log.jsonl
//
// One JSON object per line. Local-only; the Settings UI exposes
// "Open in Finder" + "Clear log" actions.
public struct DiffJournal {

    public let url: URL

    public static let `default`: DiffJournal = .init(
        url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ThreadTidy/diff-log.jsonl")
    )

    public init(url: URL) {
        self.url = url
    }

    public struct Entry: Codable {
        public let ts: String
        public let source_sha256: String
        public let format: String
        public let severity: String
        public let diff: ThreadDiff
        public let raw_text_excerpt_first_1k: String

        public init(format: Format,
                    sourceSHA256: String,
                    diff: ThreadDiff,
                    rawExcerpt: String,
                    timestamp: Date = Date()) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            self.ts = f.string(from: timestamp)
            self.source_sha256 = sourceSHA256
            self.format = format.rawValue
            self.severity = severityString(diff.severity)
            self.diff = diff
            self.raw_text_excerpt_first_1k = String(rawExcerpt.prefix(1024))
        }
    }

    public func append(_ entry: Entry) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A)  // '\n'
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: line)
            try h.close()
        } else {
            try line.write(to: url)
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func sha256(of fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func ensureDirectory() throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
    }
}

private func severityString(_ s: IntegritySeverity) -> String {
    switch s {
    case .ok: return "ok"
    case .warning: return "warning"
    case .error: return "error"
    }
}
