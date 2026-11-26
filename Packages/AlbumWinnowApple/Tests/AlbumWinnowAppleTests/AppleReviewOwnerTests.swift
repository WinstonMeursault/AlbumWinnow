import AlbumWinnowRust
import Foundation
import Testing
@testable import AlbumWinnowApple

private struct OwnerWorkspace: Sendable {
    let root = TestFiles.root.appending(path: "owner-\(UUID())")
    let suite = "org.albumwinnow.tests.owner.\(UUID())"
    var data: URL { root.appending(path: "v2") }
    func dispose() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func photos() throws -> URL {
        let folder = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        return folder
    }
}

@Test func freshOwnerUsesOnlyV2StateWithoutAutomaticSourceScanOrLegacyDeletion() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
    let old = workspace.root.appending(path: "review.sqlite")
    let oldCleanup = workspace.root.appending(path: "cleanup.sqlite")
    let bytes = Data("old user sources, protection and delete candidates must remain untouched".utf8)
    for path in [old, oldCleanup] { try bytes.write(to: path) }
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let header = try await owner.header()
    #expect(header.metadata.sourceCount == 0 && header.metadata.groupCount == 0 && header.metadata.decisionCount == 0)
    #expect(header.metadata.scanGeneration == 0)
    #expect(try await owner.queryCount() == 0)
    #expect(await owner.sourceIssues().isEmpty)
    #expect(UserDefaults(suiteName: workspace.suite)?.object(forKey: "initialized") as? Bool == true)
    for path in [old, oldCleanup] { #expect(try Data(contentsOf: path) == bytes) }
}

private func initializedOwner(_ workspace: OwnerWorkspace) async throws {
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    #expect(await owner.isHealthy())
}

@Test func initializedOwnerNeverRecreatesMissingProtectionDatabase() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    try await initializedOwner(workspace)
    let database = workspace.data.appending(path: "review.sqlite")
    try FileManager.default.removeItem(at: database)
    do {
        _ = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
        Issue.record("An initialized owner recreated a missing protection database")
    } catch let error as RustCoreFailure {
        guard case BridgeError.ProtectionUnavailable = error.underlying else { throw error }
    }
    #expect(!FileManager.default.fileExists(atPath: database.path))
}

@Test(arguments: ["false", "string", "number"])
func invalidInitializationPreferenceCannotBecomeFreshProtection(kind: String) async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let defaults = try #require(UserDefaults(suiteName: workspace.suite))
    switch kind {
    case "false": defaults.set(false, forKey: "initialized")
    case "string": defaults.set("true", forKey: "initialized")
    default: defaults.set(1, forKey: "initialized")
    }
    await #expect(throws: CleanupError.unavailableProtection) {
        try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    }
    #expect(!FileManager.default.fileExists(atPath: workspace.data.appending(path: "review.sqlite").path))
}

@Test func oneOwnerKeepsAuthoritativeManualChoicesAndCacheClearIsIndependent() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let source = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    #expect(source.id.hasPrefix("source.v2.") && source.nativeNamespace == FileSystemSource.sourceIdentityNamespace)
    #expect(!source.bookmark.isEmpty)
    let scanned = try await owner.scan()
    #expect(scanned.metadata.scanGeneration == 1 && scanned.metadata.groupCount == 1 && scanned.issues.isEmpty)
    let summary = try #require(await owner.queryPage(offset: 0, limit: 1).first)
    let delta = try await owner.applyIntent(expectedRevision: scanned.metadata.revision, signature: summary.signature,
        commandID: "manual", intent: .confirmKeep(keep: summary.preferred))
    #expect(delta.decision.removals.count == 1)
    let before = try await owner.header()
    try await owner.clearCache()
    #expect(try await owner.header() == before)
    #expect(try await owner.groupDetail(signature: summary.signature).decision == delta.decision)
    let cold = try await owner.scan()
    #expect(cold.scanned == 2 && cold.reused == 0)
    #expect(try await owner.groupDetail(signature: summary.signature).decision?.status == .confirmed)
}

private func persistedOwnerSource(_ workspace: OwnerWorkspace, folder: URL) async throws -> CoreSourceRecord {
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let record = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    _ = try await owner.scan()
    return record
}

@Test func reopeningRestoresRegisteredNativeAuthorizationWithoutScanning() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let record = try await persistedOwnerSource(workspace, folder: folder)
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    #expect(try await owner.sourcesPage(offset: 0, limit: 256) == [record])
    #expect(await owner.sourceIssues().isEmpty)
    #expect(try await owner.header().metadata.scanGeneration == 1)
    let scan = try await owner.scan()
    #expect(scan.reused == 2 && scan.scanned == 0 && scan.unavailableSources.isEmpty)
}

@Test func bookmarkCannotRetargetOldSourceIdentityWhenDirectoryIsReplaced() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let record = try await persistedOwnerSource(workspace, folder: folder)
    // Delete only generated fixtures, so the bookmark cannot find the old inode
    // by following a move and must not register a replacement under the old ID.
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    #expect(await owner.sourceIssues().map(\.source) == [record.id])
    let scan = try await owner.scan()
    #expect(scan.unavailableSources == [record.id] && scan.scanned == 0)
    let replacement = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    #expect(replacement.id != record.id)
    #expect(try await owner.sourcesPage(offset: 0, limit: 256).count == 2)
}

@Test func ownerReadOnlyAndLocksPruneChoicesAndRemovingProtectionDoesNotRestoreThem() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let source = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    _ = try await owner.scan()
    let summary = try #require(await owner.queryPage(offset: 0, limit: 1).first)
    let group = try await owner.groupDetail(signature: summary.signature).group
    let decision = try await owner.applyIntent(expectedRevision: owner.header().metadata.revision, signature: summary.signature,
        commandID: "confirm-before-protection", intent: .confirmKeep(keep: group.preferred))
    let removing = try #require(group.members.first { $0.id == decision.decision.removals.first })
    _ = try await owner.setLocked(expectedRevision: decision.metadata.revision, asset: removing, locked: true)
    #expect(try await owner.groupDetail(signature: summary.signature).decision?.removals.isEmpty == true)
    #expect(try await owner.lockedPage(offset: 0, limit: 256) == [removing])
    _ = try await owner.removeSavedLock(expectedRevision: owner.header().metadata.revision, asset: removing.id)
    #expect(try await owner.groupDetail(signature: summary.signature).decision?.removals.isEmpty == true)
    _ = try await owner.setReadOnly(expectedRevision: owner.header().metadata.revision, source: source.id, enabled: true)
    #expect(try await owner.header().readOnlySources == [source.id])
    #expect(Set(try await owner.groupDetail(signature: summary.signature).protected) == Set(group.members.map(\.id)))
    _ = try await owner.setReadOnly(expectedRevision: owner.header().metadata.revision, source: source.id, enabled: false)
    #expect(try await owner.header().readOnlySources.isEmpty)
    #expect(try await owner.groupDetail(signature: summary.signature).decision?.removals.isEmpty == true)
}

private func persistedProtectedSource(_ workspace: OwnerWorkspace, folder: URL) async throws -> CoreSourceRecord {
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let record = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    _ = try await owner.setReadOnly(expectedRevision: owner.header().metadata.revision, source: record.id, enabled: true)
    return try await owner.setSourceActive(expectedRevision: owner.header().metadata.revision, source: record.id, active: false)
}

@Test func ownerRetainsInactiveReadOnlySourceAndReportsItsMissingAuthorization() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let record = try await persistedProtectedSource(workspace, folder: folder)
    try FileManager.default.removeItem(at: folder)
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    #expect(await owner.sourceIssues().map(\.source) == [record.id])
    #expect(try await owner.sourcesPage(offset: 0, limit: 256) == [record])
    #expect(try await owner.header().readOnlySources == [record.id])
    let reset = try await owner.resetProgress(expectedRevision: owner.header().metadata.revision)
    #expect(reset.decisionCount == 0)
    #expect(try await owner.header().readOnlySources == [record.id])
}

@Test func ownerSetupNoticeAndCloudPreferencesUseIndependentV2Suite() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    #expect(await owner.needsSetupNotice())
    #expect(await owner.skipsCloudPhotos())
    await owner.acknowledgeSetupNotice()
    try await owner.setSkipCloudPhotos(false)
    #expect(!(await owner.needsSetupNotice()))
    #expect(!(await owner.skipsCloudPhotos()))
    #expect(UserDefaults(suiteName: workspace.suite)?.bool(forKey: "setupNoticeAcknowledged") == true)
    #expect(UserDefaults(suiteName: workspace.suite)?.bool(forKey: "skipCloud") == false)
    #expect(try await owner.header().metadata.scanGeneration == 0)
}

#if os(macOS)
@Test func ownerExecutesOnlyItsManualPlanAndGeneratedTrashCanBeRestored() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let folder = try workspace.photos()
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    _ = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    _ = try await owner.scan()
    let summary = try #require(await owner.queryPage(offset: 0, limit: 1).first)
    let decision = try await owner.applyIntent(expectedRevision: owner.header().metadata.revision, signature: summary.signature,
        commandID: "explicit-native-owner-confirm", intent: .confirmKeep(keep: summary.preferred))
    let (operation, receipt) = try await owner.applyCleanup(expectedRevision: decision.metadata.revision)
    let results = try await owner.cleanupResults(operation: operation, offset: 0, limit: 16)
    let moved = try #require(results.first)
    let original = URL(fileURLWithPath: moved.item.pair.remove.id.itemId)
    let trash = try #require(receipt.trashLocations[moved.item.key])
    defer {
        if original.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: trash.path) {
            try? FileManager.default.moveItem(at: trash, to: original)
        }
    }
    #expect(results.count == 1 && moved.outcome == .movedToTrash)
    #expect(original.path.hasPrefix(folder.path + "/"))
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(FileManager.default.fileExists(atPath: summary.preferred.itemId))
    #expect(try Data(contentsOf: trash) == Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")))
    #expect(try await owner.queryCount() == 0)
    #expect(receipt.metadata.decisionCount == 0)
    try FileManager.default.moveItem(at: trash, to: original)
    #expect(try Data(contentsOf: original) == Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
}
#endif

@Test func ownerPresentationPagesProvideCorePreviewsCountsAndProtectionFlags() async throws {
    let workspace = OwnerWorkspace()
    defer { workspace.dispose() }
    let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
    let folder = try workspace.photos()
    let source = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
    _ = try await owner.scan()
    let initial = try await owner.reviewPage(mode: .visible, offset: 0, limit: 1)
    let summary = try #require(initial.groups.first)
    #expect(initial.total == 1 && initial.overview.pendingGroups == 1 && initial.overview.savedRemovals == 0)
    #expect(summary.previewAssets.count == 1 && summary.previewAssets[0].id == summary.preferred)
    #expect(summary.preferredEvidence?.asset == summary.preferred)
    let group = try await owner.groupDetail(signature: summary.signature).group
    _ = try await owner.applyIntent(expectedRevision: initial.header.metadata.revision, signature: summary.signature,
        commandID: "presentation-keep", intent: .confirmKeep(keep: group.members[1].id))
    _ = try await owner.applyIntent(expectedRevision: owner.header().metadata.revision, signature: summary.signature,
        commandID: "presentation-saved-defer", intent: .setStatus(status: .deferred))
    var settings = try await owner.header().settings
    settings.query.status = .pending
    let revision = try await owner.saveSettings(expectedRevision: owner.header().metadata.revision, settings: settings)
    let candidates = try await owner.reviewPage(mode: .cleanupCandidates, offset: 0, limit: 1)
    #expect(candidates.header.metadata == revision)
    #expect(candidates.total == 1 && candidates.overview.savedRemovals == 1 && candidates.overview.hiddenSavedRemovals == 1)
    #expect(candidates.groups[0].previewAssets.map(\.id) == [group.preferred, group.members[1].id])
    #expect(candidates.groups[0].savedRemovalCount == 1)
    #expect(try await owner.reviewPage(mode: .pending, offset: 0, limit: 1).total == 0)
    let plan = try await owner.prepareCleanup(expectedRevision: revision.revision)
    #expect(plan.itemCount == 1)
    let planned = try await owner.cleanupGroups(operation: plan.operation, offset: 0, limit: 1)
    #expect(planned.count == 1 && planned[0].removalCount == 1)
    let items = try await owner.cleanupItems(operation: plan.operation, group: planned[0].index, offset: 0, limit: 16)
    #expect(items.count == 1 && items[0].pair.remove.id == group.members[0].id)
    #expect(FileManager.default.fileExists(atPath: group.members[0].id.itemId))
    try await owner.cancelPreparedCleanup(operation: plan.operation)
    #expect(FileManager.default.fileExists(atPath: group.members[0].id.itemId))
    _ = try await owner.setLocked(expectedRevision: owner.header().metadata.revision, asset: group.members[0], locked: true)
    let detail = try await owner.groupDetail(signature: summary.signature)
    #expect(detail.locked == [group.members[0].id] && detail.readOnly.isEmpty)
    #expect(try await owner.lockOwnersPage(asset: group.members[0], offset: 0, limit: 1) == [group.members[0].id])
    #expect(try await owner.reviewPage(mode: .cleanupCandidates, offset: 0, limit: 1).total == 0)
    _ = try await owner.setReadOnly(expectedRevision: owner.header().metadata.revision, source: source.id, enabled: true)
    #expect(try await owner.groupDetail(signature: summary.signature).readOnly.count == 2)
    #expect(try await owner.groupDetail(signature: summary.signature).summary.estimate.knownBytes == 0)
    let nativeAsset = PhotoAsset(group.members[0])
    let bytes = try await owner.withAssetSources(assets: [nativeAsset]) { selected in
        guard let source = selected[nativeAsset.id.source] else { throw CleanupError.unavailableSource }
        return try await source.imageData(for: nativeAsset)
    }
    #expect(bytes == (try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))))
    await #expect(throws: AssetAccessError.changedDuringScan) {
        try await owner.withAssetSources(assets: [nativeAsset]) { _ in
            _ = try await owner.setSourceActive(expectedRevision: owner.header().metadata.revision, source: source.id, active: false)
            return true
        }
    }
}
