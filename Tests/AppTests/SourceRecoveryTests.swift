import AlbumWinnowApple
import AlbumWinnowRust
import CoreImage
import XCTest
@testable import AlbumWinnowAcceptance

final class SourceRecoveryTests: XCTestCase {
    @MainActor
    func testTemporarilyMissingFolderMustRetainBookmarkForNextLaunch() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let record = try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            return try XCTUnwrap(model.registeredSources.first)
        }
        try FileManager.default.removeItem(at: folder)
        let model = try await workspace.open()
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertEqual(model.unavailableFolders, [record.id])
        XCTAssertEqual(model.registeredSources.first?.bookmark, record.bookmark,
                       "Temporary unavailability must not erase the saved bookmark")
    }

    @MainActor
    func testMalformedBookmarkIsNotSilentlyDiscarded() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let record = try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            return try XCTUnwrap(model.registeredSources.first)
        }
        let bad = Data("corrupt v2 bookmark".utf8)
        // Controlled test-only source command; the production owner never imports
        // legacy records or rewrites its own database behind the session's back.
        func changeBookmark() throws {
            let core = try RustReviewSession(databasePath: workspace.data.appending(path: "review.sqlite").path, initialized: true)
            _ = try core.registerSource(expectedRevision: core.header().metadata.revision,
                input: CoreSourceInput(kind: record.kind, namespace: record.nativeNamespace,
                    identity: record.nativeIdentity, bookmark: bad, label: record.label))
        }
        try changeBookmark()
        let model = try await workspace.open()
        XCTAssertEqual(model.unavailableFolders, [record.id])
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertEqual(model.registeredSources.first?.bookmark, bad,
                       "Failed bookmarks need an explicit user removal path")
        XCTAssertNotNil(model.errorMessage, "Unavailable saved authorization must be reported at startup")
    }

    @MainActor
    func testUnlockInheritedAliasAfterOriginalRemovedMustHaveAnEffectiveAction() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["a.png", "c.png"])
        let a = folder.appending(path: "a.png"), b = folder.appending(path: "b.png")
        try FileManager.default.linkItem(at: a, to: b)
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let group = try await scannedGroup(model)
        let original = try XCTUnwrap(group.assets.first { $0.name == "a.png" })
        let independent = try XCTUnwrap(group.assets.first { $0.name == "c.png" })
        model.setLocked(original, locked: true)
        try await awaitModel(model)
        model.setLocked(independent, locked: true)
        try await awaitModel(model)
        try FileManager.default.removeItem(at: a)
        model.scan()
        try await awaitModel(model)
        let changed = try await scannedGroup(model)
        let alias = try XCTUnwrap(changed.assets.first { $0.name == "b.png" })
        XCTAssertTrue(model.isLocked(alias))
        let owners = await model.lockOwners(for: alias)
        XCTAssertEqual(owners, [original.id])
        model.setLocked(alias, locked: false)
        try await awaitModel(model)
        XCTAssertTrue(model.isLocked(independent))
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertFalse(model.isLocked(alias), "The offered Unlock Photo action must remove inherited alias locks")
        XCTAssertFalse(model.savedLocks.contains(original.id))
        XCTAssertTrue(model.savedLocks.contains(independent.id))
    }

    @MainActor
    func testMissingFolderRetryReconnectAndExplicitRemovalPreserveProtections() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder("offline")
        let saved = try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            let group = try await scannedGroup(model)
            model.setLocked(group.preferred, locked: true)
            try await awaitModel(model)
            await model.setReadOnly(group.id.source, enabled: true)
            return (group.id.source, group.preferred.id)
        }
        try FileManager.default.removeItem(at: folder)
        let model = try await workspace.open()
        XCTAssertEqual(model.unavailableFolders, [saved.0])
        XCTAssertTrue(model.folders.isEmpty)
        model.retryFolders()
        try await awaitModel(model)
        XCTAssertEqual(model.unavailableFolders, [saved.0])
        XCTAssertNotNil(model.sourceErrorMessage, "A failed explicit retry must report the unavailable saved source")
        XCTAssertTrue(model.savedLocks.contains(saved.1))
        XCTAssertTrue(model.readOnlySources.contains(saved.0))
        let regular = workspace.root.appending(path: "not-a-folder")
        try Data([1]).write(to: regular)
        model.reconnectFolder(saved.0, to: regular)
        try await awaitModel(model)
        XCTAssertEqual(model.unavailableFolders, [saved.0])
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        let replacement = try workspace.folder("replacement")
        model.reconnectFolder(saved.0, to: replacement)
        try await awaitModel(model)
        let replacementID = try XCTUnwrap(model.folders.first).id
        XCTAssertNotEqual(replacementID, saved.0, "A new native root cannot take over protected source identity")
        XCTAssertTrue(model.unavailableFolders.isEmpty)
        XCTAssertTrue(model.savedLocks.contains(saved.1))
        XCTAssertTrue(model.readOnlySources.contains(saved.0))
        try FileManager.default.removeItem(at: replacement)
        model.retryFolders()
        try await awaitModel(model)
        XCTAssertEqual(model.unavailableFolders, [replacementID])
        model.removeUnavailableFolder(replacementID)
        try await awaitModel(model)
        XCTAssertTrue(model.unavailableFolders.isEmpty)
        XCTAssertTrue(model.savedLocks.contains(saved.1))
        await model.setReadOnly(saved.0, enabled: false)
        XCTAssertFalse(model.readOnlySources.contains(saved.0))
        XCTAssertTrue(model.savedLocks.contains(saved.1))
    }

    @MainActor
    func testExplicitRecordCleanupKeepsValidDecisionsAndIndependentLocks() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["a.png", "b.png"])
        let other = try workspace.folder("other", files: [])
        // Use unrelated pixels: scene.png is intentionally similar to burst-a.
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let bytes = try XCTUnwrap(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        for name in ["c.png", "d.png"] { try bytes.write(to: other.appending(path: name)) }
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.addFolder(other)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        XCTAssertEqual(model.totalGroupCount, 2)
        let firstSummary = try XCTUnwrap(model.visibleGroups.first { $0.preferred.name == "a.png" })
        let otherSummary = try XCTUnwrap(model.visibleGroups.first { $0.preferred.name == "c.png" })
        await model.loadDetails(for: [firstSummary, otherSummary])
        let first = try XCTUnwrap(model.details[firstSummary.id])
        let second = try XCTUnwrap(model.details[otherSummary.id])
        let kept = await model.setStatus(.kept, for: first)
        XCTAssertTrue(kept)
        let confirmed = await model.confirmSelection(in: second, keepID: second.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        model.setLocked(first.preferred, locked: true)
        try await awaitModel(model)
        model.setLocked(second.preferred, locked: true)
        try await awaitModel(model)
        try Data(contentsOf: other.appending(path: "c.png")).write(to: other.appending(path: "e.png"))
        model.scan()
        try await awaitModel(model)
        XCTAssertEqual(model.invalidDecisionCount, 1)
        model.removeInvalidDecisions()
        try await awaitModel(model)
        XCTAssertEqual(model.invalidDecisionCount, 0)
        XCTAssertEqual(model.header?.metadata.decisionCount, 1)
        model.removeSavedLock(first.preferred.id)
        try await awaitModel(model)
        XCTAssertEqual(model.savedLocks, [second.preferred.id])
        XCTAssertEqual(model.selectedCount, 0)
        var query = model.resultQuery
        query.status = .all
        model.setResultQuery(query)
        try await awaitModel(model)
        XCTAssertEqual(model.visibleGroups.first { $0.id == first.id }?.core.status, .kept)
    }

    @MainActor
    func testRemovingSavedLockOutsideResultsCannotRestoreOldRemovalCandidates() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let group = try await scannedGroup(model)
        let removable = try XCTUnwrap(group.duplicates.first?.asset)
        let confirmed = await model.confirmSelection(in: group, keepID: group.preferred.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        model.setLocked(removable, locked: true)
        try await awaitModel(model)
        XCTAssertEqual(model.selectedCount, 0)
        await model.clearScanCache()
        XCTAssertNil(model.result)
        model.removeSavedLock(removable.id)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let restored = try await scannedGroup(model)
        XCTAssertEqual(model.selectedCount, 0, "Unlocking outside current results must not revive protected stored removals")
        XCTAssertTrue(restored.core.decision?.removals.isEmpty == true)
    }

    #if os(macOS)
    @MainActor
    func testNativeBackgroundKeepsFolderScanRunningWithoutCleanup() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.sceneChanged(.active)
        model.scan()
        model.sceneChanged(.background)
        XCTAssertTrue(model.running)
        try await awaitModel(model)
        XCTAssertEqual(model.totalGroupCount, 1)
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "b.png").path))
    }
    #endif
}
