import Foundation
import os
import Photos

public actor AssetMutationService {
    private var applying = false

    public init() {}

    public func apply(_ pairs: [CleanupPair], sources: [any AssetSource]) async throws -> [CleanupItem] {
        guard !applying else { throw CleanupError.operationInProgress }
        let removals = Set(pairs.map(\.remove.id))
        let wholeGroups = Dictionary(grouping: pairs.filter { $0.wholeGroupID != nil }, by: \.wholeGroupID)
        guard !pairs.isEmpty, removals.count == pairs.count,
              removals.isDisjoint(with: pairs.compactMap { $0.keep?.id }),
              pairs.allSatisfy({ ($0.keep == nil) != ($0.wholeGroupID == nil) }),
              wholeGroups.allSatisfy({ id, group in group.count > 1 && group.contains { $0.remove.id == id } }),
              Set(sources.map(\.id)).count == sources.count else {
            throw CleanupError.invalidSelection
        }
        applying = true
        defer { applying = false }

        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var items = [CleanupItem?](repeating: nil, count: pairs.count)
        var queuedPhotos: [(Int, CleanupPair)] = []
        var rejectedGroups: [AssetID: any Error] = [:]
        for (id, group) in wholeGroups {
            guard let id else { continue }
            do {
                for pair in group {
                    try Task.checkCancellation()
                    try Self.validateRemoval(pair.remove, sources: byID)
                }
            } catch {
                rejectedGroups[id] = error
            }
        }

        for (position, pair) in pairs.enumerated() {
            do {
                try Task.checkCancellation()
                if let id = pair.wholeGroupID, let error = rejectedGroups[id] { throw error }
                try await Self.verify(pair, sources: byID)
                try Task.checkCancellation()
                if let folder = byID[pair.remove.id.source] as? FileSystemSource {
                    let path = try Self.moveToTrash(pair, folder: folder, sources: byID)
                    items[position] = CleanupItem(pair: pair, status: .movedToTrash, detail: path)
                } else if byID[pair.remove.id.source] is PhotoLibrarySource {
                    queuedPhotos.append((position, pair))
                    continue
                } else {
                    throw CleanupError.unsupportedSource
                }
            } catch {
                items[position] = Self.item(for: pair, error: error)
            }
        }

        if !queuedPhotos.isEmpty {
            let outcome: Result<Void, any Error>
            do {
                try Task.checkCancellation()
                try await Self.moveToRecentlyDeleted(queuedPhotos.map(\.1), sources: byID)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            for (position, pair) in queuedPhotos {
                switch outcome {
                case .success:
                    items[position] = CleanupItem(pair: pair, status: .movedToRecentlyDeleted, detail: nil)
                case .failure(let error):
                    items[position] = Self.item(for: pair, error: error)
                }
            }
        }
        return items.compactMap { $0 }
    }

    private static func verify(_ pair: CleanupPair, sources: [String: any AssetSource]) async throws {
        try validateRemoval(pair.remove, sources: sources)
        guard let retained = pair.keep else { return }
        guard let keep = sources[retained.id.source], let remove = sources[pair.remove.id.source] else {
            throw CleanupError.unavailableSource
        }
        if let keepFolder = keep as? FileSystemSource, let removeFolder = remove as? FileSystemSource,
           try FileSystemSource.referToSameFile(keepFolder.currentURL(for: retained), removeFolder.currentURL(for: pair.remove)) {
            throw CleanupError.sameFile
        }
        try validate(retained, sources: sources)
        guard try await DuplicateDetector.compare(retained, source: keep, pair.remove, source: remove) != .distinct else {
            throw CleanupError.noLongerDuplicate
        }
    }

    public nonisolated static func validateRemovals(_ assets: [PhotoAsset], sources: [any AssetSource]) async throws {
        let task = Task.detached {
            let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for asset in assets {
                try Task.checkCancellation()
                try validateRemoval(asset, sources: byID)
            }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    private static func validateRemoval(_ asset: PhotoAsset, sources: [String: any AssetSource]) throws {
        guard asset.photoProperties?.hasAssociatedResources != true else { throw CleanupError.protectedResources }
        switch sources[asset.id.source] {
        case let folder as FileSystemSource:
            let url = try folder.currentURL(for: asset)
            guard FileManager.default.isDeletableFile(atPath: url.path) else { throw AssetAccessError.inaccessible }
        case let photos as PhotoLibrarySource:
            _ = try photos.removableAsset(for: asset)
        case nil:
            throw CleanupError.unavailableSource
        default:
            throw CleanupError.unsupportedSource
        }
    }

    private static func validate(_ asset: PhotoAsset, sources: [String: any AssetSource]) throws {
        switch sources[asset.id.source] {
        case let folder as FileSystemSource:
            _ = try folder.currentURL(for: asset)
        case let photos as PhotoLibrarySource:
            _ = try photos.currentAsset(for: asset)
        case nil:
            throw CleanupError.unavailableSource
        default:
            throw CleanupError.unsupportedSource
        }
    }

    private static func moveToTrash(
        _ pair: CleanupPair, folder: FileSystemSource, sources: [String: any AssetSource]
    ) throws -> String? {
        let url = try folder.currentURL(for: pair.remove)
        var coordinationError: NSError?
        var result: Result<String?, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            result = Result {
                guard try folder.currentURL(for: pair.remove).path == coordinatedURL.standardizedFileURL.path else {
                    throw CleanupError.changedAsset
                }
                if let retained = pair.keep {
                    try validate(retained, sources: sources)
                    if let keepFolder = sources[retained.id.source] as? FileSystemSource,
                       try FileSystemSource.referToSameFile(keepFolder.currentURL(for: retained), coordinatedURL) {
                        throw CleanupError.sameFile
                    }
                }
                var destination: NSURL?
                try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: &destination)
                return destination?.path
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AssetAccessError.inaccessible }
        return try result.get()
    }

    private static func moveToRecentlyDeleted(_ pairs: [CleanupPair], sources: [String: any AssetSource]) async throws {
        let validation = OSAllocatedUnfairLock<Result<Void, any Error>>(initialState: .failure(CleanupError.changedAsset))
        try await PHPhotoLibrary.shared().performChanges {
            do {
                let assets = try pairs.map { pair in
                    if let retained = pair.keep { try validate(retained, sources: sources) }
                    guard let library = sources[pair.remove.id.source] as? PhotoLibrarySource else {
                        throw CleanupError.unavailableSource
                    }
                    return try library.removableAsset(for: pair.remove)
                }
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
                validation.withLock { $0 = .success(()) }
            } catch {
                validation.withLock { $0 = .failure(error) }
            }
        }
        try validation.withLock { try $0.get() }
    }

    private static func item(for pair: CleanupPair, error: any Error) -> CleanupItem {
        switch error {
        case is CancellationError:
            CleanupItem(pair: pair, status: .skipped, detail: "Cleanup was cancelled.")
        case AssetAccessError.changedDuringScan:
            CleanupItem(pair: pair, status: .skipped, detail: CleanupError.changedAsset.localizedDescription)
        case CleanupError.protectedResources, CleanupError.noLongerDuplicate, CleanupError.changedAsset, CleanupError.sameFile:
            CleanupItem(pair: pair, status: .skipped, detail: error.localizedDescription)
        default:
            CleanupItem(pair: pair, status: .failed, detail: error.localizedDescription)
        }
    }
}
