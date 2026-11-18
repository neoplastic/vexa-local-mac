import CryptoKit
import Foundation

public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case googleMeet = "google_meet"
    case teams = "teams"
    case zoom = "zoom"

    public var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        }
    }

    /// How Vexa captures a meeting on this platform.
    public enum CaptureMethod: String, Codable, Sendable {
        /// The app sends a Vexa bot into the meeting.
        case bot
        /// The user joins in Chrome and the Vexa browser extension streams the tab audio.
        case browserExtension
    }

    /// The recommended route. The extension works on every platform (Teams through
    /// patches/0002) and needs no lobby admission, so it is always the first choice.
    public var captureMethod: CaptureMethod { .browserExtension }

    /// Whether a Vexa bot is offered as a backup. Google and Zoom refuse bots.
    public var botAvailable: Bool { self == .teams }

    /// Plain-words explanation of how this platform is captured.
    public var captureExplanation: String {
        let base = "\(displayName) meetings are transcribed with the Vexa browser extension. Join the meeting yourself in Chrome."
        if botAvailable {
            return base + " A Vexa bot also works as a backup; someone may need to admit it from the lobby."
        }
        return base + " Vexa's bot can't be used here, because \(Self.botRefusalSubject(self)) refuses it."
    }

    /// Short note on why bots are not offered for this platform, or nil when they are.
    public var botRefusalNote: String? {
        botAvailable ? nil : "\(Self.botRefusalSubject(self)) refuses Vexa's bot (Vexa issues #2059 and #938)."
    }

    /// Upstream issues explaining the bot refusal (Google Meet #2059, Zoom #938), if any.
    public var botRefusalIssueURLs: [URL] {
        switch self {
        case .googleMeet: return [URL(string: "https://github.com/Vexa-ai/vexa/issues/2059")!]
        case .zoom: return [URL(string: "https://github.com/Vexa-ai/vexa/issues/938")!]
        case .teams: return []
        }
    }

    private static func botRefusalSubject(_ p: MeetingPlatform) -> String {
        p == .googleMeet ? "Google" : "Zoom"
    }
}

/// A meeting reference worked out from whatever the user pasted.
public struct ParsedMeeting: Equatable, Sendable {
    public var platform: MeetingPlatform
    public var nativeMeetingId: String
    /// Teams or Zoom passcode found in the link or invite text.
    public var passcode: String?
    /// Link passed to the bot as `meeting_url`: older Teams `/l/meetup-join/` links,
    /// and every Zoom link (Vexa needs the full Zoom link to join).
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

/// Detects Google Meet, Microsoft Teams and Zoom meetings from links, codes, IDs or
/// pasted invite text. Mirrors the rules in Vexa's own link parsers
/// (meeting-api collector/meeting_link.py and mcp link_parser.py) so the API accepts what we send.
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
        // Zoom: only ever from a Zoom link, never from a bare number (bare numbers stay Teams).
        if !input.contains(where: \.isWhitespace) {
            if let z = parseZoomURL(input, allowHostedDomain: true) { return z }
        } else if let z = firstZoomLinkInText(input) {
            return z
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

    // MARK: Zoom

    /// Zoom's join paths on a non-Zoom hostname (white-label front doors such as
    /// zoom-lfx.platform.linuxfoundation.org/meeting/<id>?password=...). Same shape as Vexa's
    /// `_ZOOM_HOSTED_PATH`: /meeting/<id> or /j/<id>, 10-11 digits, nothing after.
    static let zoomHostedPath = #"^/(?:meeting|j)/(\d{10,11})/?$"#

    /// Why a link that is clearly Zoom can't be used, or nil. Lets the UI explain the refusal
    /// instead of just saying "not recognised".
    public static func zoomRejection(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.contains(where: \.isWhitespace), let found = urlParts(input) else { return nil }
        let (comps, host) = found
        if isZoomEventsHost(host) {
            return "Zoom Events links aren't supported. Each attendee gets a personal join link that a bot can't use."
        }
        guard isZoomHost(host) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        if parts.first?.lowercased() == "my" {
            return "Zoom personal room links (/my/...) aren't supported. Ask the host for the meeting's /j/ link."
        }
        if parts.contains(where: { $0.lowercased() == "register" }) {
            return "Zoom registration links aren't supported. Register first, then paste the join link you are sent."
        }
        if parseZoomURL(input, allowHostedDomain: false) == nil {
            return "Unsupported Zoom link. Use the meeting link, for example zoom.us/j/12345678901?pwd=..."
        }
        return nil
    }

    /// Parses one Zoom meeting link. The scheme is optional; the link sent to Vexa is always
    /// https (Vexa refuses any other scheme for meeting_url).
    static func parseZoomURL(_ input: String, allowHostedDomain: Bool) -> ParsedMeeting? {
        guard let found = urlParts(input) else { return nil }
        var comps = found.0
        let host = found.1
        comps.scheme = "https"
        let query = comps.queryItems ?? []
        func param(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let passcode = param("pwd") ?? param("password")

        if isZoomEventsHost(host) { return nil }
        if isZoomHost(host) {
            let parts = comps.path.split(separator: "/").map(String.init)
            let lower = parts.map { $0.lowercased() }
            var id = ""
            if parts.count >= 2, ["j", "w"].contains(lower[0]) {
                id = parts[1]                                  // /j/<id>, /w/<id>
            } else if parts.count >= 3, lower[0] == "wc", lower[1] == "join" {
                id = parts[2]                                  // /wc/join/<id>
            } else if parts.count >= 3, lower[0] == "wc", lower[2] == "join" {
                id = parts[1]                                  // /wc/<id>/join (app.zoom.us web client)
            }
            guard match(#"^\d{9,11}$"#, id) != nil else { return nil }
            if lower[0] == "w" {
                // The bot only rewrites /j/<id> on zoom.us hosts into its web-client URL;
                // a /w/ link would make it fail. Same meeting, same host, same query.
                comps.path = "/j/" + id
            }
            guard let url = comps.string else { return nil }
            return ParsedMeeting(platform: .zoom, nativeMeetingId: id, passcode: passcode, meetingURL: url)
        }
        // Zoom behind someone else's hostname: matched on Zoom's path shape plus a passcode,
        // never on the hostname. Not used when scanning free text (same as Vexa).
        guard allowHostedDomain, passcode != nil, isPlausiblePublicHost(host),
              !hostIs(host, "teams.microsoft.com"), !hostIs(host, "teams.live.com"),
              !hostIs(host, "meet.google.com"), host != "meet.jit.si",
              let m = match(zoomHostedPath, comps.path), let url = comps.string else { return nil }
        return ParsedMeeting(platform: .zoom, nativeMeetingId: m[1], passcode: passcode, meetingURL: url,
                             note: "\(host) isn't a Zoom address. It was read as a Zoom meeting from the link's shape.")
    }

    /// First Zoom link in pasted invite text (e.g. Zoom's "Join Zoom Meeting" block).
    static func firstZoomLinkInText(_ text: String) -> ParsedMeeting? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range)
            while let last = url.last, ").,;".contains(last) { url.removeLast() }
            if let z = parseZoomURL(url, allowHostedDomain: false) { return z }
        }
        return nil
    }

    static func urlParts(_ input: String) -> (URLComponents, String)? {
        let lower = input.lowercased()
        let text = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? input : "https://" + input
        guard let comps = URLComponents(string: text), let host = comps.host?.lowercased(), !host.isEmpty
        else { return nil }
        return (comps, host)
    }

    /// Exact host or a dot-separated subdomain of it; never a substring test.
    static func hostIs(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// zoom.us and zoomgov.com, apex or any subdomain (us02web.zoom.us, acme.zoom.us).
    static func isZoomHost(_ host: String) -> Bool {
        hostIs(host, "zoom.us") || hostIs(host, "zoomgov.com")
    }

    static func isZoomEventsHost(_ host: String) -> Bool {
        hostIs(host, "events.zoom.us") || host == "ev.zoom.com"
    }

    /// Vexa refuses meeting_url hosts that are localhost or IP literals.
    static func isPlausiblePublicHost(_ host: String) -> Bool {
        host.contains(".") && host.contains(where: \.isLetter) && !host.contains(":")
            && host != "localhost" && !host.hasSuffix(".localhost")
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
