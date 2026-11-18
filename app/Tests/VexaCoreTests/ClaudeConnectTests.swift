import XCTest
@testable import VexaCore

final class ClaudeConnectTests: XCTestCase {
    func testURL() {
        XCTAssertEqual(ClaudeConnect.mcpURL(gateway: URL(string: "http://localhost:18056")!), "http://localhost:18056/mcp")
        XCTAssertEqual(ClaudeConnect.mcpURL(gateway: URL(string: "http://localhost:18056/")!), "http://localhost:18056/mcp")
    }

    func testMask() {
        XCTAssertEqual(ClaudeConnect.maskKey(""), "")
        XCTAssertEqual(ClaudeConnect.maskKey("abc"), "•••")
        let m = ClaudeConnect.maskKey("vxa_bot_secretsecret")
        XCTAssertTrue(m.hasPrefix("vxa_bot_"))
        XCTAssertFalse(m.contains("secret"))
        XCTAssertEqual(ClaudeConnect.masked("Bearer vxa_bot_secretsecret", key: "vxa_bot_secretsecret"), "Bearer " + m)
    }

    func testCodeCommand() {
        let c = ClaudeConnect.claudeCodeCommand(url: "http://localhost:18056/mcp", key: "k1", scope: .project)
        XCTAssertEqual(c, "claude mcp add --transport http --scope project vexa http://localhost:18056/mcp --header 'Authorization: Bearer k1'")
        XCTAssertTrue(ClaudeConnect.claudeCodeCommand(url: "u", key: "a'b").contains("'\\''"))
    }

    func testDesktopJSON() throws {
        let s = ClaudeConnect.desktopConfigJSON(url: "http://localhost:18056/mcp", key: "k1")
        XCTAssertTrue(s.contains("http://localhost:18056/mcp"))
        let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        let v = (o["mcpServers"] as! [String: Any])["vexa"] as! [String: Any]
        XCTAssertEqual(v["command"] as? String, "npx")
        XCTAssertEqual((v["args"] as! [String]).prefix(3).map { $0 }, ["-y", "mcp-remote", "http://localhost:18056/mcp"])
        XCTAssertEqual((v["env"] as! [String: String])["VEXA_AUTH"], "Bearer k1")
    }

    let toolsJSON = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_meetings","description":"List Meetings\n\nMore"},{"name":"stop_bot"}]}}"#

    func testParseToolsPlain() {
        let t = ClaudeConnect.parseTools(Data(toolsJSON.utf8))
        XCTAssertEqual(t, [MCPTool(name: "list_meetings", summary: "List Meetings"), MCPTool(name: "stop_bot", summary: "")])
    }

    func testParseToolsSSE() {
        let sse = "event: message\r\ndata: \(toolsJSON)\r\n\r\n"
        XCTAssertEqual(ClaudeConnect.parseTools(Data(sse.utf8))?.count, 2)
    }

    func testParseInitializeAndErrors() {
        let j = #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"Vexa MCP","version":"1.2"}}}"#
        XCTAssertEqual(ClaudeConnect.parseInitialize(Data(j.utf8)), MCPServerInfo(name: "Vexa MCP", version: "1.2"))
        XCTAssertNil(ClaudeConnect.parseTools(Data("garbage".utf8)))
        XCTAssertNil(ClaudeConnect.parseTools(Data(#"{"error":{"code":1}}"#.utf8)))
    }
}
