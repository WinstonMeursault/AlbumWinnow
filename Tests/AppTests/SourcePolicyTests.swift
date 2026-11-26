import AlbumWinnowApple
import XCTest
@testable import AlbumWinnowAcceptance

final class SourcePolicyTests: XCTestCase {
    @MainActor
    func testCrossScopePreferenceAndReadOnlyChangesPreserveManualChoices() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let a = try workspace.folder("A", files: ["a1.png", "a2.png"])
        let b = try workspace.folder("B", files: ["b1.png"])
        var scope = PhotoScope()
        scope.albums = ["missing": "Saved Album"]
        scope.dates = try CaptureRange(firstDay: Date(), lastDay: Date(), includesUnknown: true)
        let savedScope = scope
        let sides = try await workspace.withModel { model in
            model.addFolder(a)
            try await awaitModel(model)
            model.addFolder(b)
            try await awaitModel(model)
            let first = try XCTUnwrap(model.folders.first { $0.name == "A" }).id
            let second = try XCTUnwrap(model.folders.first { $0.name == "B" }).id
            let sides = ComparisonSides(first: first, second: second)
            model.setComparisonSides(sides)
            try await awaitModel(model)
            model.setPreferredSource(second)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            let group = try await scannedGroup(model)
            XCTAssertEqual(group.assets.count, 3)
            XCTAssertEqual(group.recommendation.id.source, second)
            let manualKeep = try XCTUnwrap(group.assets.first { $0.id.source == first })
            let confirmed = await model.confirmSelection(in: group, keepID: manualKeep.id, deleteAll: false)
            XCTAssertTrue(confirmed)
            XCTAssertEqual(model.selectedCount, 1)
            let previews = try await preparedPreviews(model)
            XCTAssertEqual(previews.first?.retained.count, 2)
            XCTAssertTrue(previews.allSatisfy { preview in
                guard preview.keep?.id == manualKeep.id else { return false }
                return preview.removing.allSatisfy { $0.id.source == second && $0.id != manualKeep.id }
            })
            model.setPreferredSource(first)
            try await awaitModel(model)
            model.scan()
            try await awaitModel(model)
            let updated = try await scannedGroup(model)
            XCTAssertEqual(model.selection(for: updated.id).keepID, manualKeep.id)
            XCTAssertEqual(model.selectedCount, 1)
            await model.setReadOnly(second, enabled: true)
            XCTAssertEqual(model.selectedCount, 0)
            XCTAssertEqual(model.selection(for: updated.id).keepID, manualKeep.id)
            await model.setReadOnly(second, enabled: false)
            XCTAssertEqual(model.selectedCount, 0, "Removing protection cannot silently reinstate cancelled removals")
            await model.setReadOnly(first, enabled: true)
            model.setPhotoScope(savedScope)
            try await awaitModel(model)
            return sides
        }
        let reopened = try await workspace.open()
        XCTAssertEqual(reopened.photoScope, savedScope)
        XCTAssertEqual(reopened.comparisonSides, sides)
        XCTAssertTrue(reopened.readOnlySources.contains(sides.first))
        await reopened.clearScanCache()
        XCTAssertTrue(reopened.readOnlySources.contains(sides.first))
        XCTAssertEqual(reopened.photoScope, savedScope)
    }
}
