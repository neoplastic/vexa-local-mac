import XCTest
import VexaCore
@testable import VexaLocal

/// Stubs every request on a private URLSession; nothing touches the network.
final class StubURLProtocol: URLProtocol {
    struct Stub { var status: Int; var body: Data; var error: Error? }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            body = d
        }
        Self.requests.append((request, body))
        let stub = Self.handler?(request) ?? Stub(status: 200, body: Data("{}".utf8), error: nil)
        if let e = stub.error { client?.urlProtocol(self, didFailWithError: e); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VexaClientTests: XCTestCase {
    var client: VexaClient!

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        client = VexaClient(gateway: URL(string: "http://localhost:18056")!,
                            admin: URL(string: "http://localhost:18057")!,
                            apiKey: "user-key", adminToken: "admin-tok",
                            session: URLSession(configuration: cfg))
    }

    private func json(_ s: String, status: Int = 200) -> StubURLProtocol.Stub {
        .init(status: status, body: Data(s.utf8), error: nil)
    }

    func testCreateBotRequest() async throws {
        StubURLProtocol.handler = { _ in self.json(#"{"id": 7, "status": "requested"}"#) }
        let r = try await client.createBot(.init(platform: "google_meet", native_meeting_id: "abc-defg-hij",
                                                 bot_name: "Bot", language: nil, passcode: nil))
        XCTAssertEqual(r.id, 7)
        XCTAssertEqual(r.status, "requested")
        let (req, body) = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:18056/bots")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "user-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(obj["platform"] as? String, "google_meet")
        XCTAssertEqual(obj["native_meeting_id"] as? String, "abc-defg-hij")
        XCTAssertEqual(obj["bot_name"] as? String, "Bot")
    }

    func testStopBotAcceptsEmptyBody() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(), error: nil) }
        try await client.stopBot(platform: .googleMeet, meetingId: "abc-defg-hij")
        let req = try XCTUnwrap(StubURLProtocol.requests.first?.request)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url?.path, "/bots/google_meet/abc-defg-hij")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "user-key")
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Type"))
    }

    func testStopBotAccepts204() async throws {
        StubURLProtocol.handler = { _ in .init(status: 204, body: Data(), error: nil) }
        try await client.stopBot(platform: .googleMeet, meetingId: "x")
    }

    func testRunningBots() async throws {
        StubURLProtocol.handler = { _ in
            self.json(#"{"running_bots":[{"platform":"zoom","native_meeting_id":"123","created_at":"2026-01-01T00:00:00"}]}"#)
        }
        let bots = try await client.runningBots()
        XCTAssertEqual(bots.count, 1)
        XCTAssertEqual(bots[0].platform, "zoom")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.url?.path, "/bots/status")
    }

    func testTranscriptRequest() async throws {
        StubURLProtocol.handler = { _ in self.json(#"{"segments":[{"start":1.5,"end":2,"text":"hi"}]}"#) }
        let t = try await client.transcript(platform: .teams, meetingId: "9876")
        XCTAssertEqual(t.segments.first?.text, "hi")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.url?.path, "/transcripts/teams/9876")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.httpMethod, "GET")
    }

    func testCreateAPIKeyFlow() async throws {
        StubURLProtocol.handler = { req in
            req.url?.path == "/admin/users" ? self.json(#"{"id": 42}"#) : self.json(#"{"token":"secret-token"}"#)
        }
        let key = try await client.createAPIKey(email: "me@example.com")
        XCTAssertEqual(key, "secret-token")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let (r1, b1) = StubURLProtocol.requests[0]
        XCTAssertEqual(r1.url?.absoluteString, "http://localhost:18057/admin/users")
        XCTAssertEqual(r1.value(forHTTPHeaderField: "X-Admin-API-Key"), "admin-tok")
        XCTAssertNil(r1.value(forHTTPHeaderField: "X-API-Key"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(b1)) as? [String: Any])
        XCTAssertEqual(obj["email"] as? String, "me@example.com")
        let r2 = StubURLProtocol.requests[1].request
        XCTAssertEqual(r2.httpMethod, "POST")
        XCTAssertEqual(r2.url?.path, "/admin/users/42/tokens")
        let comps = URLComponents(url: try XCTUnwrap(r2.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "scopes" })?.value, "bot,tx")
        XCTAssertEqual(r2.value(forHTTPHeaderField: "X-Admin-API-Key"), "admin-tok")
    }

    func testCreateAPIKeyStopsWhenUserCreationFails() async {
        StubURLProtocol.handler = { _ in self.json(#"{"detail":"Invalid admin token"}"#, status: 403) }
        do { _ = try await client.createAPIKey(email: "a@b.c"); XCTFail("should throw") }
        catch let e as APIError { XCTAssertEqual(e.status, 403) }
        catch { XCTFail("\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: Errors

    private func failure(_ stub: StubURLProtocol.Stub) async -> APIError? {
        StubURLProtocol.handler = { _ in stub }
        do { _ = try await client.runningBots(); return nil } catch { return error as? APIError }
    }

    func testStringDetail() async {
        let e = await failure(json(#"{"detail":"Meeting already exists"}"#, status: 409))
        XCTAssertEqual(e?.status, 409)
        XCTAssertEqual(e?.message, "Meeting already exists")
        XCTAssertEqual(e?.errorDescription, "Meeting already exists (HTTP 409)")
    }

    func testArrayDetail() async {
        let e = await failure(json(#"{"detail":[{"msg":"field required"},{"msg":"bad value"}]}"#, status: 422))
        XCTAssertEqual(e?.message, "field required; bad value")
    }

    func testNonJSONBody() async {
        let e = await failure(json("Bad gateway from nginx", status: 502))
        XCTAssertEqual(e?.message, "Bad gateway from nginx")
    }

    func testLongNonJSONBodyIsTruncated() async {
        let e = await failure(json(String(repeating: "x", count: 1000), status: 500))
        XCTAssertEqual(e?.message.count, 300)
    }

    func testEmptyErrorBodyFallsBackToStatusText() async {
        let e = await failure(.init(status: 404, body: Data(), error: nil))
        XCTAssertEqual(e?.status, 404)
        XCTAssertEqual(e?.message, HTTPURLResponse.localizedString(forStatusCode: 404))
    }

    func testJSONWithoutDetailFallsBackToStatusText() async {
        let e = await failure(json(#"{"error":"x"}"#, status: 500))
        XCTAssertEqual(e?.message, HTTPURLResponse.localizedString(forStatusCode: 500))
    }

    func testConnectionFailureHasStatusZero() async {
        let e = await failure(.init(status: 0, body: Data(), error: URLError(.cannotConnectToHost)))
        XCTAssertEqual(e?.status, 0)
        XCTAssertTrue(e?.message.contains("localhost:18056") ?? false)
        XCTAssertEqual(e?.errorDescription, e?.message, "no HTTP suffix for status 0")
    }

    func testDetailParserDirectly() {
        XCTAssertNil(VexaClient.detail(from: Data()))
        XCTAssertNil(VexaClient.detail(from: Data(#"{"detail": 5}"#.utf8)))
    }
}
