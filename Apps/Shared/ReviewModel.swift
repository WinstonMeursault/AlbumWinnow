import AlbumWinnowCore
import Foundation
import Photos
import SwiftUI

@MainActor @Observable final class ReviewModel {
    private static let folderKey = "AlbumWinnow.folderBookmarks"
    private static let photosKey = "AlbumWinnow.photosEnabled"
    private static let interruptedScanKey = "AlbumWinnow.interruptedScan"

    private(set) var folders: [FolderScope] = []
    private(set) var photosEnabled = false
    private(set) var authorization = PhotoLibrarySource.authorizationStatus()
    private(set) var result: ScanResult?
    private(set) var progress: ScanProgress?
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var resultsStale = false
    private(set) var history: [CleanupRun] = []
    var errorMessage: String?

    private let photoSource = PhotoLibrarySource()
    private let engine: ScanEngine?
    private let cleanup: AssetMutationService?
    private var scanTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    #if os(iOS)
    private var inForeground = false
    #endif

    var allowsPhotos: Bool { authorization == .authorized || authorization == .limited }
    var canScan: Bool { !running && !cleaning && !sources.isEmpty && engine != nil }
    var canClean: Bool { !running && !cleaning && !resultsStale && cleanup != nil }
    var hasPendingDownloads: Bool { !pendingDownloads.isEmpty }

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
        do {
            let folder = try FolderScope(url: url)
            guard !folders.contains(where: { $0.id == folder.id }) else { return }
            folders.append(folder)
            saveFolders()
            invalidateResults()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        saveFolders()
        invalidateResults()
    }

    func setPhotosEnabled(_ enabled: Bool) async {
        if enabled && authorization == .notDetermined {
            authorization = await PhotoLibrarySource.requestAuthorization()
        } else {
            authorization = PhotoLibrarySource.authorizationStatus()
        }
        photosEnabled = enabled && allowsPhotos
        if enabled && !allowsPhotos {
            errorMessage = "Allow access to Photos in System Settings to include the photo library."
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
        guard !pendingDownloads.isEmpty else { return }
        startScan(downloads: pendingDownloads)
    }

    private var pendingDownloads: Set<AssetID> {
        Set((result?.issues ?? []).filter {
            $0.id.source == photoSource.id && ($0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
        }.map(\.id))
    }

    private func startScan(downloads: Set<AssetID>) {
        guard canScan, let engine else { return }
        let selectedSources = sources.map { source -> any AssetSource in
            source.id == photoSource.id && !downloads.isEmpty ? PhotoLibrarySource(downloads: downloads) : source
        }
        #if os(iOS)
        UserDefaults.standard.set(true, forKey: Self.interruptedScanKey)
        #endif
        running = true
        resultsStale = false
        if downloads.isEmpty { result = nil }
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task {
            let observer = Task {
                for await update in updates { progress = update }
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
                return
            } catch {
                clearInterruptedScan()
                errorMessage = error.localizedDescription
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
            _ = try await cleanup.apply(pairs, sources: sources)
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
