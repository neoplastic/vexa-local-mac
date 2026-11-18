import SwiftUI
import VexaCore

/// What Vexa keeps in Docker (images, volumes, build cache), and cleanup actions.
/// Removal runs scripts/cleanup.sh, which applies the same rules as this page.
struct StorageView: View {
    @Environment(AppModel.self) private var app
    @State private var store = DockerStore()
    @State private var pending: CleanupAction?

    enum CleanupAction: String, Identifiable {
        case images, old, cache
        var id: String { rawValue }
        var flag: String {
            switch self {
            case .images: return "--images"
            case .old: return "--old-v010"
            case .cache: return "--build-cache"
            }
        }
        var logTitle: String {
            switch self {
            case .images: return "Removing unused Vexa images"
            case .old: return "Removing old Vexa 0.10 data"
            case .cache: return "Clearing the build cache"
            }
        }
    }

    var body: some View {
        content
            .navigationTitle("Storage")
            .toolbar {
                ToolbarItem {
                    Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.isLoading)
                        .help("Read Docker's disk usage again")
                }
            }
            .task { await refresh() }
            .alert(alertTitle, isPresented: alertShown, presenting: pending) { action in
                Button(action == .old ? "Delete" : "Remove", role: .destructive) { Task { await run(action) } }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(alertMessage(action))
            }
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        if let report = store.report {
            reportView(report)
        } else {
            switch store.phase {
            case .dockerDown(let reason):
                ContentUnavailableView {
                    Label("Docker isn't running", systemImage: "shippingbox")
                } description: {
                    Text("Start Vexa (or Colima) to see what Vexa stores in Docker.\n\(reason)")
                } actions: {
                    HStack {
                        Button("Try Again") { Task { await refresh() } }
                        Button("Start Vexa") {
                            Task { await app.startStack(); await refresh() }
                        }
                        .disabled(app.runner.isRunning || !app.projectLooksValid)
                    }
                }
                .overlay(alignment: .bottom) { vmDiskFooter.padding() }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read Docker's disk usage", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await refresh() } }
                }
            default:
                ProgressView("Reading Docker's disk usage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var vmDiskFooter: some View {
        if let disk = store.vmDisk {
            Text("Colima VM disk: \(vmDiskText(disk))").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Report

    private func reportView(_ r: VexaStorageReport) -> some View {
        let busy = app.runner.isRunning || store.isLoading || !app.projectLooksValid
        let removable = r.removableImages
        let inUse = r.images(.inUse)
        let estimate = r.estimate(for: removable)
        return Form {
            Section {
                LabeledContent("Vexa images", value: ByteCount.format(r.vexaImagesSize))
                LabeledContent("Vexa volumes", value: ByteCount.format(r.vexaVolumesSize))
                LabeledContent("Build cache", value: ByteCount.format(r.buildCache))
                LabeledContent("Other images (not Vexa's)", value: ByteCount.format(r.otherImagesSize))
                if let disk = store.vmDisk {
                    LabeledContent("Colima VM disk", value: vmDiskText(disk))
                }
                if case .failed(let message) = store.phase {
                    Label("Refresh failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !r.referencesKnown {
                    Label("Couldn't read the compose file\(store.referencesError.map { " (\($0))" } ?? ""), "
                          + "so unused Vexa images can't be told apart and are all kept.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("Overview")
                    Spacer()
                    if store.isLoading { ProgressView().controlSize(.small) }
                    else if let updatedAt = store.updatedAt {
                        Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Sizes are as Docker reports them. Images share layers, so their sizes overlap.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if removable.isEmpty && r.stoppedBots.isEmpty {
                    Text("Nothing to remove.").foregroundStyle(.secondary)
                }
                ForEach(removable) { item in
                    ImageRow(item: item, note: item.kind == .leftover ? "test build" : "superseded")
                }
                if !r.stoppedBots.isEmpty {
                    LabeledContent("Stopped meeting-bot containers", value: "\(r.stoppedBots.count)")
                }
                HStack {
                    Spacer()
                    Button("Remove Unused Vexa Images…") { pending = .images }
                        .disabled(busy || (removable.isEmpty && r.stoppedBots.isEmpty))
                }
            } header: {
                Text("Unused Vexa images")
            } footer: {
                Text(removable.isEmpty ? "Old images are removed automatically after each update."
                     : "Frees \(estimate.text). Older versions and test builds the current setup no longer uses. "
                     + "Same as 'make cleanup', without the build cache.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("\(inUse.count) images, \(ByteCount.format(r.size(of: inUse)))") {
                    ForEach(inUse) { ImageRow(item: $0, note: nil) }
                }
            } header: {
                Text("Images in use")
            } footer: {
                Text("Used by the current setup or a running container. Never removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if r.currentVolumes.isEmpty { Text("No data volumes yet.").foregroundStyle(.secondary) }
                ForEach(r.currentVolumes) { VolumeRow(volume: $0.volume, locked: true) }
            } header: {
                Text("Vexa data")
            } footer: {
                Text("Your meetings, transcripts and recordings. They can't be deleted here. To start over from "
                     + "scratch, stop Vexa and remove the vexa-v012_* volumes with 'docker volume rm' in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if r.oldImages.isEmpty && r.oldVolumes.isEmpty {
                    Text("No Vexa 0.10 leftovers.").foregroundStyle(.secondary)
                }
                ForEach(r.oldVolumes) { VolumeRow(volume: $0.volume, locked: false) }
                ForEach(r.oldImages) { ImageRow(item: $0, note: nil) }
                HStack {
                    Spacer()
                    Button("Remove Old Vexa 0.10 Data…", role: .destructive) { pending = .old }
                        .disabled(busy || (r.oldImages.isEmpty && r.oldVolumes.isEmpty))
                }
            } header: {
                Text("Old Vexa 0.10")
            } footer: {
                Text("Left behind by the previous Vexa version. Its volumes hold that version's meetings and "
                     + "transcripts; the current Vexa doesn't use them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Size", value: ByteCount.format(r.buildCache))
                HStack {
                    Spacer()
                    Button("Clear Build Cache…") { pending = .cache }
                        .disabled(busy || r.buildCache == 0)
                }
            } header: {
                Text("Build cache")
            } footer: {
                Text("Left over from building the meeting bot. Safe to clear: it's rebuilt automatically, "
                     + "so the next 'make update' just takes longer. 'make cleanup' clears it too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    private func refresh() async {
        app.reloadEnv()
        await store.refresh(projectURL: app.projectURL, colimaProfile: app.colimaProfile)
    }

    private func run(_ action: CleanupAction) async {
        app.showLog = true
        await app.runner.run(action.logTitle, script: app.script("cleanup.sh"), arguments: [action.flag],
                             in: app.projectURL)
        await refresh()
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var alertTitle: String {
        switch pending {
        case .images: return "Remove unused Vexa images?"
        case .old: return "Delete old Vexa 0.10 data?"
        case .cache: return "Clear the Docker build cache?"
        case nil: return ""
        }
    }

    private func alertMessage(_ action: CleanupAction) -> String {
        guard let r = store.report else { return "" }
        switch action {
        case .images:
            var text = "Removes \(Self.list(r.removableImages.map(\.image.displayName)))"
            if !r.stoppedBots.isEmpty { text += "\n\nand \(r.stoppedBots.count) stopped meeting-bot container(s)" }
            return text + ".\n\nFrees \(r.estimate(for: r.removableImages).text). "
                + "Images the current setup or a running container uses are kept."
        case .old:
            var parts: [String] = []
            if !r.oldVolumes.isEmpty {
                parts.append("These volumes, with any meetings and transcripts recorded with Vexa 0.10:\n"
                             + Self.list(r.oldVolumes.map(\.volume.name)))
            }
            if !r.oldImages.isEmpty {
                parts.append("These images:\n" + Self.list(r.oldImages.map(\.image.displayName)))
            }
            return "This permanently deletes:\n\n" + parts.joined(separator: "\n\n")
                + "\n\nFrees about \(ByteCount.format(r.oldDataSize)). It can't be undone. "
                + "Your current Vexa data (vexa-v012_*) is not touched."
        case .cache:
            return "Frees \(ByteCount.format(r.buildCache)). The cache is rebuilt automatically; "
                + "the next bot build ('make update') takes longer."
        }
    }

    private static func list(_ names: [String], limit: Int = 12) -> String {
        var lines = names.prefix(limit).map { "• \($0)" }
        if names.count > limit { lines.append("• and \(names.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    private func vmDiskText(_ disk: VMDisk) -> String {
        guard let used = disk.used else { return "\(ByteCount.format(disk.total)) disk" }
        var text = "\(ByteCount.format(used)) used of \(ByteCount.format(disk.total))"
        if let free = disk.available { text += " (\(ByteCount.format(free)) free)" }
        return text
    }
}

private struct ImageRow: View {
    let item: ClassifiedImage
    let note: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.image.displayName).lineLimit(1).truncationMode(.middle)
                Text([note, item.image.created.isEmpty ? nil : "created \(item.image.created)"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCount.format(item.image.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(item.image.uniqueSize.map { "\(ByteCount.format($0)) of this isn't shared with other images" } ?? "")
    }
}

private struct VolumeRow: View {
    let volume: DockerVolume
    let locked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: locked ? "lock.fill" : "externaldrive").foregroundStyle(.secondary)
            Text(volume.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(volume.size.map(ByteCount.format) ?? "–").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
