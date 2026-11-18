import Foundation

/// Picks a Node 20+ the same way `use_modern_node` in scripts/lib.sh does.
///
/// Order tried: the `node` first on PATH, nvm's default alias, Homebrew, Volta, then every
/// other nvm and fnm version (newest first). The first one that is Node 20 or newer wins.
/// The app probes the versions; this type only decides.
public enum NodeSelection {
    public static let minimumMajor = 20

    /// Follows nvm's alias files: default → lts/jod → v22.23.4 (at most 4 hops, like the script).
    /// `readAlias(name)` returns the first line of `~/.nvm/alias/<name>`, or nil when that
    /// isn't a file. Returns nil when there is no usable default alias.
    public static func nvmDefaultAlias(readAlias: (String) -> String?) -> String? {
        var alias = "default"
        for _ in 0..<4 {
            guard !alias.isEmpty, let next = readAlias(alias) else { break }
            alias = next.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return alias.isEmpty || alias == "default" ? nil : alias
    }

    /// The installed nvm version folder an alias points at: the highest `v<alias>*`
    /// (like `ls -d v22* | sort -V | tail -1`).
    public static func nvmVersion(matching alias: String, installed: [String]) -> String? {
        let prefix = "v" + (alias.hasPrefix("v") ? String(alias.dropFirst()) : alias)
        return installed.filter { $0.hasPrefix(prefix) }.max(by: versionLess)
    }

    /// Every place to look, in the order the script looks.
    public static func candidates(currentNode: String?, home: String, nvmDefaultVersion: String?,
                                  nvmVersions: [String], fnmVersions: [String]) -> [String] {
        var list: [String] = []
        if let currentNode, !currentNode.isEmpty { list.append(currentNode) }
        if let v = nvmDefaultVersion { list.append(nvmNode(home: home, version: v)) }
        list += ["/opt/homebrew/bin/node", "\(home)/.volta/bin/node"]
        let others = nvmVersions.map { nvmNode(home: home, version: $0) }
            + fnmVersions.map { "\(home)/.local/share/fnm/node-versions/\($0)/installation/bin/node" }
        list += others.sorted { versionLess($1, $0) }   // sort -rV
        return list
    }

    static func nvmNode(home: String, version: String) -> String {
        "\(home)/.nvm/versions/node/\(version)/bin/node"
    }

    /// The first candidate whose `node --version` output is 20 or newer.
    /// `versions` maps a path to its `--version` output; paths that don't run are left out.
    public static func choose(candidates: [String], versions: [String: String]) -> String? {
        candidates.first { (versions[$0].flatMap(major) ?? 0) >= minimumMajor }
    }

    /// 22 from "v22.23.4", "22.23.4" or "22".
    public static func major(_ version: String) -> Int? {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") { v.removeFirst() }
        return v.split(separator: ".").first.flatMap { Int($0) }
    }

    /// Natural ("version") ordering: runs of digits compare as numbers, so v9 < v10.
    public static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = chunks(a), y = chunks(b)
        for (p, q) in zip(x, y) where p != q {
            if let i = Int(p), let j = Int(q) {
                if i != j { return i < j }
                return p < q
            }
            return p < q
        }
        return x.count < y.count
    }

    private static func chunks(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var digits = false
        for ch in s {
            let d = ch.isASCII && ch.isNumber
            if !current.isEmpty && d != digits { out.append(current); current = "" }
            digits = d
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// The first executable `name` on a PATH string (like `command -v`).
public enum PathLookup {
    public static func find(_ name: String, in path: String, isExecutable: (String) -> Bool) -> String? {
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = (dir.hasSuffix("/") ? String(dir) : dir + "/") + name
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
