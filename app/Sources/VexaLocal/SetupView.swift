import AppKit
import SwiftUI
import VexaCore

/// The setup assistant: one row per thing Vexa Local needs, in the order to do them.
/// Opens by itself the first time and whenever something to install is missing.
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: LongSetup?

    /// setup.sh is long; ask first.
    enum LongSetup: Identifiable {
        case runSetup, everything
        var id: Self { self }
    }

    private var store: SetupStore { app.setup }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SetupItem.allCases) { item in
                        SetupRowView(item: item, row: store.facts.map { SetupPlanner.row(item, $0) },
                                     confirmSetup: { confirm = .runSetup })
                            .padding(.vertical, 12)
                        if item != SetupItem.allCases.last { Divider() }
                    }
                }
                .padding(.horizontal, 20)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 720)
        .task { await store.refresh(app) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh(app) }
        }
        // The main window's log sheet can't show while this sheet is up, so show it here.
        .sheet(isPresented: $app.showLog) { LogSheet() }
        .alert("Set up Vexa now?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { kind in
            Button("Start") {
                Task {
                    switch kind {
                    case .runSetup: _ = await store.runSetup(app); await store.refresh(app)
                    case .everything: await store.setUpEverything(app)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Setting up Vexa takes 20-40 minutes the first time and downloads about 10-20 GB. Keep the Mac on power. You can use other apps meanwhile.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up Vexa Local").font(.title2.weight(.semibold))
            Text("Vexa Local needs a few tools before it can work. Green rows are done. Press Set up everything to do the rest, or use the button on a row.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    if store.facts?.vexaSetUp == false { confirm = .everything } else { Task { await store.setUpEverything(app) } }
                } label: {
                    Label("Set up everything", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.facts == nil || store.isBusy || app.runner.isRunning)
                if store.isRunningAll { ProgressView().controlSize(.small) }
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if let message = store.message {
                Label(message, systemImage: store.messageIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(store.messageIsError ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var summary: String {
        guard let facts = store.facts else { return "Checking…" }
        let left = SetupItem.allCases.filter { $0.kind == .required && SetupPlanner.row($0, facts).state == .missing }.count
        switch left {
        case 0: return "Everything required is done."
        case 1: return "1 required step left."
        default: return "\(left) required steps left."
        }
    }

    private var footer: some View {
        HStack {
            if store.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check again") { Task { await store.refresh(app) } }
                .disabled(store.isChecking)
            Button("Close") { app.showSetup = false }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// One row: status icon, title, a plain explanation, and its buttons.
struct SetupRowView: View {
    @Environment(AppModel.self) private var app
    let item: SetupItem
    /// Nil while the first check runs.
    let row: SetupRow?
    let confirmSetup: () -> Void

    private var store: SetupStore { app.setup }
    private var facts: SetupFacts? { store.facts }
    private var unmet: [SetupItem] { facts.map { SetupPlanner.unmetDependencies(item, $0) } ?? [] }
    private var blocked: Bool { store.isBusy || app.runner.isRunning }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title).font(.headline)
                    tag
                    Spacer()
                    if store.busyItem == item { ProgressView().controlSize(.small) }
                }
                Text(row?.detail ?? "Checking…")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let row, row.state != .ok, !unmet.isEmpty {
                    Text("First: \(unmet.map(\.title).joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let row, let facts { actions(row, facts) }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch row?.state {
        case nil: ProgressView().controlSize(.small)
        case .ok?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .missing?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        case .warning?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .info?: Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.title3)
        }
    }

    private var tag: some View {
        let text: String
        switch item.kind {
        case .required: text = "Required"
        case .optional: text = "Optional"
        case .info: text = "Info"
        }
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(item.kind == .required ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.15),
                        in: Capsule())
    }

    // MARK: Buttons per row

    @ViewBuilder private func actions(_ row: SetupRow, _ f: SetupFacts) -> some View {
        switch item {
        case .commandLineTools where row.state != .ok:
            Button("Install") { run { await store.installCommandLineTools(app) } }
                .disabled(blocked)

        case .homebrew where row.state != .ok:
            VStack(alignment: .leading, spacing: 8) {
                Text("Copy this command, open Terminal, paste it and press Return. It asks for your Mac password.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(SetupStore.homebrewInstallCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Copy command", systemImage: "doc.on.doc") { store.copyHomebrewCommand() }
                    Button("Open Terminal", systemImage: "terminal") { store.openTerminal() }
                    Button("Check again") { run { await store.refresh(app) } }
                }
            }

        case .formulae where row.state != .ok:
            Button("Install missing") { run { await store.installMissingFormulae(app) } }
                .disabled(blocked || f.brewPath == nil)

        case .node where row.state != .ok:
            Button("Install Node with Homebrew") { run { await store.brewInstall(["node"], app) } }
                .disabled(blocked || f.brewPath == nil)

        case .dockerPlugins where row.state != .ok && f.dockerFixable:
            HStack {
                Button("Fix") { run { store.fixDockerConfig() } }
                    .disabled(blocked)
                Text("Saves a copy of ~/.docker/config.json first.").font(.caption).foregroundStyle(.secondary)
            }

        case .project where row.state != .ok:
            HStack {
                Button("Choose folder…") { run { await store.chooseProject(app) } }
                Button("Download it…") { run { await store.downloadProject(app) } }
                    .disabled(!f.commandLineTools)
                    .help("Pick a folder; the project is downloaded into a vexa-local-mac folder inside it.")
            }
            .disabled(blocked)

        case .appInstalled where row.state == .missing:
            HStack {
                Button("Move to Applications") { run { await store.moveToApplications(app) } }
                    .disabled(blocked)
                Text("Copies the app, then reopens it from there. Vexa keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .vexaSetup where row.state != .ok:
            Button("Run setup") { confirmSetup() }
                .disabled(blocked || !unmet.isEmpty)

        case .services where row.state != .ok:
            if f.coreServicesUp {
                Button("Start extension host") { run { await store.startDesktopHost(app) } }
                    .disabled(blocked)
            } else {
                Button("Start everything") { run { await app.startStack() } }
                    .disabled(blocked || !unmet.isEmpty)
            }

        case .chrome where row.state != .ok:
            HStack {
                Button("Install with Homebrew") { run { await store.brewInstall(["google-chrome"], app, cask: true) } }
                    .disabled(blocked || f.brewPath == nil)
                Link("Download from google.com/chrome", destination: SetupStore.chromeDownloadURL)
            }

        case .browserExtension:
            extensionActions(f)

        case .permissions where row.state != .ok:
            HStack {
                if f.microphone != .allowed {
                    Button("Microphone settings") { RecorderPermissions.openMicrophoneSettings() }
                }
                if f.screenRecording != .allowed {
                    Button("Screen & System Audio settings") { RecorderPermissions.openScreenRecordingSettings() }
                }
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder private func extensionActions(_ f: SetupFacts) -> some View {
        @Bindable var store = store
        if !f.extensionBuilt {
            if f.vexaSetUp {
                Button("Build it") { run { await store.startDesktopHost(app) } }
                    .disabled(blocked)
            }
        } else {
            if !f.extensionDone {
                ExtensionInstallSteps(includeMeetingStep: false)
                    .padding(.vertical, 4)
            }
            Toggle("Done: the extension is loaded in Chrome and has my API key", isOn: $store.extensionDone)
                .toggleStyle(.checkbox)
            Text("The app can't see inside Chrome, so tick this yourself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Runs a row's action, then checks every row again.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            await work()
            await store.refresh(app)
        }
    }
}
