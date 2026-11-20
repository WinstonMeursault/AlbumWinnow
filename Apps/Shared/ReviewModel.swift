import AlbumWinnowCore
import CoreGraphics
import Foundation
import Photos
import SwiftUI

struct CloudDownloadProgress {
    let total: Int
    private(set) var available = 0
    private(set) var failed = 0
    private(set) var ended = false
    private(set) var cancelled = false
    private var active: [AssetID: Double] = [:]
    private var finished = Set<AssetID>()

    init(total: Int) { self.total = total }

    var remaining: Int { total - available - failed }
    var needsRetry: Bool { failed > 0 || remaining > 0 }
    var processed: Double { Double(available + failed) + active.values.reduce(0, +) }

    mutating func update(_ update: PhotoLibrarySource.DownloadUpdate) {
        guard !ended else { return }
        switch update {
        case let .transferring(id, fraction):
            guard !finished.contains(id), fraction.isFinite else { return }
            active[id] = max(active[id, default: 0], min(0.99, fraction))
        case let .finished(id, isAvailable):
            guard finished.insert(id).inserted else { return }
            active.removeValue(forKey: id)
            if isAvailable { available += 1 } else { failed += 1 }
        }
    }

    mutating func end(cancelled: Bool) {
        self.cancelled = cancelled
        ended = true
        active.removeAll()
        finished.removeAll()
    }
}

@MainActor @Observable final class ReviewModel {
    static let showReviewFilenamesKey = "AlbumWinnow.showReviewFilenames"

    struct GroupSelection {
        var keepID: AssetID?
        var selected = Set<AssetID>()
        var deleteAll = false
    }

    struct CleanupGroup: Identifiable {
        let id: AssetID
        let keep: PhotoAsset?
        let pairs: [CleanupPair]
        let match: DuplicateMatch
    }

    private static let folderKey = "AlbumWinnow.folderBookmarks"
    private static let photosKey = "AlbumWinnow.photosEnabled"
    private static let interruptedScanKey = "AlbumWinnow.interruptedScan"
    private static let interruptedDownloadsKey = "AlbumWinnow.interruptedDownloads"

    private(set) var folders: [FolderScope] = []
    private(set) var photosEnabled = false
    private(set) var authorization = PhotoLibrarySource.authorizationStatus()
    private(set) var result: ScanResult?
    private(set) var progress: ScanProgress?
    private(set) var downloadProgress: CloudDownloadProgress?
    private(set) var lastCleanup: [CleanupItem]?
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var resultsStale = false
    private var selections: [AssetID: GroupSelection] = [:]
    var errorMessage: String?
    var sourceErrorMessage: String?

    private let photoSource = PhotoLibrarySource()
    private let galleryThumbnails = GalleryThumbnails()
    private let engine: ScanEngine?
    private let cleanup = AssetMutationService()
    private var scanTask: Task<Void, Never>?
    private var libraryChangedDuringScan = false
    private var libraryTask: Task<Void, Never>?
    #if os(iOS)
    private var inForeground = false
    #endif

    var allowsPhotos: Bool { authorization == .authorized || authorization == .limited }
    var hasScanSources: Bool { !folders.isEmpty || (photosEnabled && allowsPhotos) }
    var canEditSources: Bool { !running && !cleaning }
    var canScan: Bool { canEditSources && hasScanSources && engine != nil }
    var canClean: Bool { !running && !cleaning && !resultsStale && result != nil }
    var pendingDownloadCount: Int { pendingDownloadIDs.count }
    var selectedCount: Int { selections.values.reduce(0) { $0 + $1.selected.count } }
    var cleanupGroups: [CleanupGroup] {
        guard selectedCount > 0, let result else { return [] }
        return result.groups.compactMap { group in
            guard let selection = selections[group.id], !selection.selected.isEmpty else { return nil }
            let assets = [group.preferred] + group.duplicates.map(\.asset)
            if selection.deleteAll {
                let pairs = assets.map { CleanupPair(remove: $0, fromWholeGroup: group.id) }
                return CleanupGroup(id: group.id, keep: nil, pairs: pairs, match: group.match)
            }
            let keep = assets.first(where: { $0.id == selection.keepID }) ?? group.preferred
            let pairs = assets.compactMap { asset -> CleanupPair? in
                guard selection.selected.contains(asset.id), asset.id != keep.id,
                      asset.photoProperties?.hasAssociatedResources != true else { return nil }
                return CleanupPair(keep: keep, remove: asset)
            }
            return pairs.isEmpty ? nil : CleanupGroup(id: group.id, keep: keep, pairs: pairs, match: group.match)
        }
    }

    func selection(for groupID: AssetID) -> GroupSelection {
        selections[groupID] ?? GroupSelection()
    }

    func confirmSelection(in group: DuplicateGroup, keepID: AssetID?, deleteAll: Bool) async -> Bool {
        guard canClean, !Task.isCancelled else { return false }
        let assets = [group.preferred] + group.duplicates.map(\.asset)
        if deleteAll {
            let reason = await deleteAllUnavailableReason(for: assets)
            guard !Task.isCancelled, canClean, result?.groups.contains(group) == true else { return false }
            if let reason {
                errorMessage = reason
                return false
            }
            selections[group.id] = GroupSelection(selected: Set(assets.map(\.id)), deleteAll: true)
        } else {
            guard let keepID, assets.contains(where: { $0.id == keepID }) else { return false }
            let removable = assets.filter { $0.id != keepID && $0.photoProperties?.hasAssociatedResources != true }
            selections[group.id] = GroupSelection(keepID: keepID, selected: Set(removable.map(\.id)))
        }
        return true
    }

    func deleteAllUnavailableReason(for assets: [PhotoAsset]) async -> String? {
        do {
            try await AssetMutationService.validateRemovals(assets, sources: sources)
            return nil
        } catch is CancellationError {
            return nil
        } catch AssetAccessError.inaccessible {
            return "At least one photo cannot be moved from its source."
        } catch AssetAccessError.changedDuringScan {
            return CleanupError.changedAsset.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    init() {
        let data = URL.applicationSupportDirectory.appending(path: "AlbumWinnow", directoryHint: .isDirectory)
        do {
            engine = try ScanEngine(cacheURL: data.appending(path: "scan.sqlite"))
        } catch {
            engine = nil
            errorMessage = error.localizedDescription
        }
        do {
            for name in ["cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"] {
                let legacyHistory = data.appending(path: name)
                if FileManager.default.fileExists(atPath: legacyHistory.path) {
                    try FileManager.default.removeItem(at: legacyHistory)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        let defaults = UserDefaults.standard
        photosEnabled = defaults.bool(forKey: Self.photosKey)
        let bookmarks = defaults.array(forKey: Self.folderKey) as? [Data] ?? []
        for bookmark in bookmarks {
            do {
                let folder = try FolderScope(bookmark: bookmark)
                if !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }
            } catch {
                errorMessage = "A saved folder is unavailable. Select it again to restore access."
            }
        }
        if !bookmarks.isEmpty { saveFolders() }
        watchLibrary()
    }

    func addFolder(_ url: URL) {
        guard canEditSources else { return }
        do {
            let folder = try FolderScope(url: url)
            guard !folders.contains(where: { $0.id == folder.id }) else { return }
            folders.append(folder)
            saveFolders()
            invalidateResults()
        } catch {
            sourceErrorMessage = error.localizedDescription
        }
    }

    func removeFolder(_ id: String) {
        guard canEditSources else { return }
        folders.removeAll { $0.id == id }
        saveFolders()
        invalidateResults()
    }

    func setPhotosEnabled(_ enabled: Bool) async {
        guard canEditSources else { return }
        if enabled && authorization == .notDetermined {
            authorization = await PhotoLibrarySource.requestAuthorization()
        } else {
            authorization = PhotoLibrarySource.authorizationStatus()
        }
        guard canEditSources else { return }
        photosEnabled = enabled && allowsPhotos
        if enabled && !allowsPhotos {
            sourceErrorMessage = "Allow access to Photos in System Settings to include the photo library."
        }
        UserDefaults.standard.set(photosEnabled, forKey: Self.photosKey)
        invalidateResults()
        watchLibrary()
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active {
            refreshAuthorization()
            #if os(iOS)
            inForeground = true
            resumeInterruptedScan()
            #endif
        }
        #if os(iOS)
        if phase == .background {
            inForeground = false
            scanTask?.cancel()
        }
        #endif
    }

    private func refreshAuthorization() {
        let latest = PhotoLibrarySource.authorizationStatus()
        guard latest != authorization else { return }
        authorization = latest
        if photosEnabled { invalidateResults() }
        watchLibrary()
    }

    func scan() { startScan(downloads: []) }

    func downloadPendingPhotos() {
        let pending = pendingDownloadIDs
        guard !pending.isEmpty, photosEnabled, allowsPhotos else { return }
        startScan(downloads: pending)
    }

    private var pendingDownloadIDs: Set<AssetID> {
        Set((result?.issues ?? []).filter {
            $0.id.source == photoSource.id && ($0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
        }.map(\.id))
    }

    func startScan(downloads: Set<AssetID>) {
        guard canScan, let engine else { return }
        let (downloadUpdates, downloadContinuation) = AsyncStream.makeStream(of: PhotoLibrarySource.DownloadUpdate.self)
        let selectedSources = sources.map { source -> any AssetSource in
            guard source.id == photoSource.id, !downloads.isEmpty else { return source }
            return PhotoLibrarySource(downloads: downloads) { update in downloadContinuation.yield(update) }
        }
        #if os(iOS)
        UserDefaults.standard.set(true, forKey: Self.interruptedScanKey)
        UserDefaults.standard.set(downloads.map(\.item).sorted(), forKey: Self.interruptedDownloadsKey)
        #endif
        running = true
        libraryChangedDuringScan = false
        selections.removeAll()
        resultsStale = false
        lastCleanup = nil
        downloadProgress = downloads.isEmpty ? nil : CloudDownloadProgress(total: downloads.count)
        if downloads.isEmpty { result = nil }
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task {
            let observer = Task {
                for await update in updates { progress = update }
            }
            let downloadObserver = Task {
                for await update in downloadUpdates {
                    downloadProgress?.update(update)
                    #if os(iOS)
                    if case let .finished(id, true) = update {
                        let remaining = UserDefaults.standard.stringArray(forKey: Self.interruptedDownloadsKey) ?? []
                        UserDefaults.standard.set(remaining.filter { $0 != id.item }, forKey: Self.interruptedDownloadsKey)
                    }
                    #endif
                }
            }
            defer {
                continuation.finish()
                observer.cancel()
                running = false
                progress = nil
                scanTask = nil
                #if os(iOS)
                resumeInterruptedScan()
                #endif
            }
            do {
                let next = try await engine.scan(selectedSources, refreshing: downloads) { continuation.yield($0) }
                try Task.checkCancellation()
                result = next
                resultsStale = libraryChangedDuringScan
                if resultsStale { errorMessage = "The photo library changed during the scan. Scan again before cleanup." }
                clearInterruptedScan()
            } catch is CancellationError {
                // A user cancellation keeps the previous scan issues available for retry.
            } catch {
                clearInterruptedScan()
                resultsStale = result != nil
                errorMessage = error.localizedDescription
            }
            downloadContinuation.finish()
            await downloadObserver.value
            downloadProgress?.end(cancelled: Task.isCancelled)
            let unavailable = result?.issues.contains {
                downloads.contains($0.id) && ($0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
            } == true
            if let download = downloadProgress, !download.cancelled, download.needsRetry || unavailable, errorMessage == nil {
                errorMessage = "Some iCloud photos are still unavailable for this scan. Open Scan Issues to review the results and retry."
            }
        }
    }

    func cancelScan() {
        clearInterruptedScan()
        scanTask?.cancel()
    }

    private func clearInterruptedScan() {
        #if os(iOS)
        UserDefaults.standard.removeObject(forKey: Self.interruptedScanKey)
        UserDefaults.standard.removeObject(forKey: Self.interruptedDownloadsKey)
        #endif
    }

    #if os(iOS)
    private func resumeInterruptedScan() {
        guard inForeground, canScan, UserDefaults.standard.bool(forKey: Self.interruptedScanKey) else { return }
        let items = UserDefaults.standard.stringArray(forKey: Self.interruptedDownloadsKey) ?? []
        let downloads = photosEnabled && allowsPhotos ? Set(items.map { AssetID(source: photoSource.id, item: $0) }) : []
        startScan(downloads: downloads)
    }
    #endif

    func applyCleanup(_ pairs: [CleanupPair]) async {
        guard canClean, !pairs.isEmpty, pairs == cleanupGroups.flatMap(\.pairs) else { return }
        cleaning = true
        defer { cleaning = false }
        do {
            lastCleanup = try await cleanup.apply(pairs, sources: sources)
            invalidateResults()
        } catch {
            invalidateResults()
            errorMessage = error.localizedDescription
        }
    }

    func image(for asset: PhotoAsset) async throws -> AssetImage {
        guard let source = sources.first(where: { $0.id == asset.id.source }) else {
            throw CleanupError.unavailableSource
        }
        return try await source.image(for: asset)
    }

    func thumbnail(for asset: PhotoAsset, pixelSize: Int) async throws -> CGImage {
        let key = GalleryThumbnailKey(asset: asset, pixelSize: pixelSize)
        if asset.id.source == photoSource.id, photosEnabled, allowsPhotos {
            let source = photoSource
            return try await galleryThumbnails.image(for: key) {
                try await source.thumbnail(for: asset, maxPixelSize: pixelSize)
            }
        }
        guard let folder = folders.first(where: { $0.id == asset.id.source }) else {
            throw AssetAccessError.inaccessible
        }
        defer { withExtendedLifetime(folder) {} }
        let source = folder.source
        return try await galleryThumbnails.image(for: key) {
            try await source.thumbnail(for: asset, maxPixelSize: pixelSize)
        }
    }

    func sourceLabel(_ id: String) -> String {
        if id == photoSource.id { return "Photos" }
        return folders.first(where: { $0.id == id })?.name ?? "Folder"
    }

    private var sources: [any AssetSource] {
        var selected: [any AssetSource] = folders.map(\.source)
        if photosEnabled && allowsPhotos { selected.append(photoSource) }
        return selected
    }

    private func invalidateResults() {
        if result != nil || running { resultsStale = true }
        selections.removeAll()
        result = nil
        Task { await galleryThumbnails.clear() }
        scanTask?.cancel()
    }

    func libraryDidChange() {
        if running {
            libraryChangedDuringScan = true
            resultsStale = true
        } else {
            invalidateResults()
        }
    }

    private func watchLibrary() {
        libraryTask?.cancel()
        guard photosEnabled && allowsPhotos else { return }
        libraryTask = Task { [weak self, photoSource] in
            for await _ in photoSource.changes() {
                guard let self, !Task.isCancelled else { return }
                libraryDidChange()
            }
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.folderKey)
    }
}
