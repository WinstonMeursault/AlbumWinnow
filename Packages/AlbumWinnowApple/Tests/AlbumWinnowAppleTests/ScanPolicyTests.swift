import Foundation
import AlbumWinnowRust
import Testing
@testable import AlbumWinnowApple

private struct SideFixture: AssetSource {
    let id: String
    let count: Int
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: (0..<count).map { PhotoAsset(id: AssetID(source: id, item: "\($0)"), name: "\($0)", revision: "1") })
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        try Data(contentsOf: TestFiles.fixtures.appending(path: "scene.png"))
    }
}

@Test func dateRangeStoresCivilDaysAcrossDaylightSavingAndRejectsInvalidInput() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
    let range = try CaptureRange(firstDay: day, lastDay: day, calendar: calendar)
    #expect(range.end.timeIntervalSince(range.start) == 23 * 3600)
    #expect(try range.contains(range.start))
    #expect(try !range.contains(range.end))
    #expect(try !range.contains(nil))
    var unknown = range
    unknown.includesUnknown = true
    #expect(try unknown.contains(nil))
    #expect(throws: ScopeError.self) { try CaptureRange(firstDay: range.end, lastDay: day, calendar: calendar) }
    #expect(throws: ScopeError.self) { try CaptureRange(firstDay: Date(timeIntervalSince1970: .infinity), lastDay: day) }
}

@Test func crossSideEvidenceNeverAuthorizesSameSideTransitivity() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sides = ComparisonSides(first: "a", second: "b")
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.fixtureScan([SideFixture(id: "a", count: 2), SideFixture(id: "b", count: 1)], comparisonSides: sides, preferredSource: "b")
    let group = try #require(result.groups.first)
    #expect(result.groups.count == 1)
    #expect(group.assets.count == 3)
    #expect(group.edges?.count == 2)
    #expect(group.recommendation.id.source == "b")
    let a = group.assets.filter { $0.id.source == "a" }
    #expect(group.edges?.contains { $0.connects(a[0].id, a[1].id) } == false)
    let pairs = try fixtureRemovals(in: group, keeping: a[0].id)
    #expect(pairs.count == 1)
    #expect(pairs.first?.remove.source == "b")
    let same = try await engine.fixtureScan([SideFixture(id: "a", count: 2), SideFixture(id: "b", count: 0)], comparisonSides: sides)
    #expect(same.groups.isEmpty)
    await #expect(throws: ScopeError.self) { try await engine.fixtureScan([SideFixture(id: "a", count: 2)], comparisonSides: sides) }
}

@Test func unknownV2SchemaFailsClosedWithoutResettingSavedLocks() throws {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "review.sqlite")
    do {
        let session = try RustReviewSession(databasePath: url.path, initialized: false)
        let group = try fixtureReviewGroup(session)
        _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: group.members[0], locked: true)
    }
    try FixtureDatabase(url).execute("PRAGMA user_version = 999")
    let original = try Data(contentsOf: url)
    #expect(throws: (any Error).self) { try RustReviewSession(databasePath: url.path, initialized: true) }
    #expect(try Data(contentsOf: url) == original)
    #expect(try FixtureDatabase(url).integer("SELECT count(*) FROM locks") == 1)
}

@Test func readOnlySourceProtectsOverlappingPathsHardlinksAndFinalMutation() async throws {
    let scratch = TestFiles.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let readOnly = scratch.appending(path: "readonly"), other = scratch.appending(path: "other")
    for folder in [readOnly, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let original = readOnly.appending(path: "a.png"), alias = other.appending(path: "b.png")
    try Data([1]).write(to: original)
    try Data([1]).write(to: other.appending(path: "keep.png"))
    try FileManager.default.linkItem(at: original, to: alias)
    let session = try RustReviewSession(databasePath: scratch.appending(path: "review.sqlite").path, initialized: false)
    var sources = [FileSystemSource]()
    for folder in [readOnly, other] {
        let record = try session.registerSource(expectedRevision: session.header().metadata.revision,
            input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
                identity: FileSystemSource.sourceIdentity(directory: folder), bookmark: Data(), label: folder.lastPathComponent))
        sources.append(FileSystemSource(directory: folder, id: record.id))
    }
    func members(_ source: FileSystemSource) async throws -> [CoreReviewAsset] {
        try await source.snapshot().assets.map {
            try $0.reviewValue(kind: .fileSystem, nativeIdentity: source.nativeIdentity(for: $0), linkCount: source.linkCount(for: $0))
        }
    }
    let protected = try await members(sources[0])
    try session.beginReadOnlySnapshot(expectedRevision: session.header().metadata.revision, operationId: "protected", source: sources[0].id)
    try session.appendReadOnlySnapshot(operationId: "protected", members: protected, cancellation: CancellationHandle())
    _ = try session.finishReadOnlySnapshot(operationId: "protected", complete: true, cancellation: CancellationHandle())
    func assertProtected(_ assets: [CoreReviewAsset]) throws {
        let keep = try #require(assets.first { $0.name == "keep.png" })
        let group = CoreReviewGroup(preferred: keep.id, members: assets,
            duplicates: assets.filter { $0.id != keep.id }.map { CoreReviewDuplicate(asset: $0.id, kind: .exactDuplicate) },
            edges: nil, sides: nil, scene: nil, recommendation: nil, hasQualityRecommendation: true,
            sceneRecommendationReason: nil, sceneQuality: [], sceneMatches: [], evidence: [])
        try commitFixtureGroups([group], to: session)
        let summary = try #require(session.queryPage(offset: 0, limit: 1).first)
        let detail = try session.groupDetail(signature: summary.signature)
        for member in assets where member.name != "keep.png" { #expect(detail.protected.contains(member.id)) }
        let committed = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: summary.signature,
            commandId: UUID().uuidString, intent: .confirmKeep(keep: keep.id))
        #expect(committed.decision.removals.isEmpty)
        #expect(throws: BridgeError.InvalidValue) { try session.startCleanup(expectedRevision: committed.metadata.revision) }
    }
    try assertProtected(protected + (try await members(sources[1])))
    try FileManager.default.removeItem(at: original)
    try assertProtected(try await members(sources[1]))
    #expect(try Data(contentsOf: alias) == Data([1]))
}

@Test func manySameByteCrossCopiesUseLinearEvidenceAndProtectedResourcesStayRetained() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.fixtureScan([SideFixture(id: "a", count: 100), SideFixture(id: "b", count: 100)],
        comparisonSides: ComparisonSides(first: "a", second: "b"))
    let group = try #require(result.groups.first)
    #expect(group.assets.count == 200)
    #expect(group.edges?.count == 199)
    let pairs = try fixtureRemovals(in: group, keeping: group.preferred.id)
    #expect(pairs.allSatisfy { $0.keep?.source != $0.remove.source })
    let protected = PhotoAsset(id: AssetID(source: "a", item: "protected"), name: "protected", revision: "1",
        photoProperties: PhotoProperties(isLivePhoto: true, hasEdits: false, hasAlternatePhoto: false))
    let ordinary = PhotoAsset(id: AssetID(source: "b", item: "ordinary"), name: "ordinary", revision: "1")
    let protectedGroup = DuplicateGroup(preferred: ordinary,
        duplicates: [DuplicateMember(asset: protected, match: .exactDuplicate)], preferredDimensions: nil)
    #expect(try fixtureRemovals(in: protectedGroup, keeping: ordinary.id).isEmpty)
}

private struct UnselectedSource: AssetSource {
    let id = "unselected"
    func snapshot() async throws -> AssetSnapshot { throw AssetAccessError.inaccessible }
    func imageData(for asset: PhotoAsset) async throws -> Data { throw AssetAccessError.inaccessible }
}

@Test func crossModeDoesNotEvenEnumerateAnUnselectedSource() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.fixtureScan([SideFixture(id: "a", count: 1), SideFixture(id: "b", count: 1), UnselectedSource()],
        comparisonSides: ComparisonSides(first: "a", second: "b"))
    #expect(result.groups.count == 1)
    #expect(result.scanned == 2)
    #expect(result.issues.isEmpty)
}

@Test func crossSourceRuleIsEnforcedBeforeAPlanCanBeCreated() throws {
    let a = PhotoAsset(id: AssetID(source: "a", item: "one"), name: "one", revision: "1")
    let sameSide = PhotoAsset(id: AssetID(source: "a", item: "two"), name: "two", revision: "1")
    var group = DuplicateGroup(preferred: a, duplicates: [DuplicateMember(asset: sameSide, match: .exactDuplicate)], preferredDimensions: nil)
    group.comparisonSides = ComparisonSides(first: "a", second: "b")
    group.edges = [MatchEdge(first: a.id, second: sameSide.id, match: .exactDuplicate)]
    #expect(throws: BridgeError.InvalidValue) { try fixtureRemovals(in: group, keeping: a.id) }
}

@Test func malformedReadOnlyIdentityCannotLoadAsUsableProtection() throws {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "review.sqlite")
    do {
        let session = try RustReviewSession(databasePath: url.path, initialized: false)
        let group = try fixtureReviewGroup(session)
        let before = try session.header()
        try session.beginReadOnlySnapshot(expectedRevision: before.metadata.revision, operationId: "invalid", source: group.preferred.sourceId)
        var invalid = group.members[0]
        invalid.nativeIdentity = ""
        #expect(throws: BridgeError.InvalidValue) {
            try session.appendReadOnlySnapshot(operationId: "invalid", members: [invalid], cancellation: CancellationHandle())
        }
        try session.discardReadOnlySnapshot(operationId: "invalid")
        #expect(try session.header() == before)
        try session.beginReadOnlySnapshot(expectedRevision: before.metadata.revision, operationId: "valid", source: group.preferred.sourceId)
        try session.appendReadOnlySnapshot(operationId: "valid", members: group.members, cancellation: CancellationHandle())
        _ = try session.finishReadOnlySnapshot(operationId: "valid", complete: true, cancellation: CancellationHandle())
    }
    try FixtureDatabase(url).execute("UPDATE read_only_members SET payload = X'00'")
    let corrupt = try Data(contentsOf: url)
    #expect(throws: (any Error).self) { try RustReviewSession(databasePath: url.path, initialized: true) }
    #expect(try Data(contentsOf: url) == corrupt)
}
