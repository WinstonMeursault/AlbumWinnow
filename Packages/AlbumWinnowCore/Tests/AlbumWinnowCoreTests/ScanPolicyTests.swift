import Foundation
import GRDB
import Testing
@testable import AlbumWinnowCore

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
    let engine = try ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.scan([SideFixture(id: "a", count: 2), SideFixture(id: "b", count: 1)], comparisonSides: sides, preferredSource: "b")
    let group = try #require(result.groups.first)
    #expect(result.groups.count == 1)
    #expect(group.assets.count == 3)
    #expect(group.edges?.count == 2)
    #expect(group.recommendation.id.source == "b")
    let a = group.assets.filter { $0.id.source == "a" }
    #expect(group.match(between: a[0].id, and: a[1].id) == nil)
    let pairs = group.removalPairs(keeping: a[0].id, protection: CleanupProtection())
    #expect(pairs.count == 1)
    #expect(pairs.first?.remove.id.source == "b")
    let same = try await engine.scan([SideFixture(id: "a", count: 2), SideFixture(id: "b", count: 0)], comparisonSides: sides)
    #expect(same.groups.isEmpty)
    await #expect(throws: ScopeError.self) { try await engine.scan([SideFixture(id: "a", count: 2)], comparisonSides: sides) }
}

@Test func reviewSchemaMigrationPreservesLocksAndFailsClosedForUnknownSchema() throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let url = scratch.appending(path: "review.sqlite")
    let store = try ReviewStateStore(url: url)
    var state = ReviewState()
    state.locked = [AssetID(source: "photos-library", item: "one")]
    try store.save(state)
    let database = try DatabaseQueue(path: url.path)
    try database.write { db in
        try db.execute(sql: "UPDATE review_state SET schema = 1")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('reviewStateV2', 'reviewStateV3')")
        try db.execute(sql: "DROP TABLE review_decisions")
        try db.execute(sql: "DROP TABLE review_position")
    }
    #expect(try ReviewStateStore(url: url).load().locked == state.locked)
    try database.write { db in try db.execute(sql: "UPDATE review_state SET schema = 999") }
    #expect(throws: CleanupError.self) { try store.load() }
}

@Test func readOnlySourceProtectsOverlappingPathsHardlinksAndFinalMutation() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let readOnly = scratch.appending(path: "readonly")
    let other = scratch.appending(path: "other")
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let original = readOnly.appending(path: "a.png"), alias = other.appending(path: "b.png")
    try Data([1]).write(to: original)
    try FileManager.default.linkItem(at: original, to: alias)
    let first = FileSystemSource(directory: readOnly), second = FileSystemSource(directory: other)
    let a = try #require(try await first.snapshot().assets.first)
    let b = try #require(try await second.snapshot().assets.first)
    let protection = CleanupProtection(readOnlySources: [first.id], readOnlyRevisions: [a.id: a.revision])
    #expect(!protection.validateForReview(a))
    #expect(!protection.validateForReview(b))
    try FileManager.default.removeItem(at: original)
    #expect(!protection.validateForReview(b), "Deleting the original path cannot unprotect its surviving alias")
    let outcomes = try await AssetMutationService().apply([CleanupPair(keep: a, remove: b)], sources: [first, second], protection: protection)
    #expect(outcomes.first?.status == .skipped)
    #expect(FileManager.default.fileExists(atPath: alias.path))
}

@Test func manySameByteCrossCopiesUseLinearEvidenceAndProtectedResourcesStayRetained() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.scan([SideFixture(id: "a", count: 100), SideFixture(id: "b", count: 100)],
        comparisonSides: ComparisonSides(first: "a", second: "b"))
    let group = try #require(result.groups.first)
    #expect(group.assets.count == 200)
    #expect(group.edges?.count == 199)
    let pairs = group.removalPairs(keeping: group.preferred.id, protection: CleanupProtection())
    #expect(pairs.allSatisfy { $0.keep?.id.source != $0.remove.id.source })
    let protected = PhotoAsset(id: AssetID(source: "a", item: "protected"), name: "protected", revision: "1",
        photoProperties: PhotoProperties(isLivePhoto: true, hasEdits: false, hasAlternatePhoto: false))
    let ordinary = PhotoAsset(id: AssetID(source: "b", item: "ordinary"), name: "ordinary", revision: "1")
    let protectedGroup = DuplicateGroup(preferred: ordinary,
        duplicates: [DuplicateMember(asset: protected, match: .exactDuplicate)], preferredDimensions: nil)
    #expect(protectedGroup.removalPairs(keeping: ordinary.id, protection: CleanupProtection()).isEmpty)
}

private struct UnselectedSource: AssetSource {
    let id = "unselected"
    func snapshot() async throws -> AssetSnapshot { throw AssetAccessError.inaccessible }
    func imageData(for asset: PhotoAsset) async throws -> Data { throw AssetAccessError.inaccessible }
}

@Test func crossModeDoesNotEvenEnumerateAnUnselectedSource() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let result = try await engine.scan([SideFixture(id: "a", count: 1), SideFixture(id: "b", count: 1), UnselectedSource()],
        comparisonSides: ComparisonSides(first: "a", second: "b"))
    #expect(result.groups.count == 1)
    #expect(result.scanned == 2)
    #expect(result.issues.isEmpty)
}

@Test func crossSourceRuleIsEnforcedAtFinalPairValidation() throws {
    let a = PhotoAsset(id: AssetID(source: "a", item: "one"), name: "one", revision: "1")
    let sameSide = PhotoAsset(id: AssetID(source: "a", item: "two"), name: "two", revision: "1")
    let protection = CleanupProtection(comparisonSides: ComparisonSides(first: "a", second: "b"))
    #expect(throws: CleanupError.invalidSelection) { try protection.validatePair(CleanupPair(keep: a, remove: sameSide)) }
}

@Test func malformedReadOnlyIdentityCannotLoadAsUsableProtection() throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = try ReviewStateStore(url: scratch.appending(path: "review.sqlite"))
    var state = ReviewState()
    let id = AssetID(source: "folder:/fixture", item: "/fixture/a.png")
    state.readOnlySources = [id.source]
    state.readOnlyRevisions = [id: "corrupt-identity"]
    #expect(throws: CleanupError.self) { try store.save(state) }
    let database = try DatabaseQueue(path: scratch.appending(path: "review.sqlite").path)
    try database.write { db in
        try db.execute(sql: "INSERT OR REPLACE INTO review_state VALUES (1, 3, ?)", arguments: [try JSONEncoder().encode(state)])
    }
    #expect(throws: CleanupError.self) { try store.load() }
}
