import XCTest
import VexaCore
@testable import VexaLocal

/// A pretend Mac: files, executables and command results. Nothing real is run.
final class FakeMac: @unchecked Sendable {
    let home = "/Users/me"
    var files: [String: String] = [:]
    var executables: Set<String> = []
    var folders: [String: [String]] = [:]
    var commands: [String: CommandResult] = [:]
    var apps: Set<String> = []
    private(set) var ran: [[String]] = []
    private let lock = NSLock()

    func ok(_ output: String = "") -> CommandResult { CommandResult(status: 0, output: output, error: "", timedOut: false) }
    func fail(_ error: String = "nope") -> CommandResult { CommandResult(status: 1, output: "", error: error, timedOut: false) }

    private func record(_ args: [String]) -> CommandResult {
        lock.withLock {
            ran.append(args)
            return commands[args.joined(separator: " ")]
                ?? CommandResult(status: 127, output: "", error: "not found", timedOut: false)
        }
    }

    var probe: SystemProbe {
        SystemProbe(
            home: home,
            path: "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            run: { args, _ in self.record(args) },
            fileExists: { self.files[$0] != nil || self.executables.contains($0) || self.folders[$0] != nil },
            isExecutable: { self.executables.contains($0) },
            readFile: { self.files[$0].map { Data($0.utf8) } },
            listDirectory: { self.folders[$0] ?? [] },
            appInstalled: { self.apps.contains($0) },
            microphone: { .allowed },
            screenRecording: { .notAsked })
    }

    /// Like this Mac: everything installed, Node 16 first on PATH, nvm default → v22.23.4,
    /// plugins linked into ~/.docker/cli-plugins (so the config has no plugin folder).
    static func readyLikeThisMac(project: String = "/p") -> FakeMac {
        let m = FakeMac()
        m.executables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/opt/homebrew/bin/docker",
                         "/opt/homebrew/bin/colima", "/usr/local/bin/node",
                         "/opt/homebrew/lib/docker/cli-plugins/docker-compose",
                         "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"]
        for v in ["v22.22.2", "v22.23.4", "v24.11.0"] {
            m.executables.insert("/Users/me/.nvm/versions/node/\(v)/bin/node")
            m.commands["/Users/me/.nvm/versions/node/\(v)/bin/node --version"] = m.ok("\(v)\n")
        }
        m.folders["/Users/me/.nvm/versions/node"] = ["v22.22.2", "v22.23.4", "v24.11.0"]
        m.files["/Users/me/.nvm/alias/default"] = "lts/jod\n"
        m.files["/Users/me/.nvm/alias/lts/jod"] = "v22.23.4\n"
        m.files["/Users/me/.docker/config.json"] = #"{"auths": {}, "currentContext": "colima"}"#
        m.commands["/usr/local/bin/node --version"] = m.ok("v16.18.0\n")
        m.commands["xcode-select -p"] = m.ok("/Applications/Xcode.app/Contents/Developer\n")
        m.commands["/opt/homebrew/bin/brew list --formula -1"] =
            m.ok((SetupFacts.formulae + ["git", "python@3.13"]).joined(separator: "\n") + "\n")
        m.commands["docker compose version"] = m.ok("Docker Compose version 2.40.1\n")
        m.commands["docker buildx version"] = m.ok("github.com/docker/buildx v0.35.0 Homebrew\n")
        m.commands["colima status --profile default"] = m.ok()
        m.files["\(project)/scripts/start.sh"] = ""
        m.files["\(project)/.env"] = "A=1"
        m.folders["\(project)/vexa"] = []
        m.files["\(project)/vexa/clients/extension/dist/manifest.json"] = "{}"
        m.apps = [SetupProber.chromeBundleID]
        return m
    }
}

final class SetupProberTests: XCTestCase {
    func testGatherOnAReadyMac() async {
        let mac = FakeMac.readyLikeThisMac()
        let f = await SetupProber.gather(projectPath: "/p", colimaProfile: "default", probe: mac.probe)
        XCTAssertTrue(f.commandLineTools)
        XCTAssertEqual(f.brewPath, "/opt/homebrew/bin/brew")
        XCTAssertEqual(f.missingFormulae, [])
        XCTAssertEqual(f.nodePath, "/Users/me/.nvm/versions/node/v22.23.4/bin/node")
        XCTAssertEqual(f.nodeVersion, "v22.23.4")
        XCTAssertTrue(f.dockerComposeWorks)
        XCTAssertTrue(f.dockerBuildxWorks)
        XCTAssertEqual(f.dockerPluginDir, "/opt/homebrew/lib/docker/cli-plugins")
        XCTAssertTrue(f.homebrewPluginsPresent)
        XCTAssertFalse(f.dockerConfig.hasPluginDir)
        XCTAssertFalse(f.dockerNeedsPluginDir, "plugins already work, so the config is left alone")
        XCTAssertTrue(f.dockerOK)
        XCTAssertTrue(f.projectValid)
        XCTAssertTrue(f.vexaSetUp)
        XCTAssertTrue(f.extensionBuilt)
        XCTAssertTrue(f.colimaRunning)
        for item: SetupItem in [.commandLineTools, .homebrew, .formulae, .node, .dockerPlugins, .project, .vexaSetup] {
            XCTAssertEqual(SetupPlanner.row(item, f).state, .ok, "\(item)")
        }
        // Node probing stops at the first good one, like the script.
        XCTAssertFalse(mac.ran.contains(["/Users/me/.nvm/versions/node/v24.11.0/bin/node", "--version"]))
    }

    func testGatherOnABareMac() async {
        let mac = FakeMac()
        mac.commands["xcode-select -p"] = mac.fail("unable to get active developer directory")
        let f = await SetupProber.gather(projectPath: "/nowhere", colimaProfile: "default", probe: mac.probe)
        XCTAssertFalse(f.commandLineTools)
        XCTAssertNil(f.brewPath)
        XCTAssertEqual(f.missingFormulae, SetupFacts.formulae)
        XCTAssertNil(f.nodePath)
        XCTAssertNil(f.newestNodeFound)
        XCTAssertFalse(f.dockerComposeWorks)
        XCTAssertFalse(f.colimaRunning)
        XCTAssertFalse(f.projectValid)
        // No docker or colima on PATH: they aren't even run.
        XCTAssertFalse(mac.ran.contains { $0.first == "docker" || $0.first == "colima" })
        XCTAssertEqual(SetupPlanner.nextAction(f), .installCommandLineTools)
    }

    func testOnlyOldNodeIsReported() async {
        let mac = FakeMac()
        mac.executables = ["/usr/local/bin/node"]
        mac.commands["/usr/local/bin/node --version"] = mac.ok("v16.18.0\n")
        let node = await SetupProber.findNode(mac.probe)
        XCTAssertNil(node.path)
        XCTAssertEqual(node.newest, "v16.18.0")
    }

    func testBrokenDockerConfigIsSpotted() async {
        let mac = FakeMac.readyLikeThisMac()
        mac.commands["docker compose version"] = mac.fail("docker: 'compose' is not a docker command.")
        mac.files["/Users/me/.docker/config.json"] = #"{"credsStore": "desktop"}"#
        let f = await SetupProber.gather(projectPath: "/p", colimaProfile: "default", probe: mac.probe)
        XCTAssertTrue(f.dockerNeedsPluginDir)
        XCTAssertTrue(f.dockerCredsBroken)
        XCTAssertEqual(SetupPlanner.nextAction(f), .fixDockerConfig)
    }

    func testColimaProfileIsUsed() async {
        let mac = FakeMac.readyLikeThisMac()
        let f = await SetupProber.gather(projectPath: "/p", colimaProfile: "work", probe: mac.probe)
        XCTAssertFalse(f.colimaRunning)
        XCTAssertTrue(mac.ran.contains(["colima", "status", "--profile", "work"]))
    }

    func testIntelHomebrewPrefix() async {
        let mac = FakeMac()
        mac.executables = ["/usr/local/bin/brew"]
        let f = await SetupProber.gather(projectPath: "/p", colimaProfile: "default", probe: mac.probe)
        XCTAssertEqual(f.brewPath, "/usr/local/bin/brew")
        XCTAssertEqual(f.dockerPluginDir, "/usr/local/lib/docker/cli-plugins")
    }
}

final class DockerConfigWriterTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testBacksUpAndFixes() throws {
        let file = dir.appendingPathComponent("config.json")
        let original = #"{"auths": {"x": {}}, "credsStore": "desktop", "currentContext": "colima"}"#
        try Data(original.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

        let backup = try DockerConfigWriter.apply(at: file, addPluginDir: "/opt/homebrew/lib/docker/cli-plugins",
                                                  removeDesktopCredsStore: true,
                                                  now: Date(timeIntervalSince1970: 0))
        let b = try XCTUnwrap(backup)
        XCTAssertTrue(b.lastPathComponent.hasPrefix("config.json.bak-"))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), original)

        let fixed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(fixed["credsStore"])
        XCTAssertEqual(fixed["currentContext"] as? String, "colima")
        XCTAssertNotNil(fixed["auths"])
        XCTAssertEqual(fixed["cliPluginsExtraDirs"] as? [String], ["/opt/homebrew/lib/docker/cli-plugins"])
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o640)
    }

    func testCreatesMissingFile() throws {
        let file = dir.appendingPathComponent("sub/config.json")
        let backup = try DockerConfigWriter.apply(at: file, addPluginDir: "/d", removeDesktopCredsStore: false)
        XCTAssertNil(backup)
        let fixed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(fixed["cliPluginsExtraDirs"] as? [String], ["/d"])
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testLeavesInvalidFileAlone() throws {
        let file = dir.appendingPathComponent("config.json")
        try Data("{broken".utf8).write(to: file)
        XCTAssertThrowsError(try DockerConfigWriter.apply(at: file, addPluginDir: "/d", removeDesktopCredsStore: true))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["config.json"], "no backup made")
    }

    func testFollowsSymlink() throws {
        let real = dir.appendingPathComponent("dotfiles-config.json")
        try Data("{}".utf8).write(to: real)
        let link = dir.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try DockerConfigWriter.apply(at: link, addPluginDir: "/d", removeDesktopCredsStore: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("/d"))
    }
}

final class AppMoverTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func fakeApp(at url: URL, version: String) throws {
        let macos = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data(version.utf8).write(to: macos.appendingPathComponent("VexaLocal"))
    }

    func testCopiesAndReplacesOlderCopy() async throws {
        let source = dir.appendingPathComponent("build/Vexa Local.app")
        let apps = dir.appendingPathComponent("Applications")
        let dest = apps.appendingPathComponent("Vexa Local.app")
        try fakeApp(at: source, version: "new")
        try fakeApp(at: dest, version: "old")
        try Data("stale".utf8).write(to: dest.appendingPathComponent("Contents/stale.txt"))

        try await AppMover.copy(from: source, to: dest)

        let binary = dest.appendingPathComponent("Contents/MacOS/VexaLocal")
        XCTAssertEqual(try String(contentsOf: binary, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/stale.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Vexa Local.app"], "no temp copy left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays")
    }

    func testFailedCopyLeavesOldCopy() async throws {
        let apps = dir.appendingPathComponent("Applications")
        let dest = apps.appendingPathComponent("Vexa Local.app")
        try fakeApp(at: dest, version: "old")
        do {
            try await AppMover.copy(from: dir.appendingPathComponent("missing.app"), to: dest)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not copy"))
        }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("Contents/MacOS/VexaLocal"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Vexa Local.app"])
    }
}

@MainActor
final class SetupStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("scripts/start.sh"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRefreshFillsFactsAndSavesAValidProjectPath() async {
        let mac = FakeMac.readyLikeThisMac(project: dir.path)
        let defaults = TestDefaults()
        let app = AppModel(defaults: defaults)
        app.projectPath = dir.path
        defaults.removeObject(forKey: "vexa.projectPath")   // as if it was only guessed
        let store = SetupStore(defaults: defaults, probe: mac.probe, bundlePath: "/Applications/Vexa Local.app")

        let f = await store.refresh(app)
        XCTAssertEqual(store.facts, f)
        XCTAssertFalse(store.isChecking)
        XCTAssertTrue(f.chromeInstalled)
        XCTAssertEqual(f.microphone, .allowed)
        XCTAssertEqual(f.screenRecording, .notAsked)
        XCTAssertEqual(f.appLocation, .installed)
        XCTAssertEqual(store.missingInstallSteps, [])
        XCTAssertEqual(defaults.string(forKey: "vexa.projectPath"), dir.path)
    }

    func testOpensAtLaunchFirstTimeAndWhenSomethingIsMissing() async {
        let mac = FakeMac.readyLikeThisMac(project: dir.path)
        let defaults = TestDefaults()
        let app = AppModel(defaults: defaults)
        app.projectPath = dir.path
        let store = SetupStore(defaults: defaults, probe: mac.probe, bundlePath: "/Applications/Vexa Local.app")
        await store.refresh(app)
        XCTAssertTrue(store.shouldOpenAtLaunch, "first launch")
        store.markSeen()
        XCTAssertFalse(store.shouldOpenAtLaunch)

        let moved = SetupStore(defaults: defaults, probe: mac.probe, bundlePath: dir.path + "/build/Vexa Local.app")
        await moved.refresh(app)
        XCTAssertEqual(moved.missingInstallSteps, [.appInstalled])
        XCTAssertTrue(moved.shouldOpenAtLaunch)
    }

    func testExtensionDonePersists() {
        let defaults = TestDefaults()
        let store = SetupStore(defaults: defaults, probe: FakeMac().probe)
        XCTAssertFalse(store.extensionDone)
        store.extensionDone = true
        XCTAssertTrue(SetupStore(defaults: defaults, probe: FakeMac().probe).extensionDone)
    }
}

@MainActor
final class ScriptRunnerCommandTests: XCTestCase {
    func testRunsACommandFromPath() async {
        let runner = ScriptRunner()
        let dir = FileManager.default.temporaryDirectory
        let code = await runner.run("Echo", command: ["echo", "hello", "world"], in: dir)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(runner.title, "Echo")
        XCTAssertTrue(runner.log.contains("hello world"))
    }

    func testMissingCommandFails() async {
        let runner = ScriptRunner()
        let code = await runner.run("Nope", command: ["vexa-no-such-command-\(UUID().uuidString)"],
                                    in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(code, 127)
        XCTAssertFalse(runner.isRunning)
    }
}
