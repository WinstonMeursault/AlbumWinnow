import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class ResultQueryTests: XCTestCase {
    @MainActor
    func testFiltersPersistWithoutDroppingHiddenManualCandidates() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "photos"), data = root.appending(path: "state")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let bytes = try Data(contentsOf: fixture)
        for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: data)
        model.addFolder(folder)
        model.scan()
        await waitUntil { !model.running }
        let group = try XCTUnwrap(model.result?.groups.first)
        model.downloadAndRescan(group.preferred)
        XCTAssertFalse(model.running, "A folder item cannot authorize a Photos download")
        let manualKeep = try XCTUnwrap(group.duplicates.first?.id)
        let confirmed = await model.confirmSelection(in: group, keepID: manualKeep, deleteAll: false)
        XCTAssertTrue(confirmed)
        var query = ReviewResultQuery()
        query.status = .kept
        query.sort = .bytes
        model.setResultQuery(query)
        XCTAssertTrue(model.visibleGroups.isEmpty)
        XCTAssertEqual(model.hiddenCandidateCount, 1)
        XCTAssertEqual(model.cleanupGroups.flatMap(\.pairs).count, 1)
        XCTAssertEqual(model.selection(for: group.id).keepID, manualKeep)

        let reopened = ReviewModel(dataDirectory: data)
        XCTAssertEqual(reopened.resultQuery, query)
        XCTAssertFalse(reopened.canClean)
        reopened.sceneChanged(.active)
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.hiddenCandidateCount, 1)
        XCTAssertEqual(reopened.selection(for: group.id).keepID, manualKeep)
        XCTAssertEqual(reopened.cleanupGroups.flatMap(\.pairs).first?.keep?.id, manualKeep)
        await reopened.clearScanCache()
        reopened.scan()
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.resultQuery, query)
        XCTAssertEqual(reopened.selectedCount, 1)
        reopened.setResultQuery(ReviewResultQuery())
        XCTAssertEqual(reopened.visibleGroups.count, 1)
        XCTAssertEqual(reopened.hiddenCandidateCount, 0)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for scan")
    }
}
