import XCTest
@testable import VexaCore

final class ModelCacheTests: XCTestCase {
    private var hub: URL!

    override func setUpWithError() throws {
        hub = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hub)
    }

    /// Creates a cache entry; each file is (snapshot name, blob size).
    private func makeRepo(_ id: String, files: [String: Int], blobExtra: Int = 0) throws {
        let fm = FileManager.default
        let dir = HFCache.repoDirectory(id, hub: hub)
        let blobs = dir.appendingPathComponent("blobs")
        let snap = dir.appendingPathComponent("snapshots/abc123")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        for (name, size) in files {
            let blob = blobs.appendingPathComponent(UUID().uuidString)
            try Data(count: size).write(to: blob)
            try fm.createSymbolicLink(at: snap.appendingPathComponent(name), withDestinationURL: blob)
        }
        if blobExtra > 0 {
            try Data(count: blobExtra).write(to: blobs.appendingPathComponent("x.incomplete"))
        }
    }

    func testCompatibilityFilter() {
        XCTAssertTrue(ModelCatalog.isCompatible(files: ["config.json", "weights.npz"]))
        XCTAssertTrue(ModelCatalog.isCompatible(files: ["config.json", "weights.safetensors", "README.md"]))
        XCTAssertFalse(ModelCatalog.isCompatible(files: ["config.json", "model.safetensors"]))
        XCTAssertFalse(ModelCatalog.isCompatible(files: ["weights.npz"]))
        XCTAssertFalse(ModelCatalog.isCompatible(files: []))
    }

    func testRepoIdParsing() {
        XCTAssertEqual(HFCache.repoId(fromDirectoryName: "models--mlx-community--whisper-tiny-mlx"),
                       "mlx-community/whisper-tiny-mlx")
        XCTAssertNil(HFCache.repoId(fromDirectoryName: "datasets--a--b"))
        XCTAssertNil(HFCache.repoId(fromDirectoryName: ".locks"))
        XCTAssertNil(HFCache.repoId(fromDirectoryName: "models--broken"))
    }

    func testEnumeratesOnlyCompatibleModels() throws {
        try makeRepo("mlx-community/whisper-tiny-mlx", files: ["config.json": 10, "weights.npz": 100])
        try makeRepo("mlx-community/whisper-small-mlx", files: ["config.json": 5, "weights.safetensors": 50])
        try makeRepo("mlx-community/whisper-large-v3-asr-fp16", files: ["config.json": 5, "model.safetensors": 500])
        try makeRepo("someone/not-a-speech-model", files: ["config.json": 5, "weights.npz": 5])
        let found = HFCache.downloadedModels(hub: hub)
        XCTAssertEqual(found.map(\.repoId), ["mlx-community/whisper-tiny-mlx", "mlx-community/whisper-small-mlx"])
        XCTAssertEqual(found.map(\.bytes), [110, 55])
    }

    func testPartialDownloadIsSkippedButCounted() throws {
        try makeRepo("mlx-community/whisper-base-mlx", files: ["config.json": 10], blobExtra: 1000)
        XCTAssertTrue(HFCache.downloadedModels(hub: hub).isEmpty)
        XCTAssertEqual(HFCache.bytesOnDisk("mlx-community/whisper-base-mlx", hub: hub), 1010)
    }

    func testTotalsAndEmptyCache() throws {
        XCTAssertEqual(HFCache.totalBytes(HFCache.downloadedModels(hub: hub)), 0)
        try makeRepo("mlx-community/whisper-tiny-mlx", files: ["config.json": 10, "weights.npz": 100])
        try makeRepo("mlx-community/distil-whisper-large-v3", files: ["config.json": 1, "weights.npz": 1000])
        XCTAssertEqual(HFCache.totalBytes(HFCache.downloadedModels(hub: hub)), 1111)
    }

    func testMissingHubDirectory() {
        let missing = hub.appendingPathComponent("nope")
        XCTAssertTrue(HFCache.downloadedModels(hub: missing).isEmpty)
    }

    func testDeleteRemovesModelFromEnumeration() throws {
        try makeRepo("mlx-community/whisper-tiny-mlx", files: ["config.json": 10, "weights.npz": 100])
        try FileManager.default.removeItem(at: HFCache.repoDirectory("mlx-community/whisper-tiny-mlx", hub: hub))
        XCTAssertTrue(HFCache.downloadedModels(hub: hub).isEmpty)
    }
}
