import Foundation
import Observation
import VexaCore

/// What we know about one Hugging Face repo.
struct RepoInfo: Sendable {
    var sizeBytes: Int64
    var compatible: Bool
}

struct HubModel: Identifiable, Decodable, Sendable {
    var id: String
    var downloads: Int?
}

enum DownloadState: Equatable {
    case running(fraction: Double)
    case failed(String)
}

/// Lists MLX Whisper models on Hugging Face, and downloads/deletes them locally.
@MainActor @Observable
final class ModelStore {
    var hubError: String?
    var isLoadingHub = false
    var repoInfo: [String: RepoInfo] = [:]
    var downloads: [String: DownloadState] = [:]
    /// Bumped after downloads/deletes so views re-check the cache.
    var cacheVersion = 0

    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var infoRequests: Set<String> = []

    /// Compatible, non-recommended models to show. Filled as repos are checked.
    var compatibleModels: [HubModel] = []
    /// Progress of the compatibility check.
    var checkedCount = 0
    var totalToCheck = 0
    var unreachableCount = 0
    /// Compatible models in the local cache.
    var downloaded: [CachedModel] = []

    @ObservationIgnored private var listLoaded = false
    @ObservationIgnored private var allHubModels: [HubModel] = []
    private static let maxConcurrent = 6

    func refreshDownloaded() {
        downloaded = HFCache.downloadedModels()
    }

    /// Lists mlx-community Whisper repos, then keeps only the ones mlx-whisper can load.
    /// Results are cached for the session. Pass force to start over.
    func loadHubModels(force: Bool = false) async {
        guard !isLoadingHub else { return }
        if force { listLoaded = false }
        refreshDownloaded()
        if listLoaded && unreachableCount == 0 { return }
        isLoadingHub = true
        defer { isLoadingHub = false }
        if !listLoaded {
            var comps = URLComponents(string: "https://huggingface.co/api/models")!
            comps.queryItems = [.init(name: "author", value: "mlx-community"), .init(name: "search", value: "whisper"),
                                .init(name: "sort", value: "downloads"), .init(name: "limit", value: "300")]
            do {
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                // "-asr-" repos are packaged for mlx-audio / transformers, not mlx-whisper.
                allHubModels = try JSONDecoder().decode([HubModel].self, from: data).filter { !$0.id.contains("-asr-") }
                listLoaded = true
                hubError = nil
            } catch {
                hubError = "Could not reach Hugging Face: \(error.localizedDescription)"
                return
            }
        }
        let recommended = Set(ModelCatalog.recommended.map(\.id))
        let candidates = allHubModels.filter { !recommended.contains($0.id) }
        let pending = candidates.filter { repoInfo[$0.id] == nil }
        totalToCheck = pending.count
        checkedCount = 0
        unreachableCount = 0
        updateCompatible(candidates)

        var iterator = pending.makeIterator()
        await withTaskGroup(of: (String, RepoInfo?).self) { group in
            func addNext() {
                guard let next = iterator.next() else { return }
                group.addTask { (next.id, await Self.fetchInfo(next.id)) }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            while let (id, info) = await group.next() {
                checkedCount += 1
                if let info { repoInfo[id] = info } else { unreachableCount += 1 }
                if checkedCount % 10 == 0 { updateCompatible(candidates) }
                addNext()
            }
        }
        updateCompatible(candidates)
        if unreachableCount > 0 && unreachableCount == pending.count {
            hubError = "Could not reach Hugging Face to check which models are compatible."
        } else {
            hubError = nil
        }
    }

    private func updateCompatible(_ candidates: [HubModel]) {
        compatibleModels = candidates.filter { repoInfo[$0.id]?.compatible == true }
    }

    /// Fetches file list and total size for one repo (once).
    func loadInfo(_ id: String) async {
        guard repoInfo[id] == nil, !infoRequests.contains(id) else { return }
        infoRequests.insert(id)
        defer { infoRequests.remove(id) }
        if let info = await Self.fetchInfo(id) { repoInfo[id] = info }
    }

    nonisolated private static func fetchInfo(_ id: String) async -> RepoInfo? {
        struct Entry: Decodable {
            struct LFS: Decodable { var size: Int64 }
            var path: String
            var size: Int64?
            var lfs: LFS?
        }
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/main"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return RepoInfo(sizeBytes: entries.reduce(0) { $0 + ($1.lfs?.size ?? $1.size ?? 0) },
                        compatible: ModelCatalog.isCompatible(files: entries.map(\.path)))
    }

    func isDownloaded(_ id: String) -> Bool {
        _ = cacheVersion
        return HFCache.isDownloaded(id)
    }

    /// Downloads with huggingface_hub from the Whisper server's own venv, so the
    /// cache layout is exactly what the server will read.
    func download(_ id: String, python: URL) {
        guard processes[id] == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            downloads[id] = .failed("Whisper isn't installed yet. Run 'make setup' in the project folder.")
            return
        }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1])", id]
        process.environment = ScriptRunner.shellEnvironment
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        processes[id] = process
        downloads[id] = .running(fraction: 0)

        process.terminationHandler = { proc in
            let err = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
            Task { @MainActor in
                self.processes[id] = nil
                if proc.terminationStatus == 0 {
                    self.downloads[id] = nil
                } else if proc.terminationReason == .uncaughtSignal {
                    self.downloads[id] = nil  // cancelled
                } else {
                    let lastLine = err.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)"
                    self.downloads[id] = .failed(lastLine)
                }
                self.cacheVersion += 1
                self.refreshDownloaded()
            }
        }
        do {
            try process.run()
        } catch {
            processes[id] = nil
            downloads[id] = .failed(error.localizedDescription)
            return
        }
        Task { await self.trackProgress(id) }
    }

    func cancelDownload(_ id: String) {
        processes[id]?.terminate()
    }

    func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: HFCache.repoDirectory(id))
        cacheVersion += 1
        refreshDownloaded()
    }

    private func trackProgress(_ id: String) async {
        await loadInfo(id)
        while processes[id] != nil {
            if let total = repoInfo[id]?.sizeBytes, total > 0 {
                let done = Double(HFCache.bytesOnDisk(id)) / Double(total)
                downloads[id] = .running(fraction: min(done, 0.99))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
