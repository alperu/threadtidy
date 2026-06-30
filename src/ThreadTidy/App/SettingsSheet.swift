import SwiftUI
import AppKit
import ThreadTidyKit

// SwiftUI sheet exposing the Settings model. Mounted from a gear
// button in the top action bar. Persistence happens on every change
// via Settings.save(); next pipeline run picks up the new values.
struct SettingsSheet: View {
    @Binding var settings: ThreadTidyKit.Settings
    @Environment(\.dismiss) private var dismiss

    @State private var llamaInstalled: Bool = false
    @State private var llamaSizeMB: String = "—"
    @State private var downloadProgress: Double = 0
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var downloadError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ThreadTidy Settings").font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            // Engine
            VStack(alignment: .leading, spacing: 6) {
                Text("Default engine").font(.subheadline).fontWeight(.semibold)
                Picker("", selection: $settings.defaultEngine) {
                    Text("Auto (heuristic when known, AI for unknown)")
                        .tag(ParserEngineSetting.auto)
                    Text("Heuristic only").tag(ParserEngineSetting.heuristic)
                    Text("AI only").tag(ParserEngineSetting.ai)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            // Differential mode
            VStack(alignment: .leading, spacing: 6) {
                Text("Differential check (heuristic vs AI)")
                    .font(.subheadline).fontWeight(.semibold)
                Picker("", selection: differentialBinding) {
                    Text("Off").tag("off")
                    Text("Sample 1-in-10").tag("sample10")
                    Text("Always").tag("always")
                    Text("AI only (skip heuristic)").tag("aiOnly")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            // AI model
            VStack(alignment: .leading, spacing: 6) {
                Text("AI model").font(.subheadline).fontWeight(.semibold)
                Picker("", selection: $settings.preferredAIModel) {
                    ForEach(AIModel.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                HStack {
                    Image(systemName: llamaInstalled ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                        .foregroundStyle(llamaInstalled ? .green : .secondary)
                    if let task = downloadTask, !task.isCancelled {
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(llamaInstalled
                             ? "Weights installed (\(llamaSizeMB) MB)"
                             : "Weights not installed (~\(settings.preferredAIModel.approximateDiskBytes / 1024 / 1024) MB)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if downloadTask != nil {
                        Button("Cancel") {
                            downloadTask?.cancel()
                            downloadTask = nil
                            downloadProgress = 0
                        }
                    } else if llamaInstalled {
                        Button("Remove", role: .destructive) {
                            try? ModelStore.default.remove(settings.preferredAIModel)
                            refreshModelStatus()
                        }
                    } else {
                        Button("Download") { startDownload() }
                    }
                }
                if downloadTask != nil {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                }
                if let err = downloadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                // Runtime availability — separate from weights on disk.
                HStack(spacing: 6) {
                    Image(systemName: ModelStore.isRuntimeAvailable
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ModelStore.isRuntimeAvailable ? .green : .orange)
                    Text(ModelStore.isRuntimeAvailable
                         ? (llamaInstalled
                            ? "Inference runtime available — model ready to use"
                            : "Inference runtime available — download weights to enable")
                         : "Inference runtime not bundled in this build — weights can download but cannot run yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Output destination — where cleaned PDFs are written.
            VStack(alignment: .leading, spacing: 6) {
                Text("Output destination").font(.subheadline).fontWeight(.semibold)
                Picker("", selection: outputDestinationBinding) {
                    Text("Downloads folder").tag("downloads")
                    Text("Same folder as source PDF").tag("sameAsSource")
                    Text("Custom folder…").tag("custom")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                // Custom-folder controls. Always rendered so layout
                // doesn't jump; disabled unless `.custom` is selected.
                HStack(spacing: 8) {
                    Button("Choose folder…") { chooseCustomFolder() }
                        .disabled(settings.outputDestination.tag != "custom")
                    Text(customFolderLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.leading, 18)
            }

            Divider()

            // Output behavior
            VStack(alignment: .leading, spacing: 6) {
                Text("Output").font(.subheadline).fontWeight(.semibold)
                Toggle("Include quoted text in body", isOn: $settings.includeQuotedText)
                Toggle("Render engine footer in output PDF", isOn: $settings.renderEngineFooter)
            }

            Divider()

            // Diff log + raw MLX output log
            VStack(alignment: .leading, spacing: 6) {
                Text("Logs")
                    .font(.subheadline).fontWeight(.semibold)
                HStack {
                    Button("Differential journal") {
                        let url = DiffJournal.default.url
                        let dir = url.deletingLastPathComponent()
                        if FileManager.default.fileExists(atPath: dir.path) {
                            NSWorkspace.shared.open(dir)
                        }
                    }
                    Button("AI raw output") {
                        let url = FileManager.default
                            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                            .first?
                            .appendingPathComponent("ThreadTidy/mlx-raw.jsonl")
                        if let url, FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else if let url {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())
                        }
                    }
                    Button("Clear diff log", role: .destructive) {
                        try? DiffJournal.default.clear()
                    }
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: settings) { _ in settings.save() }
        .onAppear { refreshModelStatus() }
        .onChange(of: settings.preferredAIModel) { _ in refreshModelStatus() }
    }

    private var differentialBinding: Binding<String> {
        Binding(
            get: {
                switch settings.differentialMode {
                case .off: return "off"
                case .sample: return "sample10"
                case .always: return "always"
                case .aiOnly: return "aiOnly"
                }
            },
            set: { newValue in
                switch newValue {
                case "off":      settings.differentialMode = .off
                case "sample10": settings.differentialMode = .sample(everyN: 10)
                case "always":   settings.differentialMode = .always
                case "aiOnly":   settings.differentialMode = .aiOnly
                default: break
                }
            }
        )
    }

    private var outputDestinationBinding: Binding<String> {
        Binding(
            get: { settings.outputDestination.tag },
            set: { newValue in
                switch newValue {
                case "downloads":
                    settings.outputDestination = .downloads
                case "sameAsSource":
                    settings.outputDestination = .sameAsSource
                case "custom":
                    // Preserve any previously-chosen URL; otherwise leave
                    // the case as `.custom(url:)` with a placeholder that
                    // resolve() will treat as stale (-> Downloads fallback).
                    if let existing = settings.outputDestination.customURL {
                        settings.outputDestination = .custom(url: existing)
                    } else {
                        // Use a known-nonexistent path as the "unset" sentinel;
                        // resolve() handles it via the stale-path guard.
                        settings.outputDestination = .custom(url: URL(fileURLWithPath: "/var/empty/__threadtidy_unset__"))
                    }
                default: break
                }
            }
        )
    }

    private var customFolderLabel: String {
        if case .custom(let url) = settings.outputDestination {
            if url.path.contains("__threadtidy_unset__") {
                return "(no folder selected)"
            }
            return url.path
        }
        return ""
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Choose output folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDestination = .custom(url: url)
        }
    }

    private func startDownload() {
        downloadError = nil
        downloadProgress = 0
        let model = settings.preferredAIModel
        downloadTask = Task { @MainActor in
            do {
                try await ModelStore.default.install(model) { p in
                    downloadProgress = p
                }
                downloadTask = nil
                refreshModelStatus()
            } catch is CancellationError {
                downloadTask = nil
                downloadProgress = 0
            } catch {
                downloadError = error.localizedDescription
                downloadTask = nil
                downloadProgress = 0
            }
        }
    }

    private func refreshModelStatus() {
        let store = ModelStore.default
        llamaInstalled = store.isInstalled(settings.preferredAIModel)
        if let s = store.sizeOnDisk(settings.preferredAIModel) {
            llamaSizeMB = "\(s / 1024 / 1024)"
        } else {
            llamaSizeMB = "—"
        }
    }
}
