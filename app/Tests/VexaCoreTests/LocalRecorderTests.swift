import XCTest
@testable import VexaCore

/// Synthetic audio at 16 kHz: silence is zeros, "speech" is a 220 Hz tone.
private enum Audio {
    static let rate = 16_000
    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }
    static func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }
}

final class WAVEncoderTests: XCTestCase {
    func testHeaderBytes() {
        let h = WAVEncoder.header(dataByteCount: 32_000, sampleRate: 16_000)
        XCTAssertEqual(h.count, 44)
        XCTAssertEqual(Array(h[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(h[4..<8]), [0x24, 0x7D, 0x00, 0x00])        // 36 + 32000 = 32036
        XCTAssertEqual(Array(h[8..<16]), Array("WAVEfmt ".utf8))
        XCTAssertEqual(Array(h[16..<20]), [16, 0, 0, 0])                   // fmt chunk size
        XCTAssertEqual(Array(h[20..<22]), [1, 0])                          // PCM
        XCTAssertEqual(Array(h[22..<24]), [1, 0])                          // mono
        XCTAssertEqual(Array(h[24..<28]), [0x80, 0x3E, 0x00, 0x00])        // 16000 Hz
        XCTAssertEqual(Array(h[28..<32]), [0x00, 0x7D, 0x00, 0x00])        // 32000 bytes/s
        XCTAssertEqual(Array(h[32..<34]), [2, 0])                          // block align
        XCTAssertEqual(Array(h[34..<36]), [16, 0])                         // bits per sample
        XCTAssertEqual(Array(h[36..<40]), Array("data".utf8))
        XCTAssertEqual(Array(h[40..<44]), [0x00, 0x7D, 0x00, 0x00])        // 32000 data bytes
    }

    func testPCM16LittleEndianAndClipping() {
        let d = WAVEncoder.pcm16([0, 1, -1, 2, -2, 0.5, .nan])
        XCTAssertEqual(Array(d), [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x3F, 0x00, 0x00])
    }

    func testEncodeIsHeaderPlusData() {
        let wav = WAVEncoder.encode(Audio.tone(0.5))
        XCTAssertEqual(wav.count, 44 + 16_000)
        XCTAssertEqual(Array(wav[40..<44]), [0x80, 0x3E, 0x00, 0x00])
    }
}

final class AudioChunkerTests: XCTestCase {
    private func run(_ pieces: [[Float]], pieceSize: Int? = nil) -> (chunks: [AudioChunk], chunker: AudioChunker) {
        var chunker = AudioChunker()
        var out: [AudioChunk] = []
        let all = pieces.flatMap { $0 }
        if let pieceSize {
            var i = 0
            while i < all.count {
                out += chunker.append(Array(all[i..<min(all.count, i + pieceSize)]))
                i += pieceSize
            }
        } else {
            out += chunker.append(all)
        }
        out += chunker.flush()
        return (out, chunker)
    }

    func testSilenceProducesNothing() {
        let r = run([Audio.silence(10)])
        XCTAssertTrue(r.chunks.isEmpty)
        XCTAssertEqual(r.chunker.droppedChunks, 0)
        XCTAssertEqual(r.chunker.totalSamples, 160_000)
    }

    func testCutsAfterPauseWithPreRoll() {
        var chunker = AudioChunker()
        // Nothing yet: speech has not been followed by a long enough pause.
        XCTAssertTrue(chunker.append(Audio.silence(1) + Audio.tone(2) + Audio.silence(0.5)).isEmpty)
        XCTAssertTrue(chunker.isInSpeech)
        let chunks = chunker.append(Audio.silence(0.5))
        XCTAssertEqual(chunks.count, 1)
        let c = chunks[0]
        XCTAssertEqual(c.startSample, 16_000 - 4_800)              // 0.3 s pre-roll before the speech
        XCTAssertEqual(c.startOffset, 0.7, accuracy: 0.001)
        XCTAssertEqual(c.speechDuration, 2, accuracy: 0.03)
        XCTAssertEqual(c.duration, 0.3 + 2 + 0.3, accuracy: 0.03)  // pre-roll + speech + kept silence
        XCTAssertFalse(c.forced)
        XCTAssertFalse(chunker.isInSpeech)
        XCTAssertTrue(chunker.flush().isEmpty)
    }

    func testShortPauseKeepsOneChunk() {
        let r = run([Audio.tone(1), Audio.silence(0.4), Audio.tone(1), Audio.silence(1)])
        XCTAssertEqual(r.chunks.count, 1)
        XCTAssertEqual(r.chunks[0].startSample, 0)
        XCTAssertEqual(r.chunks[0].speechDuration, 2, accuracy: 0.05)
    }

    func testLongPauseSplitsIntoTwoChunks() {
        let r = run([Audio.tone(1), Audio.silence(1), Audio.tone(1), Audio.silence(1)])
        XCTAssertEqual(r.chunks.count, 2)
        XCTAssertEqual(r.chunks[1].startOffset, 2 - 0.3, accuracy: 0.001)
    }

    func testForcedCutAtMaxLength() {
        let r = run([Audio.tone(30)])
        XCTAssertEqual(r.chunks.count, 2)
        XCTAssertTrue(r.chunks[0].forced)
        XCTAssertLessThanOrEqual(r.chunks[0].duration, 25.0001)
        XCTAssertGreaterThan(r.chunks[0].duration, 22)
        // Nothing lost or duplicated at the cut.
        XCTAssertEqual(r.chunks[1].startSample, r.chunks[0].startSample + r.chunks[0].samples.count)
        XCTAssertEqual(r.chunks[0].samples.count + r.chunks[1].samples.count, 30 * 16_000)
    }

    func testForcedCutPrefersQuietMoment() {
        // A short dip (too short to cut on) at 23 s; the 25 s limit should cut there.
        let r = run([Audio.tone(23), Audio.tone(0.2, amplitude: 0.02), Audio.tone(6.8)])
        XCTAssertEqual(r.chunks.count, 2)
        XCTAssertTrue(r.chunks[0].forced)
        XCTAssertEqual(r.chunks[0].duration, 23.2, accuracy: 0.25)
    }

    func testMostlySilentChunkIsDropped() {
        // A 40 ms click: speech, but far too little to be worth sending.
        let r = run([Audio.silence(1), Audio.tone(0.04, amplitude: 0.5), Audio.silence(2)])
        XCTAssertTrue(r.chunks.isEmpty)
        XCTAssertEqual(r.chunker.droppedChunks, 1)
    }

    func testQuietNoiseIsNotSpeech() {
        // Constant low hiss below the threshold (≈ -50 dBFS).
        let hiss = (0..<(16_000 * 5)).map { _ in Float.random(in: -0.005...0.005) }
        XCTAssertTrue(run([hiss]).chunks.isEmpty)
    }

    func testPieceSizeDoesNotChangeResult() {
        let audio = [Audio.silence(0.5), Audio.tone(1.5), Audio.silence(1), Audio.tone(0.8), Audio.silence(0.2)]
        let whole = run(audio).chunks
        let pieces = run(audio, pieceSize: 333).chunks
        XCTAssertEqual(whole, pieces)
        XCTAssertEqual(whole.count, 2)
    }

    func testFlushReturnsSpeechInProgress() {
        var chunker = AudioChunker()
        XCTAssertTrue(chunker.append(Audio.tone(1.25)).isEmpty)
        let rest = chunker.flush()
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].duration, 1.25, accuracy: 0.001)
    }

    func testRMS() {
        XCTAssertEqual(audioRMS([]), 0)
        XCTAssertEqual(audioRMS([0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(audioRMS(Audio.tone(1, amplitude: 1)), 0.7071, accuracy: 0.001)
    }
}

final class LaneClockTests: XCTestCase {
    func testFirstBlockSetsStart() {
        var clock = LaneClock()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(clock.silenceBefore(incoming: 8_000, at: now), 0)
        XCTAssertEqual(clock.start, Date(timeIntervalSince1970: 999.5))
        XCTAssertEqual(clock.date(ofSample: 16_000), Date(timeIntervalSince1970: 1_000.5))
    }

    func testJitterIsIgnoredAndGapsAreFilled() {
        var clock = LaneClock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = clock.silenceBefore(incoming: 16_000, at: t0)                                          // 999…1000
        XCTAssertEqual(clock.silenceBefore(incoming: 1_600, at: t0.addingTimeInterval(0.3)), 0)    // 0.2 s late: jitter
        // Next block arrives 3 s after it should have started.
        let fill = clock.silenceBefore(incoming: 16_000, at: t0.addingTimeInterval(0.1 + 3 + 1))
        XCTAssertEqual(fill, 48_000)
        XCTAssertEqual(clock.samples, 16_000 + 1_600 + 48_000 + 16_000)
    }
}

final class LocalTranscriptTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: 1_795_010_700)   // 2026-11-18 14:05:00 UTC

    func testLinesUseChunkStartAndFilterHallucinations() throws {
        let json = #"""
        {"text":" Hello there. Thanks for watching!","language":"en","segments":[
          {"id":0,"start":0.5,"end":2.0,"text":" Hello there.","no_speech_prob":0.01,"avg_logprob":-0.2},
          {"id":1,"start":2.0,"end":3.0,"text":" Thanks for watching!","no_speech_prob":0.1,"avg_logprob":-0.3},
          {"id":2,"start":3.0,"end":4.0,"text":" Hmm","no_speech_prob":0.9,"avg_logprob":-1.5},
          {"id":3,"start":4.0,"end":9.0,"text":" Late words","no_speech_prob":0.2,"avg_logprob":-0.4}
        ]}
        """#
        let reply = try JSONDecoder().decode(WhisperVerboseResponse.self, from: Data(json.utf8))
        let lines = LocalTranscript.lines(from: reply, chunkStart: t0, chunkDuration: 6, lane: .systemAudio, speaker: "Others")
        XCTAssertEqual(lines.map(\.text), ["Hello there.", "Late words"])
        XCTAssertEqual(lines[0].start, t0.addingTimeInterval(0.5))
        XCTAssertEqual(lines[0].end, t0.addingTimeInterval(2))
        XCTAssertEqual(lines[1].end, t0.addingTimeInterval(6))   // clamped to the chunk
        XCTAssertEqual(lines[0].speaker, "Others")
        XCTAssertEqual(lines[0].lane, .systemAudio)
    }

    func testTextWithoutSegmentsBecomesOneLine() {
        let lines = LocalTranscript.lines(from: .init(text: " Hi.", segments: []), chunkStart: t0, chunkDuration: 2,
                                          lane: .microphone, speaker: "You")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hi.")
    }

    func testMarkdownMergesLanesInTimeOrder() {
        let lines = [
            TranscriptLine(lane: .systemAudio, speaker: "Others", start: t0.addingTimeInterval(5), end: t0.addingTimeInterval(7), text: "How are you?"),
            TranscriptLine(lane: .microphone, speaker: "You", start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(2), text: "Hi."),
            TranscriptLine(lane: .microphone, speaker: "You", start: t0.addingTimeInterval(2.5), end: t0.addingTimeInterval(4), text: "Can you hear me?"),
            TranscriptLine(lane: .microphone, speaker: "You", start: t0.addingTimeInterval(8), end: t0.addingTimeInterval(9), text: "Fine."),
            TranscriptLine(lane: .microphone, speaker: "You", start: t0.addingTimeInterval(200), end: t0.addingTimeInterval(201), text: "Later."),
        ]
        let header = LocalTranscript.Header(title: LocalTranscript.title(startedAt: t0, timeZone: utc), startedAt: t0,
                                            endedAt: t0.addingTimeInterval(1_800),
                                            speakers: [(.microphone, "You"), (.systemAudio, "Others")],
                                            languageCode: "en", model: "whisper-large-v3-turbo")
        let md = LocalTranscript.markdown(header: header, lines: lines, timeZone: utc)
        XCTAssertTrue(md.hasPrefix("# Recording 2026-11-18 14:05\n"))
        XCTAssertTrue(md.contains("- **Ended:** 14:35 (30 min)\n"))
        XCTAssertTrue(md.contains("- **Speakers:** You (microphone), Others (system audio)\n"))
        XCTAssertTrue(md.contains("- **Language:** English\n"))
        XCTAssertTrue(md.contains("- **Model:** whisper-large-v3-turbo\n"))
        let body = md.components(separatedBy: "---\n\n").last!
        XCTAssertEqual(body, """
        **You** · 14:05:01
        Hi. Can you hear me?

        **Others** · 14:05:05
        How are you?

        **You** · 14:05:08
        Fine.

        **You** · 14:08:20
        Later.


        """)
    }

    func testMarkdownWhileRecordingAndWithFailures() {
        var header = LocalTranscript.Header(title: "Recording", startedAt: t0, speakers: [(.microphone, "You")], languageCode: nil)
        var md = LocalTranscript.markdown(header: header, lines: [], timeZone: utc)
        XCTAssertTrue(md.contains("- **Status:** recording…"))
        XCTAssertTrue(md.contains("- **Language:** Detect automatically"))
        XCTAssertTrue(md.hasSuffix(LocalTranscript.noSpeechMarker + "\n"))
        header.failedChunks = 2
        header.failedAudioFolder = "x unsent audio"
        md = LocalTranscript.markdown(header: header, lines: [], timeZone: utc)
        XCTAssertTrue(md.contains("_2 pieces of audio could not be transcribed; the audio is saved in \"x unsent audio\"._"))
    }

    func testFileNamesAndTitle() {
        XCTAssertEqual(LocalTranscript.fileName(startedAt: t0, timeZone: utc), "2026-11-18 1405 Recording.md")
        XCTAssertEqual(LocalTranscript.title(startedAt: t0, timeZone: utc), "Recording 2026-11-18 14:05")
        let dir = URL(fileURLWithPath: "/tmp/t")
        let taken: Set<String> = ["/tmp/t/a.md", "/tmp/t/a 2.md"]
        XCTAssertEqual(LocalTranscript.uniqueURL(in: dir, fileName: "a.md") { taken.contains($0.path) }.lastPathComponent, "a 3.md")
        XCTAssertEqual(LocalTranscript.uniqueURL(in: dir, fileName: "b.md") { taken.contains($0.path) }.lastPathComponent, "b.md")
    }

    func testWhisperEndpointFromEnv() {
        var e = WhisperEndpoint.from(env: [:])
        XCTAssertEqual(e.baseURL.absoluteString, "http://127.0.0.1:8083")
        XCTAssertEqual(e.token, "")
        XCTAssertEqual(e.transcriptionsURL.absoluteString, "http://127.0.0.1:8083/v1/audio/transcriptions")
        XCTAssertEqual(e.healthURL.absoluteString, "http://127.0.0.1:8083/health")
        e = WhisperEndpoint.from(env: ["WHISPER_HOST": "0.0.0.0", "WHISPER_PORT": "9000", "TRANSCRIPTION_SERVICE_TOKEN": "tok"])
        XCTAssertEqual(e.baseURL.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(e.token, "tok")
        e = WhisperEndpoint.from(env: ["WHISPER_HOST": "studio.local", "WHISPER_PORT": "abc"])
        XCTAssertEqual(e.baseURL.absoluteString, "http://studio.local:8083")
    }

    func testMultipartForm() {
        var form = MultipartForm(boundary: "B")
        form.addField("language", "en")
        form.addFile("file", filename: "c.wav", mimeType: "audio/wav", data: Data([1, 2]))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
        let expected = Data("--B\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n".utf8)
            + Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"c.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            + Data([1, 2]) + Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(form.finished, expected)
    }

    func testRecordingCodableAcceptsOlderEntries() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Recording","start":0,"filePath":"/x.md","lanes":["microphone","systemAudio"]}]"#
        let list = try JSONDecoder().decode([LocalRecording].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.lanes, [.microphone, .systemAudio])
        XCTAssertNil(list.first?.end)
        XCTAssertNil(list.first?.audioFiles)
        let again = try JSONDecoder().decode([LocalRecording].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again, list)
    }
}
