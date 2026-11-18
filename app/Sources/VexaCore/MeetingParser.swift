import CryptoKit
import Foundation

public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case googleMeet = "google_meet"
    case teams = "teams"

    public var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        }
    }
}

/// A meeting reference worked out from whatever the user pasted.
public struct ParsedMeeting: Equatable, Sendable {
    public var platform: MeetingPlatform
    public var nativeMeetingId: String
    /// Teams passcode found in the link or invite text.
    public var passcode: String?
    /// Older Teams `/l/meetup-join/` links are passed to the bot as-is.
    public var meetingURL: String?
    /// Work/school Teams host (e.g. teams.microsoft.com). Nil means teams.live.com.
    public var teamsBaseHost: String?
    /// True when only a bare Teams meeting ID was given, so the host is unknown.
    public var needsTeamsHost: Bool = false
    public var note: String?

    public init(platform: MeetingPlatform, nativeMeetingId: String, passcode: String? = nil,
                meetingURL: String? = nil, teamsBaseHost: String? = nil,
                needsTeamsHost: Bool = false, note: String? = nil) {
        self.platform = platform
        self.nativeMeetingId = nativeMeetingId
        self.passcode = passcode
        self.meetingURL = meetingURL
        self.teamsBaseHost = teamsBaseHost
        self.needsTeamsHost = needsTeamsHost
        self.note = note
    }
}

/// Detects Google Meet and Microsoft Teams meetings from links, codes, IDs or
/// pasted invite text. Mirrors the rules in Vexa's own link parser
/// (services/mcp/main.py) so the API accepts what we send.
public enum MeetingParser {
    // meet.google.com/abc-defg-hij (with or without scheme, extra path/query ignored)
    static let meetURL = #"^(?:https?://)?meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#].*)?$"#
    // abc-defg-hij, or the same ten letters without dashes
    static let meetCode = #"^([a-z]{3})-?([a-z]{4})-?([a-z]{3})$"#
    // Older Teams links: teams.microsoft.com/l/meetup-join/...
    static let teamsLegacy = #"^https?://(?:[a-z0-9-]+\.)*teams\.microsoft\.(?:com|us)/l/meetup-join/"#
    // teams.live.com/meet/<id>?p=<pass>, teams.microsoft.com/meet/<id>?p=<pass>,
    // and the v2 deep link teams.microsoft.com/v2/?meetingjoin=true#/meet/<id>?p=<pass>
    static let teamsShort = #"^(?:https?://)?((?:[a-z0-9-]+\.)*teams\.(?:live\.com|microsoft\.com|microsoft\.us))/(?:v2/?(?:\?[^#]*)?#/)?meet/(\d{10,15})/?(?:\?(?:[^#]*&)?p=([A-Za-z0-9]+))?"#
    // "Meeting ID: 123 456 789 012" in pasted invite text
    static let inviteId = #"meeting\s*id\s*:?\s*(\d[\d ]{8,22}\d)"#
    static let invitePasscode = #"pass(?:code|word)\s*:?\s*([A-Za-z0-9]{4,20})"#
    // A bare Teams meeting ID, spaces allowed: 123 456 789 012
    static let bareTeamsId = #"^\d{10,15}$"#

    public static func parse(_ raw: String) -> ParsedMeeting? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let m = match(meetURL, input) {
            return ParsedMeeting(platform: .googleMeet, nativeMeetingId: m[1].lowercased())
        }
        if let m = match(meetCode, input) {
            return ParsedMeeting(platform: .googleMeet,
                                 nativeMeetingId: "\(m[1])-\(m[2])-\(m[3])".lowercased())
        }
        if match(teamsLegacy, input) != nil {
            // Same stable ID Vexa's MCP parser uses: first 16 hex chars of SHA-256(url).
            let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            return ParsedMeeting(platform: .teams, nativeMeetingId: String(digest.prefix(16)),
                                 meetingURL: input,
                                 note: "Older-style Teams link. The full link is passed to the bot.")
        }
        if let m = match(teamsShort, input) {
            let host = m[1].lowercased()
            return ParsedMeeting(platform: .teams, nativeMeetingId: m[2],
                                 passcode: m[3].isEmpty ? nil : m[3],
                                 teamsBaseHost: host.hasSuffix("teams.live.com") ? nil : host)
        }
        if let m = match(inviteId, input) {
            let digits = m[1].filter(\.isNumber)
            if (10...15).contains(digits.count) {
                let pass = match(invitePasscode, input)?[1]
                return ParsedMeeting(platform: .teams, nativeMeetingId: digits, passcode: pass,
                                     needsTeamsHost: true)
            }
        }
        let compact = input.replacingOccurrences(of: " ", with: "")
        if match(bareTeamsId, compact) != nil {
            return ParsedMeeting(platform: .teams, nativeMeetingId: compact, needsTeamsHost: true)
        }
        return nil
    }

    /// Teams passcodes must be 4-20 letters or digits (Vexa API rule).
    public static func isValidTeamsPasscode(_ s: String) -> Bool {
        match(#"^[A-Za-z0-9]{4,20}$"#, s, caseInsensitive: false) != nil
    }

    /// Returns all capture groups (index 0 = whole match); missing groups are "".
    static func match(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
