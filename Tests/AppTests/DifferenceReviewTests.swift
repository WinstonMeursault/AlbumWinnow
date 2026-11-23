import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class DifferenceReviewTests: XCTestCase {
    @MainActor
    func testDifferenceReadPreservesConfirmedPlanAndRejectsChangedResources() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.acceptanceDocumentsDirectory.appending(path: "DifferenceReview-\(UUID())")
        let folder = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures")
        for name in ["detail-a.png", "detail-b.png"] {
            try Data(contentsOf: fixtures.appending(path: name)).write(to: folder.appending(path: name))
        }
        let model = ReviewModel(dataDirectory: root.appending(path: "state"))
        model.addFolder(folder)
        model.scan()
        for _ in 0..<1000 where model.running { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.running)
        let group = try XCTUnwrap(model.result?.groups.first)
        let reference = group.preferred
        let comparison = try XCTUnwrap(group.duplicates.first?.asset)
        let confirmed = await model.confirmSelection(in: group, keepID: reference.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        model.setLocked(reference, locked: true)
        let plan = model.cleanupGroups.flatMap(\.pairs)
        XCTAssertEqual(plan.count, 1)
        let store = try ReviewStateStore(url: root.appending(path: "state/review.sqlite"))
        let savedState = try store.load()
        let difference = try await model.difference(reference: reference, comparison: comparison)
        XCTAssertEqual(model.cleanupGroups.flatMap(\.pairs), plan)
        XCTAssertEqual(model.selection(for: group.id).keepID, reference.id)
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(try store.load(), savedState)
        XCTAssertLessThanOrEqual(max(difference.reference.width, difference.reference.height), 512)
        try Data("changed".utf8).write(to: folder.appending(path: comparison.name))
        do {
            _ = try await model.difference(reference: reference, comparison: comparison)
            XCTFail("Difference evidence must not survive an underlying resource replacement")
        } catch AssetAccessError.changedDuringScan {}
        XCTAssertFalse(model.canClean)
        XCTAssertTrue(model.resultsStale)
        XCTAssertEqual(try store.load(), savedState, "A changed resource blocks cleanup while saved decisions await revalidation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: reference.name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: comparison.name).path))
    }
}
