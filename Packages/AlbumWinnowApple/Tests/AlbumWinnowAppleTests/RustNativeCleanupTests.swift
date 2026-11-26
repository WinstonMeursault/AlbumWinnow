import AlbumWinnowRust
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AlbumWinnowApple

struct NativeCleanupFixture {
    let base: URL
    let source: FileSystemSource
    let session: RustReviewSession
    let pairCount: Int

    init(pairs: Int = 1) throws {
        base = TestFiles.root.appending(path: UUID().uuidString)
        let folder = base.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pairCount = pairs
        for index in 0..<pairs {
            let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: index == 0 ? "burst-a.png" : "orientation.png"))
            for name in ["keep\(index).png", "remove\(index).png"] { try bytes.write(to: folder.appending(path: name)) }
        }
        session = try RustReviewSession(databasePath: base.appending(path: "v2/review.sqlite").path, initialized: false)
        let record = try session.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .fileSystem,
            namespace: FileSystemSource.sourceIdentityNamespace, identity: FileSystemSource.sourceIdentity(directory: folder), bookmark: Data(), label: "Generated test copies"))
        source = FileSystemSource(directory: folder, id: record.id)
    }
    func prepare(all: Bool = false, scene: CoreSceneProvider? = nil) async throws -> String {
        if scene != nil {
            var settings = try session.header().settings
            settings.similarScenesEnabled = true
            settings.query.collection = .similarScenes
            _ = try session.saveSettings(expectedRevision: session.header().metadata.revision, settings: settings)
        }
        let assets = try await source.snapshot().assets
        let groups = try (0..<pairCount).map { index in
            let keep = try #require(assets.first { $0.name == "keep\(index).png" })
            let remove = try #require(assets.first { $0.name == "remove\(index).png" })
            let members = try [keep, remove].map { try $0.reviewValue(kind: .fileSystem, nativeIdentity: source.nativeIdentity(for: $0), linkCount: source.linkCount(for: $0)) }
            return CoreReviewGroup(preferred: keep.id.coreValue, members: members,
                duplicates: [CoreReviewDuplicate(asset: remove.id.coreValue, kind: scene == nil ? .exactDuplicate : .sceneSimilar)], edges: nil, sides: nil,
                scene: scene, recommendation: nil, hasQualityRecommendation: true, sceneRecommendationReason: nil,
                sceneQuality: [], sceneMatches: [], evidence: [])
        }
        let scanOperation = "native-scan-\(UUID())"
        try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: scanOperation)
        try session.appendScanGroups(operationId: scanOperation, groups: groups, cancellation: CancellationHandle())
        _ = try session.finishScan(operationId: scanOperation, cancellation: CancellationHandle())
        for index in 0..<pairCount {
            let summary = try #require(session.queryPage(offset: UInt64(index), limit: 1).first)
            _ = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: summary.signature,
                commandId: "\(scanOperation)-confirm-\(index)", intent: all ? .confirmDeleteAll : .confirmKeep(keep: groups[index].preferred))
        }
        return try session.startCleanup(expectedRevision: session.header().metadata.revision).operation
    }
    func context(additional: [any AssetSource] = []) throws -> AppleAssetSources {
        try AppleAssetSources(sources: [source] + additional, registered: session.sourcesPage(offset: 0, limit: 256))
    }
    func results(_ operation: String) throws -> [CoreCleanupResult] {
        try session.cleanupResultsPage(operation: operation, completed: true, offset: 0, limit: 256)
    }
    func restore(_ receipt: AppleCleanupReceipt, operation: String) throws {
        for result in try results(operation) where result.outcome == .movedToTrash {
            let original = URL(fileURLWithPath: result.item.pair.remove.id.itemId)
            let trash = try #require(receipt.trashLocations[result.item.key])
            #expect(original.path.hasPrefix(base.path + "/"))
            #expect(FileManager.default.fileExists(atPath: trash.path))
            try FileManager.default.moveItem(at: trash, to: original)
            #expect(FileManager.default.fileExists(atPath: original.path))
            let fixture = TestFiles.fixtures.appending(path: result.item.key.group == 0 ? "burst-a.png" : "orientation.png")
            #expect(try Data(contentsOf: original) == Data(contentsOf: fixture))
        }
    }
}

@Test func rustAuthorizedNativeTrashIsRecoverableAndPartialFailurePreservesTheOtherFiles() async throws {
    let fixture = try NativeCleanupFixture(pairs: 2)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let operation = try await fixture.prepare()
    let companion = fixture.source.directory.appending(path: "remove1.png.xmp")
    try Data("generated edit companion".utf8).write(to: companion)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    defer { try? fixture.restore(receipt, operation: operation) }
    let results = try fixture.results(operation)
    #expect(results.map(\.outcome) == [.movedToTrash, .skipped(reason: .protectedResources)])
    #expect(receipt.metadata.decisionCount == 1)
    #expect(try fixture.session.queryCount() == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: "remove0.png").path))
    for name in ["keep0.png", "keep1.png", "remove1.png", "remove1.png.xmp"] {
        #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: name).path))
    }
    #expect(try Data(contentsOf: companion) == Data("generated edit companion".utf8))
}

@Test func nativeWholeGroupPreflightBlocksEveryMoveWhenOneNewCompanionAppears() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let operation = try await fixture.prepare(all: true)
    try Data("generated edit".utf8).write(to: fixture.source.directory.appending(path: "remove0.png.xmp"))
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).map(\.outcome) == [.skipped(reason: .protectedResources), .skipped(reason: .protectedResources)])
    for name in ["keep0.png", "remove0.png"] { #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: name).path)) }
    #expect(receipt.metadata.decisionCount == 1)
}

@Test func nativeAtomicCancellationPreventsAnyRecoveryOperation() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let operation = try await fixture.prepare()
    let cancel = CancellationHandle()
    cancel.cancel()
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context(), cancellation: cancel)
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).map(\.outcome) == [.skipped(reason: .cancelled)])
    #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: "remove0.png").path))
}

@Test func nativeCurrentLockAliasIsProtectedAfterTheLockedPathWasReplaced() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let lockedURL = fixture.source.directory.appending(path: "locked.png")
    try Data(contentsOf: TestFiles.fixtures.appending(path: "orientation.png")).write(to: lockedURL)
    let snapshot = try await fixture.source.snapshot()
    let locked = try #require(snapshot.assets.first { $0.name == "locked.png" })
    let old = try locked.reviewValue(kind: .fileSystem, nativeIdentity: fixture.source.nativeIdentity(for: locked), linkCount: fixture.source.linkCount(for: locked))
    _ = try fixture.session.setLocked(expectedRevision: fixture.session.header().metadata.revision, asset: old, locked: true)
    try FileManager.default.removeItem(at: lockedURL)
    try FileManager.default.linkItem(at: fixture.source.directory.appending(path: "remove0.png"), to: lockedURL)
    let operation = try await fixture.prepare()
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).first?.outcome == .skipped(reason: .userProtected))
    #expect(FileManager.default.fileExists(atPath: lockedURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: "remove0.png").path))
}

@Test func unavailableInactiveReadOnlyRootBlocksNativeFilesystemRemoval() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let protectedURL = fixture.base.appending(path: "protected")
    try FileManager.default.createDirectory(at: protectedURL, withIntermediateDirectories: true)
    let record = try fixture.session.registerSource(expectedRevision: fixture.session.header().metadata.revision,
        input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
                              identity: FileSystemSource.sourceIdentity(directory: protectedURL), bookmark: Data(), label: "Inactive protected source"))
    _ = try fixture.session.setSourceActive(expectedRevision: fixture.session.header().metadata.revision, source: record.id, active: false)
    try fixture.session.beginReadOnlySnapshot(expectedRevision: fixture.session.header().metadata.revision, operationId: "protected", source: record.id)
    _ = try fixture.session.finishReadOnlySnapshot(operationId: "protected", complete: true, cancellation: CancellationHandle())
    let operation = try await fixture.prepare()
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).first?.outcome == .skipped(reason: .unavailableProtection))
    #expect(FileManager.default.fileExists(atPath: fixture.source.directory.appending(path: "remove0.png").path))
}

@Test func retargetedFolderCannotExecuteTheRegisteredWholeGroupPlan() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let operation = try await fixture.prepare(all: true)
    let saved = fixture.base.appending(path: "original-photos")
    try FileManager.default.moveItem(at: fixture.source.directory, to: saved)
    try FileManager.default.createDirectory(at: fixture.source.directory, withIntermediateDirectories: true)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).map(\.outcome) == [.failed, .failed])
    #expect(receipt.metadata.decisionCount == 1)
    for name in ["keep0.png", "remove0.png"] { #expect(FileManager.default.fileExists(atPath: saved.appending(path: name).path)) }
}

@Test func nativeSceneCleanupRequiresTheCurrentVisionProviderAndFreshMeasurements() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let keep = fixture.source.directory.appending(path: "keep0.png")
    let remove = fixture.source.directory.appending(path: "remove0.png")
    try Data(contentsOf: TestFiles.fixtures.appending(path: "scene.png")).write(to: keep)
    let source = try #require(CGImageSourceCreateWithURL(keep as CFURL, nil))
    let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let crop = try #require(original.cropping(to: CGRect(x: Double(original.width) * 0.04, y: 0,
        width: Double(original.width) * 0.92, height: Double(original.height))))
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, crop, nil)
    #expect(CGImageDestinationFinalize(destination))
    try (bytes as Data).write(to: remove)
    var stale = SceneFeature.provider
    stale.modelRevision = "unknown"
    let rejected = try await fixture.prepare(scene: stale)
    let first = try await AppleCleanupExecutor(session: fixture.session).apply(operation: rejected, sources: fixture.context())
    #expect(first.trashLocations.isEmpty)
    #expect(try fixture.results(rejected).first?.outcome == .skipped(reason: .noLongerDuplicate))
    let operation = try await fixture.prepare(scene: SceneFeature.provider)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    defer { if let url = receipt.trashLocations.values.first { try? FileManager.default.moveItem(at: url, to: remove) } }
    let results = try fixture.results(operation)
    #expect(results.first?.outcome == .movedToTrash, "Results: \(results); diagnostics: \(receipt.diagnostics); interruption: \(String(describing: receipt.interruption))")
    #expect(!FileManager.default.fileExists(atPath: remove.path))
    #expect(FileManager.default.fileExists(atPath: keep.path))
}
