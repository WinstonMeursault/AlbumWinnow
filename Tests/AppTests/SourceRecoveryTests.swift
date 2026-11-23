import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class SourceRecoveryTests: XCTestCase {
    @MainActor
    private func isolated(_ action: (URL) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan", "AlbumWinnow.skipCloud"]
        let previous = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.acceptanceDocumentsDirectory.appending(path: "TailAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        try await action(root)
    }

    @MainActor
    func testTemporarilyMissingFolderMustRetainBookmarkForNextLaunch() async throws {
        try await isolated { root in
            let folder = root.appending(path: "offline-folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scope = try FolderScope(url: folder)
            let bookmark = scope.bookmark
            UserDefaults.standard.set([bookmark], forKey: "AlbumWinnow.folderBookmarks")
            try FileManager.default.removeItem(at: folder)
            let model = ReviewModel(dataDirectory: root.appending(path: "state"))
            let saved = UserDefaults.standard.array(forKey: "AlbumWinnow.folderBookmarks") as? [Data] ?? []
            print("AUDIT_BOOKMARK missingFolderCount=\(model.folders.count) savedCount=\(saved.count) error=\(model.errorMessage ?? "none")")
            XCTAssertEqual(saved.count, 1, "Temporary unavailability must not erase the saved bookmark")
        }
    }

    @MainActor
    func testMalformedBookmarkIsNotSilentlyDiscarded() async throws {
        try await isolated { root in
            UserDefaults.standard.set([Data("corrupt bookmark".utf8)], forKey: "AlbumWinnow.folderBookmarks")
            let model = ReviewModel(dataDirectory: root.appending(path: "state"))
            XCTAssertNotNil(model.errorMessage)
            let saved = UserDefaults.standard.array(forKey: "AlbumWinnow.folderBookmarks") as? [Data] ?? []
            XCTAssertEqual(saved.count, 1, "Failed bookmarks need an explicit user removal path")
        }
    }

    @MainActor
    func testUnlockInheritedAliasAfterOriginalRemovedMustHaveAnEffectiveAction() async throws {
        try await isolated { root in
            let folder = root.appending(path: "photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png"))
            let a = folder.appending(path: "a.png"), b = folder.appending(path: "b.png")
            try bytes.write(to: a)
            try FileManager.default.linkItem(at: a, to: b)
            try bytes.write(to: folder.appending(path: "c.png"))
            let model = ReviewModel(dataDirectory: root.appending(path: "state"))
            model.addFolder(folder); model.scan()
            await waitForScan(model)
            let original = try XCTUnwrap(model.result?.groups.flatMap(\.assets).first { $0.name == "a.png" })
            model.setLocked(original, locked: true)
            let independent = try XCTUnwrap(model.result?.groups.flatMap(\.assets).first { $0.name == "c.png" })
            model.setLocked(independent, locked: true)
            try FileManager.default.removeItem(at: a)
            model.scan(); await waitForScan(model)
            let alias = try XCTUnwrap(model.result?.groups.flatMap(\.assets).first { $0.name == "b.png" })
            XCTAssertTrue(model.isLocked(alias))
            model.setLocked(alias, locked: false)
            print("AUDIT_ALIAS lockedAfterUnlock=\(model.isLocked(alias)) storedLocks=\(model.reviewState.locked)")
            XCTAssertTrue(model.isLocked(independent))
            XCTAssertEqual(model.selectedCount, 0)
            XCTAssertFalse(model.isLocked(alias), "The offered Unlock Photo action must work or explain the inherited protection")
        }
    }

    @MainActor
    func testMissingFolderRetryReconnectAndExplicitRemovalPreserveProtections() async throws {
        try await isolated { root in
            let folder = root.appending(path: "offline")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scope = try FolderScope(url: folder)
            UserDefaults.standard.set([scope.bookmark], forKey: "AlbumWinnow.folderBookmarks")
            let stateURL = root.appending(path: "state")
            let store = try ReviewStateStore(url: stateURL.appending(path: "review.sqlite"))
            var state = ReviewState()
            let lock = AssetID(source: scope.id, item: folder.appending(path: "locked.png").path)
            state.locked = [lock]; state.lockedRevisions = [lock: "1:2:3:4:5:6:7"]
            state.readOnlySources = [scope.id]; state.readOnlyRevisions = [lock: "1:2:3:4:5:6:7"]
            try store.save(state)
            try FileManager.default.removeItem(at: folder)
            let model = ReviewModel(dataDirectory: stateURL)
            XCTAssertEqual(model.unavailableFolders.count, 1)
            XCTAssertTrue(model.folders.isEmpty)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.retryFolders()
            XCTAssertEqual(model.folders.count, 1)
            XCTAssertTrue(model.unavailableFolders.isEmpty)
            let reopened = ReviewModel(dataDirectory: stateURL)
            XCTAssertEqual(reopened.folders.count, 1)
            reopened.removeFolder(scope.id)
            XCTAssertTrue(reopened.reviewState.locked.contains(lock))
            XCTAssertTrue(reopened.readOnlySources.contains(scope.id))
            UserDefaults.standard.set([Data("bad".utf8)], forKey: "AlbumWinnow.folderBookmarks")
            let corrupt = ReviewModel(dataDirectory: stateURL)
            let regularFile = root.appending(path: "not-a-folder")
            try Data([1]).write(to: regularFile)
            corrupt.reconnectFolder(try XCTUnwrap(corrupt.unavailableFolders.first), to: regularFile)
            XCTAssertEqual(corrupt.unavailableFolders.count, 1)
            XCTAssertTrue(corrupt.folders.isEmpty)
            XCTAssertNotNil(corrupt.sourceErrorMessage)
            corrupt.reconnectFolder(try XCTUnwrap(corrupt.unavailableFolders.first), to: folder)
            XCTAssertEqual(corrupt.folders.count, 1)
            UserDefaults.standard.set([Data("bad".utf8)], forKey: "AlbumWinnow.folderBookmarks")
            let removable = ReviewModel(dataDirectory: stateURL)
            removable.removeUnavailableFolder(try XCTUnwrap(removable.unavailableFolders.first))
            XCTAssertTrue(removable.unavailableFolders.isEmpty)
            XCTAssertTrue(removable.reviewState.locked.contains(lock))
            await removable.setReadOnly(scope.id, enabled: false)
            XCTAssertTrue(removable.reviewState.readOnlyRevisions?.isEmpty == true)
            XCTAssertTrue(removable.reviewState.locked.contains(lock))
        }
    }

    @MainActor
    func testExplicitRecordCleanupKeepsValidDecisionsAndIndependentLocks() async throws {
        try await isolated { root in
            let url = root.appending(path: "state")
            let store = try ReviewStateStore(url: url.appending(path: "review.sqlite"))
            let a = AssetID(source: "photos-library", item: "a"), b = AssetID(source: "photos-library", item: "b")
            var state = ReviewState()
            state.locked = [a, b]
            state.decisions["valid"] = ReviewDecision(status: .kept)
            var invalid = ReviewDecision(status: .confirmed)
            invalid.invalidated = true
            state.decisions["old"] = invalid
            try store.save(state)
            let model = ReviewModel(dataDirectory: url)
            XCTAssertEqual(model.invalidDecisionCount, 1)
            model.removeInvalidDecisions()
            XCTAssertEqual(model.reviewState.decisions.keys.sorted(), ["valid"])
            model.removeSavedLock(a)
            XCTAssertEqual(model.reviewState.locked, [b])
            XCTAssertEqual(model.selectedCount, 0)
        }
    }

    @MainActor
    func testRemovingSavedLockOutsideResultsCannotRestoreOldRemovalCandidates() async throws {
        try await isolated { root in
            let folder = root.appending(path: "photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png"))
            for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
            let source = FileSystemSource(directory: folder)
            let assets = try await source.snapshot().assets.sorted { $0.name < $1.name }
            let scan = try await ScanEngine(cacheURL: root.appending(path: "seed.sqlite")).scan([source])
            let group = try XCTUnwrap(scan.groups.first)
            var state = ReviewState()
            state.decisions[try group.reviewSignature()] = ReviewDecision(status: .confirmed, keepID: assets[0].id, removals: [assets[1].id], members: assets)
            state.locked = [assets[1].id]; state.lockedRevisions = [assets[1].id: assets[1].revision]
            let data = root.appending(path: "state")
            try ReviewStateStore(url: data.appending(path: "review.sqlite")).save(state)
            let model = ReviewModel(dataDirectory: data)
            model.addFolder(folder)
            model.removeSavedLock(assets[1].id)
            model.scan(); await waitForScan(model)
            XCTAssertEqual(model.selectedCount, 0, "Unlocking outside the current results must not revive protected stored removals")
            XCTAssertTrue(model.reviewState.decisions.values.allSatisfy { $0.removals.isEmpty })
        }
    }

    #if os(macOS)
    @MainActor
    func testNativeBackgroundKeepsFolderScanRunningWithoutCleanup() async throws {
        try await isolated { root in
            let folder = root.appending(path: "photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png"))
            for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
            let model = ReviewModel(dataDirectory: root.appending(path: "state"))
            model.addFolder(folder)
            model.sceneChanged(.active)
            model.scan()
            model.sceneChanged(.background)
            XCTAssertTrue(model.running)
            await waitForScan(model)
            XCTAssertEqual(model.result?.groups.count, 1)
            XCTAssertEqual(model.selectedCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))
        }
    }
    #endif

    @MainActor
    private func waitForScan(_ model: ReviewModel) async {
        for _ in 0..<1000 {
            if !model.running { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Audit scan timed out")
    }
}
