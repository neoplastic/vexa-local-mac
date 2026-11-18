import Foundation
import VexaCore

/// Talks to the Vexa desktop host (started by scripts/desktop.sh), which receives the
/// browser extension's audio and transcribes it. It keeps its meetings in memory only.
struct DesktopHostClient {
    static let defaultPort = 8056

    var baseURL: URL = URL(string: "http://localhost:\(DesktopHostClient.defaultPort)")!
    /// Injectable for tests; production uses the shared session.
    var session: URLSession = .shared

    /// All meetings the host knows about, with their segments when it includes them.
    func meetings() async throws -> [DesktopMeeting] {
        let data = try await get(baseURL.appendingPathComponent("bots"))
        return try JSONDecoder().decode(DesktopMeetingList.self, from: data).meetings
    }

    /// One meeting's transcript. Segment times are absolute Unix seconds.
    func transcript(platform: String, nativeMeetingId: String) async throws -> TranscriptResponse {
        let id = ExtensionSync.encodePathSegment(nativeMeetingId)
        guard let url = URL(string: "\(baseURL.absoluteString)/transcripts/\(ExtensionSync.encodePathSegment(platform))/\(id)")
        else { throw APIError(status: 0, message: "Bad meeting id") }
        return try JSONDecoder().decode(TranscriptResponse.self, from: try await get(url))
    }

    /// True when GET /bots answers successfully.
    func isUp() async -> Bool {
        (try? await get(baseURL.appendingPathComponent("bots"), timeout: 2)) != nil
    }

    private func get(_ url: URL, timeout: TimeInterval = 10) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }
}
