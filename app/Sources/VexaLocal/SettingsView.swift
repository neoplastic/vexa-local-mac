import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var keyMessage: String?
    @State private var keyError = false
    @State private var working = false

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
                    Label("No .env yet. Run 'make setup' in the project folder first.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
                SecureField("API key", text: $app.apiKey)
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
                Text("Created automatically the first time you send a bot. Uses ADMIN_API_TOKEN from .env.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Services") {
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
                    Button("Open dashboard") { NSWorkspace.shared.open(app.dashboardURL) }
                        .disabled(app.vexaState != .up)
                }
                .disabled(app.runner.isRunning || !app.projectLooksValid)
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
