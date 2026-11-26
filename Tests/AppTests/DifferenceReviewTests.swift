import AlbumWinnowApple
import XCTest
@testable import AlbumWinnowAcceptance

final class DifferenceReviewTests: XCTestCase {
    @MainActor
    func testDifferenceReadPreservesConfirmedPlanAndRejectsChangedResources() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: ["detail-a.png"], fixture: "detail-a.png")
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures")
        try Data(contentsOf: fixtures.appending(path: "detail-b.png")).write(to: folder.appending(path: "detail-b.png"))
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        model.scan()
        try await awaitModel(model)
        let group = try await scannedGroup(model)
        let reference = group.preferred
        let comparison = try XCTUnwrap(group.duplicates.first?.asset)
        let confirmed = await model.confirmSelection(in: group, keepID: reference.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        model.setLocked(reference, locked: true)
        try await awaitModel(model)
        let before = try await preparedPreviews(model)
        XCTAssertEqual(before.flatMap(\.removing).count, 1)
        let savedHeader = model.header
        let savedDecision = try XCTUnwrap(model.details[group.id]).core.decision
        let difference = try await model.difference(reference: reference, comparison: comparison)
        let after = try await preparedPreviews(model)
        XCTAssertEqual(after.flatMap(\.removing), before.flatMap(\.removing))
        XCTAssertEqual(model.selection(for: group.id).keepID, reference.id)
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.header, savedHeader)
        XCTAssertEqual(model.details[group.id]?.core.decision, savedDecision)
        XCTAssertLessThanOrEqual(max(difference.reference.width, difference.reference.height), 512)
        try Data("changed".utf8).write(to: folder.appending(path: comparison.name))
        do {
            _ = try await model.difference(reference: reference, comparison: comparison)
            XCTFail("Difference evidence must not survive an underlying resource replacement")
        } catch AssetAccessError.changedDuringScan {}
        XCTAssertFalse(model.canClean)
        XCTAssertTrue(model.resultsStale)
        XCTAssertEqual(model.header, savedHeader, "A changed resource blocks cleanup without rewriting saved decisions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: reference.name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: comparison.name).path))
    }
}
