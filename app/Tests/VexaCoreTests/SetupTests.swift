import XCTest
@testable import VexaCore

final class NodeSelectionTests: XCTestCase {
    let home = "/Users/me"

    /// default → lts/jod → v22.23.4, like this Mac's nvm.
    func testFollowsNvmAliasChain() {
        let files = ["default": "lts/jod\n", "lts/jod": "v22.23.4"]
        XCTAssertEqual(NodeSelection.nvmDefaultAlias { files[$0] }, "v22.23.4")
    }

    func testNoDefaultAlias() {
        XCTAssertNil(NodeSelection.nvmDefaultAlias { _ in nil })
    }

    func testEmptyDefaultAliasIsIgnored() {
        XCTAssertNil(NodeSelection.nvmDefaultAlias { $0 == "default" ? "" : nil })
    }

    func testAliasLoopStopsAfterFourHops() {
        let files = ["default": "a", "a": "b", "b": "a"]
        // default → a → b → a → b: stops, returns whatever it reached.
        XCTAssertEqual(NodeSelection.nvmDefaultAlias { files[$0] }, "b")
    }

    func testAliasPointingBackToDefaultIsIgnored() {
        XCTAssertNil(NodeSelection.nvmDefaultAlias { $0 == "default" ? "default" : nil })
    }

    func testAliasThatIsNotAFileStopsTheChain() {
        // "lts/*" has no file: the chain stops at it.
        XCTAssertEqual(NodeSelection.nvmDefaultAlias { $0 == "default" ? "lts/*" : nil }, "lts/*")
    }

    func testNvmVersionMatchingPicksHighest() {
        let installed = ["v22.9.0", "v22.10.1", "v20.1.0", "v24.11.0"]
        XCTAssertEqual(NodeSelection.nvmVersion(matching: "22", installed: installed), "v22.10.1")
        XCTAssertEqual(NodeSelection.nvmVersion(matching: "v22.9.0", installed: installed), "v22.9.0")
        XCTAssertEqual(NodeSelection.nvmVersion(matching: "v24", installed: installed), "v24.11.0")
        XCTAssertNil(NodeSelection.nvmVersion(matching: "lts/*", installed: installed))
        XCTAssertNil(NodeSelection.nvmVersion(matching: "18", installed: installed))
    }

    func testCandidateOrderMatchesScript() {
        let list = NodeSelection.candidates(currentNode: "/usr/local/bin/node", home: home,
                                            nvmDefaultVersion: "v22.23.4",
                                            nvmVersions: ["v22.22.2", "v24.11.0", "v22.23.4"],
                                            fnmVersions: ["v20.11.0"])
        XCTAssertEqual(list, [
            "/usr/local/bin/node",
            "/Users/me/.nvm/versions/node/v22.23.4/bin/node",
            "/opt/homebrew/bin/node",
            "/Users/me/.volta/bin/node",
            "/Users/me/.nvm/versions/node/v24.11.0/bin/node",
            "/Users/me/.nvm/versions/node/v22.23.4/bin/node",
            "/Users/me/.nvm/versions/node/v22.22.2/bin/node",
            "/Users/me/.local/share/fnm/node-versions/v20.11.0/installation/bin/node",
        ])
    }

    func testCandidatesWithoutCurrentOrDefault() {
        let list = NodeSelection.candidates(currentNode: nil, home: home, nvmDefaultVersion: nil,
                                            nvmVersions: [], fnmVersions: [])
        XCTAssertEqual(list, ["/opt/homebrew/bin/node", "/Users/me/.volta/bin/node"])
    }

    /// This Mac: an old Node 16 first on PATH, nvm default → v22.23.4 (what lib.sh picks).
    func testSkipsOldCurrentNodeAndUsesNvmDefault() {
        let candidates = NodeSelection.candidates(currentNode: "/usr/local/bin/node", home: home,
                                                  nvmDefaultVersion: "v22.23.4",
                                                  nvmVersions: ["v22.22.2", "v22.23.4", "v24.11.0"], fnmVersions: [])
        let versions = [
            "/usr/local/bin/node": "v16.18.0",
            "/Users/me/.nvm/versions/node/v22.23.4/bin/node": "v22.23.4",
            "/Users/me/.nvm/versions/node/v24.11.0/bin/node": "v24.11.0",
            "/Users/me/.nvm/versions/node/v22.22.2/bin/node": "v22.22.2",
        ]
        XCTAssertEqual(NodeSelection.choose(candidates: candidates, versions: versions),
                       "/Users/me/.nvm/versions/node/v22.23.4/bin/node")
    }

    func testPrefersCurrentNodeWhenNewEnough() {
        let c = ["/opt/homebrew/bin/node", "/x/node"]
        XCTAssertEqual(NodeSelection.choose(candidates: c, versions: ["/opt/homebrew/bin/node": "v20.0.0", "/x/node": "v24.0.0"]),
                       "/opt/homebrew/bin/node")
    }

    func testNoSuitableNode() {
        XCTAssertNil(NodeSelection.choose(candidates: ["/a", "/b"], versions: ["/a": "v18.20.0", "/b": "garbage"]))
        XCTAssertNil(NodeSelection.choose(candidates: [], versions: [:]))
    }

    func testMajor() {
        XCTAssertEqual(NodeSelection.major("v22.23.4"), 22)
        XCTAssertEqual(NodeSelection.major("20.1.0\n"), 20)
        XCTAssertEqual(NodeSelection.major("18"), 18)
        XCTAssertNil(NodeSelection.major(""))
        XCTAssertNil(NodeSelection.major("node"))
    }

    func testVersionOrdering() {
        XCTAssertTrue(NodeSelection.versionLess("v9.0.0", "v10.0.0"))
        XCTAssertTrue(NodeSelection.versionLess("v22.9.0", "v22.10.0"))
        XCTAssertFalse(NodeSelection.versionLess("v22.10.0", "v22.9.0"))
        XCTAssertFalse(NodeSelection.versionLess("v1", "v1"))
        XCTAssertTrue(NodeSelection.versionLess("v1", "v1.0"))
    }

    func testPathLookup() {
        let exec: Set<String> = ["/usr/local/bin/node", "/usr/bin/git"]
        XCTAssertEqual(PathLookup.find("node", in: "/opt/homebrew/bin:/usr/local/bin:/usr/bin", isExecutable: exec.contains),
                       "/usr/local/bin/node")
        XCTAssertEqual(PathLookup.find("git", in: "/usr/bin/::/bin", isExecutable: exec.contains), "/usr/bin/git")
        XCTAssertNil(PathLookup.find("brew", in: "/usr/bin", isExecutable: exec.contains))
    }
}

final class DockerConfigFileTests: XCTestCase {
    let dir = DockerConfigFile.homebrewPluginDir

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStatusOfMissingAndEmptyFile() {
        XCTAssertEqual(DockerConfigFile.status(nil), .init(readable: true, hasPluginDir: false, desktopCredsStore: false))
        XCTAssertEqual(DockerConfigFile.status(Data(" \n".utf8)).readable, true)
    }

    func testStatusOfThisMachinesConfig() {
        let data = Data(#"{"auths": {}, "currentContext": "colima"}"#.utf8)
        XCTAssertEqual(DockerConfigFile.status(data), .init(readable: true, hasPluginDir: false, desktopCredsStore: false))
    }

    func testStatusFindsPluginDirAndDesktopCreds() {
        let data = Data(#"{"credsStore":"desktop","cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins/"]}"#.utf8)
        XCTAssertEqual(DockerConfigFile.status(data), .init(readable: true, hasPluginDir: true, desktopCredsStore: true))
    }

    func testStatusOfInvalidJSON() {
        XCTAssertFalse(DockerConfigFile.status(Data("{nope".utf8)).readable)
        XCTAssertFalse(DockerConfigFile.status(Data("[1,2]".utf8)).readable)
    }

    func testFixAddsPluginDirAndKeepsEverythingElse() throws {
        let data = Data(#"{"auths":{"ghcr.io":{"auth":"abc"}},"currentContext":"colima","experimental":true,"cliPluginsExtraDirs":["/other"]}"#.utf8)
        let out = try json(DockerConfigFile.fixed(data, addPluginDir: dir, removeDesktopCredsStore: true))
        XCTAssertEqual(out["cliPluginsExtraDirs"] as? [String], ["/other", dir])
        XCTAssertEqual(out["currentContext"] as? String, "colima")
        XCTAssertEqual(out["experimental"] as? Bool, true)
        XCTAssertEqual((out["auths"] as? [String: [String: String]])?["ghcr.io"]?["auth"], "abc")
    }

    func testFixDoesNotDuplicatePluginDir() throws {
        let data = Data(#"{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}"#.utf8)
        let out = try json(DockerConfigFile.fixed(data, addPluginDir: dir, removeDesktopCredsStore: false))
        XCTAssertEqual(out["cliPluginsExtraDirs"] as? [String], [dir])
    }

    func testFixRemovesOnlyDesktopCredsStore() throws {
        let desktop = Data(#"{"credsStore":"desktop","auths":{}}"#.utf8)
        let out = try json(DockerConfigFile.fixed(desktop, addPluginDir: nil, removeDesktopCredsStore: true))
        XCTAssertNil(out["credsStore"])
        XCTAssertNotNil(out["auths"])
        XCTAssertNil(out["cliPluginsExtraDirs"])

        let keychain = Data(#"{"credsStore":"osxkeychain"}"#.utf8)
        let kept = try json(DockerConfigFile.fixed(keychain, addPluginDir: nil, removeDesktopCredsStore: true))
        XCTAssertEqual(kept["credsStore"] as? String, "osxkeychain")
    }

    func testFixOfMissingFileCreatesOne() throws {
        let out = try DockerConfigFile.fixed(nil, addPluginDir: dir, removeDesktopCredsStore: false)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains(#""/opt/homebrew/lib/docker/cli-plugins""#), "slashes not escaped: \(text)")
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(try json(out)["cliPluginsExtraDirs"] as? [String], [dir])
    }

    func testFixRefusesInvalidFiles() {
        XCTAssertThrowsError(try DockerConfigFile.fixed(Data("{oops".utf8), addPluginDir: dir, removeDesktopCredsStore: true)) {
            XCTAssertEqual($0 as? DockerConfigFile.FixError, .notAnObject)
        }
        XCTAssertThrowsError(try DockerConfigFile.fixed(Data(#"{"cliPluginsExtraDirs":"/x"}"#.utf8),
                                                        addPluginDir: dir, removeDesktopCredsStore: false)) {
            XCTAssertEqual($0 as? DockerConfigFile.FixError, .unexpectedPluginDirs)
        }
    }

    func testBackupName() {
        let date = Date(timeIntervalSince1970: 1_794_000_000)   // 2026-11-06 21:20:00 UTC
        XCTAssertEqual(DockerConfigFile.backupName(for: date, timeZone: TimeZone(identifier: "UTC")!),
                       "config.json.bak-20261106-212000")
    }
}

final class SetupPlannerTests: XCTestCase {
    /// A Mac with everything installed, set up and running.
    private func ready() -> SetupFacts {
        var f = SetupFacts()
        f.commandLineTools = true
        f.brewPath = "/opt/homebrew/bin/brew"
        f.installedFormulae = Set(SetupFacts.formulae + ["git", "node"])
        f.nodePath = "/opt/homebrew/bin/node"
        f.nodeVersion = "v24.1.0"
        f.dockerComposeWorks = true
        f.dockerBuildxWorks = true
        f.projectPath = "/p"
        f.projectValid = true
        f.appBundlePath = "/Applications/Vexa Local.app"
        f.envExists = true
        f.vexaFolderExists = true
        f.colimaRunning = true
        f.whisperUp = true
        f.gatewayUp = true
        f.desktopHostUp = true
        f.chromeInstalled = true
        f.extensionBuilt = true
        f.extensionDone = true
        f.microphone = .allowed
        f.screenRecording = .allowed
        return f
    }

    func testEverythingDone() {
        let f = ready()
        XCTAssertNil(SetupPlanner.nextAction(f))
        XCTAssertTrue(SetupPlanner.rows(f).allSatisfy { $0.state == .ok }, "\(SetupPlanner.rows(f).filter { $0.state != .ok })")
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f), [])
    }

    func testRowsAreInDependencyOrder() {
        let order = SetupPlanner.rows(SetupFacts()).map(\.item)
        XCTAssertEqual(order, SetupItem.allCases)
        for (i, item) in order.enumerated() {
            for dep in item.dependencies {
                XCTAssertLessThan(order.firstIndex(of: dep)!, i, "\(item) depends on a later row \(dep)")
            }
        }
    }

    func testKinds() {
        XCTAssertEqual(SetupItem.allCases.filter { $0.kind == .optional }, [.chrome, .browserExtension])
        XCTAssertEqual(SetupItem.allCases.filter { $0.kind == .info }, [.permissions])
        XCTAssertFalse(SetupItem.services.isInstallStep)
        XCTAssertTrue(SetupItem.appInstalled.isInstallStep)
    }

    func testFreshMacStartsWithCommandLineTools() {
        let f = SetupFacts()
        XCTAssertEqual(SetupPlanner.nextAction(f), .installCommandLineTools)
        XCTAssertTrue(SetupPlanner.nextAction(f)!.needsUser)
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f),
                       [.commandLineTools, .homebrew, .formulae, .node, .dockerPlugins, .project, .vexaSetup])
    }

    func testWalksTheStepsInOrder() {
        var f = SetupFacts()
        f.appBundlePath = "/Users/me/vexa-local-mac/app/build/Vexa Local.app"
        f.commandLineTools = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .installHomebrew)
        f.brewPath = "/opt/homebrew/bin/brew"
        f.installedFormulae = ["docker", "uv"]
        XCTAssertEqual(SetupPlanner.nextAction(f),
                       .brewInstall(["colima", "docker-compose", "docker-buildx", "ffmpeg", "pnpm", "node"]))
        f.installedFormulae = Set(SetupFacts.formulae)
        XCTAssertEqual(SetupPlanner.nextAction(f), .brewInstall(["node"]))
        XCTAssertEqual(SetupPlanner.nextAction(f)?.item, .node)
        f.nodePath = "/n"
        f.homebrewPluginsPresent = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .fixDockerConfig)
        f.dockerConfig.hasPluginDir = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .needsAttention(.dockerPlugins))
        f.dockerComposeWorks = true
        f.dockerBuildxWorks = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .chooseProject)
        f.projectValid = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .moveToApplications)
        f.appBundlePath = "/Applications/Vexa Local.app"
        XCTAssertEqual(SetupPlanner.nextAction(f), .runSetup)
        f.envExists = true
        f.vexaFolderExists = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .startServices)
        f.colimaRunning = true; f.whisperUp = true; f.gatewayUp = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .startDesktopHost)
        f.desktopHostUp = true; f.extensionBuilt = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .installChrome)
        f.chromeInstalled = true
        XCTAssertEqual(SetupPlanner.nextAction(f), .loadExtension)
        f.extensionDone = true
        XCTAssertNil(SetupPlanner.nextAction(f))
    }

    func testOnlyAutomaticStepsDontNeedTheUser() {
        let auto: [SetupAction] = [.brewInstall(["x"]), .fixDockerConfig, .runSetup, .startServices, .startDesktopHost]
        XCTAssertTrue(auto.allSatisfy { !$0.needsUser })
        let manual: [SetupAction] = [.installCommandLineTools, .installHomebrew, .chooseProject, .moveToApplications,
                                     .installChrome, .loadExtension, .needsAttention(.dockerPlugins)]
        XCTAssertTrue(manual.allSatisfy(\.needsUser))
        XCTAssertTrue(manual.allSatisfy { !$0.prompt.isEmpty })
    }

    func testOptionalRowsAreWarningsNotMissing() {
        var f = ready()
        f.chromeInstalled = false
        f.extensionBuilt = false
        f.extensionDone = false
        f.microphone = .notAsked
        XCTAssertEqual(SetupPlanner.row(.chrome, f).state, .warning)
        XCTAssertEqual(SetupPlanner.row(.browserExtension, f).state, .warning)
        XCTAssertEqual(SetupPlanner.row(.permissions, f).state, .info)
        XCTAssertTrue(SetupPlanner.row(.permissions, f).detail.contains("macOS asks the first time you record"))
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f), [])
    }

    func testServicesStoppedAreNotAnInstallStep() {
        var f = ready()
        f.colimaRunning = false; f.whisperUp = false; f.gatewayUp = false; f.desktopHostUp = false
        let row = SetupPlanner.row(.services, f)
        XCTAssertEqual(row.state, .missing)
        XCTAssertEqual(row.detail, "Not running: Colima, Whisper, Vexa, extension host.")
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f), [])
        XCTAssertEqual(SetupPlanner.nextAction(f), .startServices)
    }

    func testOnlyHostDownIsAWarning() {
        var f = ready()
        f.desktopHostUp = false
        let row = SetupPlanner.row(.services, f)
        XCTAssertEqual(row.state, .warning)
        XCTAssertEqual(row.detail, "Running: Colima, Whisper, Vexa. Not running: extension host.")
        XCTAssertEqual(SetupPlanner.nextAction(f), .startDesktopHost)
    }

    func testDockerRows() {
        var f = ready()
        // Plugins found another way (linked into ~/.docker/cli-plugins): nothing to fix.
        f.homebrewPluginsPresent = true
        XCTAssertFalse(f.dockerNeedsPluginDir)
        XCTAssertEqual(SetupPlanner.row(.dockerPlugins, f).state, .ok)

        f.dockerComposeWorks = false
        XCTAssertTrue(f.dockerNeedsPluginDir)
        XCTAssertTrue(f.dockerFixable)
        XCTAssertTrue(SetupPlanner.row(.dockerPlugins, f).detail.contains("plugin folder"))

        f = ready()
        f.dockerConfig.desktopCredsStore = true
        XCTAssertEqual(SetupPlanner.row(.dockerPlugins, f).state, .missing)
        XCTAssertEqual(SetupPlanner.nextAction(f), .fixDockerConfig)
        f.credentialHelperInstalled = true
        XCTAssertEqual(SetupPlanner.row(.dockerPlugins, f).state, .ok)

        f = ready()
        f.dockerConfig = .init(readable: false)
        f.dockerComposeWorks = false
        f.homebrewPluginsPresent = true
        XCTAssertFalse(f.dockerFixable)
        XCTAssertEqual(SetupPlanner.nextAction(f), .needsAttention(.dockerPlugins))
        XCTAssertTrue(SetupPlanner.row(.dockerPlugins, f).detail.contains("isn't valid JSON"))
    }

    func testNodeRowMentionsOldVersion() {
        var f = ready()
        f.nodePath = nil
        f.nodeVersion = nil
        f.newestNodeFound = "v16.18.0"
        XCTAssertEqual(SetupPlanner.row(.node, f).detail, "The browser extension's host needs Node 20 or newer. Found only Node 16.18.0.")
        f = ready()
        f.nodePath = "/Users/me/.nvm/versions/node/v22.23.4/bin/node"
        f.nodeVersion = "v22.23.4"
        XCTAssertEqual(SetupPlanner.row(.node, f).detail, "Node 22.23.4 at /Users/me/.nvm/versions/node/v22.23.4/bin/node.")
    }

    func testAppLocation() {
        XCTAssertEqual(AppLocation(bundlePath: "/Applications/Vexa Local.app"), .installed)
        XCTAssertEqual(AppLocation(bundlePath: "/Applications/Vexa Local.app/"), .installed)
        XCTAssertEqual(AppLocation(bundlePath: "/Users/me/vexa-local-mac/app/build/Vexa Local.app"), .elsewhere)
        XCTAssertEqual(AppLocation(bundlePath: "/Users/me/Applications/Vexa Local.app"), .elsewhere)
        XCTAssertEqual(AppLocation(bundlePath: "/Users/me/vexa-local-mac/app/.build/debug"), .notABundle)

        var f = ready()
        f.appBundlePath = "/x/.build/debug"
        XCTAssertEqual(SetupPlanner.row(.appInstalled, f).state, .info)
        XCTAssertNil(SetupPlanner.nextAction(f))
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f), [])
        f.appBundlePath = "/x/build/Vexa Local.app"
        XCTAssertEqual(SetupPlanner.row(.appInstalled, f).state, .missing)
        XCTAssertEqual(SetupPlanner.missingInstallSteps(f), [.appInstalled])
    }

    func testUnmetDependencies() {
        var f = ready()
        f.installedFormulae = []
        XCTAssertEqual(SetupPlanner.unmetDependencies(.dockerPlugins, f), [.formulae])
        XCTAssertEqual(SetupPlanner.unmetDependencies(.vexaSetup, f), [.formulae])
        XCTAssertEqual(SetupPlanner.unmetDependencies(.homebrew, f), [])
        f.brewPath = nil
        XCTAssertEqual(SetupPlanner.unmetDependencies(.node, f), [.homebrew])
    }

    func testVexaSetUpNeedsEnvAndFolder() {
        var f = ready()
        f.envExists = false
        XCTAssertFalse(f.vexaSetUp)
        XCTAssertTrue(SetupPlanner.row(.vexaSetup, f).detail.contains("20-40 minutes"))
        f = ready()
        f.vexaFolderExists = false
        XCTAssertEqual(SetupPlanner.nextAction(f), .runSetup)
    }
}

@MainActor
final class SetupSequenceTests: XCTestCase {
    private func installedEverything() -> SetupFacts {
        var f = SetupFacts()
        f.commandLineTools = true
        f.brewPath = "/b"
        f.nodePath = "/n"
        f.dockerComposeWorks = true
        f.dockerBuildxWorks = true
        f.projectValid = true
        f.appBundlePath = "/Applications/Vexa Local.app"
        f.chromeInstalled = true
        f.extensionDone = true
        return f
    }

    func testRunsAutomaticStepsInOrderUntilDone() async {
        var f = installedEverything()
        var ran: [SetupAction] = []
        let outcome = await SetupSequence.run(check: { f }, perform: { action in
            ran.append(action)
            switch action {
            case .brewInstall: f.installedFormulae = Set(SetupFacts.formulae)
            case .runSetup: f.envExists = true; f.vexaFolderExists = true
            case .startServices: f.colimaRunning = true; f.whisperUp = true; f.gatewayUp = true
            case .startDesktopHost: f.desktopHostUp = true; f.extensionBuilt = true
            default: break
            }
            return true
        })
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(ran, [.brewInstall(SetupFacts.formulae), .runSetup, .startServices, .startDesktopHost])
    }

    func testStopsAtHomebrew() async {
        var f = installedEverything()
        f.brewPath = nil
        var ran = 0
        let outcome = await SetupSequence.run(check: { f }, perform: { _ in ran += 1; return true })
        XCTAssertEqual(outcome, .needsUser(.installHomebrew))
        XCTAssertEqual(ran, 0)
    }

    func testStopsAtFirstFailure() async {
        var f = installedEverything()
        f.installedFormulae = Set(SetupFacts.formulae)
        var ran: [SetupAction] = []
        let outcome = await SetupSequence.run(check: { f }, perform: { ran.append($0); return false })
        XCTAssertEqual(outcome, .failed(.runSetup))
        XCTAssertEqual(ran, [.runSetup])
    }

    func testStopsWhenAStepDoesNotHelp() async {
        var f = installedEverything()
        f.installedFormulae = Set(SetupFacts.formulae)
        f.envExists = true
        f.vexaFolderExists = true
        var ran = 0
        // "Succeeds" but nothing starts.
        let outcome = await SetupSequence.run(check: { f }, perform: { _ in ran += 1; return true })
        XCTAssertEqual(outcome, .stuck(.startServices))
        XCTAssertEqual(ran, 1)
    }

    func testStopsAtChromeAfterRequiredSteps() async {
        var f = installedEverything()
        f.installedFormulae = Set(SetupFacts.formulae)
        f.envExists = true; f.vexaFolderExists = true
        f.colimaRunning = true; f.whisperUp = true; f.gatewayUp = true; f.desktopHostUp = true; f.extensionBuilt = true
        f.chromeInstalled = false
        let outcome = await SetupSequence.run(check: { f }, perform: { _ in true })
        XCTAssertEqual(outcome, .needsUser(.installChrome))
    }
}
