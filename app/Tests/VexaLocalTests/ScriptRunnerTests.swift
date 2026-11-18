import XCTest
@testable import VexaLocal

@MainActor
final class ScriptRunnerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func script(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("t.sh")
        try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: url)
        return url
    }

    func testCapturesStdoutAndStderrAndExitCode() async throws {
        let s = try script("echo out; echo err >&2; exit 3")
        let runner = ScriptRunner()
        let code = await runner.run("Test", script: s, in: dir)
        XCTAssertEqual(code, 3)
        XCTAssertEqual(runner.lastExitCode, 3)
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.title, "Test")
        XCTAssertTrue(runner.log.contains("out"))
        XCTAssertTrue(runner.log.contains("err"))
    }

    func testPassesArgumentsAndWorkingDirectory() async throws {
        let s = try script(#"echo "arg=$1 $2"; pwd -P"#)
        let runner = ScriptRunner()
        let code = await runner.run("Args", script: s, arguments: ["a", "b"], in: dir)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(runner.log.contains("arg=a b"))
        XCTAssertTrue(runner.log.contains(dir.resolvingSymlinksInPath().path))
    }

    func testStripsANSIColours() async throws {
        let s = try script(#"printf '\033[1;32mgreen\033[0m plain\n'"#)
        let runner = ScriptRunner()
        await runner.run("Colour", script: s, in: dir)
        XCTAssertTrue(runner.log.contains("green plain"))
        XCTAssertFalse(runner.log.contains("\u{1B}"))
    }

    func testRefusesSecondConcurrentRun() async throws {
        let slow = try script("sleep 0.6; echo done")
        let runner = ScriptRunner()
        let first = Task { await runner.run("Slow", script: slow, in: dir) }
        while !runner.isRunning { await Task.yield() }
        let second = await runner.run("Other", script: slow, in: dir)
        XCTAssertEqual(second, -1)
        XCTAssertEqual(runner.title, "Slow", "refused run must not clobber state")
        let firstCode = await first.value
        XCTAssertEqual(firstCode, 0)
        XCTAssertTrue(runner.log.contains("done"))
    }

    func testCanRunAgainAfterFinish() async throws {
        let s = try script("echo hi")
        let runner = ScriptRunner()
        await runner.run("One", script: s, in: dir)
        let code = await runner.run("Two", script: s, in: dir)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(runner.title, "Two")
    }

    func testShellEnvironmentPathHasHomebrew() {
        let path = ScriptRunner.shellEnvironment["PATH"] ?? ""
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}
