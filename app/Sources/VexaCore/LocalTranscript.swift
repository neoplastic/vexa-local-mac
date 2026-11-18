import Foundation

// The local recorder: records the microphone and the Mac's own sound, sends speech to the
// project's Whisper server and writes a Markdown transcript. Vexa is not involved.

/// One audio source the local recorder can capture.
public enum RecordingLane: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The Mac's microphone (you).
    case microphone
    /// What the Mac plays: the other people in the meeting.
    case systemAudio

    public var id: Self { self }
    public var defaultSpeaker: String { self == .microphone ? "You" : "Others" }
    public var displayName: String { self == .microphone ? "Microphone" : "System audio" }
}

/// One transcribed line with wall-clock times.
public struct TranscriptLine: Equatable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var lane: RecordingLane
    public var speaker: String
    public var start: Date
    public var end: Date
    public var text: String

    public init(lane: RecordingLane, speaker: String, start: Date, end: Date, text: String) {
        self.lane = lane; self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

/// A recording made by the local recorder, kept in UserDefaults (`LocalRecording.defaultsKey`).
public struct LocalRecording: Codable, Equatable, Sendable, Identifiable {
    public static let defaultsKey = "vexa.recordings"

    public var id: UUID
    public var title: String
    public var start: Date
    /// Nil while recording.
    public var end: Date?
    /// The Markdown transcript.
    public var filePath: String
    public var lanes: [RecordingLane]
    /// WAV files saved with "Keep the audio" (absent in older entries).
    public var audioFiles: [String]?

    public init(id: UUID = UUID(), title: String, start: Date, end: Date? = nil, filePath: String,
                lanes: [RecordingLane], audioFiles: [String]? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.filePath = filePath; self.lanes = lanes; self.audioFiles = audioFiles
    }
}

/// The `verbose_json` reply of POST /v1/audio/transcriptions.
public struct WhisperVerboseResponse: Decodable, Equatable, Sendable {
    public struct Segment: Decodable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public var noSpeechProb: Double?
        public var avgLogprob: Double?

        enum CodingKeys: String, CodingKey {
            case start, end, text
            case noSpeechProb = "no_speech_prob"
            case avgLogprob = "avg_logprob"
        }

        public init(start: Double, end: Double, text: String, noSpeechProb: Double? = nil, avgLogprob: Double? = nil) {
            self.start = start; self.end = end; self.text = text
            self.noSpeechProb = noSpeechProb; self.avgLogprob = avgLogprob
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            noSpeechProb = try c.decodeIfPresent(Double.self, forKey: .noSpeechProb)
            avgLogprob = try c.decodeIfPresent(Double.self, forKey: .avgLogprob)
        }
    }

    public var text: String
    public var language: String?
    public var segments: [Segment]

    enum CodingKeys: String, CodingKey { case text, language, segments }

    public init(text: String, language: String? = nil, segments: [Segment]) {
        self.text = text; self.language = language; self.segments = segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }
}

/// Where the Whisper server listens, from the project's .env.
public struct WhisperEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }

    /// WHISPER_HOST (default 127.0.0.1; 0.0.0.0 means "all interfaces", so use loopback),
    /// WHISPER_PORT (default 8083), TRANSCRIPTION_SERVICE_TOKEN.
    public static func from(env: [String: String]) -> WhisperEndpoint {
        var host = env["WHISPER_HOST"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if host.isEmpty || host == "0.0.0.0" { host = "127.0.0.1" }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }   // IPv6 literal
        var port = env["WHISPER_PORT"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if Int(port) == nil { port = "8083" }
        let url = URL(string: "http://\(host):\(port)") ?? URL(string: "http://127.0.0.1:8083")!
        return WhisperEndpoint(baseURL: url, token: env["TRANSCRIPTION_SERVICE_TOKEN"] ?? "")
    }

    public var healthURL: URL { baseURL.appendingPathComponent("health") }
    public var transcriptionsURL: URL { baseURL.appendingPathComponent("v1/audio/transcriptions") }
}

/// A multipart/form-data body.
public struct MultipartForm: Sendable {
    public let boundary: String
    public private(set) var body = Data()

    public init(boundary: String = "vexa-\(UUID().uuidString)") { self.boundary = boundary }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                          + "Content-Type: \(mimeType)\r\n\r\n").utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// The body with the closing boundary.
    public var finished: Data { body + Data("--\(boundary)--\r\n".utf8) }
}

public enum LocalTranscript {
    /// Languages offered in the recorder. nil = let Whisper detect it.
    public static let languages: [(code: String?, name: String)] = [
        ("en", "English"), (nil, "Detect automatically"),
        ("nl", "Dutch"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("es", "Spanish"), ("pl", "Polish"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"),
        ("fi", "Finnish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
    ]

    public static func languageName(_ code: String?) -> String {
        languages.first { $0.code == code }?.name ?? (code ?? "Detect automatically")
    }

    /// Phrases Whisper is known to invent for silence or noise (from video subtitles).
    static let hallucinations: Set<String> = [
        "thanks for watching", "thank you for watching", "thanks for watching!", "please subscribe",
        "subtitles by the amara.org community", "like and subscribe", "see you in the next video",
        "you", "bye.", "bye",
    ]

    static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// True for segments Whisper most likely made up: empty text, a known filler phrase, or
    /// Whisper's own "no speech" verdict (no_speech_prob > 0.6 with a low average log-probability).
    public static func isLikelyHallucination(_ s: WhisperVerboseResponse.Segment) -> Bool {
        let text = normalized(s.text)
        if text.isEmpty { return true }
        if hallucinations.contains(text) { return true }
        if let p = s.noSpeechProb, p > 0.6, (s.avgLogprob ?? -2) < -1 { return true }
        return false
    }

    /// Turns a Whisper reply for a chunk that started at `chunkStart` into lines with clock times.
    public static func lines(from response: WhisperVerboseResponse, chunkStart: Date, chunkDuration: TimeInterval? = nil,
                             lane: RecordingLane, speaker: String) -> [TranscriptLine] {
        var segments = response.segments
        // A reply with text but no segments (other response formats): one line for the chunk.
        if segments.isEmpty, !normalized(response.text).isEmpty {
            segments = [.init(start: 0, end: chunkDuration ?? 0, text: response.text)]
        }
        return segments.compactMap { s in
            guard !isLikelyHallucination(s) else { return nil }
            var start = max(0, s.start)
            var end = max(start, s.end)
            if let d = chunkDuration { start = min(start, d); end = min(end, d) }
            return TranscriptLine(lane: lane, speaker: speaker, start: chunkStart.addingTimeInterval(start),
                                  end: chunkStart.addingTimeInterval(end),
                                  text: s.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// "Recording 2026-11-18 14:05"
    public static func title(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "Recording \(format(startedAt, "yyyy-MM-dd HH:mm", timeZone))"
    }

    /// "2026-11-18 1405 Recording.md" — sorts with the other transcripts in the folder.
    public static func fileName(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(format(startedAt, "yyyy-MM-dd HHmm", timeZone)) Recording.md"
    }

    /// `name` in `directory`, or "name 2", "name 3"… when it is taken.
    public static func uniqueURL(in directory: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(fileName)
        guard exists(first) else { return first }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !exists(url) { return url }
            n += 1
        }
    }

    public struct Header: Sendable, Equatable {
        public var title: String
        public var startedAt: Date
        /// Nil while still recording.
        public var endedAt: Date?
        /// The lanes recorded, with the name used for each.
        public var speakers: [(lane: RecordingLane, name: String)]
        public var languageCode: String?
        public var model: String?
        /// Chunks Whisper could not transcribe (their audio is kept next to the transcript).
        public var failedChunks: Int
        public var failedAudioFolder: String?

        public init(title: String, startedAt: Date, endedAt: Date? = nil,
                    speakers: [(lane: RecordingLane, name: String)], languageCode: String?,
                    model: String? = nil, failedChunks: Int = 0, failedAudioFolder: String? = nil) {
            self.title = title; self.startedAt = startedAt; self.endedAt = endedAt; self.speakers = speakers
            self.languageCode = languageCode; self.model = model
            self.failedChunks = failedChunks; self.failedAudioFolder = failedAudioFolder
        }

        public static func == (a: Header, b: Header) -> Bool {
            a.title == b.title && a.startedAt == b.startedAt && a.endedAt == b.endedAt
                && a.speakers.map(\.lane) == b.speakers.map(\.lane) && a.speakers.map(\.name) == b.speakers.map(\.name)
                && a.languageCode == b.languageCode && a.model == b.model
                && a.failedChunks == b.failedChunks && a.failedAudioFolder == b.failedAudioFolder
        }
    }

    public static let noSpeechMarker = "_No speech transcribed yet._"

    /// Markdown with both lanes merged in time order. Consecutive lines from the same speaker
    /// form one paragraph, unless more than `paragraphGap` seconds pass between them.
    public static func markdown(header: Header, lines: [TranscriptLine], timeZone: TimeZone = .current,
                                paragraphGap: TimeInterval = 60) -> String {
        let started = DateFormatter()
        started.dateStyle = .full
        started.timeStyle = .short
        started.timeZone = timeZone

        var out = "# \(header.title)\n\n"
        out += "- **Started:** \(started.string(from: header.startedAt))\n"
        if let end = header.endedAt {
            let minutes = max(0, Int((end.timeIntervalSince(header.startedAt) / 60).rounded()))
            out += "- **Ended:** \(format(end, "HH:mm", timeZone)) (\(minutes) min)\n"
        } else {
            out += "- **Status:** recording…\n"
        }
        let who = header.speakers.map { "\($0.name) (\($0.lane.displayName.lowercased()))" }
        if !who.isEmpty { out += "- **Speakers:** \(who.joined(separator: ", "))\n" }
        out += "- **Language:** \(languageName(header.languageCode))\n"
        if let model = header.model { out += "- **Model:** \(model)\n" }
        out += "- **Recorded with:** Vexa Local recorder (Whisper only, no Vexa)\n"
        out += "\n---\n\n"

        let ordered = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .sorted { a, b in a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset }
            .map(\.element)
        if ordered.isEmpty {
            out += noSpeechMarker + "\n"
        } else {
            var speaker: String?
            var lastEnd = Date.distantPast
            var paragraph: [String] = []
            func flush() {
                if !paragraph.isEmpty { out += paragraph.joined(separator: " ") + "\n\n" }
                paragraph = []
            }
            for line in ordered {
                if line.speaker != speaker || line.start.timeIntervalSince(lastEnd) > paragraphGap {
                    flush()
                    out += "**\(line.speaker)** · \(format(line.start, "HH:mm:ss", timeZone))\n"
                    speaker = line.speaker
                }
                paragraph.append(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                lastEnd = max(lastEnd, line.end)
            }
            flush()
        }
        if header.failedChunks > 0 {
            out += "---\n\n_\(header.failedChunks) piece\(header.failedChunks == 1 ? "" : "s") of audio could not be transcribed"
            if let folder = header.failedAudioFolder { out += "; the audio is saved in \"\(folder)\"" }
            out += "._\n"
        }
        return out
    }

    static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        f.timeZone = timeZone
        return f.string(from: date)
    }
}
