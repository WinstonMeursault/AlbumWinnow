import AlbumWinnowApple
import XCTest
@testable import AlbumWinnowAcceptance

final class FixtureSeedTests: XCTestCase {
    @MainActor
    func testHostProvidesIsolatedFolderFixtures() async throws {
        let folder = URL.acceptanceDocumentsDirectory.appending(path: "AppTestFixtures")
        let snapshot = try await FileSystemSource(directory: folder, id: "controlled.fixture.source").snapshot()
        XCTAssertEqual(snapshot.assets.count, 10)
        XCTAssertTrue(snapshot.assets.contains { $0.name == "gallery-wide-a.png" })
        XCTAssertTrue(snapshot.assets.contains { $0.name == "review-detail-b.png" })
        // Model tests open a separate v2 owner, not the host's live database.
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let model = try await workspace.open()
        model.addFolder(folder)
        try await awaitModel(model)
        XCTAssertEqual(model.folders.map(\.name), ["AppTestFixtures"])
        XCTAssertTrue(model.canScan)
    }
}
