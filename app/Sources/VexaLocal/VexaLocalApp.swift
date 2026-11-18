import AppKit
import SwiftUI

/// Owns the model so quitting can stop Vexa first (see QuitController).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// The Whisper-only recorder (Record pane).
    let recorder = RecorderStore()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A recording in progress is stopped and saved first; then the usual quit flow runs.
        if recorder.isQuitting { return .terminateCancel }
        if recorder.phase == .recording || recorder.phase == .stopping {
            Task { @MainActor in
                await recorder.finishForQuit()
                switch model.quit.shouldTerminate(model) {
                case .terminateNow: NSApp.reply(toApplicationShouldTerminate: true)
                case .terminateCancel: NSApp.reply(toApplicationShouldTerminate: false)
                case .terminateLater: break   // QuitController replies when it is done
                @unknown default: NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        return model.quit.shouldTerminate(model)
    }
}

@main
struct VexaLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var app: AppModel { delegate.model }

    init() {
        // Running from `swift run` has no bundle; make it a normal foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Vexa Local") {
            ContentView()
                .environment(app)
                .environment(delegate.recorder)
                .frame(minWidth: 820, minHeight: 560)
                .task { app.startPolling() }
        }
        .windowResizability(.contentMinSize)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case join = "Join meeting"
    case record = "Record"
    case sessions = "Transcripts"
    case models = "Whisper models"
    case storage = "Storage"
    case claude = "Connect Claude"
    case settings = "Settings"
    // Identity is the case itself, so List rows are tagged with Pane values
    // that match the sidebar's Pane? selection.
    var id: Self { self }
    var icon: String {
        switch self {
        case .join: return "person.badge.plus"
        case .record: return "mic.circle"
        case .sessions: return "doc.text"
        case .models: return "waveform"
        case .storage: return "internaldrive"
        case .claude: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(RecorderStore.self) private var recorder
    @AppStorage("vexa.pane") private var savedPane: String = Pane.join.rawValue
    @State private var pane: Pane? = nil

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p == .record && recorder.phase != .idle ? "record.circle.fill" : p.icon)
                        .badge(p == .sessions ? app.sessions.filter { !$0.finished }.count : 0)
                        .tag(p)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    SetupWarningRow()
                    StatusPanel()
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch pane ?? .join {
            case .join: JoinView(onJoined: { pane = .sessions })
            case .record: RecordView()
            case .sessions: SessionsView()
            case .models: ModelsView()
            case .storage: StorageView()
            case .claude: ClaudeView()
            case .settings: SettingsView()
            }
        }
        .onAppear { if pane == nil { pane = Pane(rawValue: savedPane) ?? .join } }
        .onChange(of: pane) { if let pane { savedPane = pane.rawValue } }
        // While the setup assistant is open, it shows the log itself (one sheet at a time).
        .sheet(isPresented: Binding(get: { app.showLog && !app.showSetup }, set: { app.showLog = $0 })) { LogSheet() }
        .sheet(isPresented: $app.showSetup) { SetupView() }
        .task {
            // First launch, or something to install is missing: open the setup assistant.
            await app.setup.refresh(app)
            if app.setup.shouldOpenAtLaunch {
                app.showSetup = true
                app.setup.markSeen()
            }
        }
        .overlay { QuitOverlay() }
        .overlay { RecorderQuitOverlay() }
        .alert(quitQuestion, isPresented: quitAlertShown) {
            Button("Stop and Quit", role: .destructive) { app.quit.confirmQuit() }
            Button("Cancel", role: .cancel) { app.quit.cancelQuit() }
        } message: {
            Text(QuitController.detail)
        }
    }

    private var quitQuestion: String {
        if case .confirm(let n) = app.quit.phase { return QuitController.question(n) }
        return ""
    }

    private var quitAlertShown: Binding<Bool> {
        Binding(get: { if case .confirm = app.quit.phase { return true } else { return false } },
                set: { shown in
                    if !shown, case .confirm = app.quit.phase { app.quit.cancelQuit() }
                })
    }
}

/// Covers the window while the app checks what's running and stops Vexa on quit.
struct QuitOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let quit = app.quit
        if quit.phase == .checking || quit.phase == .stopping {
            ZStack {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(quit.phase == .checking ? "Checking what's running…" : "Stopping Vexa before quitting…")
                            .font(.headline)
                    }
                    if quit.phase == .stopping {
                        Text("Stopping meeting bots, the Vexa containers and Whisper. Colima keeps running. "
                             + "This can take up to \(Int(QuitController.maxWait.components.seconds)) seconds.")
                            .font(.callout).foregroundStyle(.secondary)
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(quit.runner.log.isEmpty ? "…" : quit.runner.log)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .frame(height: 160)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                            .onChange(of: quit.runner.log) { proxy.scrollTo("end") }
                        }
                        HStack {
                            Spacer()
                            Button("Quit Now") { quit.quitNow() }
                                .help("Quit without waiting; stopping carries on in the background.")
                        }
                    }
                }
                .padding(20)
                .frame(width: 520)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 12)
            }
        }
    }
}

/// Shown in the sidebar while a required install step is missing.
struct SetupWarningRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let missing = app.setup.missingInstallSteps
        if !missing.isEmpty {
            Button { app.showSetup = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setup isn't finished").font(.callout.weight(.medium))
                        Text(missing.count == 1 ? "1 step left. Open the setup assistant."
                             : "\(missing.count) steps left. Open the setup assistant.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .help("Missing: \(missing.map(\.title).joined(separator: ", "))")
        }
    }
}

/// Status lights and start/stop controls at the bottom of the sidebar.
struct StatusPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusLight(label: "Whisper", state: app.whisperState,
                        detail: app.whisperLoadedModel?.replacingOccurrences(of: "mlx-community/", with: ""))
            StatusLight(label: "Vexa", state: app.vexaState, detail: nil)
            HStack {
                if app.vexaState == .up || app.whisperState == .up {
                    Button("Stop") { Task { await app.stopStack() } }
                }
                if app.vexaState != .up || app.whisperState != .up {
                    Button("Start") { Task { await app.startStack() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .disabled(app.runner.isRunning || !app.projectLooksValid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusLight: View {
    let label: String
    let state: ServiceState
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout.weight(.medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .help(state == .up ? "\(label) is running" : "\(label) is not running")
    }

    private var color: Color {
        switch state {
        case .up: return .green
        case .down: return .red
        case .unknown: return .gray
        }
    }
}

struct LogSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(app.runner.title).font(.headline)
                if app.runner.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let code = app.runner.lastExitCode, !app.runner.isRunning {
                    Label(code == 0 ? "Done" : "Failed (exit \(code))",
                          systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(code == 0 ? .green : .red)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(app.runner.log.isEmpty ? "…" : app.runner.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: app.runner.log) { proxy.scrollTo("end") }
            }
            HStack {
                Spacer()
                Button("Close") { app.showLog = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.runner.isRunning)
            }
        }
        .padding(20)
        .frame(width: 640, height: 420)
    }
}
