import AlbumWinnowRust
import Foundation
import Testing
@testable import AlbumWinnowApple

@Test func cleanupValidatesAssetsAndReturnsPartialOutcome() async throws {
    // Deliberately supplied scan labels exercise final native verification, not recognition accuracy.
    let fixture = try NativeCleanupFixture(pairs: 3)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = fixture.source.directory
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-b.png"))
        .write(to: folder.appending(path: "remove1.png"))
    let operation = try await fixture.prepare()
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-b.png"))
        .write(to: folder.appending(path: "remove0.png"), options: .atomic)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    let results = try fixture.results(operation)
    #expect(results.map(\.outcome) == [.skipped(reason: .changedAsset), .skipped(reason: .noLongerDuplicate), .movedToTrash])
    #expect(!FileManager.default.fileExists(atPath: fixture.base.appending(path: "cleanup.sqlite").path))
    for name in ["keep0.png", "keep1.png", "keep2.png", "remove0.png", "remove1.png"] {
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "remove2.png").path))
    try fixture.restore(receipt, operation: operation)
}

@Test func missingKeepPreventsRemoval() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let operation = try await fixture.prepare()
    _ = try fixture.session.cancelCleanup(operation: operation)
    let summary = try #require(fixture.session.queryPage(offset: 0, limit: 1).first)
    let before = try fixture.session.header()
    #expect(throws: BridgeError.InvalidValue) {
        try fixture.session.applyIntent(expectedRevision: before.metadata.revision, signature: summary.signature,
            commandId: "invalid-keep", intent: .confirmKeep(keep: CoreAssetKey(sourceId: fixture.source.id, itemId: "absent")))
    }
    #expect(try fixture.session.header() == before)
    let current = try fixture.session.startCleanup(expectedRevision: before.metadata.revision).operation
    try FileManager.default.removeItem(at: fixture.source.directory.appending(path: "keep0.png"))
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: current, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(current).map(\.outcome) == [.failed])
    #expect(!receipt.diagnostics.isEmpty)
    #expect(receipt.diagnostics.values.allSatisfy { $0.reason == .inaccessible && $0.detail == nil })
    #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: "remove0.png").path))
}

@Test func overlappingFoldersCannotMoveTheSoleCopy() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    for name in ["keep0.png", "remove0.png"] {
        try FileManager.default.removeItem(at: fixture.source.directory.appending(path: name))
    }
    let child = fixture.source.directory.appending(path: "nested")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let file = child.appending(path: "only.png")
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    try bytes.write(to: file)
    let record = try fixture.session.registerSource(expectedRevision: fixture.session.header().metadata.revision,
        input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
            identity: FileSystemSource.sourceIdentity(directory: child), bookmark: Data(), label: "Nested"))
    let inner = FileSystemSource(directory: child, id: record.id)
    let receipt = try await ScanEngine(cacheURL: fixture.base.appending(path: "cache.sqlite"))
        .scan(fixture.context(additional: [inner]), review: fixture.session)
    #expect(receipt.scanned == 1)
    #expect(try fixture.session.queryCount() == 0)
    #expect(throws: BridgeError.InvalidValue) {
        try fixture.session.startCleanup(expectedRevision: fixture.session.header().metadata.revision)
    }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func wholeGroupCleanupRequiresCurrentAssetsAndMovesEveryCopy() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let folder = fixture.source.directory
    let operation = try await fixture.prepare(all: true)
    #expect(try fixture.session.cleanupItemsPage(operation: operation, group: 0, offset: 0, limit: 16).count == 2)
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-b.png"))
        .write(to: folder.appending(path: "remove0.png"), options: .atomic)
    let rejected = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(rejected.trashLocations.isEmpty)
    #expect(try fixture.results(operation).map(\.outcome) == [.skipped(reason: .changedAsset), .skipped(reason: .changedAsset)])
    for name in ["keep0.png", "remove0.png"] { #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path)) }
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")).write(to: folder.appending(path: "remove0.png"), options: .atomic)
    let refreshed = try await fixture.prepare(all: true)
    let applied = try await AppleCleanupExecutor(session: fixture.session).apply(operation: refreshed, sources: fixture.context())
    #expect(try fixture.results(refreshed).map(\.outcome) == [.movedToTrash, .movedToTrash])
    for name in ["keep0.png", "remove0.png"] { #expect(!FileManager.default.fileExists(atPath: folder.appending(path: name).path)) }
    try fixture.restore(applied, operation: refreshed)
}

@Test func removalPreflightHonorsCancellation() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let suite = "org.albumwinnow.tests.preflight.\(UUID())"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let owner = try await AppleReviewOwner.open(directory: fixture.base.appending(path: "owner-v2"), preferencesSuite: suite)
    let record = try await owner.addFolder(fixture.source.directory, expectedRevision: owner.header().metadata.revision)
    let assets = try await FileSystemSource(directory: fixture.source.directory, id: record.id).snapshot().assets
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await owner.validateRemovability(assets: assets)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    for asset in assets { #expect(FileManager.default.fileExists(atPath: asset.id.item)) }
}
