import XCTest
@testable import VexaCore

/// Google Meet and Zoom refuse Vexa's bot (issues #2059 and #938), so they use the browser extension.
final class PlatformAvailabilityTests: XCTestCase {
    func testExtensionIsRecommendedEverywhereAndBotOnlyForTeams() {
        for p in MeetingPlatform.allCases { XCTAssertEqual(p.captureMethod, .browserExtension) }
        XCTAssertTrue(MeetingPlatform.teams.botAvailable)
        XCTAssertFalse(MeetingPlatform.googleMeet.botAvailable)
        XCTAssertFalse(MeetingPlatform.zoom.botAvailable)
    }

    func testExtensionPlatformsExplainWhyAndLinkTheIssues() {
        let meet = MeetingPlatform.googleMeet
        XCTAssertTrue(meet.captureExplanation.contains("browser extension"))
        XCTAssertTrue(meet.captureExplanation.contains("Google"))
        XCTAssertTrue(meet.botRefusalNote?.contains("#2059") ?? false)
        XCTAssertEqual(meet.botRefusalIssueURLs.map(\.absoluteString), ["https://github.com/Vexa-ai/vexa/issues/2059"])
        let zoom = MeetingPlatform.zoom
        XCTAssertTrue(zoom.captureExplanation.contains("Zoom"))
        XCTAssertEqual(zoom.botRefusalIssueURLs.map(\.absoluteString), ["https://github.com/Vexa-ai/vexa/issues/938"])
        XCTAssertTrue(zoom.botRefusalNote?.contains("#938") ?? false)
    }

    func testTeamsOffersTheBotAsABackupWithNoRefusalNote() {
        XCTAssertNil(MeetingPlatform.teams.botRefusalNote)
        XCTAssertTrue(MeetingPlatform.teams.botRefusalIssueURLs.isEmpty)
        XCTAssertTrue(MeetingPlatform.teams.captureExplanation.contains("browser extension"))
        XCTAssertTrue(MeetingPlatform.teams.captureExplanation.contains("backup"))
    }

    func testMeetLinksStillParseSoTheAppCanExplain() {
        let p = MeetingParser.parse("https://meet.google.com/vzm-nfkp-hgn")
        XCTAssertEqual(p?.platform, .googleMeet)
        XCTAssertEqual(p?.platform.captureMethod, .browserExtension)
    }

    func testZoomLinksParseAsExtensionMeetings() {
        let p = MeetingParser.parse("https://zoom.us/j/81373189640?pwd=abc")
        XCTAssertEqual(p?.platform, .zoom)
        XCTAssertEqual(p?.platform.captureMethod, .browserExtension)
    }
}
