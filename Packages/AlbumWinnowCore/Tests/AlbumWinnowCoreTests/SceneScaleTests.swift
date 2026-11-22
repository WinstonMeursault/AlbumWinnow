import Darwin
import Foundation
import Testing
@testable import AlbumWinnowCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["ALBUMWINNOW_SCENE_SCALE"] != nil))
func sceneScaleCacheCancellationAndBoundedGrouping() async throws {
    let count = try #require(Int(ProcessInfo.processInfo.environment["ALBUMWINNOW_SCENE_SCALE"] ?? ""))
    #expect([10_000, 50_000, 100_000].contains(count))
    let scratch = TestFiles.root.appending(path: "scratch/scene-scale-\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let cache = try ScanCache(url: scratch.appending(path: "cache.sqlite"))
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "scene.png"))
    let feature = try SceneFeature(input: .bytes(AssetImage(data: bytes)))
    let assets = (0..<count).map { PhotoAsset(id: AssetID(source: "scale-fixture", item: String(format: "%06d", $0)), name: "Synthetic \($0)", revision: "1") }
    let started = Date()
    for asset in assets { try cache.storeSceneFeature(feature, for: asset) }
    let stored = Date()
    var items: [SceneItem] = []
    for asset in assets {
        let restored = try #require(try cache.sceneFeature(for: asset))
        items.append(SceneItem(asset: asset, evidence: PhotoEvidence(width: 512, height: 512,
            bitDepth: nil, hasWideColor: false, edgeContrast: nil), feature: restored))
    }
    let loaded = Date()
    // Every observation is independently restored. Identical generated pixels stress dense buckets,
    // maximum-size splits and cache memory, and do not measure natural-photo accuracy.
    let groups = try SceneGrouping.groups(items, sides: nil) { _ in }
    let grouped = Date()
    #expect(groups.allSatisfy { $0.assets.count <= SceneGrouping.maximumMembers })
    let ids = groups.flatMap { $0.assets.map(\.id) }
    #expect(Set(ids).count == ids.count)
    #expect(ids.count >= count - 1)
    let archive = try feature.archive()
    let quality = feature.quality
    let cancellationAssets = Array(assets.prefix(2048))
    let cancelled = Task {
        let cancellationItems = try cancellationAssets.map { asset in
            SceneItem(asset: asset, evidence: PhotoEvidence(width: 512, height: 512,
                bitDepth: nil, hasWideColor: false, edgeContrast: nil),
                feature: try SceneFeature(archive: archive, quality: quality))
        }
        return try SceneGrouping.groups(cancellationItems, sides: nil) { done in
            if done >= 1024 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    do { _ = try await cancelled.value; Issue.record("Scene grouping ignored cancellation") }
    catch is CancellationError {}
    #expect(try cache.sceneFeature(for: assets[1024]) != nil, "Cancellation must leave reusable feature data")
    let resumed = try SceneGrouping.groups(items, sides: nil) { _ in }
    #expect(resumed.map(\.id) == groups.map(\.id))
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("SCENE_SCALE count=\(count) cache_write_s=\(stored.timeIntervalSince(started)) cache_load_s=\(loaded.timeIntervalSince(stored)) grouping_s=\(grouped.timeIntervalSince(loaded)) peak_rss_bytes=\(usage.ru_maxrss) groups=\(groups.count) max_candidates=\(SceneCandidates.limit) max_members=\(SceneGrouping.maximumMembers)")
}
