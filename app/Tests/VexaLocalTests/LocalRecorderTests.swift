import AVFoundation
import XCTest
import VexaCore
@testable import VexaLocal

/// Stubs the Whisper server for the recorder tests (separate from VexaClientTests' stub).
final class WhisperStubProtocol: URLProtocol {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Reply)?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let reply: Reply = Self.lock.withLock {
            Self.requests.append((request, body))
            return Self.handler?(request, body) ?? Reply(status: 200, body: #"{"text":"","segments":[]}"#)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() { lock.withLock { handler = nil; requests = [] } }
    static var count: Int { lock.withLock { requests.count } }
}

/// Collects queue results from the worker task.
private actor Collector {
    var outcomes: [TranscriptionOutcome] = []
    func add(_ o: TranscriptionOutcome) { outcomes.append(o) }
}

final class WhisperClientTests: XCTestCase {
    var client: WhisperClient!

    override func setUp() {
        WhisperStubProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [WhisperStubProtocol.self]
        client = WhisperClient(endpoint: WhisperEndpoint(baseURL: URL(string: "http://127.0.0.1:8083")!, token: "tok"),
                               session: URLSession(configuration: cfg))
    }

    private func job(_ second: Double, speaker: String = "You") -> TranscriptionJob {
        TranscriptionJob(lane: .microphone, speaker: speaker, start: Date(timeIntervalSince1970: 1_000 + second),
                         duration: 3, wav: WAVEncoder.encode([0, 0.1, -0.1]))
    }

    func testTranscribeSendsMultipartWithTokenAndParses() async throws {
        WhisperStubProtocol.handler = { _, _ in
            .init(status: 200, body: #"{"text":" Hi.","language":"en","segments":[{"start":0.2,"end":1.1,"text":" Hi.","no_speech_prob":0.01,"avg_logprob":-0.2}]}"#)
        }
        let wav = WAVEncoder.encode([0, 0.5])
        let reply = try await client.transcribe(wav: wav, language: "en")
        XCTAssertEqual(reply.segments.first?.text, " Hi.")
        XCTAssertEqual(reply.language, "en")

        let (req, body) = try XCTUnwrap(WhisperStubProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8083/v1/audio/transcriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let type = try XCTUnwrap(req.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertNotNil(body.range(of: wav))
    }

    func testNoLanguageFieldForAutoDetect() async throws {
        _ = try await client.transcribe(wav: WAVEncoder.encode([0]), language: nil)
        let body = String(decoding: try XCTUnwrap(WhisperStubProtocol.requests.first?.body), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
    }

    func testErrorStatusIsReported() async {
        WhisperStubProtocol.handler = { _, _ in .init(status: 401, body: #"{"detail":"Invalid or missing API token"}"#) }
        do {
            _ = try await client.transcribe(wav: Data(), language: "en")
            XCTFail("expected an error")
        } catch let f as WhisperClient.Failure {
            XCTAssertEqual(f.status, 401)
            XCTAssertEqual(f.message, "Invalid or missing API token")
            XCTAssertFalse(f.isRetryable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testHealth() async {
        WhisperStubProtocol.handler = { req, _ in
            XCTAssertEqual(req.url?.path, "/health")
            return .init(status: 200, body: #"{"status":"ok","model":"mlx-community/whisper-large-v3-turbo"}"#)
        }
        let h = await client.health()
        XCTAssertEqual(h?.status, "ok")
        XCTAssertEqual(h?.model, "mlx-community/whisper-large-v3-turbo")
        WhisperStubProtocol.handler = { _, _ in .init(status: 500, body: "") }
        let down = await client.health()
        XCTAssertNil(down)
    }

    func testQueueKeepsOrderAndRetriesOnce() async throws {
        var calls = 0
        WhisperStubProtocol.handler = { _, _ in
            calls += 1
            if calls == 1 { return .init(status: 503, body: #"{"detail":"Transcriber busy"}"#, headers: ["Retry-After": "0"]) }
            return .init(status: 200, body: #"{"text":"x","segments":[{"start":1,"end":2,"text":" Call \#(calls)"}]}"#)
        }
        let collector = Collector()
        let queue = TranscriptionQueue(client: client, language: "en", retryDelay: 0) { await collector.add($0) }
        queue.enqueue(job(0))
        queue.enqueue(job(10))
        queue.enqueue(job(20))
        XCTAssertGreaterThan(queue.pending, 0)
        await queue.finish()
        XCTAssertEqual(queue.pending, 0)

        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(WhisperStubProtocol.count, 4)   // first chunk was retried
        var texts: [String] = []
        for case .done(let job, let lines) in outcomes {
            XCTAssertEqual(lines.first?.start, job.start.addingTimeInterval(1))
            texts += lines.map(\.text)
        }
        XCTAssertEqual(texts, ["Call 2", "Call 3", "Call 4"])
    }

    func testQueueReportsFailureAfterRetry() async {
        WhisperStubProtocol.handler = { _, _ in .init(status: 500, body: #"{"detail":"boom"}"#) }
        let collector = Collector()
        let queue = TranscriptionQueue(client: client, language: nil, retryDelay: 0) { await collector.add($0) }
        queue.enqueue(job(0))
        await queue.finish()
        let outcomes = await collector.outcomes
        XCTAssertEqual(WhisperStubProtocol.count, 2)
        guard case .failed(_, let message) = outcomes.first else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("boom"))
    }

    func testCancelledQueueReportsTheRestAsFailed() async {
        let collector = Collector()
        let queue = TranscriptionQueue(client: client, language: nil, retryDelay: 0) { await collector.add($0) }
        queue.enqueue(job(0))
        queue.enqueue(job(10))
        queue.enqueue(job(20))
        queue.cancel()
        queue.enqueue(job(30))   // after cancel(): ignored
        await queue.finish()
        XCTAssertEqual(queue.pending, 0)
        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes.count, 3)
        guard case .failed(let job, let message) = outcomes.last else { return XCTFail("expected a failure") }
        XCTAssertEqual(job.start, Date(timeIntervalSince1970: 1_020))
        XCTAssertEqual(message, TranscriptionQueue.notSent)
    }

    func testLaneRecorderSendsSpeechWithClockTimes() async throws {
        WhisperStubProtocol.handler = { _, body in
            // The chunk is a WAV with 0.3 s pre-roll + 1 s tone + 0.3 s kept silence.
            XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
            return .init(status: 200, body: #"{"text":"x","segments":[{"start":0.3,"end":1.3,"text":" Hello"}]}"#)
        }
        let collector = Collector()
        let queue = TranscriptionQueue(client: client, language: "en", retryDelay: 0) { await collector.add($0) }
        let lane = LaneRecorder(lane: .systemAudio, speaker: "Others", transcriber: queue, audioFile: nil)
        let tone = (0..<16_000).map { 0.3 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let before = Date()
        lane.ingest([Float](repeating: 0, count: 16_000))
        lane.ingest(tone)
        lane.ingest([Float](repeating: 0, count: 16_000))
        lane.finish()
        await queue.finish()

        let outcomes = await collector.outcomes
        guard case .done(let job, let lines) = outcomes.first else { return XCTFail("expected a result") }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(job.speaker, "Others")
        XCTAssertEqual(job.lane, .systemAudio)
        XCTAssertEqual(job.duration, 1.6, accuracy: 0.03)
        // The tone started 1 s after the lane's first sample; the chunk 0.3 s before that.
        XCTAssertEqual(lines.first?.text, "Hello")
        let firstSample = before.addingTimeInterval(-1)   // first block was 1 s long, captured "now"
        XCTAssertEqual(job.start.timeIntervalSince(firstSample), 0.7, accuracy: 0.3)
        XCTAssertEqual(lines.first!.start.timeIntervalSince(job.start), 0.3, accuracy: 0.001)
    }

    func testLaneRecorderKeepsAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-lane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = TranscriptionQueue(client: client, language: nil) { _ in }
        let url = dir.appendingPathComponent("a.wav")
        let lane = LaneRecorder(lane: .microphone, speaker: "You", transcriber: queue, audioFile: url)
        lane.ingest([Float](repeating: 0.25, count: 8_000))
        lane.finish()
        queue.cancel()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 16_000)
        XCTAssertEqual(data.prefix(44), WAVEncoder.header(dataByteCount: 16_000, sampleRate: 16_000))
        // Plays as a normal audio file.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 8_000)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
    }
}

final class MonoResamplerTests: XCTestCase {
    func testStereo48kBecomesMono16k() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let resampler = MonoResampler()
        var total = 0
        var peak: Float = 0
        for _ in 0..<100 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            for i in 0..<4_800 {
                buffer.floatChannelData![0][i] = 0.5
                buffer.floatChannelData![1][i] = 0.1
            }
            let out = resampler.process(buffer)
            total += out.count
            peak = max(peak, out.suffix(100).max() ?? 0)
        }
        XCTAssertEqual(Double(total), 160_000, accuracy: 400)   // 10 s at 16 kHz (minus converter latency, no drift)
        XCTAssertEqual(peak, 0.3, accuracy: 0.02)              // average of the two channels
    }

    func testInterleavedInt16Downmix() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let p = buffer.int16ChannelData![0]
        p[0] = 16_384; p[1] = 0; p[2] = -32_768; p[3] = -32_768
        XCTAssertEqual(MonoResampler.downmix(buffer), [0.25, -1])
        XCTAssertEqual(MonoResampler().process(buffer), [0.25, -1])   // already 16 kHz: no resampling
    }

    func testMeterScale() {
        XCTAssertEqual(LaneRecorder.meterValue(0), 0)
        XCTAssertEqual(LaneRecorder.meterValue(1), 1)
        XCTAssertEqual(LaneRecorder.meterValue(0.001), 0, accuracy: 0.001)   // -60 dBFS
        XCTAssertEqual(LaneRecorder.meterValue(0.0316), 0.5, accuracy: 0.01) // -30 dBFS
    }
}

@MainActor
final class RecorderStoreTests: XCTestCase {
    func testSettingsAndRecordingsPersist() throws {
        let defaults = TestDefaults()

        let store = RecorderStore(defaults: defaults)
        XCTAssertTrue(store.useMicrophone)
        XCTAssertTrue(store.useSystemAudio)
        XCTAssertEqual(store.languageCode, "en")
        XCTAssertFalse(store.keepAudio)
        XCTAssertEqual(store.label(for: .microphone), "You")
        XCTAssertEqual(store.label(for: .systemAudio), "Others")
        store.systemAudioLabel = "  "
        XCTAssertEqual(store.label(for: .systemAudio), "Others")   // blank falls back
        store.microphoneLabel = "David"
        store.useSystemAudio = false
        XCTAssertEqual(store.selectedLanes, [.microphone])

        // A recording that never got an end (app killed) is closed when loaded.
        let unfinished = LocalRecording(title: "Recording", start: Date(timeIntervalSince1970: 100),
                                        filePath: "/nonexistent/x.md", lanes: [.microphone])
        defaults.set(try JSONEncoder().encode([unfinished]), forKey: LocalRecording.defaultsKey)

        let again = RecorderStore(defaults: defaults)
        XCTAssertEqual(again.label(for: .microphone), "David")
        XCTAssertFalse(again.useSystemAudio)
        XCTAssertEqual(again.recordings.count, 1)
        XCTAssertEqual(again.recordings.first?.end, Date(timeIntervalSince1970: 100))
        again.removeRecording(unfinished.id)
        XCTAssertTrue(again.recordings.isEmpty)
        XCTAssertEqual(RecorderStore(defaults: defaults).recordings.count, 0)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(RecordView.elapsed(5), "00:05")
        XCTAssertEqual(RecordView.elapsed(65), "01:05")
        XCTAssertEqual(RecordView.elapsed(3_725), "1:02:05")
    }
}
