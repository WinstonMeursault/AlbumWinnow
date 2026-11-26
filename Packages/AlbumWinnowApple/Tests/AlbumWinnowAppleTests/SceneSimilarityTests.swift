import AlbumWinnowRust
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AlbumWinnowApple

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
        let database = try FixtureDatabase(url)
        try database.execute("UPDATE scene_features SET provider = X'00'")
        #expect(try cache.sceneFeature(for: asset) == nil)
        try cache.storeSceneFeature(feature, for: asset)
        try database.execute("UPDATE scene_features SET archive = ?", bindings: [.blob(Data("invalid".utf8))])
        #expect(try cache.sceneFeature(for: asset) == nil)
        #expect(try cache.signatures(source: asset.id.source).count == 1)
        try cache.storeSceneFeature(feature, for: asset)
        var invalidQuality = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature.quality)) as? [String: Any])
        invalidQuality["focusEnergy"] = -1
        let malformed = try JSONSerialization.data(withJSONObject: invalidQuality)
        try database.execute("UPDATE scene_features SET quality = ?", bindings: [.blob(malformed)])
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
        let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let source = SceneFixtureSource(images: ["first": try sceneBytes(), "second": try croppedScene()])
        let task = Task {
            try await engine.fixtureScan([source], includeSimilarScenes: true) { update in
                if case .similarity(let completed, _) = update, completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled scene analysis returned a cleanup result") }
        catch is CancellationError {}
        let resumed = try await engine.fixtureScan([source], includeSimilarScenes: true)
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
        let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let source = SceneFixtureSource(images: ["first": first, "second": second])
        let normal = try await engine.fixtureScan([source])
        #expect(normal.groups.isEmpty)
        let similar = try await engine.fixtureScan([source], includeSimilarScenes: true)
        let group = try #require(similar.groups.first)
        #expect(group.match == .sceneSimilar)
        #expect(group.sceneEvidence?.count == 1)
        #expect(group.sceneEvidence?.first?.sharedBurst == false)
        #expect(group.assets.allSatisfy { $0.captureDate == nil })
        let cached = try await engine.fixtureScan([source], includeSimilarScenes: true)
        #expect(cached.groups == similar.groups)
        #expect(cached.reused == 2)
    }

    @Test func duplicateGroupsTakePriorityOverSceneQueueAndTimeAloneIsNotEvidence() async throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
        let bytes = try sceneBytes()
        let source = SceneFixtureSource(images: ["a": bytes, "b": bytes, "c": try croppedScene()])
        let result = try await engine.fixtureScan([source], includeSimilarScenes: true)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.match == .exactDuplicate)
        #expect(Set(result.groups.flatMap { $0.assets.map(\.id) }).count == 2)
        let distinct = try await engine.fixtureScan([SceneFixtureSource(images: ["scene": bytes, "flat": try sceneBytes("flat-a.png")], date: Date())], includeSimilarScenes: true)
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
        let chain = try SceneGrouping.fixtureGroups([a, b, c], sides: nil) { _ in }
        #expect(chain.allSatisfy { $0.assets.count < 3 })
        let many = (0..<200).map { index in
            SceneItem(asset: PhotoAsset(id: AssetID(source: "fixture", item: String(format: "%04d", index)), name: "\(index)", revision: "1"), evidence: b.evidence, feature: b.feature)
        }
        let groups = try SceneGrouping.fixtureGroups(many, sides: nil) { _ in }
        #expect(groups.allSatisfy { $0.assets.count <= SceneGrouping.maximumMembers })
        let ids = groups.flatMap { $0.assets.map(\.id) }
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 200)
        let index = SceneCandidates()
        for (position, item) in many.enumerated() {
            #expect(try index.candidates(for: item.feature, asset: item.asset).count <= SceneCandidates.limit)
            try index.insert(item.feature, asset: item.asset, at: position)
        }
    }

    @Test func nativeSceneSessionCommitsDirectlyAndRequiresFinalNativeValidation() throws {
        let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let review = try RustReviewSession(databasePath: scratch.appending(path: "review.sqlite").path, initialized: false)
        let source = try review.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .controlledTest,
            namespace: "native.scene.fixture.v2", identity: Data([1]), bookmark: Data(), label: "Generated"))
        var settings = try review.header().settings
        settings.similarScenesEnabled = true
        _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
        let bytes = [try sceneBytes(), try croppedScene()]
        let fingerprints = try bytes.map { try PreparedImage(data: $0).fingerprint }
        let items = try bytes.enumerated().map { index, data in
            let fingerprint = fingerprints[index]
            return SceneItem(asset: PhotoAsset(id: AssetID(source: source.id, item: "\(index)"), name: "\(index).png", revision: "1"),
                evidence: PhotoEvidence(width: fingerprint.width, height: fingerprint.height,
                    bitDepth: fingerprint.observedBitDepth, hasWideColor: fingerprint.hasWideColor, edgeContrast: fingerprint.edgeDetail),
                feature: try SceneFeature(input: .bytes(AssetImage(data: data))), bitDepth: fingerprint.bitDepth)
        }
        let cancellation = CancellationHandle()
        let operation = "native-scene"
        try review.beginScan(expectedRevision: review.header().metadata.revision, operationId: operation)
        try review.appendScanAssets(operationId: operation, assets: items.map { item in
            CoreScanReviewAsset(asset: item.asset.reviewValue(kind: .controlledTest), evidence: CoreReviewEvidence(
                asset: item.asset.id.coreValue, width: UInt32(item.evidence.width), height: UInt32(item.evidence.height),
                bitDepth: item.evidence.bitDepth.map(UInt16.init), wideColor: item.evidence.hasWideColor,
                edgeDetail: item.evidence.edgeContrast, captureDate: nil))
        }, cancellation: cancellation)
        let detection = try RustScanSession(operationId: operation, sourceIds: [source.id], sides: nil,
            preferredSource: nil, cancellation: cancellation)
        try detection.appendPrepared(items: items.enumerated().map { index, item in
            ScanItemInput(asset: item.asset.id.coreValue, revision: "1", fingerprint: try fingerprints[index].coreValue,
                          associatedResources: false, nativeIdentity: nil)
        })
        try detection.completePreparation()
        while true {
            let batch = try detection.nextBatch(maximum: 16)
            if batch.done { break }
            try detection.submitResults(operationId: operation, batchId: batch.batchId, results: batch.tasks.map {
                CoreTaskResult(taskId: $0.taskId, outcome: .matched(kind: .distinct))
            })
        }
        #expect(try detection.sceneCandidatePage(offset: 0, limit: 16).count == 2)
        var validated = [AssetID]()
        let scenes = try SceneGrouping.detect(items, operation: operation, sides: nil, preferredSource: nil,
            cancellation: cancellation, validate: { validated.append($0.id) }, progress: { _ in })
        #expect(validated.count == 6, "Two checks around the distance and one final check per member")
        #expect(Set(validated.suffix(2)) == Set(items.map { $0.asset.id }))
        _ = try review.finishDetectedScan(operationId: operation, detection: detection, scenes: scenes, cancellation: cancellation)
        settings.query.collection = .similarScenes
        _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
        let summary = try #require(review.queryPage(offset: 0, limit: 1).first)
        let detail = try review.groupDetail(signature: summary.signature)
        #expect(detail.group.scene == SceneFeature.provider)
        #expect(detail.group.sceneMatches.count == 1 && detail.group.members.count == 2)
        var checks = 0
        #expect(throws: AssetAccessError.changedDuringScan) {
            try SceneGrouping.detect(items, operation: operation, sides: nil, preferredSource: nil,
                cancellation: cancellation, validate: { _ in
                    checks += 1
                    if checks == 5 { throw AssetAccessError.changedDuringScan }
                }, progress: { _ in })
        }
        #expect(checks == 5, "A changed final member aborts the handoff instead of publishing a partial scene")
    }

    @Test func finalSceneCleanupRechecksContentConfigurationAndReadOnlyProtection() async throws {
        let fixture = try NativeCleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = fixture.source.directory.appending(path: "keep0.png")
        let second = fixture.source.directory.appending(path: "remove0.png")
        try sceneBytes("flat-a.png").write(to: first)
        let cropped = try croppedScene()
        try cropped.write(to: second)
        let mismatch = try await fixture.prepare(scene: SceneFeature.provider)
        let rejected = try await AppleCleanupExecutor(session: fixture.session).apply(operation: mismatch, sources: fixture.context())
        #expect(rejected.trashLocations.isEmpty)
        #expect(try fixture.results(mismatch).first?.outcome == .skipped(reason: .noLongerDuplicate))
        try sceneBytes().write(to: first)
        let members = try await fixture.source.snapshot().assets.map {
            try $0.reviewValue(kind: .fileSystem, nativeIdentity: fixture.source.nativeIdentity(for: $0), linkCount: fixture.source.linkCount(for: $0))
        }
        try fixture.session.beginReadOnlySnapshot(expectedRevision: fixture.session.header().metadata.revision,
            operationId: "protected", source: fixture.source.id)
        try fixture.session.appendReadOnlySnapshot(operationId: "protected", members: members, cancellation: CancellationHandle())
        _ = try fixture.session.finishReadOnlySnapshot(operationId: "protected", complete: true, cancellation: CancellationHandle())
        await #expect(throws: BridgeError.InvalidValue) { try await fixture.prepare(scene: SceneFeature.provider) }
        #expect(FileManager.default.fileExists(atPath: second.path))
        _ = try fixture.session.removeReadOnly(expectedRevision: fixture.session.header().metadata.revision, source: fixture.source.id)
        var stale = SceneFeature.provider
        stale.modelRevision = "unknown"
        let outdated = try await fixture.prepare(scene: stale)
        let skipped = try await AppleCleanupExecutor(session: fixture.session).apply(operation: outdated, sources: fixture.context())
        #expect(skipped.trashLocations.isEmpty)
        #expect(try fixture.results(outdated).first?.outcome == .skipped(reason: .noLongerDuplicate))
        let valid = try await fixture.prepare(scene: SceneFeature.provider)
        let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: valid, sources: fixture.context())
        let result = try #require(fixture.results(valid).first)
        #expect(result.outcome == .movedToTrash)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
        let trash = try #require(receipt.trashLocations[result.item.key])
        try FileManager.default.moveItem(at: trash, to: second)
        #expect(try Data(contentsOf: second) == cropped)
    }
}

// Direct scene-driver fixtures inspect its output without creating a production
// group projection or a second review owner.
extension SceneGrouping {
    static var maximumMembers: Int { 24 }
    static func fixtureGroups(_ items: [SceneItem], sides: ComparisonSides?, preferredSource: String? = nil,
                       cancellation: CancellationHandle = CancellationHandle(),
                       validate: (PhotoAsset) throws -> Void = { _ in }, progress: (Int) -> Void) throws -> [DuplicateGroup] {
        let session = try detect(items, operation: UUID().uuidString, sides: sides, preferredSource: preferredSource,
                                 cancellation: cancellation, validate: validate, progress: progress)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.asset.id, $0) })
        return try coreResult { try session.groups() }.map { detected in
            let members = detected.members.map { byID[AssetID($0)]! }
            try Task.checkCancellation()
            let reference = members[0]
            let matches = detected.edges.map {
                SceneMatchEvidence(edge: MatchEdge(first: AssetID($0.first), second: AssetID($0.second), match: .sceneSimilar),
                                   featureDistance: $0.distance, sharedBurst: $0.sharedBurst)
            }
            var group = DuplicateGroup(preferred: reference.asset, duplicates: members.dropFirst().map { member in
                DuplicateMember(asset: member.asset, match: matches.contains { $0.edge.connects(reference.asset.id, member.asset.id) } ? .sceneSimilar : .distinct)
            }, preferredDimensions: ImageDimensions(width: reference.evidence.width, height: reference.evidence.height))
            group.match = .sceneSimilar
            group.sceneAlgorithm = SceneFeature.version
            group.sceneEvidence = matches
            group.edges = matches.map(\.edge)
            group.comparisonSides = sides
            group.evidence = Dictionary(uniqueKeysWithValues: members.map { ($0.asset.id, $0.evidence) })
            group.sceneQuality = Dictionary(uniqueKeysWithValues: members.map { ($0.asset.id, $0.feature.quality) })
            group.recommendedID = detected.recommended.map(AssetID.init)
            group.hasQualityRecommendation = detected.recommended != nil
            group.sceneRecommendationReason = detected.reason.map {
                switch $0 {
                case .associatedResources: .associatedResources
                case .focusSignal: .focusSignal
                case .exposureSignal: .exposureSignal
                case .sourcePreference: .sourcePreference
                }
            }
            return group
        }
    }
}
