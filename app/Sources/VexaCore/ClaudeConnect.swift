import Foundation

/// A tool advertised by Vexa's MCP server.
public struct MCPTool: Equatable, Sendable {
    public let name: String
    public let summary: String
    public init(name: String, summary: String) { self.name = name; self.summary = summary }
}

/// Server info from an MCP `initialize` reply.
public struct MCPServerInfo: Equatable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) { self.name = name; self.version = version }
}

/// Pure helpers for connecting Claude to Vexa's MCP server (streamable HTTP, `Authorization: Bearer <key>`).
public enum ClaudeConnect {
    public enum CodeScope: String, CaseIterable, Sendable {
        case user, local, project
    }

    /// Local MCP endpoint: the gateway's `/mcp` (no trailing slash; `/mcp/` answers 307).
    public static func mcpURL(gateway: URL) -> String {
        var s = gateway.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/mcp"
    }

    /// Masks a key, keeping only the first 8 characters.
    public static func maskKey(_ key: String) -> String {
        if key.isEmpty { return "" }
        if key.count <= 8 { return String(repeating: "•", count: key.count) }
        return String(key.prefix(8)) + String(repeating: "•", count: 12)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `claude mcp add` command for Claude Code.
    public static func claudeCodeCommand(url: String, key: String, scope: CodeScope = .user, name: String = "vexa") -> String {
        "claude mcp add --transport http --scope \(scope.rawValue) \(name) \(url) --header \(shellQuote("Authorization: Bearer \(key)"))"
    }

    /// `claude_desktop_config.json` using `mcp-remote` (Desktop only launches stdio servers from this file).
    /// The header goes through an env var so the space in "Bearer <key>" is not split by npx.
    public static func desktopConfigJSON(url: String, key: String, name: String = "vexa") -> String {
        let obj: [String: Any] = [
            "mcpServers": [
                name: [
                    "command": "npx",
                    "args": ["-y", "mcp-remote", url, "--header", "Authorization:${VEXA_AUTH}"],
                    "env": ["VEXA_AUTH": "Bearer \(key)"],
                ] as [String: Any]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    public static let desktopConfigPath = "~/Library/Application Support/Claude/claude_desktop_config.json"

    /// Replaces the key in a string with its masked form (for on-screen display).
    public static func masked(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: maskKey(key))
    }

    // MARK: JSON-RPC parsing

    /// Extracts the JSON object from either a plain JSON body or an SSE-framed body (`data:` lines).
    public static func jsonPayload(_ body: Data) -> [String: Any]? {
        if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { return o }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var found: [String: Any]?
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("data:") else { continue }
            let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let d = chunk.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["result"] != nil || o["error"] != nil {
                found = o
            }
        }
        return found
    }

    public static func parseInitialize(_ body: Data) -> MCPServerInfo? {
        guard let r = jsonPayload(body)?["result"] as? [String: Any],
              let info = r["serverInfo"] as? [String: Any], let name = info["name"] as? String else { return nil }
        return MCPServerInfo(name: name, version: info["version"] as? String ?? "")
    }

    public static func parseTools(_ body: Data) -> [MCPTool]? {
        guard let r = jsonPayload(body)?["result"] as? [String: Any], let arr = r["tools"] as? [[String: Any]] else { return nil }
        return arr.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return MCPTool(name: name, summary: firstLine(t["description"] as? String ?? ""))
        }
    }

    static func firstLine(_ s: String) -> String {
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    // MARK: Live check

    public enum CheckResult: Equatable, Sendable {
        case ok(MCPServerInfo, [MCPTool])
        case unauthorized
        case failed(String)
    }

    /// Read-only probe: initialize, notifications/initialized, tools/list.
    public static func check(url: String, key: String) async -> CheckResult {
        guard let endpoint = URL(string: url) else { return .failed("Bad URL") }
        func post(_ body: [String: Any], session: String?) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: endpoint, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, r) = try await URLSession.shared.data(for: req)
            return (d, r as! HTTPURLResponse)
        }
        do {
            let (d1, r1) = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-03-26", "capabilities": [String: Any](),
                "clientInfo": ["name": "vexa-local-mac", "version": "1"]]], session: nil)
            if r1.statusCode == 401 || r1.statusCode == 403 { return .unauthorized }
            guard r1.statusCode == 200, let info = parseInitialize(d1) else { return .failed("HTTP \(r1.statusCode)") }
            let sid = r1.value(forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: sid)
            let (d2, r2) = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: sid)
            guard r2.statusCode == 200, let tools = parseTools(d2) else { return .failed("tools/list failed (HTTP \(r2.statusCode))") }
            return .ok(info, tools)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
