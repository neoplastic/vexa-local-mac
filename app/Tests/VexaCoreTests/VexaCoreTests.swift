import XCTest
@testable import VexaCore

final class MeetingParserTests: XCTestCase {
    func testGoogleMeetURL() {
        let p = MeetingParser.parse("https://meet.google.com/abc-defg-hij?authuser=0")
        XCTAssertEqual(p?.platform, .googleMeet)
        XCTAssertEqual(p?.nativeMeetingId, "abc-defg-hij")
    }

    func testGoogleMeetURLWithoutScheme() {
        XCTAssertEqual(MeetingParser.parse("meet.google.com/abc-defg-hij")?.nativeMeetingId, "abc-defg-hij")
    }

    func testGoogleMeetBareCode() {
        XCTAssertEqual(MeetingParser.parse(" ABC-DEFG-HIJ ")?.nativeMeetingId, "abc-defg-hij")
        XCTAssertEqual(MeetingParser.parse("abcdefghij")?.nativeMeetingId, "abc-defg-hij")
    }

    func testTeamsLiveURL() {
        let p = MeetingParser.parse("https://teams.live.com/meet/9387167464734?p=qxJanYOcdjN4d6UlGa")
        XCTAssertEqual(p?.platform, .teams)
        XCTAssertEqual(p?.nativeMeetingId, "9387167464734")
        XCTAssertEqual(p?.passcode, "qxJanYOcdjN4d6UlGa")
        XCTAssertNil(p?.teamsBaseHost)
        XCTAssertEqual(p?.needsTeamsHost, false)
    }

    func testTeamsEnterpriseShortURL() {
        let p = MeetingParser.parse("https://teams.microsoft.com/meet/123456789012?p=Ab12Cd&anon=true")
        XCTAssertEqual(p?.nativeMeetingId, "123456789012")
        XCTAssertEqual(p?.passcode, "Ab12Cd")
        XCTAssertEqual(p?.teamsBaseHost, "teams.microsoft.com")
    }

    func testTeamsV2DeepLink() {
        let p = MeetingParser.parse("https://teams.microsoft.com/v2/?meetingjoin=true#/meet/1234567890123?p=XyZ987")
        XCTAssertEqual(p?.nativeMeetingId, "1234567890123")
        XCTAssertEqual(p?.passcode, "XyZ987")
        XCTAssertEqual(p?.teamsBaseHost, "teams.microsoft.com")
    }

    func testTeamsGovHost() {
        let p = MeetingParser.parse("https://gov.teams.microsoft.us/meet/1234567890?p=abcd")
        XCTAssertEqual(p?.teamsBaseHost, "gov.teams.microsoft.us")
    }

    func testTeamsLegacyLinkHashesLikeVexa() {
        let url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        let p = MeetingParser.parse(url)
        XCTAssertEqual(p?.platform, .teams)
        XCTAssertEqual(p?.meetingURL, url)
        XCTAssertEqual(p?.nativeMeetingId.count, 16)
        XCTAssertTrue(p?.nativeMeetingId.allSatisfy(\.isHexDigit) ?? false)
    }

    func testTeamsInviteText() {
        let text = """
        Microsoft Teams meeting
        Join on your computer
        Meeting ID: 312 004 451 623
        Passcode: Ux7Ab2
        """
        let p = MeetingParser.parse(text)
        XCTAssertEqual(p?.platform, .teams)
        XCTAssertEqual(p?.nativeMeetingId, "312004451623")
        XCTAssertEqual(p?.passcode, "Ux7Ab2")
        XCTAssertEqual(p?.needsTeamsHost, true)
    }

    func testTeamsBareId() {
        let p = MeetingParser.parse("312 004 451 623")
        XCTAssertEqual(p?.platform, .teams)
        XCTAssertEqual(p?.nativeMeetingId, "312004451623")
        XCTAssertEqual(p?.needsTeamsHost, true)
    }

    func testRejectsOtherInput() {
        XCTAssertNil(MeetingParser.parse(""))
        XCTAssertNil(MeetingParser.parse("https://zoom.us/j/123456789"))
        XCTAssertNil(MeetingParser.parse("12345"))
        XCTAssertNil(MeetingParser.parse("https://example.com/meet/abc-defg-hij"))
        XCTAssertNil(MeetingParser.parse("abc-defg-hijk"))
    }

    func testPasscodeValidation() {
        XCTAssertTrue(MeetingParser.isValidTeamsPasscode("Ab12"))
        XCTAssertFalse(MeetingParser.isValidTeamsPasscode("ab!"))
        XCTAssertFalse(MeetingParser.isValidTeamsPasscode("abc"))
    }
}

final class EnvFileTests: XCTestCase {
    func testParse() {
        let env = EnvFile.parse("# comment\nA=1\nB = \"two\"\n\nBAD LINE\nC=x=y\n")
        XCTAssertEqual(env, ["A": "1", "B": "two", "C": "x=y"])
    }

    func testSettingReplacesAndAppends() {
        let text = "A=1\nWHISPER_MODEL=old\n"
        XCTAssertEqual(EnvFile.setting("WHISPER_MODEL", to: "new", in: text), "A=1\nWHISPER_MODEL=new\n")
        XCTAssertEqual(EnvFile.setting("B", to: "2", in: text), "A=1\nWHISPER_MODEL=old\nB=2\n")
    }
}

final class TranscriptTests: XCTestCase {
    func testDecodesAliasedFields() throws {
        let json = #"{"id":1,"status":"active","segments":[{"start":1.5,"end":3,"text":" Hi","speaker":"Ann","completed":true}]}"#
        let t = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
        XCTAssertEqual(t.segments.first?.start, 1.5)
        XCTAssertEqual(t.segments.first?.speaker, "Ann")
    }

    func testMarkdownGroupsSpeakers() {
        let segs = [
            TranscriptSegment(start: 0, end: 2, text: "Hello there.", speaker: "Ann"),
            TranscriptSegment(start: 2, end: 4, text: "How are you?", speaker: "Ann"),
            TranscriptSegment(start: 65, end: 67, text: "Good thanks.", speaker: "Bo"),
            TranscriptSegment(start: 70, end: 71, text: "   ", speaker: "Bo"),
        ]
        let header = TranscriptFormatter.Header(platform: .googleMeet, meetingId: "abc-defg-hij",
                                                startedAt: Date(timeIntervalSince1970: 0), status: "active")
        let md = TranscriptFormatter.markdown(header: header, segments: segs, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(md.contains("**Ann** · 00:00:00\nHello there. How are you?\n"))
        XCTAssertTrue(md.contains("**Bo** · 00:01:05\nGood thanks.\n"))
    }

    func testAbsoluteTimesUseClockTime() {
        let seg = TranscriptSegment(start: 5, end: 6, text: "x", absoluteStartTime: "2026-11-18T03:04:05.123")
        XCTAssertEqual(TranscriptFormatter.timestamp(seg, timeZone: TimeZone(identifier: "UTC")!), "03:04:05")
    }
}

final class ModelCatalogTests: XCTestCase {
    func testCompatibility() {
        XCTAssertTrue(ModelCatalog.isCompatible(files: ["config.json", "weights.npz"]))
        XCTAssertTrue(ModelCatalog.isCompatible(files: ["config.json", "weights.safetensors"]))
        XCTAssertFalse(ModelCatalog.isCompatible(files: ["config.json", "model.safetensors"]))
    }

    func testCacheDirectoryName() {
        let hub = URL(fileURLWithPath: "/tmp/hub")
        XCTAssertEqual(HFCache.repoDirectory("mlx-community/whisper-tiny-mlx", hub: hub).lastPathComponent,
                       "models--mlx-community--whisper-tiny-mlx")
    }
}
