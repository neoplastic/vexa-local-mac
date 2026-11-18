import Foundation

// The setup assistant's pure logic: what is checked, what each row says, and what to do next.
// The app gathers `SetupFacts` (VexaLocal/SetupProbe.swift); everything here is testable.

/// One row of the setup assistant, in order. Each row depends only on rows above it.
public enum SetupItem: String, CaseIterable, Identifiable, Sendable {
    case commandLineTools, homebrew, formulae, node, dockerPlugins, project, appInstalled, vexaSetup, services
    case chrome, browserExtension, permissions

    public var id: String { rawValue }

    public enum Kind: Sendable { case required, optional, info }

    public var kind: Kind {
        switch self {
        case .chrome, .browserExtension: return .optional
        case .permissions: return .info
        default: return .required
        }
    }

    /// Things that are installed once. Services are left out: they are stopped on quit,
    /// and the sidebar already has a Start button for them.
    public var isInstallStep: Bool { kind == .required && self != .services }

    public var title: String {
        switch self {
        case .commandLineTools: return "Command Line Tools (git)"
        case .homebrew: return "Homebrew"
        case .formulae: return "Homebrew tools"
        case .node: return "Node 20 or newer"
        case .dockerPlugins: return "Docker compose and buildx"
        case .project: return "Project folder"
        case .appInstalled: return "App installed in Applications"
        case .vexaSetup: return "Vexa set up"
        case .services: return "Services running"
        case .chrome: return "Google Chrome"
        case .browserExtension: return "Browser extension"
        case .permissions: return "Permissions for the Record page"
        }
    }

    /// Rows that must be fine before this row's button can work.
    public var dependencies: [SetupItem] {
        switch self {
        case .commandLineTools, .homebrew, .appInstalled, .permissions: return []
        case .formulae, .node: return [.homebrew]
        case .dockerPlugins: return [.formulae]
        case .project: return [.commandLineTools]
        case .vexaSetup: return [.commandLineTools, .homebrew, .formulae, .node, .dockerPlugins, .project]
        case .services: return [.vexaSetup]
        case .chrome: return []
        case .browserExtension: return [.vexaSetup]
        }
    }
}

public enum PermissionStatus: Equatable, Sendable {
    case allowed, notAsked, denied
}

/// Where the running app lives.
public enum AppLocation: Equatable, Sendable {
    /// In /Applications.
    case installed
    /// A .app somewhere else (e.g. app/build); it can be moved.
    case elsewhere
    /// Not an app bundle at all (`swift run`); nothing to move.
    case notABundle

    public static let applicationsFolder = "/Applications/"

    public init(bundlePath: String) {
        let path = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        if !path.hasSuffix(".app") {
            self = .notABundle
        } else if path.hasPrefix(Self.applicationsFolder) {
            self = .installed
        } else {
            self = .elsewhere
        }
    }
}

/// Everything the assistant knows about this Mac. Gathered by the app; read-only here.
public struct SetupFacts: Equatable, Sendable {
    public static let formulae = ["colima", "docker", "docker-compose", "docker-buildx", "uv", "ffmpeg", "pnpm"]

    public var commandLineTools = false
    public var brewPath: String?
    public var installedFormulae: Set<String> = []
    /// The Node 20+ that scripts will use, if any.
    public var nodePath: String?
    public var nodeVersion: String?
    /// The newest Node found at all (shown when it is too old).
    public var newestNodeFound: String?
    public var dockerComposeWorks = false
    public var dockerBuildxWorks = false
    public var dockerConfig = DockerConfigFile.Status()
    public var dockerPluginDir = DockerConfigFile.homebrewPluginDir
    /// Homebrew's compose/buildx plugin files are in `dockerPluginDir`.
    public var homebrewPluginsPresent = false
    /// `docker-credential-desktop` is on PATH.
    public var credentialHelperInstalled = false
    public var projectPath = ""
    public var projectValid = false
    /// Bundle.main.bundlePath of the running app.
    public var appBundlePath = "/Applications/Vexa Local.app"
    public var envExists = false
    public var vexaFolderExists = false
    public var colimaRunning = false
    public var whisperUp = false
    public var gatewayUp = false
    public var desktopHostUp = false
    public var chromeInstalled = false
    public var extensionBuilt = false
    /// The user ticked "Done" after loading the extension in Chrome.
    public var extensionDone = false
    public var microphone = PermissionStatus.notAsked
    public var screenRecording = PermissionStatus.notAsked

    public init() {}

    public var appLocation: AppLocation { AppLocation(bundlePath: appBundlePath) }
    public var missingFormulae: [String] { Self.formulae.filter { !installedFormulae.contains($0) } }
    public var hasNode: Bool { nodePath != nil }
    public var vexaSetUp: Bool { projectValid && envExists && vexaFolderExists }
    public var coreServicesUp: Bool { colimaRunning && whisperUp && gatewayUp }

    /// Docker can't find compose/buildx, and adding Homebrew's plugin folder would fix that.
    public var dockerNeedsPluginDir: Bool {
        !(dockerComposeWorks && dockerBuildxWorks) && homebrewPluginsPresent
            && dockerConfig.readable && !dockerConfig.hasPluginDir
    }
    /// The left-over Docker Desktop credential helper would break image pulls.
    public var dockerCredsBroken: Bool { dockerConfig.desktopCredsStore && !credentialHelperInstalled }
    public var dockerFixable: Bool { dockerConfig.readable && (dockerNeedsPluginDir || dockerCredsBroken) }
    public var dockerOK: Bool { dockerComposeWorks && dockerBuildxWorks && !dockerCredsBroken }
}

public enum SetupState: Equatable, Sendable {
    /// Done.
    case ok
    /// Required and not done.
    case missing
    /// Optional and not done.
    case warning
    /// Nothing to do here; just information.
    case info
}

public struct SetupRow: Equatable, Identifiable, Sendable {
    public var item: SetupItem
    public var state: SetupState
    /// One or two plain sentences.
    public var detail: String
    public var id: SetupItem { item }
}

/// Something the assistant can do, or ask the user to do.
public enum SetupAction: Equatable, Sendable {
    case installCommandLineTools
    case installHomebrew
    case brewInstall([String])
    case fixDockerConfig
    /// Nothing the app can fix by itself; the row explains.
    case needsAttention(SetupItem)
    case chooseProject
    /// Copy the app into /Applications and reopen it from there.
    case moveToApplications
    case runSetup
    case startServices
    /// scripts/desktop.sh start: builds the extension and starts its host.
    case startDesktopHost
    case installChrome
    case loadExtension

    /// Steps "Set up everything" can't do on its own.
    public var needsUser: Bool {
        switch self {
        case .brewInstall, .fixDockerConfig, .runSetup, .startServices, .startDesktopHost: return false
        default: return true
        }
    }

    public var item: SetupItem {
        switch self {
        case .installCommandLineTools: return .commandLineTools
        case .installHomebrew: return .homebrew
        case .brewInstall(let names): return names == ["node"] ? .node : .formulae
        case .fixDockerConfig: return .dockerPlugins
        case .needsAttention(let item): return item
        case .chooseProject: return .project
        case .moveToApplications: return .appInstalled
        case .runSetup: return .vexaSetup
        case .startServices: return .services
        case .startDesktopHost: return .browserExtension
        case .installChrome: return .chrome
        case .loadExtension: return .browserExtension
        }
    }

    /// What to tell the user when "Set up everything" stops here.
    public var prompt: String {
        switch self {
        case .installCommandLineTools:
            return "Install Apple's Command Line Tools first. Press Install on that row and follow Apple's window."
        case .installHomebrew:
            return "Install Homebrew first. Copy the command, paste it into Terminal, then come back here."
        case .brewInstall(let names): return "Installing \(names.joined(separator: ", "))."
        case .fixDockerConfig: return "Fixing Docker's settings."
        case .needsAttention(let item): return "\(item.title) needs a look. See that row."
        case .chooseProject: return "Choose your vexa-local-mac folder, or download it."
        case .moveToApplications:
            return "Move the app to Applications next. Press Move to Applications; the app reopens from there."
        case .runSetup: return "Setting up Vexa."
        case .startServices: return "Starting everything."
        case .startDesktopHost: return "Starting the extension host."
        case .installChrome:
            return "Everything required is done. Optional: install Google Chrome for the browser extension."
        case .loadExtension:
            return "Everything is ready. Last step: load the extension in Chrome, then tick Done."
        }
    }
}

public enum SetupPlanner {
    /// One row per item, in order.
    public static func rows(_ f: SetupFacts) -> [SetupRow] {
        SetupItem.allCases.map { row($0, f) }
    }

    public static func row(_ item: SetupItem, _ f: SetupFacts) -> SetupRow {
        let (state, detail) = describe(item, f)
        return SetupRow(item: item, state: state, detail: detail)
    }

    /// Required install steps that aren't done (opens the assistant at launch; sidebar warning).
    public static func missingInstallSteps(_ f: SetupFacts) -> [SetupItem] {
        SetupItem.allCases.filter { $0.isInstallStep && row($0, f).state == .missing }
    }

    /// Rows this row depends on that aren't done yet.
    public static func unmetDependencies(_ item: SetupItem, _ f: SetupFacts) -> [SetupItem] {
        item.dependencies.filter { row($0, f).state != .ok }
    }

    /// The next thing to do, in row order. Nil when everything is done.
    public static func nextAction(_ f: SetupFacts) -> SetupAction? {
        if !f.commandLineTools { return .installCommandLineTools }
        guard f.brewPath != nil else { return .installHomebrew }
        let packages = f.missingFormulae + (f.hasNode ? [] : ["node"])
        if !packages.isEmpty { return .brewInstall(packages) }
        if f.dockerFixable { return .fixDockerConfig }
        if !f.dockerOK { return .needsAttention(.dockerPlugins) }
        if !f.projectValid { return .chooseProject }
        if f.appLocation == .elsewhere { return .moveToApplications }
        if !f.vexaSetUp { return .runSetup }
        if !f.coreServicesUp { return .startServices }
        if !f.desktopHostUp || !f.extensionBuilt { return .startDesktopHost }
        if !f.chromeInstalled { return .installChrome }
        if !f.extensionDone { return .loadExtension }
        return nil
    }

    // MARK: Row text

    private static func describe(_ item: SetupItem, _ f: SetupFacts) -> (SetupState, String) {
        switch item {
        case .commandLineTools:
            return f.commandLineTools
                ? (.ok, "Installed. They include git.")
                : (.missing, "Apple's Command Line Tools give you git. macOS shows its own installer.")

        case .homebrew:
            if let brew = f.brewPath { return (.ok, "Found at \(brew).") }
            return (.missing, "Homebrew installs the other tools. It asks for your password, so you install it in Terminal.")

        case .formulae:
            let missing = f.missingFormulae
            if missing.isEmpty { return (.ok, "All installed: \(SetupFacts.formulae.joined(separator: ", ")).") }
            return (.missing, "Missing: \(missing.joined(separator: ", ")).")

        case .node:
            if let path = f.nodePath {
                let version = f.nodeVersion.map { "Node \(clean($0))" } ?? "Node"
                return (.ok, "\(version) at \(path).")
            }
            let found = f.newestNodeFound.map { " Found only Node \(clean($0))." } ?? " No Node found."
            return (.missing, "The browser extension's host needs Node 20 or newer.\(found)")

        case .dockerPlugins:
            if !f.dockerConfig.readable {
                return (.missing, "~/.docker/config.json isn't valid JSON. Fix it by hand, then check again.")
            }
            if f.dockerCredsBroken {
                return (.missing, "Docker's settings still use Docker Desktop's login helper, which isn't installed. Image downloads would fail.")
            }
            if f.dockerOK { return (.ok, "docker compose and docker buildx work.") }
            if f.dockerNeedsPluginDir {
                return (.missing, "Docker can't find compose and buildx. Its settings need Homebrew's plugin folder.")
            }
            if !f.missingFormulae.isEmpty { return (.missing, "Install the Homebrew tools first.") }
            let broken = [f.dockerComposeWorks ? nil : "docker compose", f.dockerBuildxWorks ? nil : "docker buildx"]
                .compactMap { $0 }.joined(separator: " and ")
            return (.missing, "\(broken) doesn't work. Try reinstalling docker-compose and docker-buildx.")

        case .project:
            if f.projectValid { return (.ok, f.projectPath) }
            return (.missing, "The app runs scripts from your vexa-local-mac folder. Choose it, or download it.")

        case .appInstalled:
            switch f.appLocation {
            case .installed: return (.ok, "Running from \(f.appBundlePath).")
            case .elsewhere:
                return (.missing, "Running from \(f.appBundlePath). Move it to Applications so it's easy to find and keeps working.")
            case .notABundle:
                return (.info, "Running outside an app bundle (a development build). Use make install to put the app in Applications.")
            }

        case .vexaSetup:
            if f.vexaSetUp { return (.ok, "Vexa and its settings (.env) are in place.") }
            if !f.projectValid { return (.missing, "Choose the project folder first.") }
            return (.missing, "Not set up yet. Setup downloads Vexa, a Whisper model and Docker images: about 10-20 GB. It takes 20-40 minutes the first time.")

        case .services:
            let parts: [(String, Bool)] = [("Colima", f.colimaRunning), ("Whisper", f.whisperUp),
                                           ("Vexa", f.gatewayUp), ("extension host", f.desktopHostUp)]
            let up = parts.filter(\.1).map(\.0), down = parts.filter { !$0.1 }.map(\.0)
            if down.isEmpty { return (.ok, "Running: \(up.joined(separator: ", ")).") }
            let text = (up.isEmpty ? "" : "Running: \(up.joined(separator: ", ")). ")
                + "Not running: \(down.joined(separator: ", "))."
            return (f.coreServicesUp ? .warning : .missing, text)

        case .chrome:
            return f.chromeInstalled
                ? (.ok, "Installed.")
                : (.warning, "Needed only for the browser extension. The Teams bot and the Record page work without it.")

        case .browserExtension:
            if !f.extensionBuilt {
                return (.warning, f.vexaSetUp
                        ? "Not built yet. Starting the extension host builds it."
                        : "Built during setup.")
            }
            if f.extensionDone { return (.ok, "Built and loaded in Chrome.") }
            return (.warning, "Built. Load it in Chrome once, paste your API key into it, then tick Done.")

        case .permissions:
            let ok = f.microphone == .allowed && f.screenRecording == .allowed
            let text = "Microphone: \(words(f.microphone)). Screen & System Audio Recording: \(words(f.screenRecording))."
                + (ok ? "" : " macOS asks the first time you record.")
            return (ok ? .ok : .info, text)
        }
    }

    private static func words(_ p: PermissionStatus) -> String {
        switch p {
        case .allowed: return "allowed"
        case .notAsked: return "not allowed yet"
        case .denied: return "turned off"
        }
    }

    private static func clean(_ version: String) -> String {
        let v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.hasPrefix("v") ? String(v.dropFirst()) : v
    }
}

/// How a "Set up everything" run ended.
public enum SetupRunOutcome: Equatable, Sendable {
    case finished
    /// Stopped at a step the user has to do.
    case needsUser(SetupAction)
    /// The step failed (non-zero exit, error).
    case failed(SetupAction)
    /// The step ran, but the check still asks for it.
    case stuck(SetupAction)
}

public enum SetupSequence {
    /// Runs the automatic steps in order, checking again after each one. Stops at the
    /// first step that needs the user, the first failure, or a step that didn't help.
    @MainActor
    public static func run(maxSteps: Int = 12,
                           check: () async -> SetupFacts,
                           perform: (SetupAction) async -> Bool) async -> SetupRunOutcome {
        var done: [SetupAction] = []
        for _ in 0..<maxSteps {
            let facts = await check()
            guard let action = SetupPlanner.nextAction(facts) else { return .finished }
            if action.needsUser { return .needsUser(action) }
            if done.contains(action) { return .stuck(action) }
            done.append(action)
            if !(await perform(action)) { return .failed(action) }
        }
        let facts = await check()
        return SetupPlanner.nextAction(facts).map { .stuck($0) } ?? .finished
    }
}
