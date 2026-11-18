import XCTest
@testable import VexaCore

final class ExtensionTranscriptTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let header = TranscriptFormatter.Header(platform: .googleMeet, meetingId: "vzm-nfkp-hgn",
                                            startedAt: Date(timeIntervalSince1970: 1_794_970_000), status: "active")

    // MARK: Epoch timestamps

    func testEpochSegmentsPrintLocalClockTime() {
        // 1794971050 = 2026-11-18 03:04:10 UTC
        let segs = [TranscriptSegment(start: 1_794_971_050.669, end: 1_794_971_054.2, text: "So is this capturing?", speaker: "You")]
        let md = TranscriptFormatter.markdown(header: header, segments: segs, timeZone: utc)
        XCTAssertTrue(md.contains("**You** · 03:04:10"), md)
        XCTAssertFalse(md.contains("498"), "must not print epoch seconds as hours")
    }

    func testEpochTimestampFollowsTheTimeZone() {
        let segs = [TranscriptSegment(start: 1_794_971_050, end: 1_794_971_052, text: "Hi", speaker: "You")]
        let tokyo = TranscriptFormatter.markdown(header: header, segments: segs, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(tokyo.contains("12:04:10"), tokyo)
    }

    func testSmallStartValuesStayOffsets() {
        let segs = [TranscriptSegment(start: 3725, end: 3730, text: "Hi", speaker: "A")]
        XCTAssertTrue(TranscriptFormatter.markdown(header: header, segments: segs, timeZone: utc).contains("01:02:05"))
    }

    func testEpochSegmentsAreOrderedByTime() {
        let segs = [TranscriptSegment(start: 1_794_971_060, end: 1_794_971_061, text: "second", speaker: "B"),
                    TranscriptSegment(start: 1_794_971_050, end: 1_794_971_051, text: "first", speaker: "A")]
        let md = TranscriptFormatter.markdown(header: header, segments: segs, timeZone: utc)
        XCTAssertLessThan(md.range(of: "first")!.lowerBound, md.range(of: "second")!.lowerBound)
    }

    func testDesktopHostSegmentJSONDecodes() throws {
        let json = #"""
        {"segment_id":"ch-1000:3:1794971050669","speaker":"You","speaker_key":"ch-1000:3","text":"So is this capturing?",
         "start":1794971050.669,"end":1794971054.253,"completed":true,"words":[],"language":"en","source":"glow-bound","confidence":1}
        """#
        let seg = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        XCTAssertEqual(seg.start, 1_794_971_050.669, accuracy: 0.001)
        XCTAssertEqual(seg.speaker, "You")
        XCTAssertEqual(seg.completed, true)
    }

    // MARK: File names

    func testFileNameSanitisesTeamsThreadIds() {
        let name = TranscriptFormatter.fileName(platform: .teams,
                                                meetingId: "19:meeting_MmExZGU3OWUtYzg3ZC00YmE0LThhZDctMjg1ZjMwM2QyZTdl@thread.v2",
                                                startedAt: Date(timeIntervalSince1970: 0))
        for bad in [":", "@", "/"] { XCTAssertFalse(name.dropLast(3).contains(bad), name) }
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertLessThan(name.count, 90)
    }

    func testFileNameKeepsSimpleIds() {
        let name = TranscriptFormatter.fileName(platform: .googleMeet, meetingId: "vzm-nfkp-hgn",
                                                startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasSuffix("Google Meet vzm-nfkp-hgn.md"), name)
        XCTAssertEqual(TranscriptFormatter.safeFileComponent("a/b:c"), "a-b-c")
        XCTAssertEqual(TranscriptFormatter.safeFileComponent("///"), "meeting")
    }

    // MARK: Desktop host list

    func testDesktopMeetingListDecodes() throws {
        let json = #"""
        {"meetings":[{"id":10,"platform":"google_meet","native_meeting_id":"vzm-nfkp-hgn","status":"active",
         "start_time":"2026-11-18T03:06:44.542Z","segments":[{"text":"hi","start":1794971050.6,"end":1794971051}]}],"has_more":false}
        """#
        let list = try JSONDecoder().decode(DesktopMeetingList.self, from: Data(json.utf8))
        let m = try XCTUnwrap(list.meetings.first)
        XCTAssertEqual(m.meetingPlatform, .googleMeet)
        XCTAssertTrue(m.isActive)
        XCTAssertNotNil(m.startDate)
        XCTAssertEqual(m.segments?.count, 1)
        XCTAssertFalse(list.hasMore)
    }

    func testShouldTrackRules() {
        func meeting(_ platform: String, _ id: String, status: String = "completed", segs: [TranscriptSegment]? = nil) -> DesktopMeeting {
            DesktopMeeting(platform: platform, nativeMeetingId: id, status: status, segments: segs)
        }
        let speech = [TranscriptSegment(start: 1_794_971_050, end: 1_794_971_052, text: "hello")]
        XCTAssertTrue(ExtensionSync.shouldTrack(meeting("zoom", "81373189640", segs: speech)))
        XCTAssertTrue(ExtensionSync.shouldTrack(meeting("teams", "19:x@thread.v2", segs: speech)))
        // selftest probes, voice notes and other platforms are skipped
        XCTAssertFalse(ExtensionSync.shouldTrack(meeting("google_meet", "selftest-123", segs: speech)))
        XCTAssertFalse(ExtensionSync.shouldTrack(meeting("note", "note-abc", segs: speech)))
        XCTAssertFalse(ExtensionSync.shouldTrack(meeting("youtube", "abc", segs: speech)))
        // a finished meeting with no speech is not worth a file; a live one is shown straight away
        XCTAssertFalse(ExtensionSync.shouldTrack(meeting("teams", "19:x@thread.v2")))
        XCTAssertFalse(ExtensionSync.shouldTrack(meeting("zoom", "1", segs: [TranscriptSegment(start: 1, end: 2, text: "  ")])))
        XCTAssertTrue(ExtensionSync.shouldTrack(meeting("zoom", "1", status: "active")))
        // once tracked, keep tracking even if the host later reports nothing
        XCTAssertTrue(ExtensionSync.shouldTrack(meeting("zoom", "1"), alreadyTracked: true))
    }

    func testSameMeetingMatchesByStartTime() {
        let t = Date(timeIntervalSince1970: 1_794_970_000)
        XCTAssertTrue(ExtensionSync.isSameMeeting(storedStart: t, hostStart: t.addingTimeInterval(1)))
        XCTAssertFalse(ExtensionSync.isSameMeeting(storedStart: t, hostStart: t.addingTimeInterval(3600)))
        XCTAssertTrue(ExtensionSync.isSameMeeting(storedStart: t, hostStart: nil))
    }

    func testNeverShrinkASavedTranscript() {
        XCTAssertFalse(ExtensionSync.shouldWrite(newSegmentCount: 0, savedSegmentCount: 7))
        XCTAssertFalse(ExtensionSync.shouldWrite(newSegmentCount: 3, savedSegmentCount: 7))
        XCTAssertTrue(ExtensionSync.shouldWrite(newSegmentCount: 7, savedSegmentCount: 7))
        XCTAssertTrue(ExtensionSync.shouldWrite(newSegmentCount: 8, savedSegmentCount: 7))
        XCTAssertTrue(ExtensionSync.shouldWrite(newSegmentCount: 0, savedSegmentCount: 0))
    }

    func testPathSegmentEncoding() {
        XCTAssertEqual(ExtensionSync.encodePathSegment("19:meeting_Mm@thread.v2"), "19%3Ameeting_Mm%40thread.v2")
        XCTAssertEqual(ExtensionSync.encodePathSegment("vzm-nfkp-hgn"), "vzm-nfkp-hgn")
        XCTAssertEqual(ExtensionSync.encodePathSegment("a/b c"), "a%2Fb%20c")
    }

    func testDismissalKeyDiffersPerStartTime() {
        let a = ExtensionSync.dismissalKey(platform: .zoom, meetingId: "1", start: Date(timeIntervalSince1970: 100))
        let b = ExtensionSync.dismissalKey(platform: .zoom, meetingId: "1", start: Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(a, b)
    }

    // MARK: Failure reasons

    func testFailureReasonMapping() {
        func d(_ r: String?, _ c: String? = nil) -> String? { BotFailure.describe(reason: r, completionReason: c) }
        XCTAssertEqual(d("zoom_requires_rtms"), "Zoom blocks automated bots in this meeting")
        XCTAssertEqual(d("never_reached_lobby"), "Google refused the bot")
        XCTAssertEqual(d("Navigation to https://workspace.google.com/products/meet failed", "join_failure"), "Google refused the bot")
        XCTAssertEqual(d(nil, "stopped"), "Stopped")
        XCTAssertEqual(d("none", "stopped"), "Stopped")
        XCTAssertEqual(d(nil, "awaiting_admission_timeout"), "Nobody let the bot in from the lobby")
        XCTAssertEqual(d(nil, "awaiting_admission_rejected"), "The host declined the bot")
        XCTAssertEqual(d(nil, "join_failure"), "Could not join the meeting")
        XCTAssertNil(d(nil, nil))
        XCTAssertNil(d("  ", ""))
    }

    func testUnknownReasonIsShownRawAndTruncated() {
        XCTAssertEqual(BotFailure.describe(reason: "odd_new_reason", completionReason: nil), "odd_new_reason")
        let long = String(repeating: "x", count: 500)
        let out = BotFailure.describe(reason: long, completionReason: nil, maxLength: 50)
        XCTAssertEqual(out?.count, 50)
        XCTAssertTrue(out?.hasSuffix("…") ?? false)
        // a generic completion label gives way to a more specific raw reason
        XCTAssertEqual(BotFailure.describe(reason: "Page crashed", completionReason: "join_failure"), "Page crashed")
        // a specific completion label wins over an unknown raw reason
        XCTAssertEqual(BotFailure.describe(reason: "self_initiated_leave", completionReason: "stopped"), "Stopped")
    }

    func testGatewayRowDecodingAndLatestRow() throws {
        let json = #"""
        {"meetings":[
         {"id":3,"platform":"zoom","native_meeting_id":"85823172363","status":"failed","data":{"reason":null,"completion_reason":"join_failure"}},
         {"id":9,"platform":"zoom","native_meeting_id":"85823172363","status":"failed","data":{"reason":"zoom_requires_rtms","completion_reason":"join_failure","bot_logs":[1,2]}},
         {"id":11,"platform":"google_meet","native_meeting_id":"vzm-nfkp-hgn","status":"failed"}]}
        """#
        struct R: Decodable { var meetings: [GatewayMeetingRow] }
        let rows = try JSONDecoder().decode(R.self, from: Data(json.utf8)).meetings
        XCTAssertEqual(rows.count, 3)
        let latest = try XCTUnwrap(BotFailure.latestRow(in: rows, platform: .zoom, meetingId: "85823172363"))
        XCTAssertEqual(latest.id, 9)
        XCTAssertEqual(latest.reason, "zoom_requires_rtms")
        XCTAssertEqual(latest.completionReason, "join_failure")
        XCTAssertNil(rows[2].reason)
        XCTAssertNil(BotFailure.latestRow(in: rows, platform: .teams, meetingId: "85823172363"))
    }
}
