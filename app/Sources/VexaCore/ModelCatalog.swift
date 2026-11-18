import Foundation

/// A Whisper model we suggest, with plain-language guidance.
public struct RecommendedModel: Identifiable, Sendable {
    public let id: String          // Hugging Face repo id
    public let title: String
    public let detail: String
}

public enum ModelCatalog {
    public static let recommended: [RecommendedModel] = [
        .init(id: "mlx-community/whisper-large-v3-turbo", title: "Large v3 Turbo",
              detail: "Best balance of speed and accuracy. The default."),
        .init(id: "mlx-community/whisper-large-v3-turbo-q4", title: "Large v3 Turbo, 4-bit",
              detail: "A third of the size and lighter on memory. Slightly less accurate."),
        .init(id: "mlx-community/whisper-large-v3-mlx", title: "Large v3",
              detail: "Most accurate. Roughly 2-3x slower than Turbo, needs more memory."),
        .init(id: "mlx-community/distil-whisper-large-v3", title: "Distil Large v3",
              detail: "Fast and accurate, but English only."),
        .init(id: "mlx-community/whisper-medium-mlx", title: "Medium",
              detail: "Older mid-size model. Turbo is usually better."),
        .init(id: "mlx-community/whisper-small-mlx", title: "Small",
              detail: "For Macs with 8 GB memory. Noticeably less accurate."),
        .init(id: "mlx-community/whisper-base-mlx", title: "Base",
              detail: "Very fast, rough accuracy."),
        .init(id: "mlx-community/whisper-tiny-mlx", title: "Tiny",
              detail: "For testing the pipeline only."),
    ]

    /// mlx-whisper loads config.json plus weights.npz or weights.safetensors.
    /// Repos with model.safetensors are for other libraries (mlx-audio, transformers).
    public static func isCompatible(files: [String]) -> Bool {
        let names = Set(files)
        return names.contains("config.json")
            && (names.contains("weights.npz") || names.contains("weights.safetensors"))
    }
}

/// Reads the local Hugging Face cache (same layout huggingface_hub uses).
public enum HFCache {
    public static var hubDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"], !hub.isEmpty { return URL(fileURLWithPath: hub) }
        if let home = env["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    public static func repoDirectory(_ repoId: String, hub: URL = hubDirectory) -> URL {
        hub.appendingPathComponent("models--" + repoId.replacingOccurrences(of: "/", with: "--"))
    }

    /// True when a snapshot holds a config and loadable weights.
    public static func isDownloaded(_ repoId: String, hub: URL = hubDirectory) -> Bool {
        let snapshots = repoDirectory(repoId, hub: hub).appendingPathComponent("snapshots")
        let fm = FileManager.default
        guard let revs = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return false }
        for rev in revs {
            let files = (try? fm.contentsOfDirectory(atPath: snapshots.appendingPathComponent(rev).path)) ?? []
            if ModelCatalog.isCompatible(files: files) { return true }
        }
        return false
    }

    /// Bytes stored for a repo, including partial downloads.
    public static func bytesOnDisk(_ repoId: String, hub: URL = hubDirectory) -> Int64 {
        let blobs = repoDirectory(repoId, hub: hub).appendingPathComponent("blobs")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// A compatible MLX Whisper model found in the local cache.
public struct CachedModel: Identifiable, Equatable, Sendable {
    public var id: String { repoId }
    public let repoId: String
    public let bytes: Int64
}

extension HFCache {
    /// Turns "models--org--name" into "org/name". Returns nil for other cache entries.
    public static func repoId(fromDirectoryName name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        guard let range = rest.range(of: "--") else { return nil }
        let org = rest[..<range.lowerBound]
        let repo = rest[range.upperBound...]
        guard !org.isEmpty, !repo.isEmpty else { return nil }
        return "\(org)/\(repo)"
    }

    /// Every compatible MLX Whisper model in the cache, largest first.
    /// Partial downloads and repos meant for other libraries are skipped.
    public static func downloadedModels(hub: URL = hubDirectory) -> [CachedModel] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []
        var result: [CachedModel] = []
        for name in names {
            guard let id = repoId(fromDirectoryName: name),
                  id.localizedCaseInsensitiveContains("whisper"),
                  isDownloaded(id, hub: hub) else { continue }
            result.append(CachedModel(repoId: id, bytes: bytesOnDisk(id, hub: hub)))
        }
        return result.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.repoId < $1.repoId }
    }

    public static func totalBytes(_ models: [CachedModel]) -> Int64 {
        models.reduce(0) { $0 + $1.bytes }
    }
}
