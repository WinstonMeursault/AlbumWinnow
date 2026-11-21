import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class ReviewPersistenceTests: XCTestCase {
    @MainActor
    func testDecisionsRestoreOnlyAfterScanAndLocksSurviveResetAndCacheClear() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan"]
        let previous = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "photos")
        let state = root.appending(path: "state")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures")
        let bytes = try Data(contentsOf: fixtures.appending(path: "burst-a.png"))
        for name in ["a.png", "b.png", "c.png"] { try bytes.write(to: folder.appending(path: name)) }
        let initial = ReviewModel(dataDirectory: state)
        initial.addFolder(folder)
        initial.scan()
        await waitUntil { !initial.running }
        let group = try XCTUnwrap(initial.result?.groups.first)
        let confirmed = await initial.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(initial.selectedCount, 2)
        initial.setStatus(.deferred, for: group)
        XCTAssertEqual(initial.selectedCount, 2, "Skip must not cancel a confirmed plan")
        initial.rememberPosition(group)

        let reopened = ReviewModel(dataDirectory: state)
        XCTAssertFalse(reopened.canClean)
        XCTAssertEqual(reopened.selectedCount, 0)
        reopened.sceneChanged(.active)
        await waitUntil { !reopened.running }
        let restored = try XCTUnwrap(reopened.result?.groups.first)
        XCTAssertEqual(reopened.selectedCount, 2)
        XCTAssertEqual(reopened.status(for: restored), .deferred)
        XCTAssertEqual(reopened.resumeGroup?.id, restored.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))

        let locked = restored.duplicates[0].asset
        reopened.setLocked(locked, locked: true)
        XCTAssertEqual(reopened.selectedCount, 1)
        let reason = await reopened.deleteAllUnavailableReason(for: [restored.preferred] + restored.duplicates.map(\.asset))
        XCTAssertNotNil(reason)
        let other = try XCTUnwrap(restored.duplicates.first { $0.id != locked.id }?.asset)
        reopened.setLocked(other, locked: true)
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertEqual(reopened.selection(for: restored.id).keepID, restored.preferred.id,
                       "Locking every removal must preserve the confirmed manual keep choice")
        reopened.setLocked(other, locked: false)
        XCTAssertEqual(reopened.selectedCount, 0, "Unlocking does not add a deletion plan")
        reopened.resetReviewProgress()
        XCTAssertEqual(reopened.selectedCount, 0)
        XCTAssertTrue(reopened.isLocked(locked))
        await reopened.clearScanCache()
        reopened.scan()
        await waitUntil { !reopened.running }
        XCTAssertTrue(reopened.isLocked(locked))
        let changed = try XCTUnwrap(reopened.result?.groups.first)
        let confirmedAgain = await reopened.confirmSelection(in: changed, keepID: changed.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmedAgain)
        try bytes.write(to: folder.appending(path: "d.png"))
        reopened.scan()
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.selectedCount, 0, "New members invalidate old deletion decisions")
        XCTAssertNotNil(reopened.reviewNotice)
        XCTAssertTrue(reopened.isLocked(locked))
        try FileManager.default.removeItem(at: folder.appending(path: "d.png"))
        reopened.scan()
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.selectedCount, 0, "Returning to old membership must not revive an invalidated plan")
    }

    @MainActor
    func testCorruptProtectionStoreDisablesCleanup() throws {
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("corrupt".utf8).write(to: root.appending(path: "review.sqlite"))
        let model = ReviewModel(dataDirectory: root)
        XCTAssertFalse(model.protectionAvailable)
        XCTAssertFalse(model.canClean)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Review scan did not finish")
    }
}
