import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class SourcePolicyTests: XCTestCase {
    @MainActor
    func testCrossScopePreferenceAndReadOnlyChangesPreserveManualChoices() async throws {
        let defaults = UserDefaults.standard
        let keys = ["AlbumWinnow.folderBookmarks", "AlbumWinnow.photosEnabled", "AlbumWinnow.interruptedScan"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        let a = root.appending(path: "A"), b = root.appending(path: "B"), data = root.appending(path: "state")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let bytes = try Data(contentsOf: fixture)
        for name in ["a1.png", "a2.png"] { try bytes.write(to: a.appending(path: name)) }
        try bytes.write(to: b.appending(path: "b1.png"))
        let model = ReviewModel(dataDirectory: data)
        model.addFolder(a); model.addFolder(b)
        let sources = model.folders.map(\.id)
        let sides = ComparisonSides(first: sources[0], second: sources[1])
        model.setComparisonSides(sides)
        model.setPreferredSource(sources[1])
        model.scan()
        await waitUntil { !model.running }
        let group = try XCTUnwrap(model.result?.groups.first)
        XCTAssertEqual(group.assets.count, 3)
        XCTAssertEqual(group.recommendation.id.source, sources[1])
        let manualKeep = try XCTUnwrap(group.assets.first { $0.id.source == sources[0] })
        let confirmed = await model.confirmSelection(in: group, keepID: manualKeep.id, deleteAll: false)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.cleanupGroups.first?.retained.count, 2)
        XCTAssertTrue(model.cleanupGroups.flatMap(\.pairs).allSatisfy { sides.permits($0.keep!.id, $0.remove.id) })
        model.setPreferredSource(sources[0])
        model.scan()
        await waitUntil { !model.running }
        let updated = try XCTUnwrap(model.result?.groups.first)
        XCTAssertEqual(model.selection(for: updated.id).keepID, manualKeep.id)
        XCTAssertEqual(model.selectedCount, 1)
        await model.setReadOnly(sources[1], enabled: true)
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertEqual(model.selection(for: updated.id).keepID, manualKeep.id)
        await model.setReadOnly(sources[1], enabled: false)
        XCTAssertEqual(model.selectedCount, 0, "Removing protection cannot silently reinstate cancelled removals")
        await model.setReadOnly(sources[0], enabled: true)
        var scope = PhotoScope()
        scope.albums = ["missing": "Saved Album"]
        scope.dates = try CaptureRange(firstDay: Date(), lastDay: Date(), includesUnknown: true)
        model.setPhotoScope(scope)
        let reopened = ReviewModel(dataDirectory: data)
        XCTAssertEqual(reopened.photoScope, scope)
        XCTAssertEqual(reopened.comparisonSides, sides)
        XCTAssertTrue(reopened.readOnlySources.contains(sources[0]))
        await reopened.clearScanCache()
        XCTAssertTrue(reopened.readOnlySources.contains(sources[0]))
        XCTAssertEqual(reopened.photoScope, scope)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for scan")
    }
}
