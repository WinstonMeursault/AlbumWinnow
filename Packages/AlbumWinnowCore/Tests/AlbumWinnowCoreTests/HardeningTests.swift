@testable import AlbumWinnowCore
import Foundation
import GRDB
import Testing

private func fixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: TestFiles.root.path).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func malformedFolderLockRevisionMustFailClosedOnLoad() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ReviewStateStore(url: root.appending(path: "review.sqlite"))
    let id = AssetID(source: "folder:/unavailable/root", item: "/unavailable/root/locked.png")
    var state = ReviewState()
    state.locked = [id]
    state.lockedRevisions = [id: "broken"]
    #expect(throws: (any Error).self) { try store.save(state) }
    let database = try DatabaseQueue(path: root.appending(path: "review.sqlite").path)
    try database.write { db in
        try db.execute(sql: "INSERT OR REPLACE INTO review_state VALUES (1, 3, ?)", arguments: [try JSONEncoder().encode(state)])
    }
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func malformedLockRevisionBlocksFinalRemovalAfterOriginalPathDisappears() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appending(path: "a.png"), b = root.appending(path: "b.png")
    let image = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    try image.write(to: a)
    try image.write(to: root.appending(path: "keep.png"))
    try FileManager.default.linkItem(at: a, to: b)
    let source = FileSystemSource(directory: root)
    let before = try await source.snapshot()
    let locked = try #require(before.assets.first { $0.name == "a.png" })
    try FileManager.default.removeItem(at: a)
    let after = try await source.snapshot()
    let alias = try #require(after.assets.first { $0.name == "b.png" })
    var state = ReviewState()
    state.locked = [locked.id]
    state.lockedRevisions = [locked.id: "broken"]
    let store = try ReviewStateStore(url: root.appending(path: "review.sqlite"))
    #expect(throws: (any Error).self) { try store.save(state) }
    let malformed = CleanupProtection(locked: state.locked, lockedRevisions: state.lockedRevisions ?? [:])
    let valid = CleanupProtection(locked: state.locked, lockedRevisions: [locked.id: locked.revision])
    #expect(!valid.validateForReview(alias))
    #expect(!malformed.validateForReview(alias), "Malformed lock data must not lose inode-alias protection")
    let keep = try #require(after.assets.first { $0.name == "keep.png" })
    let outcome = try await AssetMutationService().apply([CleanupPair(keep: keep, remove: alias)], sources: [source], protection: malformed)
    print("AUDIT_FINAL_CLEANUP", outcome.map { String(describing: $0.status) })
    #expect(outcome.allSatisfy { $0.status == .skipped }, "A corrupted lock must not authorize final removal")
}

@Test func emptySelectedAlbumsAndCancelledStateRoundTripRemainExplicit() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = ReviewState()
    var scope = PhotoScope(); scope.albums = [:]
    state.photoScope = scope; state.scanCancelledByUser = true
    let store = try ReviewStateStore(url: root.appending(path: "review.sqlite"))
    try store.save(state)
    let loaded = try store.load()
    #expect(loaded.photoScope?.albums == [:])
    #expect(loaded.scanCancelledByUser == true)
    state.anchor = "old"; state.anchorIndex = 88
    state.resetProgress()
    #expect(state.anchor == nil && state.anchorIndex == nil)
}

@Test func crossSideChangedFileIssueMustNameTheChangedFile() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let aFolder = root.appending(path: "A"), bFolder = root.appending(path: "B")
    for folder in [aFolder,bFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    let aURL=aFolder.appending(path:"a.png"), bURL=bFolder.appending(path:"b.png")
    try bytes.write(to:aURL); try bytes.write(to:bURL)
    let a=FileSystemSource(directory:aFolder), b=FileSystemSource(directory:bFolder)
    let engine=try ScanEngine(cacheURL:root.appending(path:"cache.sqlite"))
    let sides=ComparisonSides(first:a.id,second:b.id)
    let warm=try await engine.scan([a,b],comparisonSides:sides)
    #expect(warm.groups.count==1)
    let result=try await engine.scan([a,b],comparisonSides:sides,progress:{ p in
        if case .fingerprinting = p { try! Data([9]).write(to:aURL) }
    })
    print("AUDIT_CROSS_ISSUES",result.issues.map { ($0.id.item,$0.reason.rawValue) })
    #expect(result.issues.contains { $0.id.item==aURL.path && $0.reason == .changedDuringScan })
    #expect(!result.issues.contains { $0.id.item==bURL.path })
}


@Test(arguments: ["", "broken", "1:2", "x:2:3:4:5:6:7", "1:2:-1:4:5:6:7", "1:2:3:4:1000000000:6:7", "1:2:3:4:5:6:-1", "1::3:4:5:6:7", "01:2:3:4:5:6:7", "+1:2:3:4:5:6:7", "1:02:3:4:5:6:7"])
func invalidFolderRevisionsFailClosed(_ revision: String) throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = AssetID(source: "folder:/missing", item: "/missing/a.png")
    var state = ReviewState()
    state.locked = [id]; state.lockedRevisions = [id: revision]
    let store = try ReviewStateStore(url: root.appending(path: "review.sqlite"))
    #expect(throws: CleanupError.self) { try store.save(state) }
    let asset = PhotoAsset(id: AssetID(source: "folder:/other", item: "/other/b.png"), name: "b.png", revision: "1:2:3:4:5:6:7")
    #expect(!CleanupProtection(locked: [id], lockedRevisions: [id: revision]).validateForReview(asset))
}

@Test func incrementalDecisionsPositionAndResetPreserveProtectionAcrossReopen() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "review.sqlite")
    let store = try ReviewStateStore(url: url)
    var state = ReviewState()
    let id = AssetID(source: "photos-library", item: "photo")
    state.locked = [id]; state.lockedRevisions = [id: "Photos-revision"]
    state.decisions = ["one": ReviewDecision(status: .kept), "two": ReviewDecision(status: .deferred)]
    try store.save(state)
    try store.savePosition(anchor: "two", index: 1)
    state.anchor = "two"; state.anchorIndex = 1
    #expect(try ReviewStateStore(url: url).load() == state)
    var changed = state
    changed.decisions["one"] = ReviewDecision(status: .pending)
    changed.decisions.removeValue(forKey: "two")
    try store.save(changed, replacing: state)
    #expect(try store.load() == changed)
    var reset = changed; reset.resetProgress()
    try store.save(reset, replacing: changed)
    #expect(try ReviewStateStore(url: url).load() == reset)
    var invalid = reset
    let folder = AssetID(source: "folder:/missing", item: "/missing/x")
    invalid.locked.insert(folder)
    #expect(throws: CleanupError.self) { try store.save(invalid, replacing: reset) }
    #expect(try store.load() == reset, "Rejected saves must not partially change protection or decisions")
}

@Test(arguments: ["a.png", "b.png", "a2.png", "b2.png"])
func crossSideIssueIdentifiesEachChangedCohortMember(_ name: String) async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appending(path: "A"), b = root.appending(path: "B")
    for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for name in ["a.png", "a2.png"] { try bytes.write(to: a.appending(path: name)) }
    for name in ["b.png", "b2.png"] { try bytes.write(to: b.appending(path: name)) }
    let first = FileSystemSource(directory: a), second = FileSystemSource(directory: b)
    let engine = try ScanEngine(cacheURL: root.appending(path: "cache.sqlite"))
    let sides = ComparisonSides(first: first.id, second: second.id)
    _ = try await engine.scan([first, second], comparisonSides: sides)
    let changed = (name.hasPrefix("a") ? a : b).appending(path: name)
    let result = try await engine.scan([first, second], comparisonSides: sides, progress: { progress in
        if case .fingerprinting = progress { try! Data([9]).write(to: changed) }
    })
    #expect(result.issues.contains { $0.id.item == changed.path && $0.reason == .changedDuringScan })
    #expect(result.issues.allSatisfy { $0.id.item == changed.path })
}

@Test(arguments: [false, true])
func schemaTwoMigrationIsTransactionalAndPreservesDecisionsOrCorruption(_ corrupt: Bool) throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "legacy.sqlite")
    let database = try DatabaseQueue(path: url.path)
    let id = AssetID(source: "folder:/missing", item: "/missing/a.png")
    var state = ReviewState()
    state.locked = [id]; state.lockedRevisions = [id: corrupt ? "broken" : "1:2:3:4:5:6:7"]
    state.decisions = ["manual": ReviewDecision(status: .kept)]
    state.anchor = "manual"; state.anchorIndex = 12
    let bytes = try JSONEncoder().encode(state)
    try database.write { db in
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)")
        try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('reviewStateV1'), ('reviewStateV2')")
        try db.execute(sql: "CREATE TABLE review_state (id INTEGER PRIMARY KEY, schema INTEGER NOT NULL, payload BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO review_state VALUES (1, 2, ?)", arguments: [bytes])
    }
    if corrupt {
        #expect(throws: CleanupError.self) { try ReviewStateStore(url: url) }
        try database.read { db in
            let schema = try Int.fetchOne(db, sql: "SELECT schema FROM review_state")
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM review_state")
            let tables = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'review_decisions'")
            #expect(schema == 2)
            #expect(payload == bytes)
            #expect(tables == 0)
        }
    } else {
        let migrated = try ReviewStateStore(url: url)
        #expect(try migrated.load() == state)
        try migrated.savePosition(anchor: "next", index: 13)
        state.anchor = "next"; state.anchorIndex = 13
        #expect(try ReviewStateStore(url: url).load() == state)
    }
}
