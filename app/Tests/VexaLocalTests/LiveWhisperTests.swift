import AVFoundation
import XCTest
import VexaCore
@testable import VexaLocal

/// End-to-end check against the real Whisper server: chunker → WAV → Whisper → Markdown.
/// Skipped unless VEXA_LIVE_AUDIO_DIR points at a folder with a.wav and b.wav (16 kHz mono
/// speech, e.g. made with `say` + ffmpeg). Reads the token from the project's .env
/// (VEXA_PROJECT, default ~/Documents/Projects/vexa-local-mac).
final class LiveWhisperTests: XCTestCase {
    private actor Collector {
        var outcomes: [TranscriptionOutcome] = []
        func add(_ o: TranscriptionOutcome) { outcomes.append(o) }
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        return MonoResampler().process(buffer)
    }

    func testRecordingThroughWhisper() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VEXA_LIVE_AUDIO_DIR"] else {
            throw XCTSkip("Set VEXA_LIVE_AUDIO_DIR to run against the real Whisper server.")
        }
        let project = ProcessInfo.processInfo.environment["VEXA_PROJECT"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Projects/vexa-local-mac").path
        let endpoint = WhisperEndpoint.from(env: EnvFile.read(URL(fileURLWithPath: project).appendingPathComponent(".env")))
        let client = WhisperClient(endpoint: endpoint)
        guard let health = await client.health(), health.status == "ok" else { throw XCTSkip("Whisper is not running") }

        let a = try samples(URL(fileURLWithPath: dir).appendingPathComponent("a.wav"))
        let b = try samples(URL(fileURLWithPath: dir).appendingPathComponent("b.wav"))
        let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * 16_000)) }

        let collector = Collector()
        let queue = TranscriptionQueue(client: client, language: "en") { await collector.add($0) }
        let you = LaneRecorder(lane: .microphone, speaker: "You", transcriber: queue, audioFile: nil)
        let others = LaneRecorder(lane: .systemAudio, speaker: "Others", transcriber: queue, audioFile: nil)
        let start = Date()
        // "You" talk first; "Others" answer after a pause. Five seconds of pure silence on top must not reach Whisper.
        you.ingest(silence(0.5) + a + silence(Double(b.count) / 16_000 + 7))
        others.ingest(silence(0.5 + Double(a.count) / 16_000 + 1.5) + b + silence(5))
        you.finish()
        others.finish()
        await queue.finish()

        var lines: [TranscriptLine] = []
        for outcome in await collector.outcomes {
            switch outcome {
            case .done(_, let l): lines += l
            case .failed(_, let message): XCTFail("Whisper failed: \(message)")
            }
        }
        let header = LocalTranscript.Header(title: LocalTranscript.title(startedAt: start), startedAt: start,
                                            endedAt: Date(), speakers: [(.microphone, "You"), (.systemAudio, "Others")],
                                            languageCode: "en", model: health.model)
        let md = LocalTranscript.markdown(header: header, lines: lines)
        print("----- live transcript -----\n\(md)---------------------------")
        let sent = await collector.outcomes.count
        print("chunks sent to Whisper: \(sent)")
        XCTAssertTrue((2...4).contains(sent))   // a chunk or two per lane; the silence is never sent
        XCTAssertTrue(md.lowercased().contains("budget"))
        XCTAssertTrue(md.lowercased().contains("marketing"))
        let you1 = try XCTUnwrap(md.range(of: "**You**"))
        let others1 = try XCTUnwrap(md.range(of: "**Others**"))
        XCTAssertLessThan(you1.lowerBound, others1.lowerBound)
    }
}
