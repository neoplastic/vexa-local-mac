import AppKit
import SwiftUI
import VexaCore

let languages: [(code: String, name: String)] = [
    ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
    ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"),
    ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"), ("he", "Hebrew"),
    ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("vi", "Vietnamese"),
    ("id", "Indonesian"),
]

struct JoinView: View {
    @Environment(AppModel.self) private var app
    var onJoined: () -> Void

    @State private var input = ""
    @State private var passcode = ""
    @State private var teamsHost = "teams.microsoft.com"
    @State private var joining = false
    @State private var error: String?
    @AppStorage("vexa.join.showBot") private var showBot = false

    private var parsed: ParsedMeeting? { MeetingParser.parse(input) }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                TextField("Meeting link, code or ID", text: $input, prompt: Text("Paste a Teams, Google Meet or Zoom link"), axis: .vertical)
                    .lineLimit(1...4)
                detection
            } header: {
                Text("Meeting")
            } footer: {
                Text("Examples: teams.microsoft.com/meet/123456789012?p=Ab12Cd · meet.google.com/abc-defg-hij · zoom.us/j/12345678901?pwd=Ab12Cd · \"Meeting ID: 123 456 789 012  Passcode: Ab12Cd\".")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let p = parsed {
                Section("Browser extension (recommended)") { ExtensionGuideView(platform: p.platform) }
            }

            if let p = joinable {
                Section {
                    DisclosureGroup("Or send a Vexa bot instead", isExpanded: $showBot) {
                        if p.meetingURL == nil {
                            TextField("Passcode", text: $passcode, prompt: Text(p.passcode == nil ? "Usually required for Teams" : ""))
                        }
                        if p.needsTeamsHost {
                            Picker("Teams account", selection: $teamsHost) {
                                Text("Work or school (teams.microsoft.com)").tag("teams.microsoft.com")
                                Text("Personal (teams.live.com)").tag("teams.live.com")
                            }
                        }
                        TextField("Name shown in the meeting", text: $app.botName)
                        Picker("Spoken language", selection: $app.language) {
                            ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        HStack {
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red).textSelection(.enabled)
                            } else if app.vexaState == .down {
                                Label("Vexa isn't running. Use Start in the sidebar.", systemImage: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if joining { ProgressView().controlSize(.small) }
                            Button("Send bot to meeting", action: join)
                                .disabled(joining)
                        }
                    }
                } footer: {
                    Text("A backup if the extension doesn't work. The bot joins as a guest, so someone may need to admit it from the lobby, and speakers aren't named.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Transcript") {
                LabeledContent("Save to") {
                    HStack {
                        Text(app.outputDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { chooseOutputFolder() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Join meeting")
        .onChange(of: input) {
            error = nil
            if let pc = parsed?.passcode { passcode = pc }
        }
    }

    /// The detected meeting, if a bot can be offered for its platform (Teams).
    private var joinable: ParsedMeeting? {
        guard let p = parsed, p.platform.botAvailable else { return nil }
        return p
    }

    @ViewBuilder private var detection: some View {
        if let p = parsed {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(p.platform.displayName) · \(p.nativeMeetingId)",
                      systemImage: p.platform.symbolName)
                    .foregroundStyle(.green)
                if let note = p.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        } else if let reason = MeetingParser.zoomRejection(input) {
            Label(reason, systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("Not recognised as a Google Meet, Teams or Zoom meeting", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }

    private func join() {
        guard let p = joinable, !joining else { return }
        joining = true
        error = nil
        Task {
            defer { joining = false }
            do {
                _ = try await app.join(p, passcode: passcode, teamsHost: p.needsTeamsHost ? teamsHost : nil)
                input = ""
                passcode = ""
                onJoined()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseOutputFolder() {
        if let path = pickFolder(startingAt: app.outputDirectory) { app.outputDirectory = path }
    }
}

@MainActor
func pickFolder(startingAt path: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: path)
    return panel.runModal() == .OK ? panel.url?.path : nil
}
