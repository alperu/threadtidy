import Foundation

// User-tunable knobs. Persisted as JSON to UserDefaults under the
// `com.basservices.ThreadTidy.settings` key. The full UI surface
// (sheet, model picker, etc.) lives in spec 09 / spec 10 GUI work;
// this file is just the model + persistence so Pipeline + tests
// can read/write without UI.
public struct Settings: Codable, Equatable {
    public var defaultEngine: ParserEngineSetting
    public var differentialMode: DifferentialMode
    public var preferredAIModel: AIModel
    public var includeQuotedText: Bool
    public var renderEngineFooter: Bool
    public var modelDownloadOnFirstNeed: Bool
    public var outputDestination: OutputDestination

    public static let defaults = Settings(
        defaultEngine: .auto,
        differentialMode: .off,
        preferredAIModel: .llama1B,
        includeQuotedText: false,
        renderEngineFooter: false,
        modelDownloadOnFirstNeed: true,
        outputDestination: .downloads
    )

    public init(defaultEngine: ParserEngineSetting,
                differentialMode: DifferentialMode,
                preferredAIModel: AIModel,
                includeQuotedText: Bool,
                renderEngineFooter: Bool,
                modelDownloadOnFirstNeed: Bool,
                outputDestination: OutputDestination = .downloads) {
        self.defaultEngine = defaultEngine
        self.differentialMode = differentialMode
        self.preferredAIModel = preferredAIModel
        self.includeQuotedText = includeQuotedText
        self.renderEngineFooter = renderEngineFooter
        self.modelDownloadOnFirstNeed = modelDownloadOnFirstNeed
        self.outputDestination = outputDestination
    }

    // Codable: handle older payloads that pre-date `outputDestination`
    // by defaulting to `.downloads` (preserves existing behavior).
    enum CodingKeys: String, CodingKey {
        case defaultEngine, differentialMode, preferredAIModel,
             includeQuotedText, renderEngineFooter, modelDownloadOnFirstNeed,
             outputDestination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultEngine = try c.decode(ParserEngineSetting.self, forKey: .defaultEngine)
        self.differentialMode = try c.decode(DifferentialMode.self, forKey: .differentialMode)
        self.preferredAIModel = try c.decode(AIModel.self, forKey: .preferredAIModel)
        self.includeQuotedText = try c.decode(Bool.self, forKey: .includeQuotedText)
        self.renderEngineFooter = try c.decode(Bool.self, forKey: .renderEngineFooter)
        self.modelDownloadOnFirstNeed = try c.decode(Bool.self, forKey: .modelDownloadOnFirstNeed)
        self.outputDestination = (try? c.decode(OutputDestination.self, forKey: .outputDestination)) ?? .downloads
    }

    // MARK: - Persistence

    private static let key = "com.basservices.ThreadTidy.settings"

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .defaults }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// User-facing engine pick. Distinct from `ParserEngine` (Pipeline's
// internal-resolution enum) so we can extend independently.
public enum ParserEngineSetting: String, Codable, CaseIterable {
    case auto         // detect format, use heuristic if known else AI
    case heuristic    // force heuristic; throw on .unknown
    case ai           // force AI for everything
}

public enum DifferentialMode: Codable, Equatable {
    case off
    case sample(everyN: Int)   // run AI on 1-in-N files in addition to heuristic
    case always
    case aiOnly                // bypass heuristic, AI only

    enum CodingKeys: String, CodingKey { case kind, n }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "off":     self = .off
        case "always":  self = .always
        case "aiOnly":  self = .aiOnly
        case "sample":  self = .sample(everyN: try c.decode(Int.self, forKey: .n))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown DifferentialMode kind \(kind)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:                try c.encode("off",    forKey: .kind)
        case .always:             try c.encode("always", forKey: .kind)
        case .aiOnly:             try c.encode("aiOnly", forKey: .kind)
        case .sample(let n):
            try c.encode("sample", forKey: .kind)
            try c.encode(n, forKey: .n)
        }
    }
}

// Where cleaned PDFs should be written. Persisted as part of
// `Settings`. NOTE: ThreadTidy is currently NOT sandboxed, so we can
// persist a plain `file://` URL for `.custom`. If app-sandbox is ever
// enabled, switch this to a security-scoped bookmark (Data) and
// resolve at use-time.
public enum OutputDestination: Codable, Equatable {
    case downloads
    case sameAsSource
    case custom(url: URL)

    enum CodingKeys: String, CodingKey { case kind, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "downloads":    self = .downloads
        case "sameAsSource": self = .sameAsSource
        case "custom":
            let url = try c.decode(URL.self, forKey: .url)
            self = .custom(url: url)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown OutputDestination kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .downloads:    try c.encode("downloads", forKey: .kind)
        case .sameAsSource: try c.encode("sameAsSource", forKey: .kind)
        case .custom(let url):
            try c.encode("custom", forKey: .kind)
            try c.encode(url, forKey: .url)
        }
    }

    /// Tag used by the SwiftUI radio Picker (associated-value enums
    /// don't play nice as Picker selections — see `differentialBinding`).
    public var tag: String {
        switch self {
        case .downloads:    return "downloads"
        case .sameAsSource: return "sameAsSource"
        case .custom:       return "custom"
        }
    }

    /// Custom-folder URL if this case is `.custom`, otherwise nil.
    public var customURL: URL? {
        if case .custom(let url) = self { return url }
        return nil
    }

    /// Resolves the destination to a concrete directory URL. Falls back
    /// to `~/Downloads` (then `NSTemporaryDirectory()`) if the requested
    /// directory is unavailable — never crashes on stale custom paths.
    /// `input` is the URL the pipeline reads from. `originalLocation` is
    /// the canonical user-chosen file URL when known (e.g. from a Finder
    /// drag) — pass it whenever the pipeline is processing a copy of the
    /// real file, so `.sameAsSource` lands the cleaned PDF next to the
    /// real source instead of the temp copy.
    public func resolve(for input: URL,
                        originalLocation: URL? = nil,
                        fileManager: FileManager = .default) -> URL {
        switch self {
        case .sameAsSource:
            // Prefer the canonical original URL from the drop (Finder
            // drag), since `input` is usually a stable temp copy under
            // `/private/var/folders/.../T/ThreadTidy-input/`. If the
            // caller didn't supply one, AND the input parent is a
            // system temp dir, fall back to Downloads so the output
            // is still findable (writing next to the temp copy would
            // bury the file from the user's perspective).
            let candidate = (originalLocation ?? input)
                .deletingLastPathComponent()
                .standardizedFileURL
            let tempPrefix = fileManager.temporaryDirectory.standardizedFileURL.path
            // /var is a symlink to /private/var; compare both prefixes.
            let altTempPrefix = tempPrefix.hasPrefix("/private")
                ? String(tempPrefix.dropFirst("/private".count))
                : "/private" + tempPrefix
            if candidate.path.hasPrefix(tempPrefix)
                || candidate.path.hasPrefix(altTempPrefix)
                || candidate.path.contains("/ThreadTidy-input") {
                return OutputDestination.downloads.resolve(for: input, fileManager: fileManager)
            }
            return candidate
        case .custom(let url):
            // Stale-path guard: directory must still exist and be writable.
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue,
               fileManager.isWritableFile(atPath: url.path) {
                return url
            }
            return OutputDestination.downloads.resolve(for: input, fileManager: fileManager)
        case .downloads:
            if let d = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                return d
            }
            return fileManager.temporaryDirectory
        }
    }
}

public enum AIModel: String, Codable, CaseIterable {
    case llama1B  = "Llama-3.2-1B-Instruct-4bit"
    case llama3B  = "Llama-3.2-3B-Instruct-4bit"
    case phi35Mini = "Phi-3.5-mini-instruct-4bit"

    public var huggingFaceRepo: String {
        switch self {
        case .llama1B:  return "mlx-community/Llama-3.2-1B-Instruct-4bit"
        case .llama3B:  return "mlx-community/Llama-3.2-3B-Instruct-4bit"
        case .phi35Mini: return "mlx-community/Phi-3.5-mini-instruct-4bit"
        }
    }

    public var approximateDiskBytes: Int64 {
        switch self {
        case .llama1B:  return 700  * 1024 * 1024
        case .llama3B:  return 2000 * 1024 * 1024
        case .phi35Mini: return 2200 * 1024 * 1024
        }
    }

    // Approximate token budget the model can comfortably handle for a
    // single generation, INCLUDING both prompt and response. The
    // chunker uses this to decide whether to split the input into
    // multiple per-message chunks. Conservative — Llama 3.2 1B has an
    // 8K context, but quantized + KV cache + prompt overhead means
    // ~4K is a safer working budget. Phi 3.5 mini has 128K context but
    // generation slows dramatically above ~8K; we use 8K. Llama 3B
    // shares Llama 3.2's 8K context.
    public var tokenBudget: Int {
        switch self {
        case .llama1B:   return 4096
        case .llama3B:   return 8192
        case .phi35Mini: return 8192
        }
    }
}
