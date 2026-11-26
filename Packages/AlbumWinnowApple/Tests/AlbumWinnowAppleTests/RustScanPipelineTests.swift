import AlbumWinnowRust
import Foundation
import SQLite3
import Testing
@testable import AlbumWinnowApple

private struct NativeScanFixture: Sendable {
    let root: URL
    let review: RustReviewSession
    let engine: ScanEngine
    let record: CoreSourceRecord
    let source: FileSystemSource

    init() throws {
        root = TestFiles.root.appending(path: "scan-pipeline-\(UUID())")
        let folder = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        review = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
        record = try review.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .fileSystem,
            namespace: FileSystemSource.sourceIdentityNamespace, identity: FileSystemSource.sourceIdentity(directory: folder),
            bookmark: Data(), label: "Generated"))
        source = FileSystemSource(directory: folder, id: record.id)
        engine = try ScanEngine(cacheURL: root.appending(path: "cache.sqlite"))
    }
    func context(_ sources: [any AssetSource]? = nil) throws -> AppleAssetSources {
        try AppleAssetSources(sources: sources ?? [source], registered: review.sourcesPage(offset: 0, limit: 256))
    }
}

@Test func scanReceiptCommitsNativeMetadataAndCacheClearKeepsReviewAndProtection() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try fixture.context()
    let cold = try await fixture.engine.scan(context, review: fixture.review)
    #expect(cold.metadata.scanGeneration == 1 && cold.metadata.groupCount == 1)
    #expect(cold.scanned == 2 && cold.reused == 0 && cold.issues.isEmpty && cold.unavailableSources.isEmpty && cold.cacheMaintenance == .completed)
    let summary = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    let detail = try fixture.review.groupDetail(signature: summary.signature)
    #expect(Set(detail.group.members.map(\.name)) == ["a.png", "b.png"])
    #expect(detail.group.members.allSatisfy { $0.id.sourceId == fixture.record.id && $0.nativeIdentity != nil && $0.linkCount == 1 })
    #expect(detail.group.evidence.count == 2)
    let protectionCancellation = CancellationHandle()
    try fixture.review.beginReadOnlySnapshot(expectedRevision: fixture.review.header().metadata.revision,
        operationId: "native-read-only", source: fixture.record.id)
    try fixture.review.appendReadOnlySnapshot(operationId: "native-read-only", members: detail.group.members,
        cancellation: protectionCancellation)
    _ = try fixture.review.finishReadOnlySnapshot(operationId: "native-read-only", complete: true, cancellation: protectionCancellation)
    let before = try fixture.review.header()
    try await fixture.engine.clearCache()
    #expect(try fixture.review.header() == before)
    let rescanned = try await fixture.engine.scan(context, review: fixture.review)
    #expect(rescanned.scanned == 2 && rescanned.reused == 0 && rescanned.metadata.scanGeneration == 2)
    #expect(try fixture.review.header().readOnlySources == [fixture.record.id])
    let warm = try await fixture.engine.scan(context, review: fixture.review)
    #expect(warm.scanned == 0 && warm.reused == 2 && warm.metadata.scanGeneration == 3)
    #expect(try fixture.review.queryPage(offset: 0, limit: 1).first?.signature == summary.signature)
}

@Test func cancelledNativeScanKeepsCommittedChoicesAndCanExplicitlyRescan() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try fixture.context()
    _ = try await fixture.engine.scan(context, review: fixture.review)
    let group = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    _ = try fixture.review.applyIntent(expectedRevision: fixture.review.header().metadata.revision,
        signature: group.signature, commandId: "manual-confirm", intent: .confirmKeep(keep: group.preferred))
    let before = try fixture.review.header()
    let choice = try fixture.review.groupDetail(signature: group.signature)
    let task = Task {
        try await fixture.engine.scan(context, review: fixture.review) { update in
            if case .comparing = update { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    do { _ = try await task.value; Issue.record("Cancelled native scan acknowledged a commit") }
    catch is CancellationError { }
    #expect(try fixture.review.header() == before)
    #expect(try fixture.review.groupDetail(signature: group.signature) == choice)
    let resumed = try await fixture.engine.scan(context, review: fixture.review)
    #expect(resumed.reused == 2 && resumed.metadata.scanGeneration == before.metadata.scanGeneration + 1)
}

@Test func changedCoreSettingsDuringNativeScanRejectTheStagedCommit() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try fixture.context()
    _ = try await fixture.engine.scan(context, review: fixture.review)
    let before = try fixture.review.header()
    var changed = before.settings
    changed.query.sort = .newest
    let settings = changed
    do {
        _ = try await fixture.engine.scan(context, review: fixture.review) { update in
            if case .fingerprinting = update {
                _ = try? fixture.review.saveSettings(expectedRevision: before.metadata.revision, settings: settings)
            }
        }
        Issue.record("A stale native scan committed over changed Rust settings")
    } catch let error as RustCoreFailure {
        guard case BridgeError.StaleOperation = error.underlying else { throw error }
    }
    #expect(try fixture.review.header().settings == settings)
    #expect(try fixture.review.header().metadata.scanGeneration == before.metadata.scanGeneration)
    #expect(try fixture.review.header().metadata.groupCount == before.metadata.groupCount)
    // Failed staging is discarded: an explicit new operation can commit.
    _ = try await fixture.engine.scan(context, review: fixture.review)
}

@Test func nativeScanReportsUnavailableActiveSourcesAndABRequiresBoth() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missing = try fixture.review.registerSource(expectedRevision: fixture.review.header().metadata.revision,
        input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
            identity: Data(repeating: 9, count: 16), bookmark: Data(), label: "Unavailable generated root"))
    let context = try fixture.context()
    let receipt = try await fixture.engine.scan(context, review: fixture.review)
    #expect(receipt.unavailableSources == [missing.id] && receipt.metadata.groupCount == 1)
    var settings = try fixture.review.header().settings
    settings.sides = CoreComparisonSides(first: fixture.record.id, second: missing.id)
    _ = try fixture.review.saveSettings(expectedRevision: fixture.review.header().metadata.revision, settings: settings)
    let before = try fixture.review.header()
    await #expect(throws: ScopeError.invalidComparison) { try await fixture.engine.scan(context, review: fixture.review) }
    #expect(try fixture.review.header() == before)
}

@Test func scanRejectsRetargetedRootBeforeReadingAndAgainBeforeCommit() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try fixture.context()
    _ = try await fixture.engine.scan(context, review: fixture.review)
    let before = try fixture.review.header()
    let replacement = fixture.root.appending(path: "replacement")
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    let retargeted = try fixture.context([FileSystemSource(directory: replacement, id: fixture.record.id)])
    await #expect(throws: ScanError.invalidSourceSnapshot) { try await fixture.engine.scan(retargeted, review: fixture.review) }
    #expect(try fixture.review.header() == before)
    let original = fixture.root.appending(path: "original")
    await #expect(throws: ScanError.invalidSourceSnapshot) {
        try await fixture.engine.scan(context, review: fixture.review) { update in
            if case .fingerprinting(let completed, _) = update, completed == 2,
               !FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.moveItem(at: fixture.source.directory, to: original)
                try? FileManager.default.createDirectory(at: fixture.source.directory, withIntermediateDirectories: true)
            }
        }
    }
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(try fixture.review.header() == before)
}

@Test func scanRejectsBroaderNativePhotoScopeWithoutEnumeratingPhotoKit() async throws {
    let root = TestFiles.root.appending(path: "scope-pipeline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let review = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    let record = try review.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .photoLibrary,
        namespace: PhotoLibrarySource.sourceIdentityNamespace, identity: PhotoLibrarySource.sourceIdentity,
        bookmark: Data(), label: "Generated PhotoKit context"))
    var settings = try review.header().settings
    settings.photoScope.albums = [:]
    _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
    let context = try AppleAssetSources(sources: [PhotoLibrarySource(id: record.id)], registered: [record])
    let engine = try ScanEngine(cacheURL: root.appending(path: "cache.sqlite"))
    await #expect(throws: ScanError.invalidSourceSnapshot) { try await engine.scan(context, review: review) }
    #expect(try review.header().metadata.scanGeneration == 0)
}

@Test func derivedCacheFailureAfterReviewCommitReturnsExplicitMaintenanceFailure() async throws {
    let fixture = try NativeScanFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let cachePath = fixture.root.appending(path: "cache.sqlite").path
    let receipt = try await fixture.engine.scan(fixture.context(), review: fixture.review) { update in
        if case .comparing(let completed, let total) = update, completed == total {
            var database: OpaquePointer?
            if sqlite3_open_v2(cachePath, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
                _ = sqlite3_exec(database, "DROP TABLE scene_features", nil, nil, nil)
            }
            if let database { sqlite3_close(database) }
        }
    }
    guard case .failed(let diagnostic) = receipt.cacheMaintenance else {
        Issue.record("A failed derived-cache prune must be reported independently of the committed review")
        return
    }
    #expect(!diagnostic.isEmpty)
    #expect(receipt.metadata.scanGeneration == 1 && receipt.metadata.groupCount == 1)
    #expect(try fixture.review.header().metadata == receipt.metadata)
    #expect(try fixture.review.queryCount() == 1)
    let summary = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    #expect(try fixture.review.groupDetail(signature: summary.signature).group.members.count == 2)
}

private enum ScanDatabaseFixtureError: Error { case open, statement }

private func scanFixtureSQL<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ScanDatabaseFixtureError.open
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

private func scanFixtureInteger(_ path: String, _ sql: String) throws -> Int64 {
    try scanFixtureSQL(path) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ScanDatabaseFixtureError.statement }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanDatabaseFixtureError.statement }
        return sqlite3_column_int64(statement, 0)
    }
}

private func committedScanForWriteFailure() async throws -> (URL, FileSystemSource, CoreSourceRecord, CoreReviewMetadata) {
    let fixture = try NativeScanFixture()
    _ = try await fixture.engine.scan(fixture.context(), review: fixture.review)
    let group = try #require(fixture.review.queryPage(offset: 0, limit: 1).first)
    _ = try fixture.review.applyIntent(expectedRevision: fixture.review.header().metadata.revision,
        signature: group.signature, commandId: "manual-before-failed-scan", intent: .confirmKeep(keep: group.preferred))
    return (fixture.root, fixture.source, fixture.record, try fixture.review.header().metadata)
}

@Test func failedReviewCommitRollsBackChoicesAndNeverPrunesDerivedCache() async throws {
    let (root, source, record, before) = try await committedScanForWriteFailure()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "review.sqlite").path
    // Install before opening the owner: external writes to a live owner correctly
    // fail its data-version guard before a review transaction can start.
    try scanFixtureSQL(path) { database in
        guard sqlite3_exec(database,
            "CREATE TRIGGER reject_scan BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'generated failure'); END;",
            nil, nil, nil) == SQLITE_OK else { throw ScanDatabaseFixtureError.statement }
    }
    let review = try RustReviewSession(databasePath: path, initialized: true)
    let engine = try ScanEngine(cacheURL: root.appending(path: "cache.sqlite"))
    let context = try AppleAssetSources(sources: [source], registered: [record])
    // Leave one obsolete derived record that only a successful scan may prune.
    try FileManager.default.removeItem(at: source.directory.appending(path: "b.png"))
    do {
        _ = try await engine.scan(context, review: review)
        Issue.record("A rejected review write acknowledged a scan")
    } catch let error as RustCoreFailure {
        guard case BridgeError.WriteFailed = error.underlying else { throw error }
    }
    #expect(throws: BridgeError.ProtectionUnavailable) { try review.header() }
    #expect(try scanFixtureInteger(path, "SELECT revision FROM meta") == Int64(before.revision))
    #expect(try scanFixtureInteger(path, "SELECT scan_generation FROM meta") == Int64(before.scanGeneration))
    #expect(try scanFixtureInteger(path, "SELECT count(*) FROM decisions") == 1)
    #expect(try scanFixtureInteger(path, "SELECT count(*) FROM groups WHERE active=1") == 1)
    #expect(try scanFixtureInteger(root.appending(path: "cache.sqlite").path, "SELECT count(*) FROM fingerprints") == 2)
}
