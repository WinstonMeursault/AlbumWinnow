import AlbumWinnowApple
import XCTest
@testable import AlbumWinnowAcceptance

final class RemovalPreflightTests: XCTestCase {
    @MainActor
    func testLargePreflightLetsMainActorContinue() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let folder = try workspace.folder(files: [])
        try Data([0]).write(to: folder.appending(path: "test.png"))
        let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
        let record = try await owner.addFolder(folder, expectedRevision: owner.header().metadata.revision)
        let source = FileSystemSource(directory: folder, id: record.id)
        let snapshot = try await source.snapshot()
        let asset = try XCTUnwrap(snapshot.assets.first)
        var finished = false
        let task = Task {
            defer { finished = true }
            try await owner.validateRemovability(assets: Array(repeating: asset, count: 20_000))
        }
        var pulses = 0
        while !finished {
            pulses += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        try await task.value
        XCTAssertGreaterThan(pulses, 1, "The UI actor must run while file validation is in progress")
        print("Main actor advanced \(pulses) times during a 20,000-item preflight")
    }
}
