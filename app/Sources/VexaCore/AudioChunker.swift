import Foundation

/// A piece of one lane's audio that holds speech, ready to send to Whisper.
public struct AudioChunk: Equatable, Sendable {
    /// Position of the first sample, counted from the start of the lane.
    public var startSample: Int
    public var samples: [Float]
    /// How many of the samples were judged to be speech.
    public var speechSamples: Int
    public var sampleRate: Int
    /// True when the chunk was cut because it got too long, not at a pause.
    public var forced: Bool

    public var startOffset: TimeInterval { Double(startSample) / Double(sampleRate) }
    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
    public var speechDuration: TimeInterval { Double(speechSamples) / Double(sampleRate) }
}

/// Root-mean-square level of a block of samples (0 for an empty block).
public func audioRMS(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    return (sum / Float(samples.count)).squareRoot()
}

public func audioRMS(_ samples: [Float]) -> Float { audioRMS(samples[...]) }

/// Splits a stream of 16 kHz mono samples into speech chunks using frame energy.
///
/// - Silence before speech is thrown away, except a short pre-roll so the first word isn't clipped.
/// - A chunk ends after `silenceToCut` seconds of silence following speech.
/// - A chunk that reaches `maxChunk` seconds is cut at the quietest frame of its last
///   `forcedCutWindow` seconds; the rest carries on into the next chunk.
/// - Chunks with less than `minSpeech` seconds of speech are dropped: Whisper invents text for silence.
///
/// "Speech" means a frame louder than both `speechThreshold` and `noiseFactor` × the noise floor.
/// The noise floor follows the quietest recent frames: it drops at once and rises slowly.
public struct AudioChunker: Sendable {
    public struct Config: Sendable, Equatable {
        public var sampleRate = 16_000
        public var frameDuration: TimeInterval = 0.02
        public var silenceToCut: TimeInterval = 0.7
        public var maxChunk: TimeInterval = 25
        public var forcedCutWindow: TimeInterval = 3
        public var preRoll: TimeInterval = 0.3
        /// Silence kept at the end of a chunk that ended at a pause.
        public var trailingSilenceKept: TimeInterval = 0.3
        public var minSpeech: TimeInterval = 0.3
        /// Minimum RMS for speech (0.01 ≈ -40 dBFS).
        public var speechThreshold: Float = 0.01
        public var noiseFactor: Float = 3
        /// How fast the noise floor rises per frame (fraction of the gap).
        public var noiseRise: Float = 0.0002
        public init() {}
    }

    public let config: Config
    /// Chunks thrown away because they held too little speech.
    public private(set) var droppedChunks = 0
    /// Total samples taken in so far.
    public private(set) var totalSamples = 0
    public private(set) var noiseFloor: Float

    private var partialFrame: [Float] = []
    private var processed = 0                 // samples already split into frames
    private var preRollBuffer: [Float] = []
    private var current: [Float]?
    private var currentStart = 0
    private var currentFrames: [(rms: Float, speech: Bool, count: Int)] = []
    private var trailingSilence = 0

    public init(config: Config = Config()) {
        self.config = config
        noiseFloor = config.speechThreshold / max(config.noiseFactor, 1)
    }

    private var frameSize: Int { max(1, Int((config.frameDuration * Double(config.sampleRate)).rounded())) }
    private func samples(_ seconds: TimeInterval) -> Int { Int((seconds * Double(config.sampleRate)).rounded()) }

    /// True while a chunk with speech is being collected.
    public var isInSpeech: Bool { current != nil }

    /// Takes in more audio; returns any chunks that are now complete.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        totalSamples += samples.count
        var out: [AudioChunk] = []
        var input = samples[...]
        if !partialFrame.isEmpty {
            let need = frameSize - partialFrame.count
            partialFrame += input.prefix(need)
            input = input.dropFirst(need)
            if partialFrame.count < frameSize { return out }
            let frame = partialFrame
            partialFrame = []
            if let c = process(frame[...]) { out.append(c) }
        }
        while input.count >= frameSize {
            if let c = process(input.prefix(frameSize)) { out.append(c) }
            input = input.dropFirst(frameSize)
        }
        partialFrame = Array(input)
        return out
    }

    /// Ends the stream: returns what is left, if it holds enough speech.
    public mutating func flush() -> [AudioChunk] {
        var out: [AudioChunk] = []
        if !partialFrame.isEmpty {
            let frame = partialFrame
            partialFrame = []
            if let c = process(frame[...]) { out.append(c) }
        }
        if current != nil, let c = emit(trimTrailing: true, forced: false) { out.append(c) }
        preRollBuffer = []
        return out
    }

    private mutating func process(_ frame: ArraySlice<Float>) -> AudioChunk? {
        let frameStart = processed
        processed += frame.count
        let level = audioRMS(frame)
        let threshold = max(config.speechThreshold, noiseFloor * config.noiseFactor)
        let speech = level >= threshold
        noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * config.noiseRise

        guard current != nil else {
            if speech {
                current = preRollBuffer + frame
                currentStart = frameStart - preRollBuffer.count
                currentFrames = [(0, false, preRollBuffer.count), (level, true, frame.count)]
                trailingSilence = 0
                preRollBuffer = []
            } else {
                preRollBuffer += frame
                let keep = samples(config.preRoll)
                if preRollBuffer.count > keep { preRollBuffer.removeFirst(preRollBuffer.count - keep) }
            }
            return nil
        }

        current! += frame
        currentFrames.append((level, speech, frame.count))
        trailingSilence = speech ? 0 : trailingSilence + frame.count

        if trailingSilence >= samples(config.silenceToCut) {
            return emit(trimTrailing: true, forced: false)
        }
        if current!.count >= samples(config.maxChunk) {
            return forcedCut()
        }
        return nil
    }

    /// Cuts at the quietest frame in the last few seconds and keeps the rest for the next chunk.
    private mutating func forcedCut() -> AudioChunk? {
        let window = samples(config.forcedCutWindow)
        let total = current!.count
        var position = total
        var bestPosition = total
        var bestLevel = Float.greatestFiniteMagnitude
        var bestIndex = currentFrames.count
        for i in stride(from: currentFrames.count - 1, through: 0, by: -1) {
            position -= currentFrames[i].count
            if total - position > window || position <= 0 { break }
            if currentFrames[i].rms < bestLevel {
                bestLevel = currentFrames[i].rms
                bestPosition = position
                bestIndex = i
            }
        }
        // Cut just after the quietest frame (or at the end if nothing qualified).
        let cutAt = bestIndex < currentFrames.count ? bestPosition + currentFrames[bestIndex].count : total
        let restFrames = Array(currentFrames[min(bestIndex + 1, currentFrames.count)...])
        let rest = Array(current![cutAt...])
        let restStart = currentStart + cutAt
        current = Array(current![..<cutAt])
        currentFrames = Array(currentFrames[..<min(bestIndex + 1, currentFrames.count)])
        let chunk = emit(trimTrailing: false, forced: true)
        if !rest.isEmpty {
            current = rest
            currentStart = restStart
            currentFrames = restFrames
            trailingSilence = 0
            for f in restFrames.reversed() { if f.speech { break }; trailingSilence += f.count }
        }
        return chunk
    }

    private mutating func emit(trimTrailing: Bool, forced: Bool) -> AudioChunk? {
        guard var samples = current else { return nil }
        let speech = currentFrames.filter(\.speech).reduce(0) { $0 + $1.count }
        if trimTrailing {
            let excess = trailingSilence - self.samples(config.trailingSilenceKept)
            if excess > 0 { samples.removeLast(min(excess, samples.count)) }
        }
        let start = currentStart
        current = nil
        currentFrames = []
        trailingSilence = 0
        guard speech >= self.samples(config.minSpeech) else {
            droppedChunks += 1
            return nil
        }
        return AudioChunk(startSample: max(0, start), samples: samples, speechSamples: speech,
                          sampleRate: config.sampleRate, forced: forced)
    }
}

/// Keeps a lane's sample count in step with the wall clock. When a capture source stops
/// delivering audio for a while (ScreenCaptureKit can go quiet when nothing plays), this
/// says how many silent samples to insert so chunk times stay right.
public struct LaneClock: Sendable {
    public let sampleRate: Int
    /// Gaps shorter than this are normal delivery jitter and are ignored.
    public var tolerance: TimeInterval
    public private(set) var start: Date?
    public private(set) var samples = 0

    public init(sampleRate: Int = 16_000, tolerance: TimeInterval = 0.5) {
        self.sampleRate = sampleRate
        self.tolerance = tolerance
    }

    /// Call when `incoming` samples arrive at `now` (the time their last sample was captured).
    /// Returns how many silent samples to feed before them.
    public mutating func silenceBefore(incoming: Int, at now: Date) -> Int {
        let duration = Double(incoming) / Double(sampleRate)
        guard let start else {
            self.start = now.addingTimeInterval(-duration)
            samples = incoming
            return 0
        }
        let expectedStart = start.addingTimeInterval(Double(samples) / Double(sampleRate))
        let actualStart = now.addingTimeInterval(-duration)
        let gap = actualStart.timeIntervalSince(expectedStart)
        var fill = 0
        if gap > tolerance { fill = Int((gap * Double(sampleRate)).rounded()) }
        samples += fill + incoming
        return fill
    }

    /// Wall-clock time of a sample position.
    public func date(ofSample index: Int) -> Date? {
        start?.addingTimeInterval(Double(index) / Double(sampleRate))
    }
}
