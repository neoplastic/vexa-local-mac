import AppKit
import Foundation
import Observation
import VexaCore

/// A bot we sent into a meeting, and where its transcript is being written.
struct Session: Identifiable, Codable, Equatable {
    var id = UUID()
    var platform: MeetingPlatform
    var meetingId: String
    var startedAt: Date
    var filePath: String
    var status: String = "requested"
    var segmentCount: Int = 0
    var lastError: String?
    var finished = false
}

enum ServiceState: Equatable {
    case unknown, down, up
}

@MainActor @Observable
final class AppModel {
    // MARK: Settings (persisted)
    var projectPath: String { didSet { save("projectPath", projectPath); reloadEnv() } }
    var outputDirectory: String { didSet { save("outputDirectory", outputDirectory) } }
    var apiKey: String { didSet { save("apiKey", apiKey) } }
    var apiUserEmail: String { didSet { save("apiUserEmail", apiUserEmail) } }
    var botName: String { didSet { save("botName", botName) } }
    var language: String { didSet { save("language", language) } }

    // MARK: Live state
    var env: [String: String] = [:]
    var whisperState: ServiceState = .unknown
    var whisperLoadedModel: String?
    var vexaState: ServiceState = .unknown
    var sessions: [Session] = [] { didSet { saveSessions() } }
    var showLog = false

    let runner = ScriptRunner()
    let models = ModelStore()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        projectPath = d.string(forKey: Self.key("projectPath")) ?? AppModel.guessProjectPath()
        outputDirectory = d.string(forKey: Self.key("outputDirectory"))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Vexa Transcripts").path
        apiKey = d.string(forKey: Self.key("apiKey")) ?? ""
        apiUserEmail = d.string(forKey: Self.key("apiUserEmail")) ?? "me@example.com"
        botName = d.string(forKey: Self.key("botName")) ?? "Vexa Notetaker"
        language = d.string(forKey: Self.key("language")) ?? "auto"
        if let data = d.data(forKey: Self.key("sessions")), let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved
        }
        reloadEnv()
    }

    // MARK: Paths and URLs

    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    var envURL: URL { projectURL.appendingPathComponent(".env") }
    var projectLooksValid: Bool {
        FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("scripts/start.sh").path)
    }
    var whisperPython: URL { projectURL.appendingPathComponent("whisper-server/.venv/bin/python") }
    func script(_ name: String) -> URL { projectURL.appendingPathComponent("scripts/\(name)") }

    private func port(_ key: String, _ fallback: String) -> String { env[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
    var gatewayURL: URL { URL(string: "http://localhost:\(port("API_GATEWAY_HOST_PORT", "8056"))")! }
    var adminURL: URL { URL(string: "http://localhost:\(port("ADMIN_API_HOST_PORT", "8057"))")! }
    var dashboardURL: URL { URL(string: "http://localhost:\(port("DASHBOARD_HOST_PORT", "3001"))")! }
    var whisperURL: URL { URL(string: "http://127.0.0.1:\(port("WHISPER_PORT", "8083"))")! }
    var configuredModel: String { env["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo" }

    var client: VexaClient {
        VexaClient(gateway: gatewayURL, admin: adminURL, apiKey: apiKey, adminToken: env["ADMIN_API_TOKEN"] ?? "")
    }

    /// Default: the folder this app was built in (…/vexa-local-mac/app/build/X.app).
    static func guessProjectPath() -> String {
        var dir = Bundle.main.bundleURL
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/start.sh").path) { return dir.path }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Projects/vexa-local-mac").path
    }

    func reloadEnv() { env = EnvFile.read(envURL) }

    // MARK: Stack control

    func startStack() async {
        showLog = true
        await runner.run("Starting Vexa", script: script("start.sh"), in: projectURL)
        await refreshStatus()
    }

    func stopStack() async {
        showLog = true
        await runner.run("Stopping Vexa", script: script("stop.sh"), in: projectURL)
        await refreshStatus()
    }

    /// Points the Whisper server at a different model and restarts it if running.
    func useModel(_ id: String) async {
        do {
            try EnvFile.set("WHISPER_MODEL", to: id, at: envURL)
        } catch {
            runner.log = "Could not update .env: \(error.localizedDescription)"
            showLog = true
            return
        }
        reloadEnv()
        if whisperState == .up {
            showLog = true
            await runner.run("Switching Whisper to \(id)", script: script("whisper.sh"), arguments: ["restart"], in: projectURL)
            models.cacheVersion += 1
            await refreshStatus()
        }
    }

    // MARK: Status polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 2 == 0 { await self.refreshStatus() }
                await self.pollSessions()
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshStatus() async {
        struct Health: Decodable { var status: String; var model: String? }
        var req = URLRequest(url: whisperURL.appendingPathComponent("health"), timeoutInterval: 2)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let health = try? JSONDecoder().decode(Health.self, from: data) {
            whisperState = health.status == "ok" ? .up : .down
            whisperLoadedModel = health.model
        } else {
            whisperState = .down
            whisperLoadedModel = nil
        }
        let docs = URLRequest(url: gatewayURL.appendingPathComponent("docs"), timeoutInterval: 2)
        if let (_, resp) = try? await URLSession.shared.data(for: docs), (resp as? HTTPURLResponse)?.statusCode == 200 {
            vexaState = .up
        } else {
            vexaState = .down
        }
    }

    // MARK: API key

    func generateAPIKey() async throws {
        reloadEnv()
        guard let token = env["ADMIN_API_TOKEN"], !token.isEmpty else {
            throw APIError(status: 0, message: "No ADMIN_API_TOKEN in \(envURL.path). Check the project folder in Settings.")
        }
        apiKey = try await client.createAPIKey(email: apiUserEmail)
    }

    // MARK: Joining meetings

    func join(_ meeting: ParsedMeeting, passcode: String, teamsHost: String?) async throws -> Session {
        if apiKey.isEmpty { try await generateAPIKey() }

        var host = meeting.teamsBaseHost
        if meeting.needsTeamsHost, let teamsHost, teamsHost != "teams.live.com" { host = teamsHost }
        let pass = passcode.trimmingCharacters(in: .whitespaces)
        if meeting.platform == .teams, !pass.isEmpty, !MeetingParser.isValidTeamsPasscode(pass) {
            throw APIError(status: 0, message: "Teams passcodes are 4-20 letters or digits.")
        }

        let request = VexaClient.BotRequest(
            platform: meeting.platform.rawValue,
            native_meeting_id: meeting.nativeMeetingId,
            bot_name: botName.isEmpty ? nil : botName,
            language: language == "auto" || language.isEmpty ? nil : language,
            passcode: meeting.platform == .teams && !pass.isEmpty ? pass : nil,
            meeting_url: meeting.meetingURL,
            teams_base_host: host)
        let created = try await client.createBot(request)

        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let startedAt = Date()
        let file = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(TranscriptFormatter.fileName(platform: meeting.platform,
                                                                 meetingId: meeting.nativeMeetingId,
                                                                 startedAt: startedAt))
        let session = Session(platform: meeting.platform, meetingId: meeting.nativeMeetingId,
                              startedAt: startedAt, filePath: file.path, status: created.status)
        sessions.insert(session, at: 0)
        writeTranscript(for: session, segments: [])
        return session
    }

    func stopBot(_ session: Session) async {
        do {
            try await client.stopBot(platform: session.platform, meetingId: session.meetingId)
            update(session.id) { $0.status = "stopping" }
        } catch {
            update(session.id) { $0.lastError = error.localizedDescription }
        }
    }

    func removeSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: Transcript files

    private func pollSessions() async {
        guard !apiKey.isEmpty else { return }
        for session in sessions where !session.finished {
            do {
                let t = try await client.transcript(platform: session.platform, meetingId: session.meetingId)
                let status = t.status ?? session.status
                update(session.id) {
                    $0.status = status
                    $0.segmentCount = t.segments.count
                    $0.lastError = nil
                    $0.finished = TranscriptFormatter.terminalStatuses.contains(status)
                }
                if let updated = sessions.first(where: { $0.id == session.id }) {
                    writeTranscript(for: updated, segments: t.segments)
                }
            } catch let error as APIError where error.status == 404 {
                // Meeting row not created yet; keep waiting.
                continue
            } catch {
                update(session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func writeTranscript(for session: Session, segments: [TranscriptSegment]) {
        let header = TranscriptFormatter.Header(platform: session.platform, meetingId: session.meetingId,
                                                startedAt: session.startedAt, status: session.status,
                                                model: whisperLoadedModel ?? configuredModel)
        let text = TranscriptFormatter.markdown(header: header, segments: segments)
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: session.filePath), options: .atomic)
        } catch {
            update(session.id) { $0.lastError = "Could not write transcript: \(error.localizedDescription)" }
        }
    }

    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[i]
        change(&s)
        if s != sessions[i] { sessions[i] = s }
    }

    // MARK: Persistence

    /// Prefixed so keys never collide with system-wide defaults.
    private static func key(_ name: String) -> String { "vexa.\(name)" }
    private func save(_ key: String, _ value: String) { defaults.set(value, forKey: Self.key(key)) }
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) { defaults.set(data, forKey: Self.key("sessions")) }
    }
}
