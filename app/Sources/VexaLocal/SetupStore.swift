import AppKit
import Foundation
import Observation
import VexaCore

/// The setup assistant's state: the latest check, and the actions behind its buttons.
@MainActor @Observable
final class SetupStore {
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    static let projectRepo = "https://github.com/neoplastic/vexa-local-mac"
    static let chromeDownloadURL = URL(string: "https://www.google.com/chrome/")!

    /// Nil until the first check finishes.
    private(set) var facts: SetupFacts?
    private(set) var isChecking = false
    private(set) var isRunningAll = false
    /// The row whose action is running.
    private(set) var busyItem: SetupItem?
    /// A short note under the "Set up everything" button.
    var message: String?
    var messageIsError = false
    /// The user ticked "Done" after loading the extension in Chrome (the app can't see inside Chrome).
    var extensionDone: Bool {
        didSet {
            defaults.set(extensionDone, forKey: Self.extensionDoneKey)
            facts?.extensionDone = extensionDone
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let injectedProbe: SystemProbe?
    @ObservationIgnored private var checkGeneration = 0

    static let extensionDoneKey = "vexa.setup.extensionDone"
    static let seenKey = "vexa.setup.seen"

    /// Where the running app lives (Bundle.main.bundlePath); tests set their own.
    @ObservationIgnored var bundlePath: String

    init(defaults d: UserDefaults = .standard, probe: SystemProbe? = nil,
         bundlePath: String = Bundle.main.bundlePath) {
        defaults = d
        injectedProbe = probe
        self.bundlePath = bundlePath
        extensionDone = d.bool(forKey: Self.extensionDoneKey)
    }

    var probe: SystemProbe { injectedProbe ?? .live() }
    var rows: [SetupRow] { facts.map(SetupPlanner.rows) ?? [] }
    var missingInstallSteps: [SetupItem] { facts.map(SetupPlanner.missingInstallSteps) ?? [] }
    var isBusy: Bool { busyItem != nil || isRunningAll }

    /// Open the assistant at launch: the first time, and whenever something to install is missing.
    var shouldOpenAtLaunch: Bool { !defaults.bool(forKey: Self.seenKey) || !missingInstallSteps.isEmpty }
    func markSeen() { defaults.set(true, forKey: Self.seenKey) }

    // MARK: Checking

    /// Checks every row again. Overlapping checks are fine; the newest one wins.
    @discardableResult
    func refresh(_ app: AppModel) async -> SetupFacts {
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        let probe = self.probe
        async let gathered = SetupProber.gather(projectPath: app.projectPath, colimaProfile: app.colimaProfile,
                                                probe: probe)
        await app.refreshStatus()
        await app.refreshDesktopHost()
        var f = await gathered
        f.whisperUp = app.whisperState == .up
        f.gatewayUp = app.vexaState == .up
        f.desktopHostUp = app.desktopHostState == .up
        f.chromeInstalled = probe.appInstalled(SetupProber.chromeBundleID)
        f.extensionDone = extensionDone
        f.appBundlePath = bundlePath
        f.microphone = probe.microphone()
        f.screenRecording = probe.screenRecording()
        if generation == checkGeneration {
            facts = f
            isChecking = false
        }
        // Remember a folder that works, even a guessed one (see AppModel.saveProjectPath).
        if f.projectValid, f.projectPath == app.projectPath { app.saveProjectPath() }
        return f
    }

    // MARK: Set up everything

    /// Runs the automatic steps in order (install tools → fix Docker → setup.sh → start)
    /// and stops at the first step that needs the user.
    func setUpEverything(_ app: AppModel) async {
        guard !isBusy, !app.runner.isRunning else { return }
        isRunningAll = true
        message = "Working…"
        messageIsError = false
        defer { isRunningAll = false }
        let outcome = await SetupSequence.run(
            check: { await self.refresh(app) },
            perform: { action in await self.perform(action, app) })
        switch outcome {
        case .finished:
            show("Everything is set up.", error: false)
        case .needsUser(let action):
            show(action.prompt, error: false)
        case .failed(let action):
            // Keep a step's own error (e.g. from the Docker fix); otherwise say which step failed.
            if !messageIsError {
                show("\(action.item.title): that step failed. See the log for details.", error: true)
            }
        case .stuck(let action):
            show("\(action.item.title) still isn't done after trying once. See the log, then check again.", error: true)
        }
    }

    /// Does one automatic step. True when it succeeded.
    func perform(_ action: SetupAction, _ app: AppModel) async -> Bool {
        switch action {
        case .brewInstall(let names): return await brewInstall(names, app)
        case .fixDockerConfig: return fixDockerConfig()
        case .runSetup: return await runSetup(app)
        case .startServices: return await busy(.services) { await app.startStack(); return app.runner.lastExitCode == 0 }
        case .startDesktopHost: return await startDesktopHost(app)
        default: return false
        }
    }

    // MARK: Row actions

    @discardableResult
    func brewInstall(_ names: [String], _ app: AppModel, cask: Bool = false) async -> Bool {
        guard let brew = facts?.brewPath ?? SetupProber.brewPath(probe), !names.isEmpty else {
            show("Install Homebrew first.", error: true)
            return false
        }
        let item: SetupItem = cask ? .chrome : (names == ["node"] ? .node : .formulae)
        return await busy(item) {
            app.showLog = true
            let command = [brew, "install"] + (cask ? ["--cask"] : []) + names
            let code = await app.runner.run("Installing \(names.joined(separator: ", "))", command: command,
                                            in: URL(fileURLWithPath: NSHomeDirectory()))
            return code == 0
        }
    }

    func installMissingFormulae(_ app: AppModel) async {
        guard let f = facts else { return }
        // Node comes along when there's no usable one, so one brew run does both.
        let names = f.missingFormulae + (f.hasNode ? [] : ["node"])
        await brewInstall(names, app)
    }

    /// Backs up ~/.docker/config.json and fixes the plugin folder and the credential helper.
    @discardableResult
    func fixDockerConfig() -> Bool {
        guard let f = facts else { return false }
        let url = URL(fileURLWithPath: probe.home).appendingPathComponent(".docker/config.json")
        do {
            let backup = try DockerConfigWriter.apply(at: url,
                                                      addPluginDir: f.dockerNeedsPluginDir ? f.dockerPluginDir : nil,
                                                      removeDesktopCredsStore: f.dockerCredsBroken)
            show("Docker's settings are fixed." + (backup.map { " The old file is saved as \($0.lastPathComponent)." } ?? ""),
                 error: false)
            return true
        } catch {
            show("Could not fix Docker's settings: \(error.localizedDescription)", error: true)
            return false
        }
    }

    /// Shows Apple's own Command Line Tools installer.
    func installCommandLineTools(_ app: AppModel) async {
        await busy(.commandLineTools) {
            let r = await probe.run(["xcode-select", "--install"], 20)
            if r.ok || r.message.contains("install requested") {
                show("Follow Apple's window to install the Command Line Tools, then press Check again.", error: false)
            } else {
                show("Could not start the installer: \(r.message)", error: true)
            }
            return r.ok
        }
    }

    func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewInstallCommand, forType: .string)
        show("Copied. Paste it into Terminal and press Return. Come back here when it's done.", error: false)
    }

    /// Opens Terminal.app (no automation; the user pastes the command).
    func openTerminal() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseProject(_ app: AppModel) async {
        guard let path = pickFolder(startingAt: app.projectPath) else { return }
        app.projectPath = path
        await refresh(app)
        if facts?.projectValid == false {
            show("That folder doesn't contain scripts/start.sh. Pick your vexa-local-mac folder.", error: true)
        } else {
            message = nil
        }
    }

    /// Clones the project into a folder the user picks, then uses it.
    func downloadProject(_ app: AppModel) async {
        guard let parent = pickFolder(startingAt: NSHomeDirectory() + "/Documents") else { return }
        let target = URL(fileURLWithPath: parent).appendingPathComponent("vexa-local-mac")
        if FileManager.default.fileExists(atPath: target.path) {
            if FileManager.default.fileExists(atPath: target.appendingPathComponent("scripts/start.sh").path) {
                app.projectPath = target.path
                show("Using the copy that's already in \(parent).", error: false)
            } else {
                show("\(target.path) already exists but isn't the project. Pick another folder.", error: true)
            }
            return
        }
        let ok = await busy(.project) {
            app.showLog = true
            return await app.runner.run("Downloading vexa-local-mac",
                                        command: ["git", "clone", Self.projectRepo, target.path],
                                        in: URL(fileURLWithPath: parent)) == 0
        }
        if ok { app.projectPath = target.path }
    }

    /// Copies the app into /Applications (replacing an older copy), saves the project
    /// folder, reopens the copy and quits this one. Vexa keeps running.
    func moveToApplications(_ app: AppModel) async {
        guard facts?.appLocation == .elsewhere else { return }
        app.saveProjectPath()
        let source = URL(fileURLWithPath: bundlePath)
        let copied: Bool = await busy(.appInstalled) {
            do {
                try await AppMover.copy(from: source)
                return true
            } catch {
                show(error.localizedDescription, error: true)
                return false
            }
        }
        guard copied else { return }
        show("Copied to Applications. Reopening from there…", error: false)
        AppMover.relaunch(app) { [weak self] text in self?.show(text, error: true) }
    }

    @discardableResult
    func runSetup(_ app: AppModel) async -> Bool {
        let ok = await busy(.vexaSetup) {
            app.showLog = true
            return await app.runner.run("Setting up Vexa (20-40 minutes the first time)",
                                        script: app.script("setup.sh"), in: app.projectURL) == 0
        }
        app.reloadEnv()
        return ok
    }

    @discardableResult
    func startDesktopHost(_ app: AppModel) async -> Bool {
        await busy(.browserExtension) {
            await app.startDesktopHost()
            return app.runner.lastExitCode == 0
        }
    }

    // MARK: Helpers

    @discardableResult
    private func busy(_ item: SetupItem, _ work: () async -> Bool) async -> Bool {
        busyItem = item
        defer { busyItem = nil }
        return await work()
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
