import AppKit
import SwiftUI
import VexaCore

/// Shown on the Join page for every platform: the Vexa browser extension is the
/// recommended route (Teams can also use a bot as a backup).
struct ExtensionGuideView: View {
    @Environment(AppModel.self) private var app
    let platform: MeetingPlatform

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(platform.displayName) meetings are transcribed with the Vexa browser extension. Join the meeting yourself in Chrome.",
                  systemImage: "puzzlepiece.extension.fill")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let note = platform.botRefusalNote {
                HStack(spacing: 6) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    ForEach(platform.botRefusalIssueURLs, id: \.self) { url in
                        Link("Details", destination: url).font(.caption)
                    }
                }
            }

            ExtensionInstallSteps(includeMeetingStep: true,
                                  notBuiltHint: "The extension hasn't been built yet. Press Start it below, or run scripts/desktop.sh start (or make setup) in the project folder.")

            Divider()
            hostStatus
        }
        .padding(.vertical, 4)
        .task { await app.refreshDesktopHost() }
    }

    @ViewBuilder private var hostStatus: some View {
        HStack {
            switch app.desktopHostState {
            case .up:
                Label("Extension host is running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .down:
                Label("Extension host is not running", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button(app.runner.isRunning ? "Working…" : "Start it") { Task { await app.startDesktopHost() } }
                    .disabled(app.runner.isRunning || !app.projectLooksValid)
            case .unknown:
                Label("Checking the extension host…", systemImage: "circle.dotted").foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text("The extension sends audio to a small program on this Mac (the host), which transcribes it with your local Whisper. Transcripts appear on the Transcripts page.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The once-only extension steps and their buttons. Used on the Join page and in the
/// setup assistant.
struct ExtensionInstallSteps: View {
    @Environment(AppModel.self) private var app
    /// Adds step 3 (start it in a meeting).
    var includeMeetingStep = true
    /// Shown by "Show extension folder" when the extension isn't built yet.
    var notBuiltHint = "The extension hasn't been built yet. Starting the extension host builds it."

    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Install the extension once. Open chrome://extensions, turn on Developer mode, choose Load unpacked, and pick the extension folder.")
                step(2, "Paste your API key into the extension's settings (open the Vexa side panel and find Settings).")
                if includeMeetingStep {
                    step(3, "Open the meeting in Chrome, click the Vexa icon in the toolbar on the meeting tab, and press Start.")
                }
            }

            HStack {
                Button("Copy API key", systemImage: "key") { Task { await copyKey() } }
                Button("Show extension folder", systemImage: "folder") { showFolder() }
                Button("Open Chrome extensions page", systemImage: "globe") { openChromeExtensions() }
            }
            .buttonStyle(.bordered)

            if let message {
                Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(messageIsError ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func copyKey() async {
        do {
            if app.apiKey.isEmpty { try await app.generateAPIKey() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.apiKey, forType: .string)
            show("API key copied. Paste it into the extension's settings.", error: false)
        } catch {
            show("Could not get an API key: \(error.localizedDescription)", error: true)
        }
    }

    private func showFolder() {
        if app.extensionFolderExists {
            NSWorkspace.shared.activateFileViewerSelecting([app.extensionFolderURL])
            show("Choose this folder in Chrome with Load unpacked.", error: false)
        } else {
            show(notBuiltHint, error: true)
        }
    }

    private func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            show("Google Chrome isn't installed. The extension needs Chrome (or another Chromium browser that can load unpacked extensions).", error: true)
            return
        }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                                configuration: NSWorkspace.OpenConfiguration()) { _, err in
            Task { @MainActor in
                if let err { show("Chrome could not open the page: \(err.localizedDescription). Type chrome://extensions in its address bar.", error: true) }
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
