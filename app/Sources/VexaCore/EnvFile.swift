import Foundation

/// Minimal reader/writer for the project's KEY=VALUE .env file.
public enum EnvFile {
    public static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        // "\r\n" is a single Character in Swift, so normalise line endings first.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Returns `text` with KEY set to `value`, replacing the existing line or appending one.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") }) {
            lines[i] = "\(key)=\(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key)=\(value)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Updates one key in place. Writes non-atomically so the file keeps its
    /// permissions (setup makes .env readable by the owner only).
    public static func set(_ key: String, to value: String, at url: URL) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try Data(setting(key, to: value, in: text).utf8).write(to: url)
    }
}
