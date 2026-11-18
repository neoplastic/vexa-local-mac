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

    private var parsed: ParsedMeeting? { MeetingParser.parse(input) }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                TextField("Meeting link, code or ID", text: $input, prompt: Text("Paste a Google Meet or Teams link"), axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(join)
                detection
                if let p = parsed, p.platform == .teams, p.meetingURL == nil {
                    TextField("Passcode", text: $passcode, prompt: Text(p.passcode == nil ? "Usually required for Teams" : ""))
                }
                if parsed?.needsTeamsHost == true {
                    Picker("Teams account", selection: $teamsHost) {
                        Text("Work or school (teams.microsoft.com)").tag("teams.microsoft.com")
                        Text("Personal (teams.live.com)").tag("teams.live.com")
                    }
                }
            } header: {
                Text("Meeting")
            } footer: {
                Text("Examples: meet.google.com/abc-defg-hij · abc-defg-hij · teams.microsoft.com/meet/123456789012?p=Ab12Cd · \"Meeting ID: 123 456 789 012  Passcode: Ab12Cd\"")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bot") {
                TextField("Name shown in the meeting", text: $app.botName)
                Picker("Spoken language", selection: $app.language) {
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
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

            Section {
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
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil || joining)
                }
            } footer: {
                Text("Someone in the meeting may need to admit the bot from the lobby.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Join meeting")
        .onChange(of: input) {
            error = nil
            if let pc = parsed?.passcode { passcode = pc }
        }
    }

    @ViewBuilder private var detection: some View {
        if let p = parsed {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(p.platform.displayName) · \(p.nativeMeetingId)",
                      systemImage: p.platform == .googleMeet ? "video.fill" : "person.3.fill")
                    .foregroundStyle(.green)
                if let note = p.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("Not recognised as a Google Meet or Teams meeting", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }

    private func join() {
        guard let p = parsed, !joining else { return }
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
