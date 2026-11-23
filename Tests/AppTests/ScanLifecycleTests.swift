import AlbumWinnowCore
import Foundation
import XCTest
@testable import AlbumWinnowAcceptance

final class ScanLifecycleTests: XCTestCase {
    private let dataDirectory = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    #if os(iOS)
    @MainActor
    func testRelaunchResumesFolderScanFromPersistedSelection() async throws {
        let defaults = UserDefaults.standard
        let folderKey = "AlbumWinnow.folderBookmarks"
        let scanKey = "AlbumWinnow.interruptedScan"
        let photoKey = "AlbumWinnow.photosEnabled"
        let savedFolders = defaults.object(forKey: folderKey)
        let savedScan = defaults.object(forKey: scanKey)
        let savedPhotos = defaults.object(forKey: photoKey)
        defer {
            defaults.set(savedFolders, forKey: folderKey)
            defaults.set(savedScan, forKey: scanKey)
            defaults.set(savedPhotos, forKey: photoKey)
        }
        defaults.removeObject(forKey: folderKey)
        defaults.removeObject(forKey: scanKey)
        defaults.set(false, forKey: photoKey)
        let base = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNIaFiAFTEMLQkAcvNgAZRk9dYAAAAASUVORK5CYII="))
        for i in 0..<48 { try png.write(to: base.appending(path: "sample-\(i).png")) }

        let initial = ReviewModel(dataDirectory: dataDirectory)
        initial.addFolder(base)
        XCTAssertTrue(initial.canScan)
        initial.sceneChanged(.active)
        initial.scan()
        XCTAssertTrue(defaults.bool(forKey: scanKey))
        initial.sceneChanged(.background)
        await waitUntil { !initial.running }
        XCTAssertNil(initial.result)
        XCTAssertTrue(defaults.bool(forKey: scanKey))

        let reopened = ReviewModel(dataDirectory: dataDirectory)
        XCTAssertEqual(reopened.folders.map(\.name), [base.lastPathComponent])
        reopened.sceneChanged(.active)
        await waitUntil { reopened.result != nil }
        XCTAssertEqual(reopened.result?.groups.first?.duplicates.count, 47)
        XCTAssertFalse(defaults.bool(forKey: scanKey))
    }

    #endif

    @MainActor
    func testLibraryChangeDoesNotCancelActiveScanButRequiresRescan() async throws {
        let defaults = UserDefaults.standard
        let folderKey = "AlbumWinnow.folderBookmarks"
        let photoKey = "AlbumWinnow.photosEnabled"
        let savedFolders = defaults.object(forKey: folderKey)
        let savedPhotos = defaults.object(forKey: photoKey)
        defaults.removeObject(forKey: folderKey)
        defaults.set(false, forKey: photoKey)
        let base = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            defaults.set(savedFolders, forKey: folderKey)
            defaults.set(savedPhotos, forKey: photoKey)
            try? FileManager.default.removeItem(at: base)
        }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNIaFiAFTEMLQkAcvNgAZRk9dYAAAAASUVORK5CYII="))
        for i in 0..<48 { try png.write(to: base.appending(path: "sample-\(i).png")) }
        let model = ReviewModel(dataDirectory: dataDirectory)
        model.addFolder(base)
        model.scan()
        model.libraryDidChange()
        await waitUntil { !model.running }
        XCTAssertEqual(model.result?.scanned, 48)
        XCTAssertTrue(model.resultsStale)
        XCTAssertFalse(model.canClean)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertEqual(model.result?.reused, 48)
        XCTAssertFalse(model.resultsStale)
        XCTAssertTrue(model.canClean)
        model.libraryDidChange()
        XCTAssertNil(model.result)
        XCTAssertFalse(model.canClean)
    }

    #if os(iOS)
    @MainActor
    func testBackgroundPreservesDownloadConsentAndUserCancellationClearsIt() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled",
                    "AlbumWinnow.interruptedScan", "AlbumWinnow.interruptedDownloads"]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        let base = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: base)
        }
        let model = ReviewModel(dataDirectory: dataDirectory)
        model.addFolder(base)
        model.sceneChanged(.active)
        // Exercise saved consent without requiring a Photos account or making network requests.
        model.startScan(downloads: [AssetID(source: "photos-library", item: "pending-cloud")])
        model.sceneChanged(.background)
        await waitUntil { !model.running }
        XCTAssertTrue(defaults.bool(forKey: "AlbumWinnow.interruptedScan"))
        XCTAssertEqual(defaults.stringArray(forKey: "AlbumWinnow.interruptedDownloads"), ["pending-cloud"])
        model.cancelScan()
        XCTAssertNil(defaults.object(forKey: "AlbumWinnow.interruptedDownloads"))
        XCTAssertFalse(defaults.bool(forKey: "AlbumWinnow.interruptedScan"))
        model.sceneChanged(.active)
        XCTAssertFalse(model.running)
    }

    #endif

    @MainActor
    func testRetryAndCancellationPreserveStaleResultsUntilSuccessfulScan() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled",
                    "AlbumWinnow.interruptedScan", "AlbumWinnow.interruptedDownloads"]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        let folder = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures")
        let bytes = try Data(contentsOf: fixtures.appending(path: "burst-a.png"))
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: dataDirectory)
        model.addFolder(folder)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertTrue(model.canClean)
        let downloads: Set<AssetID> = [AssetID(source: "photos-library", item: "pending")]
        model.startScan(downloads: downloads)
        model.libraryDidChange()
        model.cancelScan()
        await waitUntil { !model.running }
        XCTAssertTrue(model.resultsStale)
        model.startScan(downloads: downloads)
        model.cancelScan()
        await waitUntil { !model.running }
        XCTAssertTrue(model.resultsStale)
        XCTAssertFalse(model.canClean)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertFalse(model.resultsStale)
        XCTAssertTrue(model.canClean)
    }

    @MainActor
    func testClearingCachePreservesFolderAccessAndPhotos() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled",
                    "AlbumWinnow.interruptedScan", "AlbumWinnow.interruptedDownloads"]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        let folder = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let bytes = try Data(contentsOf: fixture)
        let photo = folder.appending(path: "photo.png")
        try bytes.write(to: photo)
        let model = ReviewModel(dataDirectory: dataDirectory)
        model.addFolder(folder)
        model.scan()
        await waitUntil { !model.running }
        let bookmarks = defaults.array(forKey: "AlbumWinnow.folderBookmarks") as? [Data]
        await model.clearScanCache()
        XCTAssertFalse(model.clearingCache)
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.cacheStatus)
        XCTAssertTrue(model.canScan)
        XCTAssertEqual(defaults.array(forKey: "AlbumWinnow.folderBookmarks") as? [Data], bookmarks)
        XCTAssertEqual(try Data(contentsOf: photo), bytes)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertEqual(model.result?.scanned, 1)
        XCTAssertEqual(model.result?.reused, 0)
    }

    @MainActor
    func testFolderCleanupIsRecoverableOrLeavesBothOriginals() async throws {
        let base = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNIaFiAFTEMLQkAcvNgAZRk9dYAAAAASUVORK5CYII="))
        let folder = base.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = folder.appending(path: "a-keep.png")
        let copy = folder.appending(path: "b-copy.png")
        try png.write(to: keep)
        try png.write(to: copy)
        let source = FileSystemSource(directory: folder)
        let engine = try ScanEngine(cacheURL: base.appending(path: "scan.sqlite"))
        let scan = try await engine.scan([source])
        let group = try XCTUnwrap(scan.groups.first)
        XCTAssertEqual(group.preferred.name, "a-keep.png")
        let service = AssetMutationService()
        let pair = CleanupPair(keep: group.preferred, remove: try XCTUnwrap(group.duplicates.first).asset)
        let run = try await service.apply([pair], sources: [source], protection: CleanupProtection())
        if run.first?.status == .movedToTrash {
            let path = try XCTUnwrap(run.first?.detail)
            let trash = URL(fileURLWithPath: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(try Data(contentsOf: trash), png)
            try FileManager.default.moveItem(at: trash, to: copy)
        } else {
            XCTAssertEqual(run.first?.status, .failed)
            // Some simulator file providers do not support Trash. Failure must preserve both files.
            XCTAssertFalse(run.first?.detail?.isEmpty ?? true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertEqual(try Data(contentsOf: copy), png)
        XCTAssertEqual(try Data(contentsOf: keep), png)
        let rescan = try await engine.scan([source])
        XCTAssertEqual(rescan.groups.map(\.id), scan.groups.map(\.id))
        XCTAssertEqual(rescan.groups.flatMap(\.duplicates).map(\.id), scan.groups.flatMap(\.duplicates).map(\.id))
    }

    @MainActor
    func testCancellingSupplementRequiresManualRescanBeforeRestoringCleanup() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan",
                    "AlbumWinnow.interruptedDownloads", "AlbumWinnow.interruptedCloudPolicy"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let folder = dataDirectory.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let bytes = try Data(contentsOf: fixture)
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: dataDirectory)
        model.addFolder(folder)
        model.scan()
        await waitUntil { !model.running }
        let group = try XCTUnwrap(model.result?.groups.first)
        let confirmed = await model.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        // Synthetic consent IDs exercise cancellation without a Photos account or network request.
        model.startScan(downloads: [AssetID(source: "photos-library", item: "synthetic-pending")])
        model.cancelScan()
        await waitUntil { !model.running }
        XCTAssertTrue(model.resultsStale, "A cancelled supplement has not revalidated changed group membership")
        XCTAssertFalse(model.canClean)
        XCTAssertEqual(model.selectedCount, 1, "Saved decisions remain pending revalidation")
        let reopened = ReviewModel(dataDirectory: dataDirectory)
        reopened.sceneChanged(.active)
        XCTAssertFalse(reopened.running, "A user cancellation must not restart on relaunch")
        reopened.scan()
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.selectedCount, 1)
        XCTAssertTrue(reopened.canClean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))
    }

    @MainActor
    private func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<300 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for scan state")
    }
    @MainActor
    func testLegacyCleanupHistoryIsRemovedOnLaunch() throws {
        let folder = dataDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacyFiles = ["cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"].map {
            folder.appending(path: $0)
        }
        for url in legacyFiles { try Data("legacy history".utf8).write(to: url) }
        let model = ReviewModel(dataDirectory: dataDirectory)
        for url in legacyFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertNil(model.lastCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "scan.sqlite").path))
    }

}
