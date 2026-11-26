import AlbumWinnowRust
import Foundation
import Testing

func reviewFixture(_ session: RustReviewSession) throws -> CoreReviewGroup {
    let source = try session.registerSource(expectedRevision: session.header().metadata.revision,
        input: CoreSourceInput(kind: .controlledTest, namespace: "bridge.fixture", identity: Data([1]), bookmark: Data([2]), label: "Fixture"))
    func asset(_ item: String) -> CoreReviewAsset {
        CoreReviewAsset(id: CoreAssetKey(sourceId: source.id, itemId: item), name: item, revision: "opaque-nanosecond-revision",
                        kind: .controlledTest, properties: nil, byteCount: 100, captureDate: 1_795_000_000.123,
                        burst: nil, nativeIdentity: nil, linkCount: nil)
    }
    let a = asset("a"), b = asset("b")
    return CoreReviewGroup(preferred: a.id, members: [a, b], duplicates: [CoreReviewDuplicate(asset: b.id, kind: .exactDuplicate)],
        edges: nil, sides: nil, scene: nil, recommendation: nil, hasQualityRecommendation: true,
        sceneRecommendationReason: nil, sceneQuality: [], sceneMatches: [], evidence: [])
}

@Test func v2ReviewCommitsAndRestartsWithoutRevivingProtectedCandidatesThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-review-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let old = root.appending(path: "v1-sentinel")
    try Data("old protection and candidates".utf8).write(to: old)
    let path = root.appending(path: "v2/review.sqlite").path
    var signature = ""
    var originalRevision: UInt64 = 0
    var group: CoreReviewGroup?
    do {
        let session = try RustReviewSession(databasePath: path, initialized: false)
        #expect(try session.header().metadata.sourceCount == 0)
        #expect(try session.queryCount() == 0)
        let fixture = try reviewFixture(session)
        group = fixture
        try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: "scan")
        try session.appendScanGroups(operationId: "scan", groups: [fixture], cancellation: CancellationHandle())
        let scanned = try session.finishScan(operationId: "scan", cancellation: CancellationHandle())
        let summary = try #require(session.queryPage(offset: 0, limit: 1).first)
        signature = summary.signature
        #expect(summary.confirmedRemovalCount == 0 && summary.estimate.knownBytes == 100)
        #expect(summary.latestDate == fixture.members[0].captureDate)
        originalRevision = scanned.revision
        let decision = try session.applyIntent(expectedRevision: scanned.revision, signature: signature, commandId: "confirm", intent: .confirmKeep(keep: fixture.preferred))
        #expect(decision.decision.removals == [fixture.members[1].id])
        try session.savePosition(expectedRevision: decision.metadata.revision, sequence: 1, anchor: signature, position: 0)
    }
    let session = try RustReviewSession(databasePath: path, initialized: true)
    let fixture = try #require(group)
    #expect(try session.resumeSignature() == signature)
    let locked = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: fixture.members[1], locked: true)
    let retried = try session.applyIntent(expectedRevision: originalRevision, signature: signature, commandId: "confirm", intent: .confirmKeep(keep: fixture.preferred))
    #expect(retried.replayed && retried.decision.removals.isEmpty)
    let unlocked = try session.setLocked(expectedRevision: locked.revision, asset: fixture.members[1], locked: false)
    #expect(try session.groupDetail(signature: signature).decision?.removals.isEmpty == true)
    let all = try session.applyIntent(expectedRevision: unlocked.revision, signature: signature, commandId: "all", intent: .confirmDeleteAll)
    try session.beginReadOnlySnapshot(expectedRevision: all.metadata.revision, operationId: "policy", source: fixture.preferred.sourceId)
    try session.appendReadOnlySnapshot(operationId: "policy", members: fixture.members, cancellation: CancellationHandle())
    let readOnly = try session.finishReadOnlySnapshot(operationId: "policy", complete: true, cancellation: CancellationHandle())
    #expect(try session.groupDetail(signature: signature).decision?.deleteAll == false)
    #expect(try session.groupDetail(signature: signature).decision?.removals.isEmpty == true)
    let reset = try session.resetProgress(expectedRevision: readOnly.revision)
    #expect(try session.header().readOnlySources == [fixture.preferred.sourceId])
    #expect(reset.decisionCount == 0)
    #expect(throws: BridgeError.StaleOperation) {
        try session.savePosition(expectedRevision: reset.revision, sequence: 1, anchor: signature, position: 0)
    }
    #expect(try Data(contentsOf: old) == Data("old protection and candidates".utf8))
}

@Test func v2ReviewCancelledStagingAndMissingDatabaseFailClosedThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-review-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "v2/review.sqlite").path
    let session = try RustReviewSession(databasePath: path, initialized: false)
    let fixture = try reviewFixture(session)
    let before = try session.header().metadata
    try session.beginScan(expectedRevision: before.revision, operationId: "cancel")
    try session.appendScanGroups(operationId: "cancel", groups: [fixture], cancellation: CancellationHandle())
    let cancel = CancellationHandle()
    cancel.cancel()
    #expect(throws: BridgeError.Cancelled) { try session.finishScan(operationId: "cancel", cancellation: cancel) }
    #expect(try session.header().metadata == before)
    try session.discardScan(operationId: "cancel")
    #expect(try session.queryCount() == 0)
    #expect(throws: BridgeError.ProtectionUnavailable) { try RustReviewSession(databasePath: path, initialized: true) }
    try FileManager.default.removeItem(atPath: path)
    #expect(throws: BridgeError.ProtectionUnavailable) { try session.queryCount() }
    #expect(!session.isHealthy())
    #expect(throws: BridgeError.ProtectionUnavailable) { try RustReviewSession(databasePath: path, initialized: true) }
    #expect(!FileManager.default.fileExists(atPath: path))
}


@Test func concurrentReviewCommandsCommitOneAuthoritativeRevisionThroughSwift() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-review-threads-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    let fixture = try reviewFixture(session)
    try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: "scan")
    try session.appendScanGroups(operationId: "scan", groups: [fixture], cancellation: CancellationHandle())
    let before = try session.finishScan(operationId: "scan", cancellation: CancellationHandle())
    let signature = try #require(session.queryPage(offset: 0, limit: 1).first).signature
    let results = await withTaskGroup(of: Int.self, returning: [Int].self) { tasks in
        for index in 0..<8 {
            tasks.addTask {
                do {
                    _ = try session.applyIntent(expectedRevision: before.revision, signature: signature, commandId: "parallel-\(index)", intent: .confirmKeep(keep: fixture.preferred))
                    return 1
                } catch BridgeError.StaleOperation { return 0 }
                catch { return -1 }
            }
        }
        var values: [Int] = []
        for await result in tasks { values.append(result) }
        return values
    }
    #expect(results.filter { $0 == 1 }.count == 1)
    #expect(results.filter { $0 == 0 }.count == 7)
    #expect(try session.header().metadata.revision == before.revision + 1)
    #expect(session.isHealthy())
}
