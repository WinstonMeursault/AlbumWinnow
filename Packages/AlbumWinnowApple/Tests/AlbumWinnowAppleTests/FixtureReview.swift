import AlbumWinnowRust
import Foundation
@testable import AlbumWinnowApple

func fixtureReviewGroup(_ session: RustReviewSession, item: String = "a") throws -> CoreReviewGroup {
    let record = try session.registerSource(expectedRevision: session.header().metadata.revision,
        input: CoreSourceInput(kind: .controlledTest, namespace: "review.storage.fixture.v2",
            identity: Data([1]), bookmark: Data(), label: "Review fixture"))
    func member(_ item: String) -> CoreReviewAsset {
        PhotoAsset(id: AssetID(source: record.id, item: item), name: item, revision: "opaque-v2-revision")
            .reviewValue(kind: .controlledTest)
    }
    let a = member(item), b = member(item + "-copy")
    return CoreReviewGroup(preferred: a.id, members: [a, b],
        duplicates: [CoreReviewDuplicate(asset: b.id, kind: .exactDuplicate)], edges: nil, sides: nil,
        scene: nil, recommendation: nil, hasQualityRecommendation: true, sceneRecommendationReason: nil,
        sceneQuality: [], sceneMatches: [], evidence: [])
}

func commitFixtureGroups(_ groups: [CoreReviewGroup], to session: RustReviewSession) throws {
    let operation = UUID().uuidString
    try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: operation)
    try session.appendScanGroups(operationId: operation, groups: groups, cancellation: CancellationHandle())
    _ = try session.finishScan(operationId: operation, cancellation: CancellationHandle())
}

// Readable recognition-fixture IDs are remapped only at this test boundary.
// Selection and evidence retention come from the real core, not a Swift reference algorithm.
func fixtureRemovals(in group: DuplicateGroup, keeping: AssetID) throws -> [(keep: AssetID?, remove: AssetID)] {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    var names = Set(group.assets.map { $0.id.source })
    if let sides = group.comparisonSides { names.formUnion([sides.first, sides.second]) }
    var registered = [String: String]()
    for name in names.sorted() {
        let record = try session.registerSource(expectedRevision: session.header().metadata.revision,
            input: CoreSourceInput(kind: .controlledTest, namespace: "selection.fixture.v2",
                identity: Data(name.utf8), bookmark: Data(), label: name))
        registered[name] = record.id
    }
    let originals = Dictionary(uniqueKeysWithValues: registered.map { ($0.value, $0.key) })
    func key(_ id: AssetID) -> CoreAssetKey { CoreAssetKey(sourceId: registered[id.source]!, itemId: id.item) }
    func original(_ id: CoreAssetKey) -> AssetID { AssetID(source: originals[id.sourceId]!, item: id.itemId) }
    let sides = group.comparisonSides.map { CoreComparisonSides(first: registered[$0.first]!, second: registered[$0.second]!) }
    var settings = try session.header().settings
    settings.sides = sides
    _ = try session.saveSettings(expectedRevision: session.header().metadata.revision, settings: settings)
    let members = group.assets.map { asset in
        var value = asset.reviewValue(kind: .controlledTest)
        value.id = key(asset.id)
        return value
    }
    let input = CoreReviewGroup(preferred: key(group.preferred.id), members: members,
        duplicates: group.duplicates.map { CoreReviewDuplicate(asset: key($0.id), kind: $0.match.coreValue) },
        edges: group.edges?.map { CoreSignatureEdge(first: key($0.first), second: key($0.second), kind: $0.match.coreValue) },
        sides: sides, scene: nil, recommendation: group.recommendedID.map(key), hasQualityRecommendation: true,
        sceneRecommendationReason: nil, sceneQuality: [], sceneMatches: [], evidence: [])
    try commitFixtureGroups([input], to: session)
    let signature = try session.queryPage(offset: 0, limit: 1)[0].signature
    let committed = try session.applyIntent(expectedRevision: session.header().metadata.revision,
        signature: signature, commandId: "manual", intent: .confirmKeep(keep: key(keeping)))
    if committed.decision.removals.isEmpty { return [] }
    let plan = try session.startCleanup(expectedRevision: committed.metadata.revision)
    var result = [(keep: AssetID?, remove: AssetID)]()
    var offset: UInt64 = 0
    while true {
        let page = try session.cleanupItemsPage(operation: plan.operation, group: 0, offset: offset, limit: 16)
        result.append(contentsOf: page.map { ($0.pair.keep.map { original($0.id) }, original($0.pair.remove.id)) })
        offset += UInt64(page.count)
        if page.count < 16 { return result }
    }
}
