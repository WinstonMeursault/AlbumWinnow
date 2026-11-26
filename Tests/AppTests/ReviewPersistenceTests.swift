import AlbumWinnowApple
import AlbumWinnowRust
import SQLite3
import XCTest
@testable import AlbumWinnowAcceptance

final class ReviewPersistenceTests: XCTestCase {
    @MainActor
    func testDecisionsRestoreOnlyAfterScanAndLocksSurviveResetAndCacheClear() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["a.png", "b.png", "c.png"])
        try await workspace.withModel { initial in
            initial.addFolder(folder)
            try await awaitModel(initial)
            initial.scan()
            try await awaitModel(initial)
            let group = try await scannedGroup(initial)
            let confirmed = await initial.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
            XCTAssertTrue(confirmed)
            XCTAssertEqual(initial.selectedCount, 2)
            let deferred = await initial.setStatus(.deferred, for: group)
            XCTAssertTrue(deferred)
            XCTAssertEqual(initial.selectedCount, 2, "Skip must not cancel a confirmed plan")
            await initial.rememberPosition(try XCTUnwrap(initial.visibleGroups.first))?.value
        }

        let reopened = try await workspace.open()
        XCTAssertFalse(reopened.canClean)
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertNil(reopened.result, "Relaunch restores v2 configuration but does not automatically scan")
        reopened.scan()
        try await awaitModel(reopened)
        let restored = try await scannedGroup(reopened)
        XCTAssertEqual(reopened.selectedCount, 2)
        XCTAssertEqual(reopened.status(for: restored), .deferred)
        XCTAssertEqual(reopened.resumeGroup?.id, restored.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))
        let locked = restored.duplicates[0].asset
        reopened.setLocked(locked, locked: true)
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 1)
        let reason = await reopened.deleteAllUnavailableReason(for: restored.assets)
        XCTAssertNotNil(reason)
        let other = try XCTUnwrap(restored.duplicates.first { $0.id != locked.id }?.asset)
        reopened.setLocked(other, locked: true)
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertEqual(reopened.selection(for: restored.id).keepID, restored.preferred.id,
                       "Locking every removal must preserve the confirmed manual keep choice")
        reopened.setLocked(other, locked: false)
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 0, "Unlocking does not add a deletion plan")
        reopened.resetReviewProgress()
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertTrue(reopened.isLocked(locked))
        await reopened.clearScanCache()
        reopened.scan()
        try await awaitModel(reopened)
        let changed = try await scannedGroup(reopened)
        XCTAssertTrue(reopened.isLocked(locked))
        let confirmedAgain = await reopened.confirmSelection(in: changed, keepID: changed.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmedAgain)
        let bytes = try Data(contentsOf: folder.appending(path: "a.png"))
        try bytes.write(to: folder.appending(path: "d.png"))
        reopened.scan()
        try await awaitModel(reopened)
        _ = try await scannedGroup(reopened)
        XCTAssertEqual(reopened.selectedCount, 0, "New members invalidate old deletion decisions")
        XCTAssertNotNil(reopened.reviewNotice)
        let staleConfirmed = await reopened.confirmSelection(in: changed, keepID: changed.preferred.id, deleteAll: false)
        XCTAssertFalse(staleConfirmed, "A stale review view must not confirm a changed group")
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertTrue(reopened.isLocked(locked))
        try FileManager.default.removeItem(at: folder.appending(path: "d.png"))
        reopened.scan()
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.selectedCount, 0, "Returning to old membership must not revive an invalidated plan")
    }

    @MainActor
    func testFailedDecisionCommitDoesNotPublishSelectionOrEnableCleanup() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            XCTAssertEqual(model.selectedCount, 0)
        }
        // Install a controlled fault only while the owner is closed. Outside
        // writes to a live owner would test ownership rejection, not WriteFailed.
        func rejectDecisionWrites() throws {
            var database: OpaquePointer?
            let path = workspace.data.appending(path: "review.sqlite").path
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                throw CocoaError(.fileReadUnknown)
            }
            defer { sqlite3_close(database) }
            let sql = "CREATE TRIGGER reject_decision BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT,'controlled v2 decision write failure'); END;"
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        try rejectDecisionWrites()
        let expected = try await workspace.withModel { model in
            model.scan()
            try await awaitModel(model)
            let group = try await scannedGroup(model)
            let before = try XCTUnwrap(model.header?.metadata)
            let accepted = await model.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
            XCTAssertFalse(accepted)
            XCTAssertFalse(model.protectionAvailable)
            XCTAssertFalse(model.canClean)
            XCTAssertEqual(model.selectedCount, 0)
            XCTAssertNil(model.selection(for: group.id).keepID)
            XCTAssertNil(model.cleanupPlan)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.header?.metadata, before)
            return before
        }
        let stored = try RustReviewSession(databasePath: workspace.data.appending(path: "review.sqlite").path, initialized: true)
        XCTAssertEqual(try stored.header().metadata, expected, "The failed transaction must not alter persisted revision or decisions")
        XCTAssertEqual(try stored.header().metadata.decisionCount, 0)
        for name in ["a.png", "b.png"] { XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: name).path)) }
    }

    @MainActor
    func testCorruptProtectionStoreDisablesCleanup() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        try FileManager.default.createDirectory(at: workspace.data, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: workspace.data.appending(path: "review.sqlite"))
        let model = ReviewModel(dataDirectory: workspace.data, preferencesSuite: workspace.suite)
        await model.bootstrap()
        XCTAssertFalse(model.protectionAvailable)
        XCTAssertFalse(model.canClean)
        XCTAssertNotNil(model.errorMessage)
    }
}
