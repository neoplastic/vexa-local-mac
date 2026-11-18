import AppKit
import SwiftUI
import VexaCore

/// Instructions and ready-to-copy settings for connecting Claude to Vexa's MCP server.
struct ClaudeView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = Tab.code
    @State private var scope = ClaudeConnect.CodeScope.user
    @State private var showKey = false
    @State private var checking = false
    @State private var result: ClaudeConnect.CheckResult?
    @State private var keyError: String?
    @State private var copied: String?

    enum Tab: String, CaseIterable { case code = "Claude Code", desktop = "Claude Desktop", web = "claude.ai" }

    private var url: String { ClaudeConnect.mcpURL(gateway: app.gatewayURL) }
    private var key: String { app.apiKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusSection
                if key.isEmpty { keySection } else {
                    Picker("Client", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    switch tab {
                    case .code: codeSection
                    case .desktop: desktopSection
                    case .web: webSection
                    }
                    toolsSection
                    privacySection
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Connect Claude")
        .task(id: key) { await refresh() }
    }

    // MARK: Sections

    private var statusSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon).foregroundStyle(statusColor).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refresh() } } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text("Check again") }
                }.disabled(checking)
            }.padding(4)
        }
    }

    private var keySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("You need an API key first").font(.headline)
                Text("Claude uses a key to talk to your local Vexa. The app can make one for you. It can send bots and read transcripts.")
                    .foregroundStyle(.secondary)
                Button("Generate API key") {
                    Task {
                        do { try await app.generateAPIKey(); keyError = nil } catch { keyError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                if let keyError { Text(keyError).foregroundStyle(.red).font(.callout) }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Where to save it", selection: $scope) {
                Text("All my projects (user)").tag(ClaudeConnect.CodeScope.user)
                Text("Only this folder (local)").tag(ClaudeConnect.CodeScope.local)
                Text("Share with the team (project)").tag(ClaudeConnect.CodeScope.project)
            }
            codeBlock(display: ClaudeConnect.masked(ClaudeConnect.claudeCodeCommand(url: url, key: key, scope: scope), key: key),
                      full: ClaudeConnect.claudeCodeCommand(url: url, key: key, scope: scope), id: "code")
            steps([
                "Press Show key if you want to check the command. Then press Copy command.",
                "Open Terminal and paste the command. Press Return.",
                "Start Claude Code with `claude`. Type /mcp to see Vexa listed as connected.",
                "Ask: \"What's waiting in Vexa?\" or \"Summarize my last meeting.\"",
            ])
            if scope == .project {
                Text("Project scope writes the key into .mcp.json in that folder. Do not commit it to git.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var desktopSection: some View {
        let json = ClaudeConnect.desktopConfigJSON(url: url, key: key)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Claude Desktop starts local helper programs from a config file. The helper `mcp-remote` links it to Vexa's web address. This is the setup we recommend. It needs Node.js (for `npx`).")
                .foregroundStyle(.secondary)
            Text(ClaudeConnect.desktopConfigPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            codeBlock(display: ClaudeConnect.masked(json, key: key), full: json, id: "desktop")
            HStack {
                Button("Reveal config folder in Finder") {
                    let dir = NSString(string: "~/Library/Application Support/Claude").expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                }
            }
            steps([
                "Press Copy config.",
                "In Claude Desktop open Settings, then Developer, then Edit Config. This opens the file above.",
                "Paste the config. If the file already has `mcpServers`, add only the `vexa` entry inside it.",
                "Quit Claude Desktop fully (Cmd+Q) and open it again.",
                "Look for Vexa in the tools menu of a new chat.",
            ])
        }
    }

    private var webSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("claude.ai on the web can't reach your Mac").font(.headline)
            Text("Web connectors are called from Anthropic's cloud. Your Vexa runs at localhost, which only your Mac can reach. So claude.ai can't use it directly.")
            Text("To use it there you would have to expose Vexa to the internet with a tunnel and a public address. That makes your meeting data reachable from outside, so this app does not set it up. Claude Code and Claude Desktop connect from your own Mac and work without it.")
                .foregroundStyle(.secondary)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Claude can do").font(.headline)
            if case .ok(_, let tools) = result {
                ForEach(tools, id: \.name) { t in
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.name).font(.system(.callout, design: .monospaced)).frame(width: 220, alignment: .leading)
                        Text(t.summary).font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Text("These include tools that send a bot to a meeting, stop it, and speak in it. Claude Code asks before it runs a tool unless you allow it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Can't load the tool list because Vexa isn't reachable. Start the stack from Settings, then press Check again.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacySection: some View {
        GroupBox {
            Label("Audio and transcription stay on your Mac. But when Claude reads a transcript, that text is sent to Anthropic as part of your conversation.", systemImage: "lock.shield")
                .font(.callout).padding(4)
        }
    }

    // MARK: Pieces

    private func codeBlock(display: String, full: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(showKey ? full : display)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).fixedSize(horizontal: true, vertical: true)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button(copied == id ? "Copied" : (id == "code" ? "Copy command" : "Copy config")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(full, forType: .string)
                    copied = id
                    Task { try? await Task.sleep(for: .seconds(2)); if copied == id { copied = nil } }
                }
                Toggle(showKey ? "Hide key" : "Show key", isOn: $showKey).toggleStyle(.button)
            }
        }
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(.init(s))
                }
            }
        }
    }

    // MARK: Status

    private var statusIcon: String {
        switch result {
        case .ok: "checkmark.circle.fill"
        case .unauthorized: "key.slash"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle.dotted"
        }
    }
    private var statusColor: Color {
        switch result { case .ok: .green; case nil: .secondary; default: .orange }
    }
    private var statusTitle: String {
        switch result {
        case .ok: "MCP server is running"
        case .unauthorized: "Vexa rejected the API key"
        case .failed: "MCP server not reachable"
        case nil: key.isEmpty ? "No API key yet" : "Checking…"
        }
    }
    private var statusDetail: String {
        switch result {
        case .ok(let info, let tools): "\(info.name) \(info.version) · \(tools.count) tools · streamable HTTP · Bearer key"
        case .unauthorized: "Generate a new key in Settings, or check that it has the bot and tx scopes."
        case .failed(let m): "\(m). Make sure the Vexa stack is running."
        case nil: key.isEmpty ? "Generate a key below to continue." : ""
        }
    }

    private func refresh() async {
        guard !key.isEmpty else { result = nil; return }
        checking = true
        result = await ClaudeConnect.check(url: url, key: key)
        checking = false
    }
}
