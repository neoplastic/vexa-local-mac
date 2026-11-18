import Foundation

/// Reads and repairs `~/.docker/config.json` for a Homebrew Docker setup.
///
/// - Homebrew's `docker-compose` and `docker-buildx` are Docker CLI plugins. Docker only finds
///   them when their folder is listed in `cliPluginsExtraDirs` (or they are linked into
///   `~/.docker/cli-plugins`).
/// - Docker Desktop leaves `"credsStore": "desktop"` behind. Without Docker Desktop's
///   `docker-credential-desktop`, every image pull fails.
///
/// Only those two keys are touched; everything else in the file is kept.
public enum DockerConfigFile {
    public static let homebrewPluginDir = "/opt/homebrew/lib/docker/cli-plugins"
    static let pluginKey = "cliPluginsExtraDirs"
    static let credsKey = "credsStore"

    public struct Status: Equatable, Sendable {
        /// False when the file exists but isn't a JSON object (then it's left alone).
        public var readable: Bool
        /// `cliPluginsExtraDirs` already lists the plugin folder.
        public var hasPluginDir: Bool
        /// `"credsStore": "desktop"` is set.
        public var desktopCredsStore: Bool

        public init(readable: Bool = true, hasPluginDir: Bool = false, desktopCredsStore: Bool = false) {
            self.readable = readable
            self.hasPluginDir = hasPluginDir
            self.desktopCredsStore = desktopCredsStore
        }
    }

    public enum FixError: Error, LocalizedError, Equatable {
        case notAnObject
        case unexpectedPluginDirs

        public var errorDescription: String? {
            switch self {
            case .notAnObject: return "~/.docker/config.json isn't valid JSON, so it was left alone. Fix it by hand."
            case .unexpectedPluginDirs: return "cliPluginsExtraDirs in ~/.docker/config.json isn't a list of folders, so it was left alone."
            }
        }
    }

    /// What the file says. A missing or empty file is a readable, empty config.
    public static func status(_ data: Data?, pluginDir: String = homebrewPluginDir) -> Status {
        guard let object = try? object(data) else { return Status(readable: false) }
        let dirs = object[pluginKey] as? [Any] ?? []
        return Status(readable: true,
                      hasPluginDir: dirs.contains { ($0 as? String).map(normalised) == normalised(pluginDir) },
                      desktopCredsStore: object[credsKey] as? String == "desktop")
    }

    /// The repaired file. Adds `addPluginDir` to `cliPluginsExtraDirs` (if not already there)
    /// and removes `"credsStore": "desktop"`. Every other key is kept.
    public static func fixed(_ data: Data?, addPluginDir: String?, removeDesktopCredsStore: Bool) throws -> Data {
        var object = try object(data)
        if let dir = addPluginDir {
            var dirs: [String] = []
            if let existing = object[pluginKey] {
                guard let list = existing as? [Any], let strings = list as? [String] else {
                    throw FixError.unexpectedPluginDirs
                }
                dirs = strings
            }
            if !dirs.contains(where: { normalised($0) == normalised(dir) }) { dirs.append(dir) }
            object[pluginKey] = dirs
        }
        if removeDesktopCredsStore, object[credsKey] as? String == "desktop" {
            object.removeValue(forKey: credsKey)
        }
        var out = try JSONSerialization.data(withJSONObject: object,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }

    /// `config.json.bak-20261118-142233`
    public static func backupName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "config.json.bak-\(f.string(from: date))"
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixError.notAnObject
        }
        return object
    }

    private static func normalised(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
