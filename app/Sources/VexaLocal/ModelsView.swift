import SwiftUI
import VexaCore

struct ModelsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var confirmDelete: String?

    private var recommendedIds: Set<String> { Set(ModelCatalog.recommended.map(\.id)) }
    private var otherModels: [HubModel] {
        app.models.hubModels.filter { m in
            !recommendedIds.contains(m.id) && (search.isEmpty || m.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Selected model", value: app.configuredModel)
                    LabeledContent("Whisper is using",
                                   value: app.whisperLoadedModel ?? (app.whisperState == .up ? "…" : "not running"))
                    Text("Models come from Hugging Face and run on your Mac's GPU. Downloads are stored in \(HFCache.hubDirectory.path).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Recommended") {
                ForEach(ModelCatalog.recommended) { m in
                    ModelRow(id: m.id, title: m.title, detail: m.detail, onDelete: { confirmDelete = m.id })
                }
            }

            Section {
                if app.models.isLoadingHub && app.models.hubModels.isEmpty {
                    ProgressView("Loading from Hugging Face…")
                } else if let err = app.models.hubError {
                    Label(err, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
                ForEach(otherModels) { m in
                    ModelRow(id: m.id, title: m.id.replacingOccurrences(of: "mlx-community/", with: ""),
                             detail: m.downloads.map { "\($0.formatted()) downloads" } ?? "",
                             onDelete: { confirmDelete = m.id })
                }
            } header: {
                HStack {
                    Text("All MLX Whisper models on Hugging Face")
                    Spacer()
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                }
            }
        }
        .navigationTitle("Whisper models")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                app.models.cacheVersion += 1
                Task { await app.models.loadHubModels() }
            }
        }
        .task { await app.models.loadHubModels() }
        .confirmationDialog("Delete this model from disk?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { id in
            Button("Delete \(id.replacingOccurrences(of: "mlx-community/", with: ""))", role: .destructive) {
                try? app.models.delete(id)
            }
        } message: { _ in
            Text("You can download it again later.")
        }
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var app
    let id: String
    let title: String
    let detail: String
    let onDelete: () -> Void

    private var info: RepoInfo? { app.models.repoInfo[id] }
    private var downloaded: Bool { app.models.isDownloaded(id) }
    private var selected: Bool { app.configuredModel == id }
    private var running: Bool { app.whisperLoadedModel == id }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if running {
                        Tag(text: "In use", color: .green)
                    } else if selected {
                        Tag(text: "Selected", color: .blue)
                    }
                    if info?.compatible == false { Tag(text: "Not compatible", color: .orange) }
                }
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.vertical, 3)
        .task { await app.models.loadInfo(id) }
    }

    private var sizeText: String {
        guard let info else { return id }
        return "\(id) · \(ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file))"
    }

    @ViewBuilder private var actions: some View {
        switch app.models.downloads[id] {
        case .running(let fraction):
            ProgressView(value: fraction).frame(width: 120)
            Button("Cancel") { app.models.cancelDownload(id) }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 220)
            Button("Retry") { app.models.download(id, python: app.whisperPython) }
        case nil:
            if downloaded {
                if !selected {
                    Button("Use") { Task { await app.useModel(id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.runner.isRunning)
                }
                Button("Delete", systemImage: "trash", action: onDelete)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(selected || running)
                    .help(selected ? "This model is selected; choose another before deleting it" : "Delete from disk")
            } else {
                Button("Download") { app.models.download(id, python: app.whisperPython) }
                    .disabled(info?.compatible == false)
            }
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
