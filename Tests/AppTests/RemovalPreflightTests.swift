import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class RemovalPreflightTests: XCTestCase {
    @MainActor
    func testLargePreflightLetsMainActorContinue() async throws {
        let folder = URL.documentsDirectory.appending(path: "PreflightTest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appending(path: "test.png"))
        let source = FileSystemSource(directory: folder)
        let snapshot = try await source.snapshot()
        let asset = try XCTUnwrap(snapshot.assets.first)
        var finished = false
        let task = Task {
            defer { finished = true }
            try await AssetMutationService.validateRemovals(Array(repeating: asset, count: 20_000), sources: [source])
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
