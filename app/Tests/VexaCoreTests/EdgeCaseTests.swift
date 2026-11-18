import XCTest
@testable import VexaCore

final class EnvFileEdgeTests: XCTestCase {
    func testCommentsAndBlankLinesIgnored() {
        let e = EnvFile.parse("# comment\n\n  # indented\nA=1\n")
        XCTAssertEqual(e, ["A": "1"])
    }

    func testQuotesStripped() {
        let e = EnvFile.parse("A=\"x y\"\nB='z'\nC=\"unterminated\nD=\"\"")
        XCTAssertEqual(e["A"], "x y")
        XCTAssertEqual(e["B"], "z")
        XCTAssertEqual(e["C"], "\"unterminated")
        XCTAssertEqual(e["D"], "")
    }

    func testCRLFLineEndings() {
        let e = EnvFile.parse("A=1\r\nB=two\r\n")
        XCTAssertEqual(e["A"], "1")
        XCTAssertEqual(e["B"], "two")
    }

    func testKeyWithNoValue() {
        XCTAssertEqual(EnvFile.parse("EMPTY=\n")["EMPTY"], "")
        XCTAssertNil(EnvFile.parse("JUSTKEY\n")["JUSTKEY"])
    }

    func testValueContainingEqualsAndSpaces() {
        let e = EnvFile.parse("URL=postgres://u:p@h/db?a=b&c=d\nMSG=hello big world\n")
        XCTAssertEqual(e["URL"], "postgres://u:p@h/db?a=b&c=d")
        XCTAssertEqual(e["MSG"], "hello big world")
    }

    func testExportPrefixIsNotAValidKey() {
        // Documents current behaviour: "export A=1" is skipped, not parsed as A.
        XCTAssertNil(EnvFile.parse("export A=1")["A"])
    }

    func testInvalidKeysSkipped() {
        XCTAssertTrue(EnvFile.parse("1BAD=x\nbad-key=y\n=z").isEmpty)
    }

    func testLastDuplicateWins() {
        XCTAssertEqual(EnvFile.parse("A=1\nA=2")["A"], "2")
    }

    func testSettingReplacesExisting() {
        XCTAssertEqual(EnvFile.setting("A", to: "9", in: "A=1\nB=2\n"), "A=9\nB=2\n")
    }

    func testSettingAppendsWithTrailingNewline() {
        XCTAssertEqual(EnvFile.setting("C", to: "3", in: "A=1\n"), "A=1\nC=3\n")
        XCTAssertEqual(EnvFile.setting("C", to: "3", in: "A=1"), "A=1\nC=3\n")
        XCTAssertEqual(EnvFile.setting("C", to: "3", in: ""), "C=3\n")
    }

    func testSettingDoesNotMatchPrefixOfLongerKey() {
        let out = EnvFile.setting("A", to: "1", in: "AB=2\n")
        XCTAssertEqual(EnvFile.parse(out)["AB"], "2")
        XCTAssertEqual(EnvFile.parse(out)["A"], "1")
    }

    func testSetPreservesFilePermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("A=1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try EnvFile.set("A", to: "2", at: url)
        try EnvFile.set("B", to: "3", at: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(EnvFile.read(url), ["A": "2", "B": "3"])
    }

    func testReadMissingFileIsEmpty() {
        XCTAssertTrue(EnvFile.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")).isEmpty)
    }
}

final class TranscriptFormatterEdgeTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let header = TranscriptFormatter.Header(platform: .googleMeet, meetingId: "abc-defg-hij",
                                            startedAt: Date(timeIntervalSince1970: 0), status: "active")

    func testEmptySegments() {
        let md = TranscriptFormatter.markdown(header: header, segments: [], timeZone: utc)
        XCTAssertTrue(md.contains("_No speech transcribed yet._"))
        XCTAssertTrue(md.contains("**Meeting:** abc-defg-hij"))
    }

    func testWhitespaceOnlySegmentsDropped() {
        let md = TranscriptFormatter.markdown(header: header,
            segments: [.init(start: 0, end: 1, text: "  \n ")], timeZone: utc)
        XCTAssertTrue(md.contains("_No speech transcribed yet._"))
    }

    func testMissingSpeakerBecomesUnknown() {
        let md = TranscriptFormatter.markdown(header: header,
            segments: [.init(start: 0, end: 1, text: "hi"), .init(start: 2, end: 3, text: "there", speaker: "")], timeZone: utc)
        XCTAssertTrue(md.contains("**Unknown speaker** · 00:00:00"))
        XCTAssertTrue(md.contains("hi there"), "same (unknown) speaker merges")
    }

    func testRelativeTimestampFormatting() {
        let md = TranscriptFormatter.markdown(header: header,
            segments: [.init(start: 3725.9, end: 3730, text: "late", speaker: "A")], timeZone: utc)
        XCTAssertTrue(md.contains("**A** · 01:02:05"))
    }

    func testAbsoluteTimestampUsesTimeZone() {
        let seg = TranscriptSegment(start: 5, end: 6, text: "x", speaker: "A", absoluteStartTime: "2026-11-18T14:30:15Z")
        let md = TranscriptFormatter.markdown(header: header, segments: [seg], timeZone: utc)
        XCTAssertTrue(md.contains("**A** · 14:30:15"))
        let tokyo = TranscriptFormatter.markdown(header: header, segments: [seg], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(tokyo.contains("**A** · 23:30:15"))
    }

    func testAbsoluteTimestampWithoutZoneTreatedAsUTC() {
        let d = TranscriptFormatter.parseISO("2026-11-18T14:30:15.123456")
        XCTAssertNotNil(d)
        XCTAssertNotNil(TranscriptFormatter.parseISO("2026-11-18T14:30:15"))
        XCTAssertNil(TranscriptFormatter.parseISO("garbage"))
    }

    func testOrderingByStartThenMergesSameSpeaker() {
        let md = TranscriptFormatter.markdown(header: header, segments: [
            .init(start: 10, end: 11, text: "third", speaker: "B"),
            .init(start: 0, end: 1, text: "first", speaker: "A"),
            .init(start: 5, end: 6, text: "second", speaker: "A"),
        ], timeZone: utc)
        let a = md.range(of: "first second")
        let b = md.range(of: "third")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertTrue(a!.lowerBound < b!.lowerBound)
    }

    func testOrderingPrefersAbsoluteTimes() {
        let md = TranscriptFormatter.markdown(header: header, segments: [
            .init(start: 0, end: 1, text: "later", speaker: "A", absoluteStartTime: "2026-01-01T10:00:10Z"),
            .init(start: 99, end: 100, text: "earlier", speaker: "B", absoluteStartTime: "2026-01-01T10:00:00Z"),
        ], timeZone: utc)
        XCTAssertTrue(md.range(of: "earlier")!.lowerBound < md.range(of: "later")!.lowerBound)
    }

    func testSpeakerChangeStartsNewParagraph() {
        let md = TranscriptFormatter.markdown(header: header, segments: [
            .init(start: 0, end: 1, text: "a", speaker: "A"),
            .init(start: 1, end: 2, text: "b", speaker: "B"),
            .init(start: 2, end: 3, text: "c", speaker: "A"),
        ], timeZone: utc)
        XCTAssertEqual(md.components(separatedBy: "**A**").count - 1, 2)
    }

    func testModelLineOnlyWhenPresent() {
        var h = header
        XCTAssertFalse(TranscriptFormatter.markdown(header: h, segments: [], timeZone: utc).contains("**Model:**"))
        h.model = "whisper-x"
        XCTAssertTrue(TranscriptFormatter.markdown(header: h, segments: [], timeZone: utc).contains("**Model:** whisper-x"))
    }

    func testSegmentDecodingAcceptsFieldNamesAndDefaults() throws {
        let s = try JSONDecoder().decode(TranscriptSegment.self,
            from: Data(#"{"start_time": 4.5, "end_time": 6, "text": "x"}"#.utf8))
        XCTAssertEqual(s.start, 4.5)
        XCTAssertEqual(s.end, 6)
        let empty = try JSONDecoder().decode(TranscriptSegment.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.end, 0)
    }

    func testFileNameSanitisesSlashAndColon() {
        let name = TranscriptFormatter.fileName(platform: .teams, meetingId: "a/b:c", startedAt: Date())
        XCTAssertFalse(name.dropLast(3).contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix("a-b-c.md"))
        XCTAssertTrue(name.contains(MeetingPlatform.teams.displayName))
    }

    func testTerminalStatuses() {
        XCTAssertTrue(TranscriptFormatter.terminalStatuses.contains("completed"))
        XCTAssertFalse(TranscriptFormatter.terminalStatuses.contains("active"))
    }
}

final class MeetingParserEdgeTests: XCTestCase {
    func testSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(MeetingParser.parse("  \n https://meet.google.com/abc-defg-hij \n")?.nativeMeetingId, "abc-defg-hij")
    }

    func testUppercaseMeetCode() {
        XCTAssertEqual(MeetingParser.parse("ABC-DEFG-HIJ")?.nativeMeetingId, "abc-defg-hij")
    }

    func testMeetURLWithFragment() {
        XCTAssertEqual(MeetingParser.parse("https://meet.google.com/abc-defg-hij#x")?.nativeMeetingId, "abc-defg-hij")
    }

    func testBareCodeWithoutDashes() {
        XCTAssertEqual(MeetingParser.parse("abcdefghij")?.nativeMeetingId, "abc-defg-hij")
    }

    func testGarbageAndEmptyReturnNil() {
        XCTAssertNil(MeetingParser.parse(""))
        XCTAssertNil(MeetingParser.parse("   "))
        XCTAssertNil(MeetingParser.parse("hello world"))
        XCTAssertNil(MeetingParser.parse("https://example.com/abc-defg-hij"))
    }

    func testTeamsBareIdWithSpaces() {
        let p = MeetingParser.parse("123 456 789 012")
        XCTAssertEqual(p?.platform, .teams)
        XCTAssertEqual(p?.nativeMeetingId, "123456789012")
    }
}
