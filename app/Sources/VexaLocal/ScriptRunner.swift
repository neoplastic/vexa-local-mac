import Foundation
import Observation

/// Runs the project's shell scripts (start/stop/whisper) and setup commands, and captures their output.
@MainActor @Observable
final class ScriptRunner {
    var title = ""
    var log = ""
    var isRunning = false
    var lastExitCode: Int32?

    /// GUI apps start with a bare PATH; add the usual Homebrew and uv locations.
    static var shellEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        return env
    }

    @discardableResult
    func run(_ title: String, script: URL, arguments: [String] = [], in directory: URL) async -> Int32 {
        await launch(title, executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path] + arguments,
                     name: script.lastPathComponent, in: directory)
    }

    /// Runs a command found on the app's PATH (e.g. `brew install …`, `git clone …`).
    @discardableResult
    func run(_ title: String, command: [String], in directory: URL) async -> Int32 {
        await launch(title, executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: command,
                     name: command.first ?? "command", in: directory)
    }

    private func launch(_ title: String, executable: URL, arguments: [String], name: String,
                        in directory: URL) async -> Int32 {
        guard !isRunning else { return -1 }
        self.title = title
        log = ""
        isRunning = true
        lastExitCode = nil

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = Self.shellEnvironment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            Task { @MainActor in self.log += clean }
        }

        let code: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in self.log += "Could not run \(name): \(error.localizedDescription)\n" }
                cont.resume(returning: -1)
            }
        }
        // Collect anything still buffered after exit.
        if let rest = try? pipe.fileHandleForReading.readToEnd(), let text = String(data: rest, encoding: .utf8) {
            log += text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        isRunning = false
        lastExitCode = code
        return code
    }
}
