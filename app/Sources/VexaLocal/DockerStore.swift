import Foundation
import Observation
import VexaCore

/// Result of a short command run by `Command.run`.
struct CommandResult: Sendable {
    var status: Int32
    var output: String
    var error: String
    var timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
    /// Last non-empty line of stderr (or stdout), for error messages.
    var message: String {
        let text = error.isEmpty ? output : error
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
    }
}

/// Runs short commands (docker, colima, cleanup.sh --referenced) with a hard time limit.
/// Output goes to temporary files, so a large output or a lingering child process
/// can never block the caller.
enum Command {
    static func run(_ arguments: [String], environment: [String: String], directory: URL? = nil,
                    timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent("vexa-cmd-\(UUID().uuidString)")
            let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
            let once = Once()

            @Sendable func finish(status: Int32, timedOut: Bool, failure: String? = nil) {
                guard once.claim() else { return }
                let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                let err = failure ?? (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
                cont.resume(returning: CommandResult(status: status, output: out, error: err, timedOut: timedOut))
            }

            guard let outHandle = try? FileHandle(forWritingTo: outURL),
                  let errHandle = try? FileHandle(forWritingTo: errURL) else {
                finish(status: -1, timedOut: false, failure: "Could not create a temporary file")
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = directory }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outHandle
            process.standardError = errHandle
            process.terminationHandler = { proc in
                try? outHandle.close(); try? errHandle.close()
                finish(status: proc.terminationStatus, timedOut: false)
            }
            do {
                try process.run()
            } catch {
                try? outHandle.close(); try? errHandle.close()
                finish(status: -1, timedOut: false, failure: "Could not run \(arguments.first ?? "command"): \(error.localizedDescription)")
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(status: -1, timedOut: true, failure: "\(arguments.prefix(3).joined(separator: " ")) took longer than \(Int(timeout)) s")
            }
        }
    }
}

/// Lets exactly one of several racing callbacks win.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// How the app reaches Colima's Docker, whatever `docker context` is set to
/// (the same default scripts/lib.sh uses).
enum DockerCLI {
    @MainActor
    static func environment(colimaProfile: String) -> [String: String] {
        var env = ScriptRunner.shellEnvironment
        if env["DOCKER_HOST"]?.isEmpty ?? true {
            env["DOCKER_HOST"] = "unix://\(NSHomeDirectory())/.colima/\(colimaProfile)/docker.sock"
        }
        return env
    }

    /// False when DOCKER_HOST is a unix socket that doesn't exist (Colima never started).
    static func socketExists(in environment: [String: String]) -> Bool {
        guard let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") else { return true }
        return FileManager.default.fileExists(atPath: String(host.dropFirst("unix://".count)))
    }

    static func docker(_ args: [String], _ env: [String: String], timeout: TimeInterval = 20) async -> CommandResult {
        await Command.run(["docker"] + args, environment: env, timeout: timeout)
    }
}

/// Loads what Vexa stores in Docker for the Storage page.
@MainActor @Observable
final class DockerStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case dockerDown(String)
        case failed(String)
    }

    var phase: Phase = .idle
    var report: VexaStorageReport?
    var vmDisk: VMDisk?
    var referencesError: String?
    var updatedAt: Date?

    var isLoading: Bool { phase == .loading }

    func refresh(projectURL: URL, colimaProfile: String) async {
        guard phase != .loading else { return }
        phase = .loading
        let env = DockerCLI.environment(colimaProfile: colimaProfile)

        // Colima's disk is worth showing even when Docker itself is down.
        async let vm = loadVMDisk(profile: colimaProfile, env: env)

        guard DockerCLI.socketExists(in: env) else {
            vmDisk = await vm
            report = nil
            phase = .dockerDown("Colima isn't running, so Docker can't be reached.")
            return
        }
        let info = await DockerCLI.docker(["info", "--format", "{{.ServerVersion}}"], env, timeout: 8)
        guard info.ok else {
            vmDisk = await vm
            report = nil
            phase = .dockerDown(info.timedOut ? "Docker didn't answer in time." : info.message)
            return
        }

        async let df = DockerCLI.docker(["system", "df", "-v", "--format", "{{json .}}"], env, timeout: 90)
        async let ids = DockerCLI.docker(["ps", "-aq"], env, timeout: 15)
        async let refs = loadReferences(projectURL: projectURL, env: env)

        let idList = await ids.output.split(whereSeparator: \.isWhitespace).map(String.init)
        var containers: [DockerContainer] = []
        if !idList.isEmpty {
            let inspect = await DockerCLI.docker(["inspect", "--format", DockerParse.containerFormat] + idList,
                                                 env, timeout: 20)
            // A container removed in between makes inspect fail but still print the rest.
            containers = DockerParse.containers(inspect.output)
        }
        let usageResult = await df
        let (referenced, refError) = await refs
        vmDisk = await vm
        referencesError = refError

        guard usageResult.ok else {
            phase = .failed(usageResult.message)
            return
        }
        do {
            let usage = try DockerParse.diskUsage(usageResult.output)
            report = VexaStorageReport(usage: usage, containers: containers, referenced: referenced)
            updatedAt = Date()
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Images the current setup uses, from `scripts/cleanup.sh --referenced`.
    private nonisolated func loadReferences(projectURL: URL, env: [String: String]) async -> (Set<String>?, String?) {
        let script = projectURL.appendingPathComponent("scripts/cleanup.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return (nil, "scripts/cleanup.sh not found in the project folder.")
        }
        let result = await Command.run(["bash", script.path, "--referenced"], environment: env,
                                       directory: projectURL, timeout: 30)
        let refs = DockerParse.references(result.output)
        guard result.ok, !refs.isEmpty else { return (nil, result.message) }
        return (refs, nil)
    }

    private nonisolated func loadVMDisk(profile: String, env: [String: String]) async -> VMDisk? {
        let list = await Command.run(["colima", "list", "--json"], environment: env, timeout: 10)
        guard list.ok, let total = DockerParse.colimaDisk(list.output, profile: profile) else { return nil }
        var disk = VMDisk(total: total)
        let df = await Command.run(["colima", "ssh", "--profile", profile, "--", "df", "-k", "/var/lib/docker"],
                                   environment: env, timeout: 10)
        if df.ok, let usage = DockerParse.dfKilobytes(df.output) {
            disk.used = usage.used
            disk.available = usage.available
        }
        return disk
    }
}
