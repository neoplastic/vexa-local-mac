import XCTest

/// Syntax-checks every script with `bash -n`. Never executes them.
final class ShellScriptTests: XCTestCase {
    func testAllScriptsParse() throws {
        let scripts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts")
        let files = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
            .filter { $0.hasSuffix(".sh") }.sorted()
        XCTAssertFalse(files.isEmpty, "no scripts found at \(scripts.path)")
        for f in files {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", scripts.appendingPathComponent(f).path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(p.terminationStatus, 0, "\(f): \(msg)")
        }
    }
}
