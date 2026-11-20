import AlbumWinnowCore
import Foundation
import XCTest
@testable import AlbumWinnowAcceptance

final class ScanLifecycleTests: XCTestCase {
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
        let base = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNIaFiAFTEMLQkAcvNgAZRk9dYAAAAASUVORK5CYII="))
        for i in 0..<48 { try png.write(to: base.appending(path: "sample-\(i).png")) }

        let initial = ReviewModel()
        initial.addFolder(base)
        XCTAssertTrue(initial.canScan)
        initial.sceneChanged(.active)
        initial.scan()
        XCTAssertTrue(defaults.bool(forKey: scanKey))
        initial.sceneChanged(.background)
        await waitUntil { !initial.running }
        XCTAssertNil(initial.result)
        XCTAssertTrue(defaults.bool(forKey: scanKey))

        let reopened = ReviewModel()
        XCTAssertEqual(reopened.folders.map(\.name), [base.lastPathComponent])
        reopened.sceneChanged(.active)
        await waitUntil { reopened.result != nil }
        XCTAssertEqual(reopened.result?.groups.first?.duplicates.count, 47)
        XCTAssertFalse(defaults.bool(forKey: scanKey))
    }

    @MainActor
    func testLibraryChangeDoesNotCancelActiveScanButRequiresRescan() async throws {
        let defaults = UserDefaults.standard
        let folderKey = "AlbumWinnow.folderBookmarks"
        let photoKey = "AlbumWinnow.photosEnabled"
        let savedFolders = defaults.object(forKey: folderKey)
        let savedPhotos = defaults.object(forKey: photoKey)
        defaults.removeObject(forKey: folderKey)
        defaults.set(false, forKey: photoKey)
        let base = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            defaults.set(savedFolders, forKey: folderKey)
            defaults.set(savedPhotos, forKey: photoKey)
            try? FileManager.default.removeItem(at: base)
        }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNIaFiAFTEMLQkAcvNgAZRk9dYAAAAASUVORK5CYII="))
        for i in 0..<48 { try png.write(to: base.appending(path: "sample-\(i).png")) }
        let model = ReviewModel()
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

    @MainActor
    func testBackgroundPreservesDownloadConsentAndUserCancellationClearsIt() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled",
                    "AlbumWinnow.interruptedScan", "AlbumWinnow.interruptedDownloads"]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        let base = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: base)
        }
        let model = ReviewModel()
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

    @MainActor
    func testFolderCleanupIsRecoverableOrLeavesBothOriginals() async throws {
        let base = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
        let run = try await service.apply([pair], sources: [source])
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
    private func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<300 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for scan state")
    }
    @MainActor
    func testLegacyCleanupHistoryIsRemovedOnLaunch() throws {
        let folder = URL.applicationSupportDirectory.appending(path: "AlbumWinnow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacyFiles = ["cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"].map {
            folder.appending(path: $0)
        }
        for url in legacyFiles { try Data("legacy history".utf8).write(to: url) }
        let model = ReviewModel()
        for url in legacyFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertNil(model.lastCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "scan.sqlite").path))
    }

}
