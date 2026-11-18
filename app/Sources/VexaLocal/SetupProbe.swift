import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import VexaCore

/// Everything the setup assistant reads from the Mac. Tests swap in a fake.
struct SystemProbe: Sendable {
    var home: String
    /// The PATH the app's scripts get (ScriptRunner.shellEnvironment), used for `command -v`.
    var path: String
    /// Runs a short command found on `path`, with a time limit.
    var run: @Sendable (_ arguments: [String], _ timeout: TimeInterval) async -> CommandResult
    var fileExists: @Sendable (String) -> Bool
    /// An executable file (not a folder).
    var isExecutable: @Sendable (String) -> Bool
    /// A regular file's contents; nil for folders and missing files.
    var readFile: @Sendable (String) -> Data?
    var listDirectory: @Sendable (String) -> [String]
    var appInstalled: @Sendable (_ bundleID: String) -> Bool
    var microphone: @Sendable () -> PermissionStatus
    var screenRecording: @Sendable () -> PermissionStatus

    @MainActor
    static func live() -> SystemProbe {
        let env = ScriptRunner.shellEnvironment
        return SystemProbe(
            home: NSHomeDirectory(),
            path: env["PATH"] ?? "",
            run: { args, timeout in await Command.run(args, environment: env, timeout: timeout) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutable: { path in
                var dir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
                    && FileManager.default.isExecutableFile(atPath: path)
            },
            readFile: { path in
                var dir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue else { return nil }
                return FileManager.default.contents(atPath: path)
            },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            microphone: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .allowed
                case .notDetermined: return .notAsked
                default: return .denied
                }
            },
            // Preflight never shows a prompt. It can't tell "not asked" from "turned off".
            screenRecording: { CGPreflightScreenCaptureAccess() ? .allowed : .notAsked })
    }
}

/// Reads the machine's state into `SetupFacts`. Only read-only commands.
enum SetupProber {
    static let brewLocations = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let chromeBundleID = "com.google.Chrome"

    /// Files, folders and commands. Services, Chrome, permissions and the "Done" tick are
    /// filled in by SetupStore on the main thread.
    static func gather(projectPath: String, colimaProfile: String, probe: SystemProbe) async -> SetupFacts {
        var f = SetupFacts()
        let brew = brewPath(probe)
        f.brewPath = brew
        let prefix = brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
            ?? "/opt/homebrew"
        f.dockerPluginDir = prefix + "/lib/docker/cli-plugins"

        let hasDocker = PathLookup.find("docker", in: probe.path, isExecutable: probe.isExecutable) != nil
        let hasColima = PathLookup.find("colima", in: probe.path, isExecutable: probe.isExecutable) != nil
        async let clt = probe.run(["xcode-select", "-p"], 10)
        async let formulae = installedFormulae(brew: brew, probe: probe)
        async let node = findNode(probe)
        async let compose = hasDocker ? probe.run(["docker", "compose", "version"], 15).ok : false
        async let buildx = hasDocker ? probe.run(["docker", "buildx", "version"], 15).ok : false
        async let colima = hasColima ? probe.run(["colima", "status", "--profile", colimaProfile], 10).ok : false

        f.dockerConfig = DockerConfigFile.status(probe.readFile("\(probe.home)/.docker/config.json"),
                                                 pluginDir: f.dockerPluginDir)
        f.homebrewPluginsPresent = ["docker-compose", "docker-buildx"]
            .contains { probe.isExecutable("\(f.dockerPluginDir)/\($0)") }
        f.credentialHelperInstalled = PathLookup.find("docker-credential-desktop", in: probe.path,
                                                      isExecutable: probe.isExecutable) != nil

        f.projectPath = projectPath
        f.projectValid = probe.fileExists("\(projectPath)/scripts/start.sh")
        f.envExists = probe.fileExists("\(projectPath)/.env")
        f.vexaFolderExists = probe.fileExists("\(projectPath)/vexa")
        f.extensionBuilt = probe.fileExists("\(projectPath)/vexa/clients/extension/dist/manifest.json")

        f.commandLineTools = await clt.ok
        f.installedFormulae = await formulae
        let n = await node
        f.nodePath = n.path
        f.nodeVersion = n.version
        f.newestNodeFound = n.newest
        f.dockerComposeWorks = await compose
        f.dockerBuildxWorks = await buildx
        f.colimaRunning = await colima
        return f
    }

    static func brewPath(_ probe: SystemProbe) -> String? {
        brewLocations.first(where: probe.isExecutable)
    }

    static func installedFormulae(brew: String?, probe: SystemProbe) async -> Set<String> {
        guard let brew else { return [] }
        let result = await probe.run([brew, "list", "--formula", "-1"], 30)
        guard result.ok else { return [] }
        return Set(result.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Same search as `use_modern_node` in scripts/lib.sh; NodeSelection decides.
    static func findNode(_ probe: SystemProbe) async -> (path: String?, version: String?, newest: String?) {
        let home = probe.home
        let current = PathLookup.find("node", in: probe.path, isExecutable: probe.isExecutable)
        let alias = NodeSelection.nvmDefaultAlias { name in
            probe.readFile("\(home)/.nvm/alias/\(name)")
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { $0.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "" }
        }
        let nvmVersions = probe.listDirectory("\(home)/.nvm/versions/node")
        let defaultVersion = alias.flatMap { NodeSelection.nvmVersion(matching: $0, installed: nvmVersions) }
        let candidates = NodeSelection.candidates(
            currentNode: current, home: home, nvmDefaultVersion: defaultVersion, nvmVersions: nvmVersions,
            fnmVersions: probe.listDirectory("\(home)/.local/share/fnm/node-versions"))

        var versions: [String: String] = [:]
        for path in candidates where versions[path] == nil && probe.isExecutable(path) {
            let r = await probe.run([path, "--version"], 10)
            if r.ok { versions[path] = r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            // Stop at the first good one, like the script.
            if let chosen = NodeSelection.choose(candidates: candidates, versions: versions) {
                return (chosen, versions[chosen], versions[chosen])
            }
        }
        let newest = versions.values.max(by: NodeSelection.versionLess)
        return (nil, nil, newest)
    }
}

/// Repairs ~/.docker/config.json after making a backup next to it.
enum DockerConfigWriter {
    /// Returns the backup file, or nil when there was no file to back up.
    @discardableResult
    static func apply(at url: URL, addPluginDir: String?, removeDesktopCredsStore: Bool,
                      now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let existing = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        let data = try DockerConfigFile.fixed(existing, addPluginDir: addPluginDir,
                                              removeDesktopCredsStore: removeDesktopCredsStore)
        var backup: URL?
        var permissions: Any?
        if existing != nil {
            let b = target.deletingLastPathComponent().appendingPathComponent(DockerConfigFile.backupName(for: now))
            try fm.copyItem(at: target, to: b)
            backup = b
            permissions = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: target, options: .atomic)
        try? fm.setAttributes([.posixPermissions: permissions ?? NSNumber(value: 0o600)], ofItemAtPath: target.path)
        return backup
    }
}
