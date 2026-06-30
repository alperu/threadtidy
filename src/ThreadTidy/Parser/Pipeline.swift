import Foundation

// Orchestrator: PDF URL → format-detect → dispatch parser → Thread.
// Optionally runs both heuristic + AI and emits a ThreadDiff.
public enum Pipeline {

    public struct Input {
        public let url: URL
        public let engineOverride: ParserEngine?
        public let settings: Settings
        public init(url: URL,
                    engineOverride: ParserEngine? = nil,
                    settings: Settings = .defaults) {
            self.url = url
            self.engineOverride = engineOverride
            self.settings = settings
        }
    }

    public struct Output {
        public let thread: Thread
        public let format: Format
        public let parsedBy: ParserKind
        public let lines: [StyledLine]
        public let diff: ThreadDiff?         // populated when both engines ran
        public init(thread: Thread,
                    format: Format,
                    parsedBy: ParserKind,
                    lines: [StyledLine],
                    diff: ThreadDiff? = nil) {
            self.thread = thread
            self.format = format
            self.parsedBy = parsedBy
            self.lines = lines
            self.diff = diff
        }
    }

    public enum PipelineError: Error, LocalizedError {
        case unsupportedFormat(Format)
        case extractFailed(Error)
        case parseFailed(Error)
        case bothEnginesFailed(heuristic: Error?, ai: Error)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f):
                return "No parser available for format: \(f.rawValue). MLX fallback not yet enabled."
            case .extractFailed(let e):
                return "Could not extract text: \(e.localizedDescription)"
            case .parseFailed(let e):
                return "Parser error: \(e.localizedDescription)"
            case .bothEnginesFailed(let h, let a):
                return "Both engines failed (heur: \(h?.localizedDescription ?? "skipped"); ai: \(a.localizedDescription))"
            }
        }
    }

    public static func run(_ input: Input) throws -> Output {
        let lines: [StyledLine]
        do {
            lines = try PDFTextExtractor().extract(from: input.url)
        } catch {
            throw PipelineError.extractFailed(error)
        }
        return try run(input: input, prelinedLines: lines)
    }

    public static func run(input: Input, prelinedLines lines: [StyledLine])
        throws -> Output
    {
        let format = FormatDetector.detect(url: input.url)
        let plan = resolvePlan(format: format,
                               override: input.engineOverride,
                               settings: input.settings)

        // Run heuristic if planned. Tolerate failure when AI is
        // available as fallback.
        var heurThread: Thread?
        var heurError: Error?
        if plan.runHeuristic, let parser = pickHeuristicParser(format: format) {
            do {
                heurThread = try parser.parse(lines: lines)
            } catch {
                heurError = error
            }
        }

        // Run AI if planned (always when format is .unknown, or when
        // user opted in via settings/override).
        var aiThread: Thread?
        var aiError: Error?
        if plan.runAI {
            let mlx = MLXThreadParser(model: input.settings.preferredAIModel)
            do {
                aiThread = try mlx.parse(lines: lines)
            } catch {
                aiError = error
            }
        }

        // Pick primary thread.
        let primary: Thread
        let parsedBy: ParserKind
        switch (heurThread, aiThread) {
        case (let h?, let a?):
            primary = (plan.preferAIForPrimary ? a : h)
            parsedBy = .both
            _ = a; _ = h
        case (let h?, nil):
            primary = h
            parsedBy = .heuristic
        case (nil, let a?):
            primary = a
            parsedBy = .ai
        case (nil, nil):
            // Both off or both failed — surface the most actionable error.
            if let aiE = aiError {
                throw PipelineError.bothEnginesFailed(heuristic: heurError, ai: aiE)
            }
            if let h = heurError { throw PipelineError.parseFailed(h) }
            throw PipelineError.unsupportedFormat(format)
        }

        // Differential when both ran. Append non-ok diffs to the
        // append-only journal (`diff-log.jsonl`) so we build a
        // regression corpus from real-world disagreements.
        var diff: ThreadDiff?
        if let h = heurThread, let a = aiThread {
            let computed = DifferentialValidator.diff(heuristic: h, ai: a)
            diff = computed
            if computed.severity != .ok {
                let raw = lines.map(\.plain).joined(separator: "\n")
                let entry = DiffJournal.Entry(
                    format: format,
                    sourceSHA256: DiffJournal.sha256(of: input.url),
                    diff: computed,
                    rawExcerpt: raw
                )
                try? DiffJournal.default.append(entry)
            }
        }

        return Output(
            thread: primary,
            format: format,
            parsedBy: parsedBy,
            lines: lines,
            diff: diff
        )
    }

    // MARK: - Plan resolution

    private struct Plan {
        let runHeuristic: Bool
        let runAI: Bool
        let preferAIForPrimary: Bool
    }

    private static func resolvePlan(format: Format,
                                    override: ParserEngine?,
                                    settings: Settings) -> Plan {
        // Override always wins.
        if let o = override {
            switch o {
            case .heuristic: return Plan(runHeuristic: true,  runAI: false, preferAIForPrimary: false)
            case .ai:        return Plan(runHeuristic: false, runAI: true,  preferAIForPrimary: true)
            case .auto:      break
            }
        }
        // From settings.defaultEngine.
        switch settings.defaultEngine {
        case .heuristic:
            return Plan(runHeuristic: true,
                        runAI: false,
                        preferAIForPrimary: false)
        case .ai:
            return Plan(runHeuristic: false,
                        runAI: true,
                        preferAIForPrimary: true)
        case .auto:
            // Auto: heuristic if format is known; AI fills in for
            // .unknown OR runs alongside per differentialMode.
            let heurAvailable = (pickHeuristicParser(format: format) != nil)
            switch settings.differentialMode {
            case .off:
                return Plan(runHeuristic: heurAvailable,
                            runAI: !heurAvailable,
                            preferAIForPrimary: !heurAvailable)
            case .always:
                return Plan(runHeuristic: heurAvailable,
                            runAI: true,
                            preferAIForPrimary: !heurAvailable)
            case .sample(let n):
                let runAI = !heurAvailable || sampleHit(n: n)
                return Plan(runHeuristic: heurAvailable,
                            runAI: runAI,
                            preferAIForPrimary: !heurAvailable)
            case .aiOnly:
                return Plan(runHeuristic: false,
                            runAI: true,
                            preferAIForPrimary: true)
            }
        }
    }

    private static func pickHeuristicParser(format: Format) -> ThreadParsing? {
        switch format {
        case .gmail:      return GmailThreadParser()
        case .outlook:    return OutlookThreadParser()
        case .appleMail:  return AppleMailThreadParser()
        case .protonMail: return nil  // Phase 1c
        case .yahoo:      return nil  // Phase 1c
        case .unknown:    return nil
        }
    }

    // 1-in-N sampling — simple integer hash of UnixTime/N. Good enough
    // for "run AI on roughly 10% of files" without needing seeded RNG
    // state.
    private static func sampleHit(n: Int) -> Bool {
        guard n > 1 else { return true }
        let bucket = Int(Date().timeIntervalSince1970) / max(1, n)
        return bucket % n == 0
    }
}

public enum ParserEngine {
    case auto
    case heuristic
    case ai
}

public enum ParserKind: String, Codable {
    case heuristic
    case ai
    case both
}
