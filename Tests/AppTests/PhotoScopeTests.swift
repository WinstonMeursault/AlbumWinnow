import AlbumWinnowApple
import AlbumWinnowRust
import os
import Photos
import XCTest
@testable import AlbumWinnowAcceptance

final class PhotoScopeTests: XCTestCase {
    @MainActor
    func testAlbumUnionDateIntersectionAndUnavailableSelectionNeverExpandScope() async throws {
        guard ProcessInfo.processInfo.environment["ALBUMWINNOW_PHOTOS_FIXTURE"] == "1" else {
            throw XCTSkip("Generated Photos fixtures require explicit opt-in on a dedicated simulator")
        }
        if PhotoLibrarySource.authorizationStatus() == .notDetermined {
            _ = await PhotoLibrarySource.requestAuthorization()
        }
        guard PhotoLibrarySource.authorizationStatus() == .authorized else {
            XCTFail("Opted-in simulator Photos fixture requires full access; permission setup did not succeed")
            return
        }
        let workspace = try ModelWorkspace()
        defer { workspace.dispose() }
        let owner = try await AppleReviewOwner.open(directory: workspace.data, preferencesSuite: workspace.suite)
        let record = try await owner.enablePhotoLibrary(expectedRevision: owner.header().metadata.revision)
        func saveScope(_ scope: PhotoScope) async throws {
            let header = try await owner.header()
            var settings = header.settings
            settings.photoScope = CorePhotoScope(albums: scope.albums, dates: scope.dates.map {
                CoreCaptureRange(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970, includesUnknown: $0.includesUnknown)
            })
            _ = try await owner.saveSettings(expectedRevision: header.metadata.revision, settings: settings)
        }
        let ids = OSAllocatedUnfairLock(initialState: [String]())
        let prefix = "AlbumWinnow scope fixture \(UUID())"
        let file = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            request?.creationDate = date
            guard let asset = request?.placeholderForCreatedAsset else { return }
            let first = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: prefix + " A")
            let second = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: prefix + " B")
            first.addAssets([asset] as NSArray)
            second.addAssets([asset] as NSArray)
            let created = [asset.localIdentifier, first.placeholderForCreatedAssetCollection.localIdentifier,
                           second.placeholderForCreatedAssetCollection.localIdentifier]
            ids.withLock { $0 = created }
        }
        let created = ids.withLock { $0 }
        XCTAssertEqual(created.count, 3)
        guard created.count == 3 else { return }
        // Generated fixtures stay in this dedicated simulator; no photo deletion is authorized by this test.
        var scope = PhotoScope()
        scope.albums = [created[1]: prefix + " A", created[2]: prefix + " B"]
        scope.dates = try CaptureRange(firstDay: date, lastDay: date)
        let union = try await PhotoLibrarySource(scope: scope, id: record.id).snapshot()
        XCTAssertEqual(union.assets.map(\.id), [AssetID(source: record.id, item: created[0])])
        scope.dates = try CaptureRange(firstDay: date.addingTimeInterval(7 * 86400), lastDay: date.addingTimeInterval(7 * 86400))
        let excluded = try await PhotoLibrarySource(scope: scope, id: record.id).snapshot()
        XCTAssertTrue(excluded.assets.isEmpty)
        do {
            try await saveScope(scope)
            try await owner.validateRemovability(assets: union.assets)
            XCTFail("Final removal preflight must reject assets outside the current date range")
        } catch AssetAccessError.changedDuringScan {}
        scope.dates = nil
        let collection = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [created[1]], options: nil).firstObject)
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [created[0]], options: nil)
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(asset)
        }
        let fresh = try await PhotoLibrarySource(scope: scope, id: record.id).snapshot()
        var onlyFirst = PhotoScope()
        onlyFirst.albums = [created[1]: prefix + " A"]
        do {
            try await saveScope(onlyFirst)
            try await owner.validateRemovability(assets: fresh.assets)
            XCTFail("Final removal preflight must reject a photo removed from the selected album")
        } catch AssetAccessError.changedDuringScan {}
        let modelWorkspace = try ModelWorkspace()
        defer { modelWorkspace.dispose() }
        let model = try await modelWorkspace.open()
        await model.setPhotosEnabled(true)
        let modelSource = try XCTUnwrap(model.photoSourceID)
        let current = try await PhotoLibrarySource(scope: scope, id: modelSource).snapshot()
        model.setPhotoScope(onlyFirst)
        try await awaitModel(model)
        let reason = await model.deleteAllUnavailableReason(for: current.assets)
        XCTAssertNotNil(reason, "The app must pass its active Photos scope into the final cleanup source")
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetCollectionChangeRequest(for: collection)?.title = prefix + " renamed"
        }
        do {
            _ = try await PhotoLibrarySource(scope: scope, id: record.id).snapshot()
            XCTFail("Renamed selection must fail rather than expand to all photos")
        } catch ScopeError.unavailableAlbum {}
        do {
            try await saveScope(scope)
            try await owner.validateRemovability(assets: union.assets)
            XCTFail("Final removal preflight must reject a renamed selected album")
        } catch ScopeError.unavailableAlbum {}
        scope.albums = ["missing-\(UUID())": "Missing"]
        do {
            _ = try await PhotoLibrarySource(scope: scope, id: record.id).snapshot()
            XCTFail("Deleted selection must fail rather than expand to all photos")
        } catch ScopeError.unavailableAlbum {}
    }
}
