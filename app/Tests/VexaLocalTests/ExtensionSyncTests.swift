import XCTest
import VexaCore
@testable import VexaLocal

/// DesktopHostClient over a stubbed URLSession, and AppModel's extension-transcript sync
/// using in-memory UserDefaults and a temp folder (nothing touches the real settings).
@MainActor
final class ExtensionSyncTests: XCTestCase {
    var tmp: URL!
    var defaults: TestDefaults!
    var model: AppModel!
    var client: DesktopHostClient!

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vexa-ext-\(UUID().uuidString)")
        defaults = TestDefaults()
        model = AppModel(defaults: defaults)
        model.outputDirectory = tmp.path
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        client = DesktopHostClient(baseURL: URL(string: "http://localhost:8056")!, session: URLSession(configuration: cfg))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        defaults = nil
    }

    private func stub(_ body: String, status: Int = 200) -> StubURLProtocol.Stub {
        .init(status: status, body: Data(body.utf8), error: nil)
    }

    private func seg(_ text: String, at t: Double) -> TranscriptSegment {
        TranscriptSegment(start: t, end: t + 2, text: text, speaker: "You")
    }

    private func meeting(_ id: String = "vzm-nfkp-hgn", platform: String = "google_meet", status: String = "active",
                         start: String = "2026-11-18T03:06:44.542Z") -> DesktopMeeting {
        DesktopMeeting(id: 1, platform: platform, nativeMeetingId: id, status: status, startTime: start)
    }

    private func fileText(_ s: Session) -> String { (try? String(contentsOfFile: s.filePath, encoding: .utf8)) ?? "" }

    // MARK: DesktopHostClient

    func testListsMeetingsFromBots() async throws {
        StubURLProtocol.handler = { _ in self.stub(#"{"meetings":[{"id":7,"platform":"zoom","native_meeting_id":"81373189640","status":"completed","start_time":"2026-11-18T02:57:58.357Z","segments":[{"text":"hi","start":1794971050.6,"end":1794971052}]}],"has_more":false}"#) }
        let ms = try await client.meetings()
        XCTAssertEqual(ms.count, 1)
        XCTAssertEqual(ms[0].segments?.first?.text, "hi")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.url?.absoluteString, "http://localhost:8056/bots")
    }

    func testTranscriptURLPercentEncodesTeamsIds() async throws {
        StubURLProtocol.handler = { _ in self.stub(#"{"id":10,"platform":"teams","native_meeting_id":"x","status":"active","segments":[]}"#) }
        _ = try await client.transcript(platform: "teams", nativeMeetingId: "19:meeting_Mm@thread.v2")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.url?.absoluteString,
                       "http://localhost:8056/transcripts/teams/19%3Ameeting_Mm%40thread.v2")
    }

    func testIsUpFalseWhenHostFailsOrErrors() async {
        StubURLProtocol.handler = { _ in self.stub("{}", status: 500) }
        let a = await client.isUp()
        XCTAssertFalse(a)
        StubURLProtocol.handler = { _ in .init(status: 0, body: Data(), error: URLError(.cannotConnectToHost)) }
        let b = await client.isUp()
        XCTAssertFalse(b)
        StubURLProtocol.handler = { _ in self.stub(#"{"meetings":[]}"#) }
        let c = await client.isUp()
        XCTAssertTrue(c)
    }

    func testGatewayMeetingsClient() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let v = VexaClient(gateway: URL(string: "http://localhost:18056")!, admin: URL(string: "http://localhost:18057")!,
                           apiKey: "k", adminToken: "", session: URLSession(configuration: cfg))
        StubURLProtocol.handler = { _ in self.stub(#"{"meetings":[{"id":5,"platform":"zoom","native_meeting_id":"85823172363","status":"failed","data":{"reason":"zoom_requires_rtms"}},{"bad":true}]}"#) }
        let rows = try await v.meetings()
        XCTAssertEqual(rows.count, 1, "rows that don't decode are skipped")
        XCTAssertEqual(rows[0].reason, "zoom_requires_rtms")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.url?.absoluteString, "http://localhost:18056/meetings")
        XCTAssertEqual(StubURLProtocol.requests.first?.request.value(forHTTPHeaderField: "X-API-Key"), "k")
    }

    // MARK: Sync into sessions and files

    func testSyncCreatesSessionAndWritesFile() async throws {
        StubURLProtocol.handler = { _ in self.stub(#"{"meetings":[{"id":10,"platform":"google_meet","native_meeting_id":"vzm-nfkp-hgn","status":"active","start_time":"2026-11-18T03:06:44.542Z","segments":[{"text":"So is this capturing?","speaker":"You","start":1794971050.669,"end":1794971054.2}]},{"id":1,"platform":"google_meet","native_meeting_id":"selftest-1","status":"completed","segments":[{"text":"x","start":1,"end":2}]},{"id":5,"platform":"note","native_meeting_id":"note-1","status":"completed","segments":[{"text":"memo","start":1794971050,"end":1794971052}]}],"has_more":false}"#) }
        await model.syncExtensionTranscripts(using: client)
        XCTAssertEqual(model.desktopHostState, .up)
        XCTAssertEqual(model.sessions.count, 1)
        let s = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(s.source, .browserExtension)
        XCTAssertEqual(s.platform, .googleMeet)
        XCTAssertEqual(s.status, "active")
        XCTAssertFalse(s.finished)
        XCTAssertEqual(s.segmentCount, 1)
        XCTAssertTrue(s.filePath.hasPrefix(tmp.path))
        XCTAssertTrue(fileText(s).contains("So is this capturing?"))
        XCTAssertTrue(fileText(s).contains("**You** · "))
        XCTAssertFalse(fileText(s).contains("498:"))
    }

    func testSyncIsIdempotentAndUpdatesInPlace() async throws {
        var list = [meeting()]
        model.applyDesktopMeetings([(list[0], [seg("one", at: 1_794_971_050)])])
        model.applyDesktopMeetings([(list[0], [seg("one", at: 1_794_971_050)])])
        XCTAssertEqual(model.sessions.count, 1)
        list[0].status = "completed"
        model.applyDesktopMeetings([(list[0], [seg("one", at: 1_794_971_050), seg("two", at: 1_794_971_060)])])
        XCTAssertEqual(model.sessions.count, 1)
        let s = model.sessions[0]
        XCTAssertEqual(s.segmentCount, 2)
        XCTAssertTrue(s.finished)
        XCTAssertEqual(s.status, "completed")
        XCTAssertTrue(fileText(s).contains("two"))
    }

    func testEmptyHostNeverOverwritesSavedTranscript() async throws {
        let m = meeting(status: "completed")
        model.applyDesktopMeetings([(m, [seg("keep me", at: 1_794_971_050)])])
        let s = try XCTUnwrap(model.sessions.first)
        // host restarted: same meeting id reported with no speech
        model.applyDesktopMeetings([(m, [])])
        XCTAssertEqual(model.sessions.first?.segmentCount, 1)
        XCTAssertTrue(fileText(s).contains("keep me"))
    }

    func testMeetingMissingFromHostIsMarkedCompletedAndFileKept() async throws {
        model.applyDesktopMeetings([(meeting(), [seg("hello", at: 1_794_971_050)])])
        model.applyDesktopMeetings([])
        let s = try XCTUnwrap(model.sessions.first)
        XCTAssertTrue(s.finished)
        XCTAssertEqual(s.status, "completed")
        XCTAssertTrue(fileText(s).contains("hello"))
    }

    func testReusedMeetingIdWithNewStartTimeIsANewSession() async throws {
        model.applyDesktopMeetings([(meeting(status: "completed"), [seg("first call", at: 1_794_971_050)])])
        model.applyDesktopMeetings([(meeting(start: "2026-11-19T09:00:00.000Z"), [seg("second call", at: 1_795_000_000)])])
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertNotEqual(model.sessions[0].filePath, model.sessions[1].filePath)
        XCTAssertTrue(fileText(model.sessions[1]).contains("first call"))
    }

    func testRemovedExtensionSessionIsNotAddedBack() async throws {
        let m = meeting(status: "completed")
        model.applyDesktopMeetings([(m, [seg("hi", at: 1_794_971_050)])])
        model.removeSession(model.sessions[0])
        XCTAssertTrue(model.sessions.isEmpty)
        model.applyDesktopMeetings([(m, [seg("hi", at: 1_794_971_050)])])
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testSyncFallsBackToTranscriptEndpointWhenListHasNoSegments() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path == "/bots" {
                return self.stub(#"{"meetings":[{"id":8,"platform":"zoom","native_meeting_id":"81373189640","status":"completed","start_time":"2026-11-18T02:57:58.357Z"}]}"#)
            }
            return self.stub(#"{"id":8,"platform":"zoom","native_meeting_id":"81373189640","status":"completed","segments":[{"text":"from transcript","speaker":"A","start":1794970700,"end":1794970702}]}"#)
        }
        await model.syncExtensionTranscripts(using: client)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(fileText(model.sessions[0]).contains("from transcript"))
    }

    func testHostDownIsQuietAndKeepsSessions() async throws {
        model.applyDesktopMeetings([(meeting(), [seg("hello", at: 1_794_971_050)])])
        StubURLProtocol.handler = { _ in .init(status: 0, body: Data(), error: URLError(.cannotConnectToHost)) }
        await model.syncExtensionTranscripts(using: client)
        XCTAssertEqual(model.desktopHostState, .down)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(model.sessions[0].finished)
        XCTAssertNil(model.sessions[0].lastError)
    }

    // MARK: Persistence

    func testSessionsPersistWithSourceAndSurviveRestart() async throws {
        model.applyDesktopMeetings([(meeting(), [seg("hello", at: 1_794_971_050)])])
        let again = AppModel(defaults: defaults)
        XCTAssertEqual(again.sessions.count, 1)
        XCTAssertEqual(again.sessions[0].source, .browserExtension)
        XCTAssertEqual(again.sessions[0].meetingId, "vzm-nfkp-hgn")
    }

    func testSessionsSavedByOlderVersionsStillDecode() throws {
        let old = #"{"id":"6E2F3C43-0F2B-4C2A-9C65-0C2A3D8E8F11","platform":"teams","meetingId":"9352702018166","startedAt":784000000,"filePath":"/tmp/x.md","status":"completed","segmentCount":8,"finished":true}"#
        let s = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
        XCTAssertEqual(s.source, .bot)
        XCTAssertNil(s.failureReason)
        XCTAssertEqual(s.segmentCount, 8)
        XCTAssertTrue(s.finished)
    }
}
