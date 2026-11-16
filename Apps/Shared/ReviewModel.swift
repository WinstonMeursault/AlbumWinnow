import AlbumWinnowCore
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
    private static let folderKey = "AlbumWinnow.folderBookmarks"
    private static let photosKey = "AlbumWinnow.photosEnabled"
    private static let interruptedScanKey = "AlbumWinnow.interruptedScan"

    private(set) var folders: [FolderScope] = []
    private(set) var photosEnabled = false
    private(set) var authorization = PhotoLibrarySource.authorizationStatus()
    private(set) var result: ScanResult?
    private(set) var progress: ScanProgress?
    private(set) var downloadProgress: CloudDownloadProgress?
    private(set) var lastCleanup: CleanupRun?
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var resultsStale = false
    private(set) var history: [CleanupRun] = []
    var errorMessage: String?
    var sourceErrorMessage: String?

    private let photoSource = PhotoLibrarySource()
    private let engine: ScanEngine?
    private let cleanup: AssetMutationService?
    private var scanTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    #if os(iOS)
    private var inForeground = false
    #endif

    var allowsPhotos: Bool { authorization == .authorized || authorization == .limited }
    var hasScanSources: Bool { !folders.isEmpty || (photosEnabled && allowsPhotos) }
    var canEditSources: Bool { !running && !cleaning }
    var canScan: Bool { canEditSources && hasScanSources && engine != nil }
    var canClean: Bool { !running && !cleaning && !resultsStale && cleanup != nil }
    var pendingDownloadCount: Int { pendingDownloadIDs.count }

    init() {
        let data = URL.applicationSupportDirectory.appending(path: "AlbumWinnow", directoryHint: .isDirectory)
        do {
            engine = try ScanEngine(cacheURL: data.appending(path: "scan.sqlite"))
        } catch {
            engine = nil
            errorMessage = error.localizedDescription
        }
        do {
            cleanup = try AssetMutationService(journalURL: data.appending(path: "cleanup.sqlite"))
        } catch {
            cleanup = nil
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

    private func startScan(downloads: Set<AssetID>) {
        guard canScan, let engine else { return }
        let (downloadUpdates, downloadContinuation) = AsyncStream.makeStream(of: PhotoLibrarySource.DownloadUpdate.self)
        let selectedSources = sources.map { source -> any AssetSource in
            guard source.id == photoSource.id, !downloads.isEmpty else { return source }
            return PhotoLibrarySource(downloads: downloads) { update in downloadContinuation.yield(update) }
        }
        #if os(iOS)
        UserDefaults.standard.set(true, forKey: Self.interruptedScanKey)
        #endif
        running = true
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
                for await update in downloadUpdates { downloadProgress?.update(update) }
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
                let next = try await engine.scan(selectedSources) { continuation.yield($0) }
                try Task.checkCancellation()
                result = next
                clearInterruptedScan()
            } catch is CancellationError {
                // A user cancellation keeps the previous scan issues available for retry.
            } catch {
                clearInterruptedScan()
                errorMessage = error.localizedDescription
            }
            downloadContinuation.finish()
            await downloadObserver.value
            downloadProgress?.end(cancelled: Task.isCancelled)
        }
    }

    func cancelScan() {
        clearInterruptedScan()
        scanTask?.cancel()
    }

    private func clearInterruptedScan() {
        #if os(iOS)
        UserDefaults.standard.removeObject(forKey: Self.interruptedScanKey)
        #endif
    }

    #if os(iOS)
    private func resumeInterruptedScan() {
        guard inForeground, canScan, UserDefaults.standard.bool(forKey: Self.interruptedScanKey) else { return }
        scan()
    }
    #endif

    func applyCleanup(_ pairs: [CleanupPair]) async {
        guard canClean, let cleanup else { return }
        cleaning = true
        defer { cleaning = false }
        do {
            lastCleanup = try await cleanup.apply(pairs, sources: sources)
            invalidateResults()
            history = try await cleanup.recentRuns()
        } catch {
            invalidateResults()
            errorMessage = error.localizedDescription
        }
    }

    func loadHistory() async {
        do {
            history = try await cleanup?.recentRuns() ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func image(for asset: PhotoAsset) async throws -> AssetImage {
        guard let source = sources.first(where: { $0.id == asset.id.source }) else {
            throw CleanupError.unavailableSource
        }
        return try await source.image(for: asset)
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
        result = nil
        scanTask?.cancel()
    }

    private func watchLibrary() {
        libraryTask?.cancel()
        guard photosEnabled && allowsPhotos else { return }
        libraryTask = Task { [weak self, photoSource] in
            for await _ in photoSource.changes() {
                guard let self, !Task.isCancelled else { return }
                invalidateResults()
            }
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.folderKey)
    }
}
