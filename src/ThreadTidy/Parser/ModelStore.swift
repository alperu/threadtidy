import Foundation

// Local cache of MLX model weights. Lazy first-run download, list,
// remove. Phase 2 stub: download API is async-ready but not wired
// to HuggingFace until MLX vendoring happens.
public struct ModelStore {

    public let directory: URL

    public static let `default`: ModelStore = .init(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ThreadTidy/models", isDirectory: true)
    )

    public init(directory: URL) {
        self.directory = directory
    }

    public func isInstalled(_ model: AIModel) -> Bool {
        let url = modelURL(model)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
            && hasWeightsBlob(at: url)
    }

    public func sizeOnDisk(_ model: AIModel) -> Int64? {
        guard isInstalled(model) else { return nil }
        return directorySize(modelURL(model))
    }

    public func modelURL(_ model: AIModel) -> URL {
        directory.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    public func remove(_ model: AIModel) throws {
        let url = modelURL(model)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // Whether the MLX inference runtime is bundled in this build.
    // Flipped to true once mlx-swift is vendored and runGeneration is
    // wired up. Gated on arm64 so Intel builds fail gracefully — MLX
    // requires Apple Silicon (Metal + AMX/ANE).
    public static let isRuntimeAvailable: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    // Downloads weights, tokenizer, and config files from the model's
    // HuggingFace repo into a temp directory, then atomically moves the
    // result into place. Progress is reported as a 0…1 fraction.
    // Honors Task cancellation between files.
    public func install(_ model: AIModel,
                        progress: @escaping (Double) -> Void) async throws {
        let repo = model.huggingFaceRepo
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repo)")!
        let (metaData, metaResp) = try await URLSession.shared.data(from: apiURL)
        guard let http = metaResp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelStoreError.downloadFailed("HF API returned non-200 for \(repo)")
        }
        struct ModelInfo: Decodable {
            let siblings: [Sibling]
            struct Sibling: Decodable { let rfilename: String }
        }
        let info: ModelInfo
        do {
            info = try JSONDecoder().decode(ModelInfo.self, from: metaData)
        } catch {
            throw ModelStoreError.downloadFailed("HF API decode failed: \(error.localizedDescription)")
        }
        let wanted = info.siblings.map(\.rfilename).filter { f in
            guard !f.contains("/") else { return false }
            return f.hasSuffix(".safetensors")
                || f.hasSuffix(".json")
                || f.hasSuffix(".model")
                || f.hasSuffix(".tiktoken")
        }
        guard wanted.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw ModelStoreError.downloadFailed("no .safetensors found in \(repo)")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".tmp-\(model.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let total = Double(wanted.count)
        for (i, file) in wanted.enumerated() {
            try Task.checkCancellation()
            let src = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
            let (downloaded, resp) = try await URLSession.shared.download(from: src)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: downloaded)
                try? FileManager.default.removeItem(at: tmp)
                throw ModelStoreError.downloadFailed("\(file): HTTP \(http.statusCode)")
            }
            let dest = tmp.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: downloaded, to: dest)
            await MainActor.run { progress(Double(i + 1) / total) }
        }

        let final = modelURL(model)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
    }

    // MARK: - Private

    private func hasWeightsBlob(at dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return items.contains(where: {
            $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") || $0.hasSuffix(".gguf")
        })
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let s = values?.fileSize {
                total += Int64(s)
            }
        }
        return total
    }
}

public enum ModelStoreError: Error, LocalizedError {
    case notYetImplemented(String)
    case downloadFailed(String)
    case checksumMismatch(model: String, expected: String, got: String)
    case insufficientDiskSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .notYetImplemented(let m): return m
        case .downloadFailed(let m):    return "Model download failed: \(m)"
        case .checksumMismatch(let model, let expected, let got):
            return "Model \(model) checksum mismatch (expected \(expected), got \(got))"
        case .insufficientDiskSpace(let needed, let available):
            return "Need \(needed / 1024 / 1024) MB, have \(available / 1024 / 1024) MB"
        }
    }
}
