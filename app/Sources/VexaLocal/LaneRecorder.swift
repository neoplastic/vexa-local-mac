import Foundation
import VexaCore

/// Writes 16 kHz mono 16-bit WAV as audio arrives. The header is fixed up now and then, so
/// the file stays playable even if the app stops unexpectedly.
final class WAVFileWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private var dataBytes = 0
    private var bytesSinceHeader = 0

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: WAVEncoder.header(dataByteCount: 0, sampleRate: sampleRate))
        else { throw CaptureError(message: "Could not create \(url.lastPathComponent).") }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(_ samples: [Float]) {
        let data = WAVEncoder.pcm16(samples)
        try? handle.write(contentsOf: data)
        dataBytes += data.count
        bytesSinceHeader += data.count
        if bytesSinceHeader >= sampleRate * 2 * 10 { updateHeader() }   // every ~10 s of audio
    }

    private func updateHeader() {
        bytesSinceHeader = 0
        guard (try? handle.seek(toOffset: 0)) != nil else { return }
        try? handle.write(contentsOf: WAVEncoder.header(dataByteCount: dataBytes, sampleRate: sampleRate))
        _ = try? handle.seekToEnd()
    }

    func close() {
        updateHeader()
        try? handle.close()
    }
}

/// One lane of a recording (microphone or system audio): keeps time, finds speech, hands
/// chunks to the transcription queue and optionally saves the audio. Thread-safe: capture
/// callbacks call `ingest` from their own threads; the work runs on a private serial queue.
final class LaneRecorder: @unchecked Sendable {
    let lane: RecordingLane
    let speaker: String
    private let queue: DispatchQueue
    private let transcriber: TranscriptionQueue
    private var chunker = AudioChunker()
    private var clock = LaneClock()
    private var audioFile: WAVFileWriter?
    private var finished = false

    private let levelLock = NSLock()
    private var _level: Float = 0

    /// Recent loudness, 0…1 on a dB scale (for the level meter).
    var level: Float { levelLock.withLock { _level } }

    init(lane: RecordingLane, speaker: String, transcriber: TranscriptionQueue, audioFile: URL?) {
        self.lane = lane
        self.speaker = speaker
        self.transcriber = transcriber
        queue = DispatchQueue(label: "vexa.recorder.lane.\(lane.rawValue)", qos: .userInitiated)
        if let audioFile { self.audioFile = try? WAVFileWriter(url: audioFile) }
    }

    var audioFileURL: URL? { audioFile?.url }

    /// 16 kHz mono samples, captured just now.
    func ingest(_ samples: [Float]) {
        let now = Date()
        let meter = Self.meterValue(audioRMS(samples))
        levelLock.withLock { _level = max(meter, _level * 0.6) }
        queue.async { [self] in
            guard !finished else { return }
            var fill = clock.silenceBefore(incoming: samples.count, at: now)
            // A gap in delivery (nothing playing): feed silence so times stay right.
            while fill > 0 {
                let n = min(fill, 16_000)
                feed([Float](repeating: 0, count: n))
                fill -= n
            }
            feed(samples)
        }
    }

    /// Lets the meter fall back when no audio arrives.
    func decayLevel() { levelLock.withLock { _level *= 0.8 } }

    private func feed(_ samples: [Float]) {
        audioFile?.write(samples)
        for chunk in chunker.append(samples) { send(chunk) }
    }

    private func send(_ chunk: AudioChunk) {
        guard let start = clock.date(ofSample: chunk.startSample) else { return }
        transcriber.enqueue(TranscriptionJob(lane: lane, speaker: speaker, start: start, duration: chunk.duration,
                                             wav: WAVEncoder.encode(chunk.samples, sampleRate: chunk.sampleRate)))
    }

    /// Sends the last chunk and closes the audio file. Call after capture has stopped.
    func finish() {
        queue.sync {
            guard !finished else { return }
            finished = true
            for chunk in chunker.flush() { send(chunk) }
            audioFile?.close()
        }
        levelLock.withLock { _level = 0 }
    }

    /// RMS → 0…1, where 0 is -60 dBFS or quieter.
    static func meterValue(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}
