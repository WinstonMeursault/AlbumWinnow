import AlbumWinnowApple
import Foundation
import XCTest
@testable import AlbumWinnowAcceptance

final class ScanLifecycleTests: XCTestCase {
    #if os(iOS)
    @MainActor
    func testRelaunchResumesFolderScanFromPersistedSelection() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: (0..<48).map { "sample-\($0).png" })
        let source = try await workspace.withModel { initial in
            initial.addFolder(folder)
            try await awaitModel(initial)
            initial.sceneChanged(.active)
            initial.scan()
            XCTAssertTrue(workspace.preferences.bool(forKey: "interruptedScan"))
            initial.sceneChanged(.background)
            try await awaitModel(initial)
            XCTAssertNil(initial.result)
            XCTAssertTrue(workspace.preferences.bool(forKey: "interruptedScan"))
            return try XCTUnwrap(initial.folders.first).id
        }
        let reopened = try await workspace.open()
        XCTAssertEqual(reopened.folders.map(\.id), [source])
        reopened.sceneChanged(.active)
        try await waitForModelCondition { reopened.result != nil && !reopened.running }
        XCTAssertEqual(reopened.visibleGroups.first?.count, 48)
        XCTAssertFalse(workspace.preferences.bool(forKey: "interruptedScan"))
    }

    @MainActor
    func testBackgroundPreservesDownloadConsentAndUserCancellationClearsIt() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: [])
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.sceneChanged(.active)
        // Controlled consent marker only: this case makes no PhotoKit or network
        // request and does not claim to validate an actual iCloud transfer.
        let pending = AssetID(source: try XCTUnwrap(model.folders.first).id, item: "pending-cloud")
        model.startScan(downloads: [pending])
        model.sceneChanged(.background)
        try await awaitModel(model)
        XCTAssertTrue(workspace.preferences.bool(forKey: "interruptedScan"))
        let data = try XCTUnwrap(workspace.preferences.data(forKey: "interruptedDownloads"))
        XCTAssertEqual(try JSONDecoder().decode(Set<AssetID>.self, from: data), [pending])
        model.cancelScan()
        XCTAssertNil(workspace.preferences.object(forKey: "interruptedDownloads"))
        XCTAssertFalse(workspace.preferences.bool(forKey: "interruptedScan"))
        try await waitForModelCondition { model.header?.settings.scanCancelledByUser == true }
        model.sceneChanged(.active)
        XCTAssertFalse(model.running)
    }
    @MainActor
    func testManualRetryAfterUserCancellationCanResumeFromBackground() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        model.cancelScan()
        try await awaitModel(model)
        XCTAssertTrue(model.header?.settings.scanCancelledByUser == true)
        model.sceneChanged(.active)
        model.scan()
        model.sceneChanged(.background)
        try await awaitModel(model)
        XCTAssertTrue(workspace.preferences.bool(forKey: "interruptedScan"))
        guard model.header?.settings.scanCancelledByUser == false else {
            XCTFail("A new explicit scan must supersede the previous user-cancelled marker even if backgrounded immediately")
            return
        }
        model.sceneChanged(.active)
        try await waitForModelCondition { model.result != nil && !model.running }
        XCTAssertFalse(workspace.preferences.bool(forKey: "interruptedScan"))
        XCTAssertTrue(model.canClean)
    }
    #endif

    @MainActor
    func testLibraryChangeDoesNotCancelActiveScanButRequiresRescan() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: (0..<48).map { "sample-\($0).png" })
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        model.libraryDidChange()
        try await awaitModel(model)
        XCTAssertEqual(model.result?.scanned, 48)
        XCTAssertTrue(model.resultsStale)
        XCTAssertFalse(model.canClean)
        model.scan()
        try await awaitModel(model)
        XCTAssertEqual(model.result?.reused, 48)
        XCTAssertFalse(model.resultsStale)
        XCTAssertTrue(model.canClean)
        model.libraryDidChange()
        XCTAssertNil(model.result)
        XCTAssertFalse(model.canClean)
    }

    @MainActor
    func testRetryAndCancellationPreserveStaleResultsUntilSuccessfulScan() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        XCTAssertTrue(model.canClean)
        let pending = AssetID(source: try XCTUnwrap(model.folders.first).id, item: "controlled-pending")
        model.startScan(downloads: [pending])
        model.libraryDidChange()
        model.cancelScan()
        try await awaitModel(model)
        XCTAssertTrue(model.resultsStale)
        model.startScan(downloads: [pending])
        model.cancelScan()
        try await awaitModel(model)
        XCTAssertTrue(model.resultsStale)
        XCTAssertFalse(model.canClean)
        model.scan()
        try await awaitModel(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.resultsStale)
        XCTAssertTrue(model.canClean)
    }

    @MainActor
    func testClearingCachePreservesFolderAccessAndPhotos() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["photo.png"])
        let photo = folder.appending(path: "photo.png")
        let bytes = try Data(contentsOf: photo)
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let sources = model.registeredSources
        await model.clearScanCache()
        XCTAssertFalse(model.clearingCache)
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.cacheStatus)
        XCTAssertTrue(model.canScan)
        XCTAssertEqual(model.registeredSources, sources)
        XCTAssertEqual(try Data(contentsOf: photo), bytes)
        model.scan()
        try await awaitModel(model)
        XCTAssertEqual(model.result?.scanned, 1)
        XCTAssertEqual(model.result?.reused, 0)
    }

    @MainActor
    func testFolderCleanupIsRecoverableOrLeavesBothOriginals() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["a-keep.png", "b-copy.png"])
        let keep = folder.appending(path: "a-keep.png"), copy = folder.appending(path: "b-copy.png")
        let bytes = try Data(contentsOf: copy)
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let group = try await scannedGroup(model)
        XCTAssertEqual(group.preferred.name, "a-keep.png")
        let confirmed = await model.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        await model.prepareCleanup()
        XCTAssertEqual(model.cleanupPlan?.itemCount, 1)
        await model.applyCleanup()
        let outcome = try XCTUnwrap(model.lastCleanup?.first)
        #if os(macOS)
        XCTAssertTrue(outcome.moved, outcome.detail ?? "Native macOS fixture must actually move to Trash")
        #endif
        print("V2_MODEL_CLEANUP moved=\(outcome.moved) trashReceipt=\(outcome.trashLocation != nil)")
        if outcome.moved {
            let trash = try XCTUnwrap(outcome.trashLocation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(try Data(contentsOf: trash), bytes)
            try FileManager.default.moveItem(at: trash, to: copy)
        } else {
            // Some simulator file providers do not support recoverable Trash.
            // A real failed outcome is asserted; it is not counted as moved.
            XCTAssertFalse(outcome.detail?.isEmpty ?? true)
        }
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: keep), bytes)
        model.scan()
        try await awaitModel(model)
        let rescanned = try await scannedGroup(model)
        XCTAssertEqual(rescanned.id, group.id)
        XCTAssertEqual(rescanned.duplicates.map(\.id), group.duplicates.map(\.id))
    }

    @MainActor
    func testCancellingSupplementRequiresManualRescanBeforeRestoringCleanup() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            let group = try await scannedGroup(model)
            let confirmed = await model.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
            XCTAssertTrue(confirmed)
            let pending = AssetID(source: group.id.source, item: "controlled-pending")
            model.startScan(downloads: [pending])
            model.cancelScan()
            try await awaitModel(model)
            XCTAssertTrue(model.resultsStale, "A cancelled supplement has not revalidated changed group membership")
            XCTAssertFalse(model.canClean)
            XCTAssertEqual(model.selectedCount, 1, "Saved decisions remain pending revalidation")
            try await waitForModelCondition { model.header?.settings.scanCancelledByUser == true }
        }
        let reopened = try await workspace.open()
        reopened.sceneChanged(.active)
        XCTAssertFalse(reopened.running, "User cancellation must not restart on relaunch")
        reopened.scan()
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 1)
        XCTAssertTrue(reopened.canClean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))
    }

    @MainActor
    func testLegacyCleanupHistoryIsLeftUntouchedOnV2Launch() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        // Even additional files in the explicitly supplied directory are not
        // opportunistically removed; no legacy history is opened or imported.
        try FileManager.default.createDirectory(at: workspace.data, withIntermediateDirectories: true)
        let names = ["cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"]
        for name in names { try Data("legacy history".utf8).write(to: workspace.data.appending(path: name)) }
        let model = try await workspace.open()
        for name in names {
            XCTAssertEqual(try Data(contentsOf: workspace.data.appending(path: name)), Data("legacy history".utf8))
        }
        XCTAssertNil(model.lastCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.data.appending(path: "scan.sqlite").path))
    }
}
