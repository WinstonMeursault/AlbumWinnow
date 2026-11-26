import AlbumWinnowApple
import AlbumWinnowRust
import XCTest
@testable import AlbumWinnowAcceptance

final class V2ApplicationTests: XCTestCase {
    @MainActor
    func testFreshBootstrapLeavesLegacyFilesAndPreferencesUntouched() async throws {
        let root = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
        let legacy = root.appending(path: "legacy")
        let fresh = root.appending(path: "v2")
        let suite = "org.albumwinnow.tests.v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let files = ["review.sqlite", "scan.sqlite", "cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"]
        for file in files { try Data("legacy sentinel".utf8).write(to: legacy.appending(path: file)) }
        defaults.set([Data("old bookmark".utf8)], forKey: "AlbumWinnow.folderBookmarks")
        defaults.set(true, forKey: "AlbumWinnow.photosEnabled")
        defaults.set(true, forKey: "AlbumWinnow.interruptedScan")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = ReviewModel(dataDirectory: fresh, preferencesSuite: suite)
        XCTAssertFalse(model.canScan)
        await model.bootstrap()
        XCTAssertTrue(model.protectionAvailable, model.errorMessage ?? "")
        XCTAssertTrue(model.showingSetupNotice)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertFalse(model.photosEnabled)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.canClean)
        await model.acknowledgeSetupNotice()
        XCTAssertFalse(model.showingSetupNotice)
        for file in files { XCTAssertEqual(try Data(contentsOf: legacy.appending(path: file)), Data("legacy sentinel".utf8)) }
        XCTAssertTrue(defaults.bool(forKey: "AlbumWinnow.photosEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "AlbumWinnow.interruptedScan"))
        XCTAssertNotNil(defaults.array(forKey: "AlbumWinnow.folderBookmarks"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appending(path: "review.sqlite").path))
    }

    @MainActor
    func testCommittedChoicesUsePagedDetailsAndPreparedConfirmation() async throws {
        let root = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "photos")
        let suite = "org.albumwinnow.tests.v2.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png"))
        for name in ["a.png", "b.png", "c.png"] { try bytes.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: root.appending(path: "v2"), preferencesSuite: suite)
        await model.bootstrap()
        await model.acknowledgeSetupNotice()
        model.addFolder(folder)
        try await wait { !model.updatingPolicy }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(try XCTUnwrap(model.folders.first).id.hasPrefix("source.v2."))
        model.scan()
        try await wait { !model.running }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canClean)
        XCTAssertEqual(model.totalGroupCount, 1)
        XCTAssertEqual(model.visibleGroups.first?.count, 3)
        XCTAssertTrue(model.details.isEmpty, "Gallery data must not eagerly materialize all members")
        let summary = try XCTUnwrap(model.visibleGroups.first)
        XCTAssertEqual(summary.core.previewAssets.count, 1)
        await model.loadDetails(for: [summary])
        let group = try XCTUnwrap(model.details[summary.id])
        XCTAssertEqual(group.assets.count, 3)
        XCTAssertEqual(model.selectedCount, 0, "Estimates do not create saved removal choices")
        let preview = try await model.preview(for: group.preferred)
        XCTAssertNotNil(preview.image)
        let manualKeep = try XCTUnwrap(group.duplicates.last).id
        let confirmed = await model.confirmSelection(in: group, keepID: manualKeep, deleteAll: false)
        XCTAssertTrue(confirmed, model.errorMessage ?? "")
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.selection(for: group.id).keepID, manualKeep)
        XCTAssertEqual(model.visibleGroups.first?.core.previewAssets.count, 2)
        let deferred = await model.setStatus(.deferred, for: try XCTUnwrap(model.details[group.id]))
        XCTAssertTrue(deferred)
        XCTAssertEqual(model.selectedCount, 2)
        var query = model.resultQuery
        query.status = .kept
        model.setResultQuery(query)
        try await wait { !model.updatingPolicy }
        XCTAssertTrue(model.visibleGroups.isEmpty)
        XCTAssertEqual(model.hiddenCandidateCount, 2)
        model.releaseDetails()
        XCTAssertEqual(model.status(for: summary), .deferred, "Review-session status must remain current after detail eviction")
        await model.loadDetails(for: [summary])
        await model.prepareCleanup()
        XCTAssertEqual(model.cleanupPlan?.itemCount, 2)
        XCTAssertEqual(model.cleanupGroups.count, 1)
        let confirmation = try await model.cleanupPreview(XCTUnwrap(model.cleanupGroups.first))
        XCTAssertEqual(confirmation.keep?.id, manualKeep)
        XCTAssertEqual(confirmation.retained.map(\.id), [manualKeep])
        XCTAssertEqual(confirmation.removing.count, 2)
        await model.cancelCleanup()
        XCTAssertNil(model.cleanupPlan)
        for name in ["a.png", "b.png", "c.png"] { XCTAssertEqual(try Data(contentsOf: folder.appending(path: name)), bytes) }
        let removed = try XCTUnwrap(group.assets.first { $0.id != manualKeep })
        model.setLocked(removed, locked: true)
        try await wait { !model.updatingPolicy }
        XCTAssertTrue(model.isLocked(removed))
        XCTAssertEqual(model.selectedCount, 1)
        model.resetReviewProgress()
        try await wait { !model.updatingPolicy }
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertTrue(model.isLocked(removed))
        await model.clearScanCache()
        XCTAssertTrue(model.savedLocks.contains(removed.id))
        XCTAssertNil(model.result)
        XCTAssertTrue(model.canScan)
    }

    @MainActor
    func testUnavailableSourceReconnectRetainsOriginalProtectionIdentity() async throws {
        let root = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "original")
        let suite = "org.albumwinnow.tests.v2.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png"))
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: root.appending(path: "v2"), preferencesSuite: suite)
        await model.bootstrap()
        await model.acknowledgeSetupNotice()
        model.addFolder(folder)
        try await wait { !model.updatingPolicy }
        let originalID = try XCTUnwrap(model.folders.first).id
        model.scan()
        try await wait { !model.running }
        let summary = try XCTUnwrap(model.visibleGroups.first)
        await model.loadDetails(for: [summary])
        let asset = try XCTUnwrap(model.details[summary.id]).preferred
        model.setLocked(asset, locked: true)
        try await wait { !model.updatingPolicy }
        await model.setReadOnly(originalID, enabled: true)
        try FileManager.default.removeItem(at: folder)
        model.retryFolders()
        try await wait { !model.updatingPolicy }
        XCTAssertEqual(model.unavailableFolders, [originalID])
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.savedLocks.contains(asset.id))
        XCTAssertTrue(model.readOnlySources.contains(originalID))
        let regular = root.appending(path: "file")
        try Data([1]).write(to: regular)
        model.reconnectFolder(originalID, to: regular)
        try await wait { !model.updatingPolicy }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.protectionAvailable, "A native selection error must not corrupt the healthy core")
        XCTAssertEqual(model.unavailableFolders, [originalID])
        model.errorMessage = nil
        let replacement = root.appending(path: "replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        model.reconnectFolder(originalID, to: replacement)
        try await wait { !model.updatingPolicy }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.unavailableFolders.isEmpty)
        let replacementID = try XCTUnwrap(model.folders.first).id
        XCTAssertNotEqual(replacementID, originalID)
        XCTAssertTrue(model.savedLocks.contains(asset.id))
        XCTAssertTrue(model.readOnlySources.contains(originalID))
        XCTAssertFalse(try XCTUnwrap(model.registeredSources.first { $0.id == originalID }).active)
        model.removeFolder(replacementID)
        try await wait { !model.updatingPolicy }
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.savedLocks.contains(asset.id))
        XCTAssertTrue(model.readOnlySources.contains(originalID))
    }

    @MainActor
    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<500 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for v2 model operation")
        throw CocoaError(.userCancelled)
    }
}
