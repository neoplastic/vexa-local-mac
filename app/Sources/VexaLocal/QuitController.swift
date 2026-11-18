import AppKit
import Foundation
import Observation
import VexaCore

/// Stops Vexa (meeting bots, containers, Whisper — never Colima) when the app quits.
///
/// Flow: `applicationShouldTerminate` answers `.terminateLater` and checks what is
/// running. Nothing running → quit at once. Bots in meetings → cancel the quit and
/// ask in the window; "Stop and Quit" starts a second, confirmed quit. Otherwise run
/// scripts/stop.sh, capped at `maxWait`, then quit.
@MainActor @Observable
final class QuitController {
    enum Phase: Equatable {
        case idle
        case checking
        case confirm(meetings: Int)
        case stopping
    }

    static let settingKey = "vexa.stopOnQuit"
    static let maxWait: Duration = .seconds(90)

    /// The "Stop Vexa when quitting" setting (default on).
    static var stopOnQuit: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    var phase: Phase = .idle
    /// Its own runner, so a quit is never blocked by another script the app is running.
    let runner = ScriptRunner()

    /// Set when the app reopens itself from /Applications: quit at once and leave Vexa running.
    @ObservationIgnored var relaunching = false
    @ObservationIgnored private var confirmed = false
    @ObservationIgnored private var awaitingReply = false

    func shouldTerminate(_ app: AppModel) -> NSApplication.TerminateReply {
        // A second Cmd-Q while checking, asking or stopping: keep going with the first.
        guard phase == .idle else { return .terminateCancel }
        if relaunching { return .terminateNow }
        guard Self.stopOnQuit, app.projectLooksValid else { return .terminateNow }
        app.showLog = false   // make room for the question / progress
        phase = .checking
        awaitingReply = true
        Task { await prepare(app) }
        return .terminateLater
    }

    /// "Stop and Quit" in the question.
    func confirmQuit() {
        phase = .idle
        confirmed = true
        NSApp.terminate(nil)
    }

    func cancelQuit() {
        confirmed = false
        phase = .idle
    }

    /// "Quit Now" while stopping: leave stop.sh running on its own and quit.
    func quitNow() { reply(true) }

    private func prepare(_ app: AppModel) async {
        let alreadyConfirmed = confirmed
        confirmed = false
        let running = await checkRunning(app)
        guard running.needsStopping else { return reply(true) }

        let meetings = running.meetingsInProgress
        if meetings > 0, !alreadyConfirmed {
            reply(false)
            // Quit may come from the Dock or a logout while the app is hidden or in the background.
            NSApp.unhide(nil)
            NSApp.activate()
            if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                phase = .confirm(meetings: meetings)
            } else {
                askWithoutWindow(meetings: meetings)
            }
            return
        }

        phase = .stopping
        let finished = await Self.withTimeout(Self.maxWait) { [runner] in
            await runner.run("Stopping Vexa", script: app.script("stop.sh"), in: app.projectURL)
        }
        if !finished { runner.log += "\nStill stopping after \(Self.maxWait); quitting anyway.\n" }
        reply(true)
    }

    private func reply(_ quit: Bool) {
        guard awaitingReply else { return }
        awaitingReply = false
        if !quit { phase = .idle }
        NSApp.reply(toApplicationShouldTerminate: quit)
    }

    /// Fast look at what's running; each probe has a short time limit.
    private func checkRunning(_ app: AppModel) async -> RunningVexa {
        let env = DockerCLI.environment(colimaProfile: app.colimaProfile)
        async let containers = Self.runningContainers(env)
        await app.refreshStatus()
        let names = await containers
        return RunningVexa(dockerReachable: names != nil, runningContainers: names ?? [],
                           whisperRunning: app.whisperState == .up || app.whisperPidAlive,
                           unfinishedSessions: app.sessions.filter { !$0.finished }.count)
    }

    /// Names of running containers, or nil when Docker can't be reached.
    private nonisolated static func runningContainers(_ env: [String: String]) async -> [String]? {
        guard DockerCLI.socketExists(in: env) else { return nil }
        let ps = await DockerCLI.docker(["ps", "--format", "{{.Names}}"], env, timeout: 6)
        return ps.ok ? ps.output.split(whereSeparator: \.isNewline).map(String.init) : nil
    }

    /// Fallback when every window is closed, so there's nowhere to show the question.
    private func askWithoutWindow(meetings: Int) {
        let alert = NSAlert()
        alert.messageText = Self.question(meetings)
        alert.informativeText = Self.detail
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { confirmQuit() } else { cancelQuit() }
    }

    static func question(_ meetings: Int) -> String {
        meetings == 1 ? "1 meeting is still being transcribed — stop it and quit?"
            : "\(meetings) meetings are still being transcribed — stop them and quit?"
    }

    static let detail = "The bots leave their meetings and Vexa shuts down. Transcripts saved so far are kept."

    /// Runs `work`; returns false if it hadn't finished after `limit` (it keeps running).
    private static func withTimeout(_ limit: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            Task { @MainActor in
                await work()
                if once.claim() { cont.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { cont.resume(returning: false) }
            }
        }
    }
}
