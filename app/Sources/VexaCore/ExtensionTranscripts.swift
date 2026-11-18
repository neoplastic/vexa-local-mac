import Foundation

/// Where a transcript came from.
public enum TranscriptSource: String, Codable, Sendable {
    case bot
    case browserExtension

    public var label: String {
        switch self {
        case .bot: return "Bot"
        case .browserExtension: return "Browser extension"
        }
    }
}

/// One meeting reported by the desktop host (GET /bots). The host keeps these in memory only.
public struct DesktopMeeting: Decodable, Equatable, Sendable {
    public var id: Int?
    public var platform: String
    public var nativeMeetingId: String
    public var status: String?
    public var startTime: String?
    /// Nil when the host did not include segments; fetch the transcript separately then.
    public var segments: [TranscriptSegment]?

    enum CodingKeys: String, CodingKey {
        case id, platform, status, segments
        case nativeMeetingId = "native_meeting_id"
        case startTime = "start_time"
    }

    public init(id: Int? = nil, platform: String, nativeMeetingId: String, status: String? = nil,
                startTime: String? = nil, segments: [TranscriptSegment]? = nil) {
        self.id = id; self.platform = platform; self.nativeMeetingId = nativeMeetingId
        self.status = status; self.startTime = startTime; self.segments = segments
    }

    public var meetingPlatform: MeetingPlatform? { MeetingPlatform(rawValue: platform) }
    public var startDate: Date? { startTime.flatMap(TranscriptFormatter.parseISO) }
    /// "active" while the extension is still streaming; "completed" afterwards.
    public var isActive: Bool { status == "active" }
}

public struct DesktopMeetingList: Decodable, Sendable {
    public var meetings: [DesktopMeeting]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey { case meetings, hasMore = "has_more" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetings = try c.decodeIfPresent([DesktopMeeting].self, forKey: .meetings) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// Rules for turning the desktop host's meeting list into saved transcripts.
public enum ExtensionSync {
    /// Seconds of difference in start time still treated as the same meeting.
    public static let sameMeetingTolerance: TimeInterval = 2

    /// Whether this host meeting should become (or stay) a saved transcript.
    /// Skips voice notes, YouTube and other non-meeting platforms, the extension's own
    /// `selftest-` probes, and meetings that never produced any speech.
    public static func shouldTrack(_ m: DesktopMeeting, segmentsKnown: [TranscriptSegment]? = nil,
                                   alreadyTracked: Bool = false) -> Bool {
        guard m.meetingPlatform != nil, !m.nativeMeetingId.isEmpty,
              !m.nativeMeetingId.hasPrefix("selftest-") else { return false }
        if alreadyTracked || m.isActive { return true }
        let segs = segmentsKnown ?? m.segments ?? []
        return segs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The host restarts with an empty memory and may later reuse a meeting id for a new call.
    /// Same platform + id + start time means the same meeting; a different start time is a new one.
    public static func isSameMeeting(storedStart: Date, hostStart: Date?) -> Bool {
        guard let hostStart else { return true }   // no start time: assume the same meeting
        return abs(storedStart.timeIntervalSince(hostStart)) <= sameMeetingTolerance
    }

    /// Never replace a transcript that has speech with one that has less (host restarted or
    /// returned a partial list). Equal or larger counts are written.
    public static func shouldWrite(newSegmentCount: Int, savedSegmentCount: Int) -> Bool {
        newSegmentCount >= savedSegmentCount
    }

    /// Identifies one host meeting so a removed entry is not added back on the next poll.
    public static func dismissalKey(platform: MeetingPlatform, meetingId: String, start: Date?) -> String {
        "\(platform.rawValue)|\(meetingId)|\(start.map { String(Int($0.timeIntervalSince1970)) } ?? "")"
    }

    /// Percent-encodes a native meeting id for use as one URL path segment.
    /// Teams thread ids contain ":" and "@".
    public static func encodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }
}

/// A row from the gateway's GET /meetings, enough to explain why a bot failed.
public struct GatewayMeetingRow: Decodable, Equatable, Sendable {
    public var id: Int
    public var platform: String?
    public var nativeMeetingId: String?
    public var status: String?
    public var reason: String?
    public var completionReason: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, status, data
        case nativeMeetingId = "native_meeting_id"
        case platformSpecificId = "platform_specific_id"
    }
    enum DataKeys: String, CodingKey { case reason, completionReason = "completion_reason" }

    public init(id: Int, platform: String?, nativeMeetingId: String?, status: String? = nil,
                reason: String? = nil, completionReason: String? = nil) {
        self.id = id; self.platform = platform; self.nativeMeetingId = nativeMeetingId
        self.status = status; self.reason = reason; self.completionReason = completionReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        nativeMeetingId = try c.decodeIfPresent(String.self, forKey: .nativeMeetingId)
            ?? c.decodeIfPresent(String.self, forKey: .platformSpecificId)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        if let d = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            reason = (try? d.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            completionReason = (try? d.decodeIfPresent(String.self, forKey: .completionReason)) ?? nil
        }
    }
}

/// Plain-words reasons for a bot that ended `failed`.
public enum BotFailure {
    /// The newest row (highest id) for this platform and meeting id.
    public static func latestRow(in rows: [GatewayMeetingRow], platform: MeetingPlatform,
                                 meetingId: String) -> GatewayMeetingRow? {
        rows.filter { $0.platform == platform.rawValue && $0.nativeMeetingId == meetingId }
            .max { $0.id < $1.id }
    }

    /// Explains a failure in plain words. Falls back to the raw reason (shortened), then to nil.
    public static func describe(reason: String?, completionReason: String?, maxLength: Int = 120) -> String? {
        let reason = clean(reason)
        let completion = clean(completionReason)
        if let reason {
            let r = reason.lowercased()
            if r.contains("zoom_requires_rtms") { return "Zoom blocks automated bots in this meeting" }
            if r.contains("never_reached_lobby") || r.contains("workspace.google.com") {
                return "Google refused the bot"
            }
            if let known = known[r] { return known }
        }
        if let completion, let label = known[completion.lowercased()] {
            // A generic label such as join_failure is less useful than a raw reason with detail.
            if genericCompletions.contains(completion.lowercased()), let reason {
                return truncate(reason, maxLength)
            }
            return label
        }
        if let reason { return truncate(reason, maxLength) }
        if let completion { return truncate(completion, maxLength) }
        return nil
    }

    static let genericCompletions: Set<String> = ["join_failure", "validation_error"]

    static let known: [String: String] = [
        "stopped": "Stopped",
        "stopped_while_joining": "Stopped while joining",
        "left_alone": "Left because nobody else was in the meeting",
        "startup_alone": "Left because nobody joined",
        "evicted": "Removed from the meeting",
        "awaiting_admission_timeout": "Nobody let the bot in from the lobby",
        "awaiting_admission_rejected": "The host declined the bot",
        "join_failure": "Could not join the meeting",
        "auth_session_missing": "The bot's Google sign-in is missing",
        "validation_error": "Vexa rejected the meeting details",
        "max_bot_time_exceeded": "Reached the maximum bot time",
        "navigation_failure": "Could not open the meeting page",
        "never_reached_lobby": "Google refused the bot",
        "zoom_requires_rtms": "Zoom blocks automated bots in this meeting",
    ]

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              t.lowercased() != "none", t.lowercased() != "null" else { return nil }
        return t
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
