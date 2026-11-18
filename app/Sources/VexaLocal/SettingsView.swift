import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var keyMessage: String?
    @State private var keyError = false
    @State private var working = false
    @State private var showKey = false
    @AppStorage(QuitController.settingKey) private var stopOnQuit = true

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("Project folder") {
                    HStack {
                        Text(app.projectPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { if let p = pickFolder(startingAt: app.projectPath) { app.projectPath = p } }
                    }
                }
                if !app.projectLooksValid {
                    Label("This folder doesn't contain scripts/start.sh. Pick your vexa-local-mac folder.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if app.env.isEmpty {
                    Label("Vexa isn't set up yet. Open the setup assistant below.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                LabeledContent("Setup assistant") {
                    Button("Open…") { app.showSetup = true }
                }
            } header: {
                Text("Vexa")
            } footer: {
                Text("The vexa-local-mac checkout. The app reads ports and tokens from its .env file and runs its scripts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcripts") {
                LabeledContent("Default folder") {
                    HStack {
                        Text(app.outputDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { if let p = pickFolder(startingAt: app.outputDirectory) { app.outputDirectory = p } }
                    }
                }
            }

            Section {
                TextField("Account email", text: $app.apiUserEmail)
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        Group {
                            if showKey {
                                TextField("API key", text: $app.apiKey)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                SecureField("API key", text: $app.apiKey)
                            }
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showKey ? "Hide the key" : "Show the key")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(app.apiKey, forType: .string)
                            keyMessage = "API key copied to the clipboard."
                            keyError = false
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(app.apiKey.isEmpty)
                        .help("Copy the key")
                    }
                }
                HStack {
                    if let keyMessage {
                        Text(keyMessage).font(.caption).foregroundStyle(keyError ? .red : .green)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button(app.apiKey.isEmpty ? "Create API key" : "Create new API key") { createKey() }
                        .disabled(working || app.vexaState != .up)
                }
            } header: {
                Text("API access")
            } footer: {
                Text("Created automatically the first time you send a bot. Uses ADMIN_TOKEN from .env.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Start everything") { Task { await app.startStack() } }
                    Button("Stop everything") { Task { await app.stopStack() } }
                    Button("Restart Whisper") {
                        Task {
                            app.showLog = true
                            await app.runner.run("Restarting Whisper", script: app.script("whisper.sh"),
                                                 arguments: ["restart"], in: app.projectURL)
                            await app.refreshStatus()
                        }
                    }
                    Spacer()
                    Button("Open Vexa web app") { NSWorkspace.shared.open(app.webAppURL) }
                        .disabled(app.vexaState != .up)
                }
                .disabled(app.runner.isRunning || !app.projectLooksValid)
                Toggle("Stop Vexa when quitting", isOn: $stopOnQuit)
            } header: {
                Text("Services")
            } footer: {
                Text("When you quit the app, stop the meeting bots, the Vexa containers and Whisper "
                     + "(Colima keeps running). You're asked first if a meeting is still being transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { app.reloadEnv() }
    }

    private func createKey() {
        working = true
        keyMessage = nil
        Task {
            defer { working = false }
            do {
                try await app.generateAPIKey()
                keyMessage = "New API key saved."
                keyError = false
            } catch {
                keyMessage = error.localizedDescription
                keyError = true
            }
        }
    }
}
