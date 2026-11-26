import AlbumWinnowApple
import AlbumWinnowRust
import XCTest
@testable import AlbumWinnowAcceptance

final class ResultQueryTests: XCTestCase {
    @MainActor
    func testFiltersPersistWithoutDroppingHiddenManualCandidates() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder()
        let saved = try await workspace.withModel { model in
            model.addFolder(folder)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            let group = try await scannedGroup(model)
            model.downloadAndRescan(group.preferred)
            XCTAssertFalse(model.running, "A folder item cannot authorize a Photos download")
            let manualKeep = try XCTUnwrap(group.duplicates.first?.id)
            let confirmed = await model.confirmSelection(in: group, keepID: manualKeep, deleteAll: false)
            XCTAssertTrue(confirmed)
            var query = model.resultQuery
            query.status = .kept
            query.sort = .bytes
            model.setResultQuery(query)
            try await awaitModel(model)
            XCTAssertTrue(model.visibleGroups.isEmpty)
            XCTAssertEqual(model.hiddenCandidateCount, 1)
            let previews = try await preparedPreviews(model)
            XCTAssertEqual(previews.flatMap(\.removing).count, 1)
            XCTAssertEqual(model.selection(for: group.id).keepID, manualKeep)
            return (query, manualKeep)
        }
        let reopened = try await workspace.open()
        XCTAssertEqual(reopened.resultQuery, saved.0)
        XCTAssertFalse(reopened.canClean)
        reopened.scan()
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.hiddenCandidateCount, 1)
        let restored = try await preparedPreviews(reopened)
        XCTAssertEqual(restored.first?.keep?.id, saved.1)
        await reopened.clearScanCache()
        reopened.scan()
        try await awaitModel(reopened)
        XCTAssertEqual(reopened.resultQuery, saved.0)
        XCTAssertEqual(reopened.selectedCount, 1)
        reopened.clearResultFilters()
        try await awaitModel(reopened)
        let group = try await scannedGroup(reopened)
        XCTAssertEqual(reopened.selection(for: group.id).keepID, saved.1)
        XCTAssertEqual(reopened.visibleGroups.count, 1)
        XCTAssertEqual(reopened.hiddenCandidateCount, 0)
    }
}
