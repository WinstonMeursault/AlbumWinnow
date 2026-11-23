import AlbumWinnowCore
import os
import Photos
import XCTest
@testable import AlbumWinnowAcceptance

final class PhotoScopeTests: XCTestCase {
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
        let ids = OSAllocatedUnfairLock(initialState: [String]())
        let prefix = "AlbumWinnow scope fixture \(UUID())"
        let file = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await PHPhotoLibrary.shared().performChanges {
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
        let union = try await PhotoLibrarySource(scope: scope).snapshot()
        XCTAssertEqual(union.assets.map(\.id), [AssetID(source: "photos-library", item: created[0])])
        scope.dates = try CaptureRange(firstDay: date.addingTimeInterval(7 * 86400), lastDay: date.addingTimeInterval(7 * 86400))
        let excluded = try await PhotoLibrarySource(scope: scope).snapshot()
        XCTAssertTrue(excluded.assets.isEmpty)
        do {
            try await AssetMutationService.validateRemovals(union.assets, sources: [PhotoLibrarySource(scope: scope)])
            XCTFail("Final removal preflight must reject assets outside the current date range")
        } catch AssetAccessError.changedDuringScan {}
        scope.dates = nil
        let collection = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [created[1]], options: nil).firstObject)
        try await PHPhotoLibrary.shared().performChanges {
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [created[0]], options: nil)
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(asset)
        }
        let fresh = try await PhotoLibrarySource(scope: scope).snapshot()
        var onlyFirst = PhotoScope()
        onlyFirst.albums = [created[1]: prefix + " A"]
        do {
            try await AssetMutationService.validateRemovals(fresh.assets, sources: [PhotoLibrarySource(scope: onlyFirst)])
            XCTFail("Final removal preflight must reject a photo removed from the selected album")
        } catch AssetAccessError.changedDuringScan {}
        let savedPhotos = UserDefaults.standard.object(forKey: "AlbumWinnow.photosEnabled")
        defer { UserDefaults.standard.set(savedPhotos, forKey: "AlbumWinnow.photosEnabled") }
        let modelData = URL.acceptanceDocumentsDirectory.appending(path: "ScopeModel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: modelData) }
        let model = await ReviewModel(dataDirectory: modelData)
        await model.setPhotosEnabled(true)
        await model.setPhotoScope(onlyFirst)
        let reason = await model.deleteAllUnavailableReason(for: fresh.assets)
        XCTAssertNotNil(reason, "The app must pass its active Photos scope into the final cleanup source")
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: collection)?.title = prefix + " renamed"
        }
        do {
            _ = try await PhotoLibrarySource(scope: scope).snapshot()
            XCTFail("Renamed selection must fail rather than expand to all photos")
        } catch ScopeError.unavailableAlbum {}
        do {
            try await AssetMutationService.validateRemovals(union.assets, sources: [PhotoLibrarySource(scope: scope)])
            XCTFail("Final removal preflight must reject a renamed selected album")
        } catch ScopeError.unavailableAlbum {}
        scope.albums = ["missing-\(UUID())": "Missing"]
        do {
            _ = try await PhotoLibrarySource(scope: scope).snapshot()
            XCTFail("Deleted selection must fail rather than expand to all photos")
        } catch ScopeError.unavailableAlbum {}
    }
}
