import AlbumWinnowRust
import Foundation
import Testing

private struct HandoffFixture: Sendable {
    let root: URL
    let review: RustReviewSession
    let cancellation = CancellationHandle()
    let items: [ScanItemInput]
    let metadata: [CoreScanReviewAsset]

    init(scenes: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-handoff-\(UUID())")
        review = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
        let source = try review.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .controlledTest,
            namespace: "native.fixture.v2", identity: Data([1]), bookmark: Data(), label: "Generated"))
        if scenes {
            var settings = try review.header().settings
            settings.similarScenesEnabled = true
            _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
        }
        items = [UInt8(1), 1, 2, 3].enumerated().map { index, hash in
            ScanItemInput(asset: CoreAssetKey(sourceId: source.id, itemId: "\(index)"), revision: "ns-revision",
                fingerprint: CoreFingerprint(fileHash: Data(repeating: hash, count: 32), width: 100, height: 100,
                    bitDepth: 8, wideColor: false, perceptualHash: 0, differenceHash: 0, meanRgba: Data([128,128,128,255]), edgeDetail: 0.1),
                associatedResources: false, nativeIdentity: nil)
        }
        metadata = items.map { item in
            CoreScanReviewAsset(asset: CoreReviewAsset(id: item.asset, name: item.asset.itemId + ".png", revision: item.revision,
                kind: .controlledTest, properties: nil, byteCount: 100, captureDate: nil, burst: nil, nativeIdentity: nil, linkCount: nil),
                evidence: CoreReviewEvidence(asset: item.asset, width: 100, height: 100, bitDepth: 8, wideColor: false, edgeDetail: 0.1, captureDate: 10))
        }
    }

    func prepare() throws -> RustScanSession {
        try review.beginScan(expectedRevision: review.header().metadata.revision, operationId: "scan")
        #expect(throws: BridgeError.InvalidBuffer) {
            try review.appendScanAssets(operationId: "scan", assets: Array(repeating: metadata[0], count: 17), cancellation: cancellation)
        }
        try review.appendScanAssets(operationId: "scan", assets: metadata, cancellation: cancellation)
        let scan = try RustScanSession(operationId: "scan", sourceIds: [items[0].asset.sourceId], sides: nil,
            preferredSource: nil, cancellation: cancellation)
        try scan.appendPrepared(items: items)
        try scan.completePreparation()
        while true {
            let batch = try scan.nextBatch(maximum: 16)
            if batch.done { break }
            try scan.submitResults(operationId: "scan", batchId: batch.batchId, results: batch.tasks.map {
                CoreTaskResult(taskId: $0.taskId, outcome: .matched(kind: $0.exactIdentity ? .exactDuplicate : .distinct))
            })
        }
        #expect(throws: BridgeError.InvalidState) { try scan.sceneCandidatePage(offset: 0, limit: 16) }
        #expect(throws: BridgeError.InvalidBuffer) { try scan.finalValidationPage(offset: 0, limit: 17) }
        let ids = try scan.finalValidationPage(offset: 0, limit: 16)
        #expect(ids.count == 2)
        try scan.submitFinalValidations(operationId: "scan", validations: ids.map {
            CoreAssetValidation(asset: $0, revision: "ns-revision", accessible: true)
        })
        #expect(throws: BridgeError.InvalidBuffer) { try scan.sceneCandidatePage(offset: 0, limit: 17) }
        #expect(try scan.sceneCandidatePage(offset: 0, limit: 1) == [items[2].asset])
        #expect(try scan.sceneCandidatePage(offset: 1, limit: 16) == [items[3].asset])
        #expect(try scan.sceneCandidatePage(offset: UInt64.max, limit: 16).isEmpty)
        return scan
    }
}

@Test func completedDetectionCommitsReviewDirectlyThroughSwiftWithoutReturningGroups() throws {
    let fixture = try HandoffFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scan = try fixture.prepare()
    #expect(throws: BridgeError.InvalidValue) {
        try fixture.review.finishDetectedScan(operationId: "scan", detection: scan, scenes: nil, cancellation: CancellationHandle())
    }
    let committed = try fixture.review.finishDetectedScan(operationId: "scan", detection: scan, scenes: nil, cancellation: fixture.cancellation)
    #expect(committed.scanGeneration == 1)
    let summary = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    #expect(summary.kind == .exactDuplicate && summary.memberCount == 2 && summary.latestDate == 10)
    let detail = try fixture.review.groupDetail(signature: summary.signature)
    #expect(detail.group.members == fixture.metadata.prefix(2).map(\.asset))
    #expect(detail.group.evidence == fixture.metadata.prefix(2).map(\.evidence))
}

@Test func sceneReviewHandoffRequiresBoundedFinalFactsThroughSwift() throws {
    let fixture = try HandoffFixture(scenes: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scan = try fixture.prepare()
    let provider = CoreSceneProvider(providerId: "controlled.native", modelRevision: "2", preprocessing: "fixed", platformCompatibility: "fixture")
    let scenes = try RustSceneSession(operationId: "scan", provider: provider, sides: nil, preferredSource: nil, cancellation: fixture.cancellation)
    try scenes.appendPrepared(items: fixture.items.suffix(2).map { item in
        CoreSceneAsset(asset: item.asset, revision: item.revision, provider: provider,
            quality: CoreSceneQuality(meanLuminance: 0.5, textureVariance: 0.01, focusEnergy: 0.1, darkClipping: 0, brightClipping: 0),
            keys: [0,0,0,0], width: 100, height: 100, bitDepth: 8, wideColor: false, edgeDetail: 0.1,
            associatedResources: false, nativeIdentity: nil, burst: nil, date: 10)
    })
    try scenes.completePreparation()
    while let request = try scenes.nextWork().request {
        try scenes.submitDistance(operationId: "scan", taskId: request.taskId, distance: 0.1)
    }
    let before = try fixture.review.header().metadata
    #expect(throws: BridgeError.InvalidState) {
        try fixture.review.finishDetectedScan(operationId: "scan", detection: scan, scenes: scenes, cancellation: fixture.cancellation)
    }
    #expect(try fixture.review.header().metadata == before)
    #expect(throws: BridgeError.InvalidBuffer) { try scenes.finalValidationPage(offset: 0, limit: 17) }
    let ids = try scenes.finalValidationPage(offset: 0, limit: 16)
    try scenes.submitFinalValidations(operationId: "scan", validations: ids.map {
        CoreAssetValidation(asset: $0, revision: "ns-revision", accessible: true)
    })
    _ = try fixture.review.finishDetectedScan(operationId: "scan", detection: scan, scenes: scenes, cancellation: fixture.cancellation)
    var settings = try fixture.review.header().settings
    settings.query.collection = .similarScenes
    _ = try fixture.review.saveSettings(expectedRevision: fixture.review.header().metadata.revision, settings: settings)
    let summary = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    let detail = try fixture.review.groupDetail(signature: summary.signature)
    #expect(detail.group.scene == provider && detail.group.sceneMatches.count == 1 && detail.group.sceneQuality.count == 2)
}

@Test func concurrentDirectHandoffCommitsExactlyOnceThroughSwift() async throws {
    let fixture = try HandoffFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scan = try fixture.prepare()
    let committed = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    _ = try fixture.review.finishDetectedScan(operationId: "scan", detection: scan, scenes: nil, cancellation: fixture.cancellation)
                    return true
                } catch BridgeError.InvalidState { return false }
                catch { Issue.record(error); return false }
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    #expect(committed == 1)
    #expect(try fixture.review.header().metadata.scanGeneration == 1)
    #expect(try fixture.review.queryCount() == 1)
}
