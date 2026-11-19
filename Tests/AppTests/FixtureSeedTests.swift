import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class FixtureSeedTests: XCTestCase {
    @MainActor
    func testHostProvidesIsolatedFolderFixtures() async throws {
        let model = ReviewModel()
        XCTAssertEqual(model.folders.map(\.name), ["AppTestFixtures"])
        XCTAssertTrue(model.canScan)
        let source = try XCTUnwrap(model.folders.first?.source)
        let snapshot = try await source.snapshot()
        XCTAssertEqual(snapshot.assets.count, 10)
        XCTAssertTrue(snapshot.assets.contains { $0.name == "gallery-wide-a.png" })
        XCTAssertTrue(snapshot.assets.contains { $0.name == "review-detail-b.png" })
    }
}
