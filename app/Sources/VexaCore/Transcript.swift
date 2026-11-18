import Foundation

/// One segment from GET /transcripts/{platform}/{id}.
public struct TranscriptSegment: Decodable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var language: String?
    public var completed: Bool?
    public var absoluteStartTime: String?

    enum CodingKeys: String, CodingKey {
        case start, end, start_time, end_time, text, speaker, language, completed, absolute_start_time
    }

    public init(start: Double, end: Double, text: String, speaker: String? = nil,
                language: String? = nil, completed: Bool? = nil, absoluteStartTime: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker
        self.language = language; self.completed = completed; self.absoluteStartTime = absoluteStartTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The API serialises by alias ("start"/"end"); accept the field names too.
        start = try c.decodeIfPresent(Double.self, forKey: .start)
            ?? c.decodeIfPresent(Double.self, forKey: .start_time) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end)
            ?? c.decodeIfPresent(Double.self, forKey: .end_time) ?? start
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed)
        absoluteStartTime = try c.decodeIfPresent(String.self, forKey: .absolute_start_time)
    }
}

public struct TranscriptResponse: Decodable, Sendable {
    public var id: Int?
    public var platform: String?
    public var native_meeting_id: String?
    public var status: String?
    public var start_time: String?
    public var end_time: String?
    public var segments: [TranscriptSegment]
}

public enum TranscriptFormatter {
    /// Statuses after which the bot will not produce more transcript.
    public static let terminalStatuses: Set<String> = ["completed", "failed"]

    public struct Header: Sendable {
        public var platform: MeetingPlatform
        public var meetingId: String
        public var startedAt: Date
        public var status: String
        public var model: String?
        public init(platform: MeetingPlatform, meetingId: String, startedAt: Date, status: String, model: String? = nil) {
            self.platform = platform; self.meetingId = meetingId; self.startedAt = startedAt
            self.status = status; self.model = model
        }
    }

    /// Renders a Markdown transcript, merging consecutive lines from the same speaker.
    public static func markdown(header: Header, segments: [TranscriptSegment], timeZone: TimeZone = .current) -> String {
        let started = DateFormatter()
        started.dateStyle = .full
        started.timeStyle = .short
        started.timeZone = timeZone

        var out = "# \(header.platform.displayName) transcript\n\n"
        out += "- **Meeting:** \(header.meetingId)\n"
        out += "- **Started:** \(started.string(from: header.startedAt))\n"
        out += "- **Status:** \(header.status)\n"
        if let model = header.model { out += "- **Model:** \(model)\n" }
        out += "\n---\n\n"

        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if let a = lhs.absoluteStartTime, let b = rhs.absoluteStartTime, a != b { return a < b }
                return lhs.start < rhs.start
            }
        if ordered.isEmpty { return out + "_No speech transcribed yet._\n" }

        var currentSpeaker: String?
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out += paragraph.joined(separator: " ") + "\n\n" }
            paragraph = []
        }
        for seg in ordered {
            let speaker = seg.speaker?.isEmpty == false ? seg.speaker! : "Unknown speaker"
            if speaker != currentSpeaker {
                flush()
                out += "**\(speaker)** · \(timestamp(seg, timeZone: timeZone))\n"
                currentSpeaker = speaker
            }
            paragraph.append(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        flush()
        return out
    }

    /// Local clock time when the API gives an absolute time, else offset from the start.
    static func timestamp(_ seg: TranscriptSegment, timeZone: TimeZone) -> String {
        if let abs = seg.absoluteStartTime, let date = parseISO(abs) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            f.timeZone = timeZone
            return f.string(from: date)
        }
        let t = Int(seg.start.rounded(.down))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func parseISO(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        if let d = withFrac.date(from: s) ?? plain.date(from: s) { return d }
        // Vexa sometimes omits the zone; treat it as UTC.
        if !s.hasSuffix("Z"), !s.contains("+") { return withFrac.date(from: s + "Z") ?? plain.date(from: s + "Z") }
        return nil
    }

    /// File name like "2026-11-18 1430 Google Meet abc-defg-hij.md".
    public static func fileName(platform: MeetingPlatform, meetingId: String, startedAt: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let safeId = meetingId.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(f.string(from: startedAt)) \(platform.displayName) \(safeId).md"
    }
}
