import Foundation
import VexaCore

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status > 0 ? "\(message) (HTTP \(status))" : message }
}

/// Talks to Vexa's API gateway (user API key) and admin API (admin token).
struct VexaClient {
    var gateway: URL
    var admin: URL
    var apiKey: String
    var adminToken: String
    /// Injectable for tests; production uses the shared session.
    var session: URLSession = .shared

    struct BotRequest: Encodable {
        var platform: String
        var native_meeting_id: String
        var bot_name: String?
        var language: String?
        var passcode: String?
        var meeting_url: String?
        var teams_base_host: String?
    }

    struct MeetingResponse: Decodable {
        var id: Int
        var status: String
    }

    func createBot(_ req: BotRequest) async throws -> MeetingResponse {
        try await send("POST", gateway.appendingPathComponent("bots"), body: req, headers: ["X-API-Key": apiKey])
    }

    func stopBot(platform: MeetingPlatform, meetingId: String) async throws {
        let url = gateway.appendingPathComponent("bots/\(platform.rawValue)/\(meetingId)")
        let _: EmptyResponse = try await send("DELETE", url, body: Optional<String>.none, headers: ["X-API-Key": apiKey])
    }

    struct RunningBot: Decodable {
        var platform: String?
        var native_meeting_id: String?
        var created_at: String?
    }

    func runningBots() async throws -> [RunningBot] {
        struct Response: Decodable { var running_bots: [RunningBot] }
        let r: Response = try await send("GET", gateway.appendingPathComponent("bots/status"),
                                         body: Optional<String>.none, headers: ["X-API-Key": apiKey])
        return r.running_bots
    }

    func transcript(platform: MeetingPlatform, meetingId: String) async throws -> TranscriptResponse {
        let url = gateway.appendingPathComponent("transcripts/\(platform.rawValue)/\(meetingId)")
        return try await send("GET", url, body: Optional<String>.none, headers: ["X-API-Key": apiKey])
    }

    /// Meeting rows (newest data included), used to find out why a bot failed.
    func meetings() async throws -> [GatewayMeetingRow] {
        struct Lossy: Decodable {
            var row: GatewayMeetingRow?
            init(from decoder: Decoder) throws { row = try? GatewayMeetingRow(from: decoder) }
        }
        struct Response: Decodable { var meetings: [Lossy] }
        let r: Response = try await send("GET", gateway.appendingPathComponent("meetings"),
                                         body: Optional<String>.none, headers: ["X-API-Key": apiKey])
        return r.meetings.compactMap(\.row)
    }

    /// Creates the user (or returns the existing one) and issues a new API key.
    func createAPIKey(email: String) async throws -> String {
        struct NewUser: Encodable { var email: String; var name: String; var max_concurrent_bots: Int }
        struct User: Decodable { var id: Int }
        struct Token: Decodable { var token: String }
        let headers = ["X-Admin-API-Key": adminToken]
        let user: User = try await send("POST", admin.appendingPathComponent("admin/users"),
                                        body: NewUser(email: email, name: "Vexa Local app", max_concurrent_bots: 3),
                                        headers: headers)
        // Scopes: bot = send/stop bots, tx = read transcripts.
        var comps = URLComponents(url: admin.appendingPathComponent("admin/users/\(user.id)/tokens"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "scopes", value: "bot,tx")]
        let token: Token = try await send("POST", comps.url!, body: Optional<String>.none, headers: headers)
        return token.token
    }

    // MARK: - Plumbing

    struct EmptyResponse: Decodable {}

    private func send<Body: Encodable, Out: Decodable>(_ method: String, _ url: URL, body: Body?,
                                                       headers: [String: String]) async throws -> Out {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError(status: 0, message: "Cannot reach Vexa at \(url.host ?? "localhost"):\(url.port ?? 0). Is the stack running?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: Self.detail(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        if Out.self == EmptyResponse.self || data.isEmpty { return try JSONDecoder().decode(Out.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(Out.self, from: data)
    }

    /// FastAPI errors look like {"detail": "..."} or {"detail": [{"msg": "..."}]}.
    static func detail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        }
        if let s = obj["detail"] as? String { return s }
        if let arr = obj["detail"] as? [[String: Any]] {
            return arr.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        return nil
    }
}
