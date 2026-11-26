@testable import AlbumWinnowApple
import AlbumWinnowRust
import Foundation
import Testing

private func fixtureRoot() throws -> URL {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func malformedSavedLockPayloadMustFailClosedOnReopen() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "review.sqlite")
    do {
        let session = try RustReviewSession(databasePath: url.path, initialized: false)
        let group = try fixtureReviewGroup(session)
        _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: group.members[0], locked: true)
    }
    try FixtureDatabase(url).execute("UPDATE locks SET payload = X'00'")
    let corrupt = try Data(contentsOf: url)
    #expect(throws: (any Error).self) { try RustReviewSession(databasePath: url.path, initialized: true) }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func corruptSavedLockAfterOriginalPathDisappearsCannotOpenAsUnprotected() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appending(path: "a.png"), alias = root.appending(path: "b.png")
    let bytes = Data([1])
    try bytes.write(to: original)
    try FileManager.default.linkItem(at: original, to: alias)
    let url = root.appending(path: "review.sqlite")
    do {
        let session = try RustReviewSession(databasePath: url.path, initialized: false)
        let record = try session.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .fileSystem,
            namespace: FileSystemSource.sourceIdentityNamespace,
            identity: FileSystemSource.sourceIdentity(directory: root), bookmark: Data(), label: "Files"))
        let source = FileSystemSource(directory: root, id: record.id)
        let asset = try #require(try await source.snapshot().assets.first { $0.name == "a.png" })
        let locked = try asset.reviewValue(kind: .fileSystem, nativeIdentity: source.nativeIdentity(for: asset), linkCount: source.linkCount(for: asset))
        _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: locked, locked: true)
        var invalid = locked
        invalid.nativeIdentity = ""
        let before = try session.header()
        #expect(throws: BridgeError.InvalidValue) {
            try session.setLocked(expectedRevision: before.metadata.revision, asset: invalid, locked: true)
        }
        #expect(try session.header() == before)
    }
    try FileManager.default.removeItem(at: original)
    try FixtureDatabase(url).execute("UPDATE locks SET payload = X'00'")
    #expect(throws: (any Error).self) { try RustReviewSession(databasePath: url.path, initialized: true) }
    #expect(try Data(contentsOf: alias) == bytes)
}

@Test func emptySelectedAlbumsAndCancelledStateRoundTripRemainExplicit() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "review.sqlite").path
    do {
        let session = try RustReviewSession(databasePath: path, initialized: false)
        var settings = try session.header().settings
        settings.photoScope.albums = [:]
        settings.scanCancelledByUser = true
        _ = try session.saveSettings(expectedRevision: session.header().metadata.revision, settings: settings)
    }
    let session = try RustReviewSession(databasePath: path, initialized: true)
    #expect(try session.header().settings.photoScope.albums == [:])
    #expect(try session.header().settings.scanCancelledByUser)
    _ = try session.resetProgress(expectedRevision: session.header().metadata.revision)
    #expect(try session.header().anchor == nil && session.header().position == nil)
    #expect(try session.header().settings.photoScope.albums == [:])
    #expect(try session.header().settings.scanCancelledByUser)
}

@Test func crossSideChangedFileIssueMustNameTheChangedFile() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let aFolder = root.appending(path: "A"), bFolder = root.appending(path: "B")
    for folder in [aFolder,bFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    let aURL=aFolder.appending(path:"a.png"), bURL=bFolder.appending(path:"b.png")
    try bytes.write(to:aURL); try bytes.write(to:bURL)
    let a=FileSystemSource(fixture: aFolder), b=FileSystemSource(fixture: bFolder)
    let engine=try FixtureScanEngine(cacheURL:root.appending(path:"cache.sqlite"))
    let sides=ComparisonSides(first:a.id,second:b.id)
    let warm=try await engine.fixtureScan([a,b],comparisonSides:sides)
    #expect(warm.groups.count==1)
    let result=try await engine.fixtureScan([a,b],comparisonSides:sides,progress:{ p in
        if case .fingerprinting = p { try! Data([9]).write(to:aURL) }
    })
    print("AUDIT_CROSS_ISSUES",result.issues.map { ($0.id.item,$0.reason.rawValue) })
    #expect(result.issues.contains { $0.id.item==aURL.path && $0.reason == .changedDuringScan })
    #expect(!result.issues.contains { $0.id.item==bURL.path })
}


@Test(arguments: ["emptyNativeIdentity", "zeroLinkCount", "oversizedRevision"])
func invalidProtectionMetadataCannotPartiallyCommit(_ kind: String) throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    let group = try fixtureReviewGroup(session)
    var invalid = group.members[0]
    switch kind {
    case "emptyNativeIdentity": invalid.nativeIdentity = ""
    case "zeroLinkCount": invalid.linkCount = 0
    default: invalid.revision = String(repeating: "x", count: 8193)
    }
    let before = try session.header()
    #expect(throws: BridgeError.InvalidValue) {
        try session.setLocked(expectedRevision: before.metadata.revision, asset: invalid, locked: true)
    }
    #expect(try session.header() == before)
    #expect(try session.lockedPage(offset: 0, limit: 16).isEmpty)
}

@Test func incrementalDecisionsPositionAndResetPreserveProtectionAcrossReopen() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "review.sqlite").path
    var signatures = [String]()
    var locked: CoreReviewAsset!
    do {
        let session = try RustReviewSession(databasePath: path, initialized: false)
        let one = try fixtureReviewGroup(session, item: "one"), two = try fixtureReviewGroup(session, item: "two")
        try commitFixtureGroups([one, two], to: session)
        signatures = try session.queryPage(offset: 0, limit: 16).map(\.signature)
        for (signature, status) in zip(signatures, [CoreReviewStatus.kept, .deferred]) {
            _ = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature,
                commandId: UUID().uuidString, intent: .setStatus(status: status))
        }
        locked = one.members[0]
        _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: locked, locked: true)
        try session.savePosition(expectedRevision: session.header().metadata.revision, sequence: 1, anchor: signatures[1], position: 1)
    }
    do {
        let session = try RustReviewSession(databasePath: path, initialized: true)
        #expect(try session.resumeSignature() == signatures[1])
        #expect(try session.groupDetail(signature: signatures[0]).decision?.status == .kept)
        #expect(try session.groupDetail(signature: signatures[1]).decision?.status == .deferred)
        _ = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signatures[0],
            commandId: "pending", intent: .setStatus(status: .pending))
        #expect(try session.groupDetail(signature: signatures[1]).decision?.status == .deferred)
        _ = try session.resetProgress(expectedRevision: session.header().metadata.revision)
        let before = try session.header()
        var invalid = locked!
        invalid.id.sourceId = "unregistered"
        #expect(throws: BridgeError.InvalidValue) {
            try session.setLocked(expectedRevision: before.metadata.revision, asset: invalid, locked: true)
        }
        #expect(try session.header() == before)
    }
    let session = try RustReviewSession(databasePath: path, initialized: true)
    #expect(try session.header().metadata.decisionCount == 0)
    #expect(try session.lockedPage(offset: 0, limit: 16) == [locked])
    #expect(try session.header().anchor == nil && session.header().position == nil)
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
    let first = FileSystemSource(fixture: a), second = FileSystemSource(fixture: b)
    let engine = try FixtureScanEngine(cacheURL: root.appending(path: "cache.sqlite"))
    let sides = ComparisonSides(first: first.id, second: second.id)
    _ = try await engine.fixtureScan([first, second], comparisonSides: sides)
    let changed = (name.hasPrefix("a") ? a : b).appending(path: name)
    let result = try await engine.fixtureScan([first, second], comparisonSides: sides, progress: { progress in
        if case .fingerprinting = progress { try! Data([9]).write(to: changed) }
    })
    #expect(result.issues.contains { $0.id.item == changed.path && $0.reason == .changedDuringScan })
    #expect(result.issues.allSatisfy { $0.id.item == changed.path })
}

@Test(arguments: [false, true])
func legacyStateFilesAreNotMigratedOrModified(_ corrupt: Bool) throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appending(path: "legacy.sqlite")
    if corrupt {
        try Data("old damaged protection".utf8).write(to: old)
    } else {
        let database = try FixtureDatabase(old)
        try database.execute("CREATE TABLE review_state (id INTEGER PRIMARY KEY, schema INTEGER, payload BLOB)")
        try database.execute("INSERT INTO review_state VALUES (1, 2, ?)", bindings: [.blob(Data("old locks and manual candidates".utf8))])
    }
    let original = try Data(contentsOf: old)
    let session = try RustReviewSession(databasePath: root.appending(path: "v2/review.sqlite").path, initialized: false)
    #expect(try session.header().metadata.sourceCount == 0)
    #expect(try session.header().lockedCount == 0)
    #expect(try session.header().metadata.decisionCount == 0)
    #expect(try session.queryCount() == 0)
    #expect(try Data(contentsOf: old) == original)
}
