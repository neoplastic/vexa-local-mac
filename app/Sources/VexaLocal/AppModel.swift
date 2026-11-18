import AppKit
import Foundation
import Observation
import VexaCore

/// A meeting transcript being tracked: a bot we sent, or a meeting captured by the browser extension.
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
    var source: TranscriptSource = .bot
    /// Plain-words reason a bot failed, once the gateway has told us.
    var failureReason: String?
}

extension Session {
    /// Sessions saved by older versions have no `source` or `failureReason`.
    init(from decoder: Decoder) throws {
        enum K: String, CodingKey {
            case id, platform, meetingId, startedAt, filePath, status, segmentCount, lastError, finished
            case source, failureReason
        }
        let c = try decoder.container(keyedBy: K.self)
        self.init(platform: try c.decode(MeetingPlatform.self, forKey: .platform),
                  meetingId: try c.decode(String.self, forKey: .meetingId),
                  startedAt: try c.decode(Date.self, forKey: .startedAt),
                  filePath: try c.decode(String.self, forKey: .filePath))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "requested"
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        source = try c.decodeIfPresent(TranscriptSource.self, forKey: .source) ?? .bot
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
    }
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
    /// The desktop host that receives the browser extension's audio (scripts/desktop.sh).
    var desktopHostState: ServiceState = .unknown
    var sessions: [Session] = [] { didSet { saveSessions() } }
    var showLog = false
    /// The setup assistant sheet.
    var showSetup = false

    let runner = ScriptRunner()
    let models = ModelStore()
    /// The setup assistant's checks and actions.
    let setup = SetupStore()
    /// Stops Vexa when the app quits (see QuitController).
    let quit = QuitController()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Extension meetings the user removed from the list (see ExtensionSync.dismissalKey).
    @ObservationIgnored private var dismissedExtension: Set<String> = []
    @ObservationIgnored private var desktopTask: Task<Void, Never>?
    /// How many times this run we asked the gateway why a bot failed (per session).
    @ObservationIgnored private var failureLookups: [UUID: Int] = [:]

    init(defaults d: UserDefaults = .standard) {
        defaults = d
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
        dismissedExtension = Set(d.stringArray(forKey: Self.key("dismissedExtension")) ?? [])
        reloadEnv()
    }

    // MARK: Paths and URLs

    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    var envURL: URL { projectURL.appendingPathComponent(".env") }
    var projectLooksValid: Bool {
        FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("scripts/start.sh").path)
    }
    var whisperPython: URL { projectURL.appendingPathComponent("whisper-server/.venv/bin/python") }
    var desktopHostURL: URL { URL(string: "http://localhost:\(DesktopHostClient.defaultPort)")! }
    /// Where the Vexa Chrome extension is built (Chrome: Load unpacked).
    var extensionFolderURL: URL { projectURL.appendingPathComponent("vexa/clients/extension/dist") }
    var extensionFolderExists: Bool {
        FileManager.default.fileExists(atPath: extensionFolderURL.appendingPathComponent("manifest.json").path)
    }
    func script(_ name: String) -> URL { projectURL.appendingPathComponent("scripts/\(name)") }

    private func port(_ key: String, _ fallback: String) -> String { env[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
    var gatewayURL: URL { URL(string: "http://localhost:\(port("API_GATEWAY_HOST_PORT", "18056"))")! }
    var adminURL: URL { URL(string: "http://localhost:\(port("ADMIN_API_PORT", "18057"))")! }
    var webAppURL: URL { URL(string: "http://localhost:\(port("TERMINAL_PORT", "13000"))")! }
    var whisperURL: URL { URL(string: "http://127.0.0.1:\(port("WHISPER_PORT", "8083"))")! }
    var configuredModel: String { env["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo" }
    var colimaProfile: String { port("COLIMA_PROFILE", "default") }

    /// True while the Whisper server started by scripts/whisper.sh is alive (.run/whisper.pid).
    var whisperPidAlive: Bool {
        let file = projectURL.appendingPathComponent(".run/whisper.pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    var client: VexaClient {
        VexaClient(gateway: gatewayURL, admin: adminURL, apiKey: apiKey, adminToken: env["ADMIN_TOKEN"] ?? "")
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

    /// Saves the project folder even when it was only guessed (didSet only saves changes),
    /// so a copy of the app in /Applications, which isn't inside the project, still finds it.
    func saveProjectPath() {
        if defaults.string(forKey: Self.key("projectPath")) != projectPath { save("projectPath", projectPath) }
    }

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
                if tick % 2 == 0 {
                    await self.refreshStatus()
                    if self.vexaState == .up { await self.adoptRunningBots() }
                }
                await self.pollSessions()
                await self.fillFailureReasons()
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
        startDesktopPolling()
    }

    /// Polls the desktop host every 5 seconds. A host that is not running is skipped quietly.
    func startDesktopPolling() {
        guard desktopTask == nil else { return }
        desktopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncExtensionTranscripts(using: DesktopHostClient(baseURL: self.desktopHostURL))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Checks the desktop host right now (used by the Join page).
    func refreshDesktopHost() async {
        desktopHostState = await DesktopHostClient(baseURL: desktopHostURL).isUp() ? .up : .down
    }

    func startDesktopHost() async {
        showLog = true
        await runner.run("Starting the browser extension host", script: script("desktop.sh"),
                         arguments: ["start"], in: projectURL)
        await refreshDesktopHost()
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
        let docs = URLRequest(url: gatewayURL.appendingPathComponent("health"), timeoutInterval: 2)
        if let (_, resp) = try? await URLSession.shared.data(for: docs), (resp as? HTTPURLResponse)?.statusCode == 200 {
            vexaState = .up
        } else {
            vexaState = .down
        }
    }

    // MARK: API key

    func generateAPIKey() async throws {
        reloadEnv()
        guard let token = env["ADMIN_TOKEN"], !token.isEmpty else {
            throw APIError(status: 0, message: "No ADMIN_TOKEN in \(envURL.path). Check the project folder in Settings.")
        }
        apiKey = try await client.createAPIKey(email: apiUserEmail)
    }

    // MARK: Joining meetings

    func join(_ meeting: ParsedMeeting, passcode: String, teamsHost: String?) async throws -> Session {
        if apiKey.isEmpty { try await generateAPIKey() }

        let isTeams = meeting.platform == .teams
        var host = isTeams ? meeting.teamsBaseHost : nil
        if isTeams, meeting.needsTeamsHost, let teamsHost, teamsHost != "teams.live.com" { host = teamsHost }
        let typed = passcode.trimmingCharacters(in: .whitespaces)
        if isTeams, !typed.isEmpty, !MeetingParser.isValidTeamsPasscode(typed) {
            throw APIError(status: 0, message: "Teams passcodes are 4-20 letters or digits.")
        }
        // Teams: the passcode field (pre-filled from the link). Zoom: the link's pwd=, else
        // whatever was typed; the bot types it into Zoom's passcode screen. Meet: none.
        let pass: String
        switch meeting.platform {
        case .teams: pass = typed
        case .zoom: pass = meeting.passcode ?? typed
        case .googleMeet: pass = ""
        }

        let request = VexaClient.BotRequest(
            platform: meeting.platform.rawValue,
            native_meeting_id: meeting.nativeMeetingId,
            bot_name: botName.isEmpty ? nil : botName,
            language: language == "auto" || language.isEmpty ? nil : language,
            passcode: pass.isEmpty ? nil : pass,
            meeting_url: meeting.meetingURL,
            teams_base_host: host)
        let status: String
        do {
            do {
                status = try await client.createBot(request).status
            } catch let error as APIError where error.status == 401 || error.status == 403 {
                // Stale key (e.g. after reinstalling Vexa): mint a new one and retry once.
                try await generateAPIKey()
                status = try await client.createBot(request).status
            }
        } catch let error as APIError where error.status == 0 || error.status >= 500 {
            // A slow container start can time out upstream even though the bot
            // launched. If Vexa now lists it, track it instead of reporting failure.
            await adoptRunningBots()
            if let existing = sessions.first(where: {
                $0.source == .bot && !$0.finished && $0.platform == meeting.platform && $0.meetingId == meeting.nativeMeetingId
            }) { return existing }
            throw error
        }
        return try startTracking(platform: meeting.platform, meetingId: meeting.nativeMeetingId,
                                 startedAt: Date(), status: status)
    }

    @discardableResult
    private func startTracking(platform: MeetingPlatform, meetingId: String, startedAt: Date,
                               status: String) throws -> Session {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent(TranscriptFormatter.fileName(platform: platform, meetingId: meetingId,
                                                                 startedAt: startedAt))
        let session = Session(platform: platform, meetingId: meetingId, startedAt: startedAt,
                              filePath: file.path, status: status)
        sessions.insert(session, at: 0)
        writeTranscript(for: session, segments: [])
        return session
    }

    /// Tracks any bot Vexa is running that this app isn't following yet
    /// (e.g. started from the API, the MCP server, or after a timed-out request).
    func adoptRunningBots() async {
        guard !apiKey.isEmpty, let bots = try? await client.runningBots() else { return }
        for bot in bots {
            guard let p = bot.platform.flatMap(MeetingPlatform.init(rawValue:)),
                  let id = bot.native_meeting_id, !id.isEmpty,
                  !sessions.contains(where: { $0.source == .bot && !$0.finished && $0.platform == p && $0.meetingId == id }) else { continue }
            let started = bot.created_at.flatMap(TranscriptFormatter.parseISO) ?? Date()
            _ = try? startTracking(platform: p, meetingId: id, startedAt: started, status: "requested")
        }
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
        if session.source == .browserExtension {
            dismissedExtension.insert(ExtensionSync.dismissalKey(platform: session.platform, meetingId: session.meetingId,
                                                                 start: session.startedAt))
            defaults.set(Array(dismissedExtension), forKey: Self.key("dismissedExtension"))
        }
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: Transcript files

    private func pollSessions() async {
        guard !apiKey.isEmpty else { return }
        for session in sessions where session.source == .bot && !session.finished {
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
        let url = URL(fileURLWithPath: session.filePath)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing == text { return }
        // Never replace a transcript that has speech with an empty one.
        if let existing, !existing.contains(TranscriptFormatter.noSpeechMarker),
           text.contains(TranscriptFormatter.noSpeechMarker) { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            update(session.id) { $0.lastError = "Could not write transcript: \(error.localizedDescription)" }
        }
    }

    // MARK: Browser extension transcripts

    /// Reads the desktop host's meetings and saves them. Does nothing when the host is down.
    func syncExtensionTranscripts(using client: DesktopHostClient) async {
        let meetings: [DesktopMeeting]
        do {
            meetings = try await client.meetings()
        } catch {
            desktopHostState = .down
            return
        }
        desktopHostState = .up
        var items: [(DesktopMeeting, [TranscriptSegment])] = []
        for m in meetings {
            guard m.meetingPlatform != nil, !m.nativeMeetingId.hasPrefix("selftest-") else { continue }
            var segments = m.segments
            if segments == nil {
                segments = try? await client.transcript(platform: m.platform, nativeMeetingId: m.nativeMeetingId).segments
            }
            items.append((m, segments ?? []))
        }
        applyDesktopMeetings(items)
    }

    /// Creates or updates one session per host meeting and writes its Markdown file.
    /// Sessions are matched by platform + meeting id + start time, so a meeting id that the
    /// host reuses after a restart becomes a new session and a new file.
    func applyDesktopMeetings(_ items: [(DesktopMeeting, [TranscriptSegment])]) {
        var seen = Set<UUID>()
        for (m, segments) in items {
            guard let platform = m.meetingPlatform else { continue }
            let index = sessions.firstIndex {
                $0.source == .browserExtension && $0.platform == platform && $0.meetingId == m.nativeMeetingId
                    && ExtensionSync.isSameMeeting(storedStart: $0.startedAt, hostStart: m.startDate)
            }
            guard ExtensionSync.shouldTrack(m, segmentsKnown: segments, alreadyTracked: index != nil) else { continue }
            if index == nil, dismissedExtension.contains(
                ExtensionSync.dismissalKey(platform: platform, meetingId: m.nativeMeetingId, start: m.startDate)) { continue }

            let id: UUID
            if let index {
                id = sessions[index].id
            } else {
                let started = m.startDate ?? Self.firstSegmentTime(segments) ?? Date()
                let file = URL(fileURLWithPath: outputDirectory).appendingPathComponent(
                    TranscriptFormatter.fileName(platform: platform, meetingId: m.nativeMeetingId, startedAt: started))
                let s = Session(platform: platform, meetingId: m.nativeMeetingId, startedAt: started,
                                filePath: file.path, status: m.status ?? "active",
                                finished: TranscriptFormatter.terminalStatuses.contains(m.status ?? ""),
                                source: .browserExtension)
                sessions.insert(s, at: 0)
                id = s.id
            }
            seen.insert(id)
            guard let current = sessions.first(where: { $0.id == id }) else { continue }
            let canWrite = ExtensionSync.shouldWrite(newSegmentCount: segments.count, savedSegmentCount: current.segmentCount)
            update(id) {
                $0.status = m.status ?? $0.status
                $0.finished = TranscriptFormatter.terminalStatuses.contains($0.status)
                if canWrite { $0.segmentCount = segments.count }
                $0.lastError = nil
            }
            if canWrite, let updated = sessions.first(where: { $0.id == id }) {
                writeTranscript(for: updated, segments: segments)
            }
        }
        // The host forgets meetings when it restarts. Anything still marked live that it no
        // longer lists has ended; the saved file stays as it is.
        for s in sessions where s.source == .browserExtension && !s.finished && !seen.contains(s.id) {
            update(s.id) { $0.status = "completed"; $0.finished = true }
        }
    }

    private static func firstSegmentTime(_ segments: [TranscriptSegment]) -> Date? {
        segments.map(\.start).filter { $0 > TranscriptFormatter.epochThreshold }.min()
            .map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: Bot failure reasons

    /// Asks the gateway why failed bots failed. A few tries per session per run.
    func fillFailureReasons() async {
        let pending = sessions.filter {
            $0.source == .bot && $0.status == "failed" && $0.failureReason == nil && failureLookups[$0.id, default: 0] < 3
        }
        guard !pending.isEmpty, !apiKey.isEmpty, let rows = try? await client.meetings() else { return }
        for s in pending {
            failureLookups[s.id, default: 0] += 1
            guard let row = BotFailure.latestRow(in: rows, platform: s.platform, meetingId: s.meetingId),
                  let text = BotFailure.describe(reason: row.reason, completionReason: row.completionReason)
            else { continue }
            update(s.id) { $0.failureReason = text }
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
