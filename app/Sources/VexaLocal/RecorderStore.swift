import AppKit
import Foundation
import Observation
import VexaCore

/// The local recorder: microphone + system audio → Whisper → Markdown. Needs only the
/// project's Whisper server (no Vexa, Docker or browser extension).
@MainActor @Observable
final class RecorderStore {
    enum Phase: Equatable { case idle, starting, recording, stopping }

    enum WhisperStatus: Equatable {
        case unknown, checking, loading, down
        case up(model: String?)
        var isUp: Bool { if case .up = self { return true } else { return false } }
    }

    /// Why a recording could not start.
    enum Problem: Equatable {
        case noLanes
        case whisperDown
        case microphoneDenied
        case screenRecordingDenied(String)
        case other(String)
    }

    // MARK: Settings (persisted)
    var useMicrophone: Bool { didSet { defaults.set(useMicrophone, forKey: Self.key("useMicrophone")) } }
    var useSystemAudio: Bool { didSet { defaults.set(useSystemAudio, forKey: Self.key("useSystemAudio")) } }
    var microphoneLabel: String { didSet { defaults.set(microphoneLabel, forKey: Self.key("microphoneLabel")) } }
    var systemAudioLabel: String { didSet { defaults.set(systemAudioLabel, forKey: Self.key("systemAudioLabel")) } }
    /// Whisper language code; "" = detect automatically.
    var languageCode: String { didSet { defaults.set(languageCode, forKey: Self.key("language")) } }
    var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: Self.key("keepAudio")) } }
    /// Core Audio UID of the microphone; "" = system default.
    var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Self.key("inputDevice")) } }

    // MARK: Live state
    var phase: Phase = .idle
    var whisper: WhisperStatus = .unknown
    var problem: Problem?
    /// Something went wrong during a recording that didn't stop it.
    var warning: String?
    var startedAt: Date?
    var activeLanes: [RecordingLane] = []
    var lines: [TranscriptLine] = []
    var levels: [RecordingLane: Float] = [:]
    var pendingChunks = 0
    var failedChunks = 0
    /// The transcript of the current (or last) recording.
    var fileURL: URL?
    var inputDevices: [AudioInputDevice] = []
    /// Past recordings, newest first (UserDefaults `vexa.recordings`).
    private(set) var recordings: [LocalRecording] = [] { didSet { saveRecordings() } }
    /// True while quitting waits for the recording to finish.
    var isQuitting = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var mic: MicrophoneCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var laneRecorders: [LaneRecorder] = []
    @ObservationIgnored private var transcriber: TranscriptionQueue?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var header: LocalTranscript.Header?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var failedFolder: URL?

    init(defaults d: UserDefaults = .standard) {
        defaults = d
        useMicrophone = d.object(forKey: Self.key("useMicrophone")) as? Bool ?? true
        useSystemAudio = d.object(forKey: Self.key("useSystemAudio")) as? Bool ?? true
        microphoneLabel = d.string(forKey: Self.key("microphoneLabel")) ?? RecordingLane.microphone.defaultSpeaker
        systemAudioLabel = d.string(forKey: Self.key("systemAudioLabel")) ?? RecordingLane.systemAudio.defaultSpeaker
        languageCode = d.string(forKey: Self.key("language")) ?? "en"
        keepAudio = d.bool(forKey: Self.key("keepAudio"))
        inputDeviceUID = d.string(forKey: Self.key("inputDevice")) ?? ""
        if let data = d.data(forKey: LocalRecording.defaultsKey),
           var saved = try? JSONDecoder().decode([LocalRecording].self, from: data) {
            // A recording without an end was cut short (crash, force quit); end it at the file's last change.
            for i in saved.indices where saved[i].end == nil {
                let modified = (try? FileManager.default.attributesOfItem(atPath: saved[i].filePath))?[.modificationDate] as? Date
                saved[i].end = modified ?? saved[i].start
            }
            recordings = saved
        }
    }

    var isRecording: Bool { phase == .recording }
    var selectedLanes: [RecordingLane] {
        RecordingLane.allCases.filter { $0 == .microphone ? useMicrophone : useSystemAudio }
    }

    func label(for lane: RecordingLane) -> String {
        let raw = (lane == .microphone ? microphoneLabel : systemAudioLabel).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? lane.defaultSpeaker : raw
    }

    // MARK: Whisper

    func checkWhisper(_ app: AppModel) async {
        if whisper == .unknown { whisper = .checking }
        whisper = await Self.status(of: WhisperClient(endpoint: WhisperEndpoint.from(env: app.env)))
        if whisper.isUp, problem == .whisperDown { problem = nil }
    }

    private static func status(of client: WhisperClient) async -> WhisperStatus {
        guard let health = await client.health() else { return .down }
        return health.status == "ok" ? .up(model: health.model) : .loading
    }

    /// Runs scripts/whisper.sh start in the app's script runner (its log sheet opens).
    func startWhisper(_ app: AppModel) async {
        app.showLog = true
        await app.runner.run("Starting Whisper", script: app.script("whisper.sh"), arguments: ["start"], in: app.projectURL)
        await app.refreshStatus()
        await checkWhisper(app)
    }

    func refreshDevices() { inputDevices = AudioInputDevices.list() }

    // MARK: Start / stop

    func start(_ app: AppModel) async {
        guard phase == .idle else { return }
        problem = nil
        warning = nil
        let lanes = selectedLanes
        guard !lanes.isEmpty else { problem = .noLanes; return }
        phase = .starting
        defer { if phase == .starting { phase = .idle } }

        app.reloadEnv()
        let endpoint = WhisperEndpoint.from(env: app.env)
        whisper = await Self.status(of: WhisperClient(endpoint: endpoint))
        guard case .up(let model) = whisper else { problem = .whisperDown; return }

        if lanes.contains(.microphone), !(await RecorderPermissions.requestMicrophone()) {
            problem = .microphoneDenied
            return
        }
        if lanes.contains(.systemAudio) {
            do { _ = try await SystemAudioCapture.shareableContent() } catch {
                problem = .screenRecordingDenied(error.localizedDescription)
                return
            }
        }

        let start = Date()
        let dir = URL(fileURLWithPath: app.outputDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            problem = .other("Could not create the transcripts folder \(dir.path): \(error.localizedDescription)")
            return
        }
        let file = LocalTranscript.uniqueURL(in: dir, fileName: LocalTranscript.fileName(startedAt: start)) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let base = file.deletingPathExtension().lastPathComponent
        let language = languageCode.isEmpty ? nil : languageCode

        let queue = TranscriptionQueue(client: WhisperClient(endpoint: endpoint), language: language) { [weak self] outcome in
            await self?.receive(outcome)
        }
        let recorders = lanes.map { lane in
            LaneRecorder(lane: lane, speaker: label(for: lane), transcriber: queue,
                         audioFile: keepAudio ? dir.appendingPathComponent("\(base) \(lane.displayName.lowercased()).wav") : nil)
        }

        // Start capture. If one source fails, undo everything.
        let micCapture = lanes.contains(.microphone) ? MicrophoneCapture() : nil
        let systemCapture = lanes.contains(.systemAudio) ? SystemAudioCapture() : nil
        let onFailure: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.warning = message }
        }
        do {
            if let micCapture, let rec = recorders.first(where: { $0.lane == .microphone }) {
                micCapture.onFailure = onFailure
                try micCapture.start(deviceUID: inputDeviceUID.isEmpty ? nil : inputDeviceUID) { rec.ingest($0) }
            }
            if let systemCapture, let rec = recorders.first(where: { $0.lane == .systemAudio }) {
                systemCapture.onFailure = onFailure
                try await systemCapture.start { rec.ingest($0) }
            }
        } catch {
            micCapture?.stop()
            await systemCapture?.stop()
            recorders.forEach { $0.finish() }
            queue.cancel()
            for url in recorders.compactMap(\.audioFileURL) { try? FileManager.default.removeItem(at: url) }
            problem = .other(error.localizedDescription)
            return
        }

        mic = micCapture
        system = systemCapture
        laneRecorders = recorders
        transcriber = queue
        startedAt = start
        activeLanes = lanes
        lines = []
        failedChunks = 0
        pendingChunks = 0
        fileURL = file
        failedFolder = dir.appendingPathComponent("\(base) unsent audio")
        header = LocalTranscript.Header(title: LocalTranscript.title(startedAt: start), startedAt: start,
                                        speakers: lanes.map { ($0, label(for: $0)) }, languageCode: language,
                                        model: model?.replacingOccurrences(of: "mlx-community/", with: ""))
        let record = LocalRecording(title: header!.title, start: start, filePath: file.path, lanes: lanes,
                                    audioFiles: keepAudio ? recorders.compactMap(\.audioFileURL?.path) : nil)
        recordingID = record.id
        recordings.insert(record, at: 0)
        writeTranscript()
        phase = .recording
        startMeters()
    }

    /// Stops capture, sends the last chunk, waits for Whisper and writes the final file.
    /// With `maxWait`, gives up on Whisper after that long (unsent audio is saved instead).
    func stop(maxWait: TimeInterval? = nil) async {
        guard phase == .recording else { return }
        phase = .stopping
        mic?.stop()
        await system?.stop()
        for rec in laneRecorders { rec.finish() }
        if let queue = transcriber {
            if let maxWait {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await queue.finish(); return true }
                    group.addTask { try? await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000)); return false }
                    if await group.next() == false { queue.cancel() }
                    group.cancelAll()
                }
            } else {
                await queue.finish()
            }
        }
        meterTask?.cancel()
        meterTask = nil
        let end = Date()
        header?.endedAt = end
        writeTranscript()
        if let id = recordingID, let i = recordings.firstIndex(where: { $0.id == id }) { recordings[i].end = end }
        mic = nil
        system = nil
        laneRecorders = []
        transcriber = nil
        recordingID = nil
        levels = [:]
        pendingChunks = 0
        phase = .idle
    }

    /// Stop waiting for Whisper; what it hasn't done yet is saved as audio.
    func skipWaiting() { transcriber?.cancel() }

    /// Called when the app quits: finishes a recording (or one that is stopping) first.
    func finishForQuit() async {
        guard phase == .recording || phase == .stopping else { return }
        isQuitting = true
        defer { isQuitting = false }
        if phase == .recording {
            await stop(maxWait: 60)
        } else {
            let deadline = Date().addingTimeInterval(65)
            while phase == .stopping, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func removeRecording(_ id: UUID) {
        guard id != recordingID else { return }
        recordings.removeAll { $0.id == id }
    }

    // MARK: Results

    private func receive(_ outcome: TranscriptionOutcome) {
        switch outcome {
        case .done(_, let new):
            lines.append(contentsOf: new)
            lines.sort { $0.start < $1.start }
        case .failed(let job, let message):
            failedChunks += 1
            header?.failedChunks = failedChunks
            if let folder = failedFolder {
                header?.failedAudioFolder = folder.lastPathComponent
                let f = DateFormatter()
                f.dateFormat = "HH-mm-ss"
                let url = folder.appendingPathComponent("\(f.string(from: job.start)) \(job.speaker).wav")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try job.wav.write(to: url)
                } catch {
                    warning = "Could not save audio Whisper missed: \(error.localizedDescription)"
                }
            }
            warning = "Whisper could not transcribe a piece of audio (\(message)). Its audio is saved next to the transcript."
        }
        writeTranscript()
    }

    private func writeTranscript() {
        guard let header, let fileURL else { return }
        let text = LocalTranscript.markdown(header: header, lines: lines)
        do {
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            warning = "Could not write the transcript: \(error.localizedDescription)"
        }
    }

    private func startMeters() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var next: [RecordingLane: Float] = [:]
                for rec in self.laneRecorders {
                    next[rec.lane] = rec.level
                    rec.decayLevel()
                }
                self.levels = next
                self.pendingChunks = self.transcriber?.pending ?? 0
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    // MARK: Persistence

    private static func key(_ name: String) -> String { "vexa.recorder.\(name)" }

    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) { defaults.set(data, forKey: LocalRecording.defaultsKey) }
    }
}
