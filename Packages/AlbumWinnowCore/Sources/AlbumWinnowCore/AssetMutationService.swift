import Foundation
import os
import Photos

public actor AssetMutationService {
    private let journal: CleanupJournal
    private var applying = false

    public init(journalURL: URL) throws {
        journal = try CleanupJournal(url: journalURL)
    }

    public func recentRuns(limit: Int = 20) throws -> [CleanupRun] {
        try journal.recentRuns(limit: max(0, limit))
    }

    public func apply(_ pairs: [CleanupPair], sources: [any AssetSource]) async throws -> CleanupRun {
        guard !applying else { throw CleanupError.operationInProgress }
        let removals = Set(pairs.map(\.remove.id))
        guard !pairs.isEmpty, removals.count == pairs.count,
              removals.isDisjoint(with: pairs.map(\.keep.id)),
              Set(sources.map(\.id)).count == sources.count else {
            throw CleanupError.invalidSelection
        }
        applying = true
        defer { applying = false }

        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let run = UUID()
        let start = Date()
        try journal.begin(pairs, id: run, at: start)
        var items = pairs.map { CleanupItem(pair: $0, status: .pending, detail: nil) }
        var queuedPhotos: [(Int, CleanupPair)] = []

        for (position, pair) in pairs.enumerated() {
            do {
                try Task.checkCancellation()
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
            try journal.record([(position, items[position])], run: run)
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
            let updates = queuedPhotos.map { position, pair in
                switch outcome {
                case .success:
                    items[position] = CleanupItem(pair: pair, status: .movedToRecentlyDeleted, detail: nil)
                case .failure(let error):
                    items[position] = Self.item(for: pair, error: error)
                }
                return (position, items[position])
            }
            try journal.record(updates, run: run)
        }
        return CleanupRun(id: run, startedAt: start, items: items)
    }

    private static func verify(_ pair: CleanupPair, sources: [String: any AssetSource]) async throws {
        guard let keep = sources[pair.keep.id.source], let remove = sources[pair.remove.id.source] else {
            throw CleanupError.unavailableSource
        }
        guard pair.remove.photoProperties?.hasAssociatedResources != true else { throw CleanupError.protectedResources }
        if let keepFolder = keep as? FileSystemSource, let removeFolder = remove as? FileSystemSource,
           try FileSystemSource.referToSameFile(keepFolder.currentURL(for: pair.keep), removeFolder.currentURL(for: pair.remove)) {
            throw CleanupError.sameFile
        }
        try validate(pair.keep, sources: sources)
        if let photos = remove as? PhotoLibrarySource {
            _ = try photos.removableAsset(for: pair.remove)
        }
        let first = try await keep.image(for: pair.keep)
        let second = try await remove.image(for: pair.remove)
        guard try DuplicateDetector().compare(first, second) != .distinct else { throw CleanupError.noLongerDuplicate }
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
                try validate(pair.keep, sources: sources)
                guard try folder.currentURL(for: pair.remove).path == coordinatedURL.standardizedFileURL.path else {
                    throw CleanupError.changedAsset
                }
                if let keepFolder = sources[pair.keep.id.source] as? FileSystemSource,
                   try FileSystemSource.referToSameFile(keepFolder.currentURL(for: pair.keep), coordinatedURL) {
                    throw CleanupError.sameFile
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
                    try validate(pair.keep, sources: sources)
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
