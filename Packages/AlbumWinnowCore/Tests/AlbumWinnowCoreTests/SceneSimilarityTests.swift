import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AlbumWinnowCore

private func sceneBytes(_ name: String = "scene.png") throws -> Data {
    try Data(contentsOf: TestFiles.fixtures.appending(path: name))
}

private func croppedScene() throws -> Data {
    let source = CGImageSourceCreateWithData(try sceneBytes() as CFData, nil)!
    let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let image = original.cropping(to: CGRect(x: Double(original.width) * 0.04, y: 0,
        width: Double(original.width) * 0.92, height: Double(original.height)))!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func blendedScene(fraction: Double) throws -> Data {
    func image(_ name: String) throws -> CGImage {
        let source = CGImageSourceCreateWithData(try sceneBytes(name) as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
    let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
    context.draw(try image("scene.png"), in: rect)
    context.setAlpha(fraction)
    context.draw(try image("landscape.jpg"), in: rect)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct SceneFixtureSource: AssetSource {
    let id = "scene-fixture"
    let images: [String: Data]
    var date: Date? = nil
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: images.keys.sorted().map {
            PhotoAsset(id: AssetID(source: id, item: $0), name: $0, revision: "1", captureDate: date)
        })
    }
    func imageData(for asset: PhotoAsset) async throws -> Data { images[asset.id.item]! }
}

@Suite(.serialized)
struct SceneSimilarityTests {
    @Test func sceneFeatureCacheRoundtripAndMalformedEntryRecoveryPreserveDuplicateFingerprints() throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appending(path: "cache.sqlite")
        let cache = try ScanCache(url: url)
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: "scene"), name: "scene", revision: "1")
        let bytes = try sceneBytes()
        try cache.store([(asset, PreparedImage(data: bytes))])
        let feature = try SceneFeature(input: .bytes(AssetImage(data: bytes)))
        try cache.storeSceneFeature(feature, for: asset)
        let restored = try #require(try cache.sceneFeature(for: asset))
        #expect(try feature.distance(to: restored) == 0)
        #expect(feature.keys == restored.keys)
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in try db.execute(sql: "UPDATE scene_features SET configuration = 'other-revision'") }
        #expect(try cache.sceneFeature(for: asset) == nil)
        try cache.storeSceneFeature(feature, for: asset)
        try database.write { db in try db.execute(sql: "UPDATE scene_features SET archive = ?", arguments: [Data("invalid".utf8)]) }
        #expect(try cache.sceneFeature(for: asset) == nil)
        #expect(try cache.signatures(source: asset.id.source).count == 1)
        try cache.storeSceneFeature(feature, for: asset)
        var invalidQuality = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature.quality)) as? [String: Any])
        invalidQuality["focusEnergy"] = -1
        let malformed = try JSONSerialization.data(withJSONObject: invalidQuality)
        try database.write { db in try db.execute(sql: "UPDATE scene_features SET quality = ?", arguments: [malformed]) }
        #expect(try cache.sceneFeature(for: asset) == nil, "Out-of-range cached measurements cannot supply recommendation evidence")
        #expect(try cache.signatures(source: asset.id.source).count == 1)
        #expect(throws: (any Error).self) { try SceneFeature(archive: Data(repeating: 0, count: 16_385), quality: feature.quality) }
        try cache.storeSceneFeature(feature, for: asset)
        try cache.clear()
        #expect(try cache.sceneFeature(for: asset) == nil)
        #expect(try cache.signatures(source: asset.id.source).isEmpty)
    }

    @Test func cancellingSceneAnalysisKeepsCacheForExplicitRescan() async throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = try ScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let source = SceneFixtureSource(images: ["first": try sceneBytes(), "second": try croppedScene()])
        let task = Task {
            try await engine.scan([source], includeSimilarScenes: true) { update in
                if case .similarity(let completed, _) = update, completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled scene analysis returned a cleanup result") }
        catch is CancellationError {}
        let resumed = try await engine.scan([source], includeSimilarScenes: true)
        #expect(resumed.reused == 2)
        #expect(resumed.issues.isEmpty)
        #expect(resumed.groups.count == 1)
        #expect(resumed.groups.first?.match == .sceneSimilar)
    }

    @Test func visualSceneRetrievalWorksWithoutDatesAndDoesNotBroadenDuplicateDetector() async throws {
        let first = try sceneBytes(), second = try croppedScene()
        #expect(try DuplicateDetector().compare(first, second) == .distinct)
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = try ScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let source = SceneFixtureSource(images: ["first": first, "second": second])
        let normal = try await engine.scan([source])
        #expect(normal.groups.isEmpty)
        let similar = try await engine.scan([source], includeSimilarScenes: true)
        let group = try #require(similar.groups.first)
        #expect(group.match == .sceneSimilar)
        #expect(group.sceneEvidence?.count == 1)
        #expect(group.sceneEvidence?.first?.sharedBurst == false)
        #expect(group.assets.allSatisfy { $0.captureDate == nil })
        let cached = try await engine.scan([source], includeSimilarScenes: true)
        #expect(cached.groups == similar.groups)
        #expect(cached.reused == 2)
    }

    @Test func duplicateGroupsTakePriorityOverSceneQueueAndTimeAloneIsNotEvidence() async throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = try ScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let bytes = try sceneBytes()
        let source = SceneFixtureSource(images: ["a": bytes, "b": bytes, "c": try croppedScene()])
        let result = try await engine.scan([source], includeSimilarScenes: true)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.match == .exactDuplicate)
        #expect(Set(result.groups.flatMap { $0.assets.map(\.id) }).count == 2)
        let distinct = try await engine.scan([SceneFixtureSource(images: ["scene": bytes, "flat": try sceneBytes("flat-a.png")], date: Date())], includeSimilarScenes: true)
        #expect(distinct.groups.isEmpty)
        let flat = try SceneFeature(input: .bytes(AssetImage(data: sceneBytes("flat-a.png"))))
        let a = PhotoAsset(id: AssetID(source: "fixture", item: "a"), name: "a", revision: "1")
        let b = PhotoAsset(id: AssetID(source: "fixture", item: "b"), name: "b", revision: "1")
        #expect(try flat.match(to: flat, first: a, second: b) == nil, "Uniform-color proximity alone is not a scene match")
    }

    @Test func sceneGroupsRejectTransitiveChainsAndBoundGroupAndCandidateSizes() throws {
        func item(_ name: String, fraction: Double) throws -> SceneItem {
            let bytes = try blendedScene(fraction: fraction)
            let prepared = try PreparedImage(data: bytes).fingerprint
            return SceneItem(asset: PhotoAsset(id: AssetID(source: "fixture", item: name), name: name, revision: "1", burstIdentifier: "controlled-burst"),
                evidence: PhotoEvidence(width: prepared.width, height: prepared.height, bitDepth: prepared.observedBitDepth,
                    hasWideColor: prepared.hasWideColor, edgeContrast: prepared.edgeDetail),
                feature: try SceneFeature(input: .bytes(AssetImage(data: bytes))))
        }
        let a = try item("a", fraction: 0), b = try item("b", fraction: 0.1), c = try item("c", fraction: 0.2)
        #expect(try a.feature.match(to: b.feature, first: a.asset, second: b.asset) != nil)
        #expect(try b.feature.match(to: c.feature, first: b.asset, second: c.asset) != nil)
        #expect(try a.feature.match(to: c.feature, first: a.asset, second: c.asset) == nil)
        let chain = try SceneGrouping.groups([a, b, c], sides: nil) { _ in }
        #expect(chain.allSatisfy { $0.assets.count < 3 })
        let many = (0..<200).map { index in
            SceneItem(asset: PhotoAsset(id: AssetID(source: "fixture", item: String(format: "%04d", index)), name: "\(index)", revision: "1"), evidence: b.evidence, feature: b.feature)
        }
        let groups = try SceneGrouping.groups(many, sides: nil) { _ in }
        #expect(groups.allSatisfy { $0.assets.count <= SceneGrouping.maximumMembers })
        let ids = groups.flatMap { $0.assets.map(\.id) }
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 200)
        var index = SceneCandidates()
        for (position, item) in many.enumerated() {
            #expect(index.candidates(for: item.feature, asset: item.asset).count <= SceneCandidates.limit)
            index.insert(item.feature, asset: item.asset, at: position)
        }
    }

    @Test func finalSceneCleanupRechecksContentConfigurationAndReadOnlyProtection() async throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = scratch.appending(path: "keep-\(UUID()).png"), second = scratch.appending(path: "remove-\(UUID()).png")
        try sceneBytes("flat-a.png").write(to: first)
        try croppedScene().write(to: second)
        let source = FileSystemSource(directory: scratch)
        func assets() async throws -> (PhotoAsset, PhotoAsset) {
            let values = try await source.snapshot().assets
            return (try #require(values.first { $0.name == first.lastPathComponent }), try #require(values.first { $0.name == second.lastPathComponent }))
        }
        let (a, b) = try await assets()
        let mismatch = try await AssetMutationService().apply([CleanupPair(keep: a, remove: b, sceneAlgorithm: SceneFeature.version)], sources: [source], protection: CleanupProtection())
        #expect(mismatch.first?.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: second.path))
        try sceneBytes().write(to: first)
        let (currentA, currentB) = try await assets()
        let pair = CleanupPair(keep: currentA, remove: currentB, sceneAlgorithm: SceneFeature.version)
        let protected = try await AssetMutationService().apply([pair], sources: [source], protection: CleanupProtection(readOnlySources: [source.id]))
        #expect(protected.first?.status == .skipped)
        let stale = try await AssetMutationService().apply([CleanupPair(keep: currentA, remove: currentB, sceneAlgorithm: "unknown")], sources: [source], protection: CleanupProtection())
        #expect(stale.first?.status == .skipped)
        let valid = try await AssetMutationService().apply([pair], sources: [source], protection: CleanupProtection())
        #expect(valid.first?.status == .movedToTrash)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        if let path = valid.first?.detail { try? FileManager.default.removeItem(atPath: path) }
    }
}
