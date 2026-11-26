import AlbumWinnowRust
import Foundation
import os
import Photos
@testable import AlbumWinnowApple

/// This target runs only on the dedicated opt-in simulator scheme. Every
/// deletion is constrained to the exact assets created by the current test.
struct NativePhotosFixtureFailure: LocalizedError {
    let errorDescription: String?
}

final class NativePhotosCleanupFixture {
    private func require(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw NativePhotosFixtureFailure(errorDescription: "Native Photos fixture assertion failed") }
    }
    private func equal<T: Equatable>(_ value: T, _ expected: T) throws {
        guard value == expected else { throw NativePhotosFixtureFailure(errorDescription: "Expected \(expected), got \(value)") }
    }
    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NativePhotosFixtureFailure(errorDescription: "Missing native Photos fixture value") }
        return value
    }
    static func run(_ name: String) async throws {
        #if targetEnvironment(simulator)
        let fixture = NativePhotosCleanupFixture()
        switch name {
        case "ordinary": try await fixture.ordinaryRecovery()
        case "denied": try await fixture.ordinaryRecovery(denied: true)
        case "whole": try await fixture.wholeGroupRecovery()
        case "scope": try await fixture.scopeChange()
        default: throw NativePhotosFixtureFailure(errorDescription: "Unknown native Photos fixture case")
        }
        #else
        throw NativePhotosFixtureFailure(errorDescription: "Generated Photos fixtures require a dedicated simulator")
        #endif
    }

    private func generatedPhotos() async throws -> (ids: [String], album: String, title: String) {
        guard ProcessInfo.processInfo.environment["ALBUMWINNOW_PHOTOS_FIXTURE"] == "1" else {
            throw CleanupError.unavailableSource
        }
        if PhotoLibrarySource.authorizationStatus() == .notDetermined {
            _ = await PhotoLibrarySource.requestAuthorization()
        }
        guard PhotoLibrarySource.authorizationStatus() == .authorized else {
            throw PhotoLibraryReadError.authorizationRequired
        }
        let file = try unwrap(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
        let title = "AlbumWinnow v2 cleanup fixture \(UUID())"
        let captured = OSAllocatedUnfairLock(initialState: ([String](), ""))
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            var assets: [PHObjectPlaceholder] = []
            for _ in 0..<2 {
                let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                request?.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
                if let placeholder = request?.placeholderForCreatedAsset { assets.append(placeholder) }
            }
            album.addAssets(assets as NSArray)
            let identifiers = assets.map(\.localIdentifier)
            let albumIdentifier = album.placeholderForCreatedAssetCollection.localIdentifier
            captured.withLock { $0 = (identifiers, albumIdentifier) }
        }
        let result = captured.withLock { $0 }
        try equal(result.0.count, 2)
        return (result.0, result.1, title)
    }

    private func preferencesSuite(_ root: URL) -> String { "org.albumwinnow.native-owner.\(root.lastPathComponent)" }

    private func prepare(_ created: (ids: [String], album: String, title: String), root: URL,
                         all: Bool) async throws -> AppleReviewOwner {
        let owner = try await AppleReviewOwner.open(directory: root, preferencesSuite: preferencesSuite(root))
        let record = try await owner.enablePhotoLibrary(expectedRevision: owner.header().metadata.revision)
        var scope = PhotoScope()
        scope.albums = [created.album: created.title]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        scope.dates = try CaptureRange(firstDay: date, lastDay: date)
        var settings = try await owner.header().settings
        settings.photoScope = scope.coreValue
        _ = try await owner.saveSettings(expectedRevision: owner.header().metadata.revision, settings: settings)
        let scanned = try await owner.scan()
        try require(scanned.issues.isEmpty && scanned.unavailableSources.isEmpty && scanned.scanned == 2)
        try equal(scanned.metadata.groupCount, 1)
        let summary = try unwrap(await owner.queryPage(offset: 0, limit: 1).first)
        let group = try await owner.groupDetail(signature: summary.signature).group
        // No generated group injection: the production native scan must discover
        // exactly these two assets before the user intent can authorize cleanup.
        try equal(Set(group.members.map(\.id.itemId)), Set(created.ids))
        try require(group.members.allSatisfy { $0.id.sourceId == record.id })
        // Allowing downloads during a scan must not authorize network reads in
        // ordinary previews/differences or final native cleanup validation.
        try await owner.setSkipCloudPhotos(false)
        let previewAsset = PhotoAsset(try unwrap(group.members.first))
        let skipsCloud = try await owner.withAssetSources(assets: [previewAsset]) { sources in
            guard let source = sources[previewAsset.id.source] else { throw CleanupError.unavailableSource }
            return source.skipsCloudAsset(previewAsset.id)
        }
        try equal(skipsCloud, true)
        _ = try await owner.applyIntent(expectedRevision: owner.header().metadata.revision, signature: summary.signature,
            commandID: "native-photos-confirm", intent: all ? .confirmDeleteAll : .confirmKeep(keep: CoreAssetKey(sourceId: record.id, itemId: created.ids[0])))
        return owner
    }

    private func ordinaryRecovery(denied: Bool = false) async throws {
        let created = try await generatedPhotos()
        let root = FileManager.default.temporaryDirectory.appending(path: "native-photos-\(UUID())")
        defer {
            UserDefaults(suiteName: preferencesSuite(root))?.removePersistentDomain(forName: preferencesSuite(root))
            try? FileManager.default.removeItem(at: root)
        }
        let owner = try await prepare(created, root: root, all: false)
        let (operation, receipt) = try await owner.applyCleanup(expectedRevision: owner.header().metadata.revision)
        try require(receipt.trashLocations.isEmpty)
        try require(receipt.interruption == nil)
        let outcomes = try await owner.cleanupResults(operation: operation, offset: 0, limit: 16)
        if denied {
            try require(!receipt.diagnostics.isEmpty)
            try equal(outcomes.map(\.outcome), [.failed])
            try equal(receipt.metadata.decisionCount, 1)
            try equal(await owner.queryCount(), 1)
            try equal(PHAsset.fetchAssets(withLocalIdentifiers: created.ids, options: nil).count, 2)
            return
        }
        try require(receipt.diagnostics.isEmpty)
        try equal(outcomes.map(\.outcome), [.movedToRecentlyDeleted])
        try equal(outcomes.map(\.item.pair.remove.id.itemId), [created.ids[1]])
        try equal(PHAsset.fetchAssets(withLocalIdentifiers: [created.ids[0]], options: nil).count, 1)
        try equal(PHAsset.fetchAssets(withLocalIdentifiers: [created.ids[1]], options: nil).count, 0)
    }

    private func wholeGroupRecovery() async throws {
        let created = try await generatedPhotos()
        let root = FileManager.default.temporaryDirectory.appending(path: "native-photos-all-\(UUID())")
        defer {
            UserDefaults(suiteName: preferencesSuite(root))?.removePersistentDomain(forName: preferencesSuite(root))
            try? FileManager.default.removeItem(at: root)
        }
        let owner = try await prepare(created, root: root, all: true)
        let (operation, receipt) = try await owner.applyCleanup(expectedRevision: owner.header().metadata.revision)
        try require(receipt.diagnostics.isEmpty)
        let outcomes = try await owner.cleanupResults(operation: operation, offset: 0, limit: 16)
        try equal(outcomes.map(\.outcome), [.movedToRecentlyDeleted, .movedToRecentlyDeleted])
        try equal(Set(outcomes.map(\.item.pair.remove.id.itemId)), Set(created.ids))
        try equal(PHAsset.fetchAssets(withLocalIdentifiers: created.ids, options: nil).count, 0)
    }

    private func scopeChange() async throws {
        let created = try await generatedPhotos()
        let root = FileManager.default.temporaryDirectory.appending(path: "native-photos-scope-\(UUID())")
        defer {
            UserDefaults(suiteName: preferencesSuite(root))?.removePersistentDomain(forName: preferencesSuite(root))
            try? FileManager.default.removeItem(at: root)
        }
        let owner = try await prepare(created, root: root, all: false)
        let collection = try unwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [created.album], options: nil).firstObject)
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [created.ids[1]], options: nil)
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(assets)
        }
        let (operation, receipt) = try await owner.applyCleanup(expectedRevision: owner.header().metadata.revision)
        try require(receipt.trashLocations.isEmpty)
        try equal(await owner.cleanupResults(operation: operation, offset: 0, limit: 16).map(\.outcome), [.skipped(reason: .changedAsset)])
        try equal(PHAsset.fetchAssets(withLocalIdentifiers: created.ids, options: nil).count, 2)
    }
}
