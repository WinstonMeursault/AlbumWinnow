import AlbumWinnowCore
import ImageIO
import XCTest
@testable import AlbumWinnowAcceptance

final class SceneReviewTests: XCTestCase {
    @MainActor
    func testIndependentQueuesPreserveManualPlansAcrossCacheClearAndAnalysisToggle() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.documentsDirectory.appending(path: "SceneReview-\(UUID())")
        let folder = root.appending(path: "photos"), data = root.appending(path: "state")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures")
        let scene = try Data(contentsOf: fixtures.appending(path: "scene.png"))
        try scene.write(to: folder.appending(path: "scene-a.png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(scene as CFData, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = try XCTUnwrap(original.cropping(to: CGRect(x: Double(original.width) * 0.04, y: 0,
            width: Double(original.width) * 0.92, height: Double(original.height))))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, crop, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (encoded as Data).write(to: folder.appending(path: "scene-b.png"))
        let duplicate = try Data(contentsOf: fixtures.appending(path: "detail-a.png"))
        for name in ["duplicate-a.png", "duplicate-b.png"] { try duplicate.write(to: folder.appending(path: name)) }
        let model = ReviewModel(dataDirectory: data)
        model.addFolder(folder)
        model.setSimilarScenesEnabled(true)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.result?.groups.count, 2, "Scene issues: \(String(describing: model.result?.issues))")
        let sceneGroup = try XCTUnwrap(model.result?.groups.first { $0.match == .sceneSimilar })
        let duplicateGroup = try XCTUnwrap(model.result?.groups.first { $0.match == .exactDuplicate })
        XCTAssertEqual(model.visibleGroups.map(\.id), [duplicateGroup.id])
        XCTAssertFalse(sceneGroup.hasQualityRecommendation ?? true)
        XCTAssertTrue(model.estimatedRemovals(for: sceneGroup).isEmpty)
        let manualKeep = try XCTUnwrap(sceneGroup.assets.first { $0.name == "scene-b.png" })
        let confirmed = await model.confirmSelection(in: sceneGroup, keepID: manualKeep.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(model.hiddenCandidateCount, 1)
        XCTAssertNotNil(model.cleanupGroups.first?.pairs.first?.sceneAlgorithm)
        model.rememberPosition(sceneGroup)
        XCTAssertNotEqual(model.resumeGroup?.id, sceneGroup.id)
        model.setReviewCollection(.similarScenes)
        XCTAssertEqual(model.visibleGroups.map(\.id), [sceneGroup.id])
        XCTAssertEqual(model.resumeGroup?.id, sceneGroup.id)
        model.clearResultFilters()
        XCTAssertEqual(model.reviewCollection, .similarScenes)
        let duplicateConfirmed = await model.confirmSelection(in: duplicateGroup, keepID: duplicateGroup.preferred.id, deleteAll: false)
        XCTAssertTrue(duplicateConfirmed)
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.hiddenCandidateCount, 1)
        model.setSimilarScenesEnabled(false)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertEqual(model.selectedCount, 1)
        model.setSimilarScenesEnabled(true)
        model.scan()
        await waitUntil { !model.running }
        XCTAssertEqual(model.selectedCount, 2, "Disabling optional analysis cannot erase a still-valid manual scene plan")
        await model.clearScanCache()
        model.scan()
        await waitUntil { !model.running }
        XCTAssertEqual(model.selectedCount, 2)
        let currentScene = try XCTUnwrap(model.result?.groups.first { $0.match == .sceneSimilar })
        XCTAssertEqual(model.selection(for: currentScene.id).keepID, manualKeep.id)
        let reopened = ReviewModel(dataDirectory: data)
        XCTAssertTrue(reopened.similarScenesEnabled)
        XCTAssertEqual(reopened.reviewCollection, .similarScenes)
        reopened.sceneChanged(.active)
        await waitUntil { !reopened.running }
        XCTAssertEqual(reopened.selectedCount, 2)
        XCTAssertEqual(reopened.selection(for: currentScene.id).keepID, manualKeep.id)
        let removable = try XCTUnwrap(reopened.cleanupGroups.first { $0.match == .sceneSimilar }?.pairs.first?.remove)
        reopened.setLocked(removable, locked: true)
        XCTAssertEqual(reopened.selectedCount, 1)
        reopened.setLocked(removable, locked: false)
        XCTAssertEqual(reopened.selectedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "scene-a.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "scene-b.png").path))
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for scene scan")
    }
}
