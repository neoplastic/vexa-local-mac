import AppKit
import SwiftUI

@main
struct VexaLocalApp: App {
    @State private var app = AppModel()

    init() {
        // Running from `swift run` has no bundle; make it a normal foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Vexa Local") {
            ContentView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 560)
                .task { app.startPolling() }
        }
        .windowResizability(.contentMinSize)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case join = "Join meeting"
    case sessions = "Transcripts"
    case models = "Whisper models"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .join: return "person.badge.plus"
        case .sessions: return "doc.text"
        case .models: return "waveform"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var pane: Pane? = .join

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
                    .badge(p == .sessions ? app.sessions.filter { !$0.finished }.count : 0)
            }
            .safeAreaInset(edge: .bottom) { StatusPanel().padding(12) }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch pane ?? .join {
            case .join: JoinView(onJoined: { pane = .sessions })
            case .sessions: SessionsView()
            case .models: ModelsView()
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: $app.showLog) { LogSheet() }
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
