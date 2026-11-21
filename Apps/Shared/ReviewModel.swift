import AlbumWinnowCore
import CoreGraphics
import Foundation
import Photos
import SwiftUI

struct CloudDownloadProgress {
    private(set) var total: Int
    private(set) var available = 0
    private(set) var failed = 0
    private(set) var ended = false
    private(set) var cancelled = false
    private var active: [AssetID: Double] = [:]
    private var finished: [AssetID: Bool] = [:]

    init(total: Int) { self.total = total }

    var remaining: Int { total - available - failed }
    var needsRetry: Bool { failed > 0 || remaining > 0 }
    var processed: Double { Double(available + failed) + active.values.reduce(0, +) }

    mutating func update(_ update: PhotoLibrarySource.DownloadUpdate) {
        guard !ended else { return }
        switch update {
        case let .enumerated(ids):
            total = max(total, Set(ids).count)
        case let .transferring(id, fraction):
            guard finished[id] == nil, fraction.isFinite else { return }
            active[id] = max(active[id, default: 0], min(0.99, fraction))
        case let .finished(id, isAvailable):
            if let previous = finished.updateValue(isAvailable, forKey: id) {
                if previous { available -= 1 } else { failed -= 1 }
            }
            active.removeValue(forKey: id)
            if isAvailable { available += 1 } else { failed += 1 }
        }
    }

    mutating func reconcile(issues: [AssetIssue], requested: Set<AssetID>) {
        for issue in issues where requested.contains(issue.id) &&
            (issue.reason == .cloudDownloadRequired || issue.reason == .cloudDownloadFailed) {
            update(.finished(issue.id, available: false))
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
    static let skipCloudKey = "AlbumWinnow.skipCloud"
    static let showReviewFilenamesKey = "AlbumWinnow.showReviewFilenames"

    struct GroupSelection {
        var keepID: AssetID?
        var selected = Set<AssetID>()
        var deleteAll = false
    }

    struct CleanupGroup: Identifiable {
        let id: AssetID
        let keep: PhotoAsset?
        let retained: [PhotoAsset]
        let pairs: [CleanupPair]
        let match: DuplicateMatch
    }

    private static let folderKey = "AlbumWinnow.folderBookmarks"
    private static let photosKey = "AlbumWinnow.photosEnabled"
    private static let interruptedScanKey = "AlbumWinnow.interruptedScan"
    private static let interruptedCloudPolicyKey = "AlbumWinnow.interruptedCloudPolicy"
    private static let interruptedDownloadsKey = "AlbumWinnow.interruptedDownloads"

    private(set) var folders: [FolderScope] = []
    private(set) var photosEnabled = false
    private(set) var authorization = PhotoLibrarySource.authorizationStatus()
    private(set) var result: ScanResult?
    private(set) var scanAccounting: ScanAccounting?
    private(set) var scanCancelled = false
    private(set) var progress: ScanProgress?
    private(set) var downloadProgress: CloudDownloadProgress?
    private(set) var lastCleanup: [CleanupItem]?
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var clearingCache = false
    private(set) var cacheStatus: String?
    private(set) var resultsStale = false
    private(set) var reviewNotice: String?
    private(set) var reviewState = ReviewState()
    private(set) var protectionAvailable = false
    private(set) var skipCloudPhotos = true
    private var stateStore: ReviewStateStore?
    private var restoreRequested = false
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
    var canEditSources: Bool { !running && !cleaning && !clearingCache }
    var canScan: Bool { canEditSources && hasScanSources && engine != nil }
    var canClean: Bool { protectionAvailable && canEditSources && !resultsStale && result != nil }
    var protection: CleanupProtection { CleanupProtection(locked: reviewState.locked, available: protectionAvailable, lockedRevisions: reviewState.lockedRevisions ?? [:]) }
    var pendingDownloadCount: Int { pendingDownloadIDs.count }
    var selectedCount: Int { selections.values.reduce(0) { $0 + $1.selected.count } }
    var cleanupGroups: [CleanupGroup] {
        guard selectedCount > 0, let result else { return [] }
        return result.groups.compactMap { group in
            guard let selection = selections[group.id], !selection.selected.isEmpty else { return nil }
            let assets = [group.preferred] + group.duplicates.map(\.asset)
            if selection.deleteAll {
                guard assets.allSatisfy({ !isProtected($0) }) else { return nil }
                let pairs = assets.map { CleanupPair(remove: $0, fromWholeGroup: group.id) }
                return CleanupGroup(id: group.id, keep: nil, retained: [], pairs: pairs, match: group.match)
            }
            let keep = assets.first(where: { $0.id == selection.keepID }) ?? group.preferred
            let pairs = assets.compactMap { asset -> CleanupPair? in
                guard selection.selected.contains(asset.id), asset.id != keep.id,
                      !isProtected(asset) else { return nil }
                return CleanupPair(keep: keep, remove: asset)
            }
            return pairs.isEmpty ? nil : CleanupGroup(id: group.id, keep: keep, retained: assets.filter { !selection.selected.contains($0.id) || isProtected($0) }, pairs: pairs, match: group.match)
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
            let removable = assets.filter { $0.id != keepID && !isProtected($0) }
            selections[group.id] = GroupSelection(keepID: keepID, selected: Set(removable.map(\.id)))
        }
        guard let selection = selections[group.id] else { return false }
        var state = reviewState
        do {
            state.decisions[try group.reviewSignature()] = ReviewDecision(status: .confirmed,
                keepID: selection.keepID, removals: selection.selected, deleteAll: selection.deleteAll, members: assets)
        } catch { errorMessage = error.localizedDescription; return false }
        guard saveState(state) else { selections.removeValue(forKey: group.id); return false }
        return true
    }

    func deleteAllUnavailableReason(for assets: [PhotoAsset]) async -> String? {
        do {
            try await AssetMutationService.validateRemovals(assets, sources: sources, protection: protection)
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

    init(dataDirectory: URL? = nil) {
        let data = dataDirectory ?? URL.applicationSupportDirectory.appending(path: "AlbumWinnow", directoryHint: .isDirectory)
        do {
            let store = try ReviewStateStore(url: data.appending(path: "review.sqlite"))
            let saved = try store.load()
            reviewState = saved
            stateStore = store
            protectionAvailable = true
            restoreRequested = !saved.decisions.isEmpty || saved.anchor != nil
        } catch {
            errorMessage = "Protection could not be loaded. Cleanup is disabled. \(error.localizedDescription)"
        }
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
        skipCloudPhotos = defaults.object(forKey: Self.skipCloudKey) as? Bool ?? true
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
            if restoreRequested, canScan { scan() }
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

    func setSkipCloudPhotos(_ skip: Bool) {
        guard canEditSources else { return }
        skipCloudPhotos = skip
        UserDefaults.standard.set(skip, forKey: Self.skipCloudKey)
        invalidateResults()
    }

    func clearScanCache() async {
        guard canEditSources, let engine else { return }
        clearingCache = true
        cacheStatus = nil
        defer { clearingCache = false }
        do {
            try await engine.clearCache()
            invalidateResults()
            lastCleanup = nil
            downloadProgress = nil
            cacheStatus = "Scan cache cleared. The next scan will read all photos again."
        } catch {
            sourceErrorMessage = error.localizedDescription
        }
    }

    func downloadPendingPhotos() {
        let pending = pendingDownloadIDs
        guard !pending.isEmpty, photosEnabled, allowsPhotos else { return }
        startScan(downloads: pending)
    }

    private var pendingDownloadIDs: Set<AssetID> {
        Set((result?.issues ?? []).filter {
            $0.id.source == photoSource.id && ($0.reason == .cloudSkipped || $0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
        }.map(\.id))
    }

    func startScan(downloads: Set<AssetID>, allowsDownloads: Bool? = nil) {
        let allowsDownloads = allowsDownloads ?? !skipCloudPhotos
        guard canScan, let engine else { return }
        let (downloadUpdates, downloadContinuation) = AsyncStream.makeStream(of: PhotoLibrarySource.DownloadUpdate.self)
        let selectedSources = sources.map { source -> any AssetSource in
            guard source.id == photoSource.id else { return source }
            return PhotoLibrarySource(downloads: downloads, allowsDownloads: allowsDownloads) { update in downloadContinuation.yield(update) }
        }
        #if os(iOS)
        UserDefaults.standard.set(allowsDownloads, forKey: Self.interruptedCloudPolicyKey)
        UserDefaults.standard.set(true, forKey: Self.interruptedScanKey)
        UserDefaults.standard.set(downloads.map(\.item).sorted(), forKey: Self.interruptedDownloadsKey)
        #endif
        restoreRequested = false
        running = true
        scanAccounting = nil
        reviewNotice = nil
        scanCancelled = false
        libraryChangedDuringScan = false
        selections.removeAll()
        lastCleanup = nil
        downloadProgress = downloads.isEmpty && !allowsDownloads ? nil : CloudDownloadProgress(total: downloads.count)
        if downloads.isEmpty {
            result = nil
            resultsStale = false
        }
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let (accountUpdates, accountContinuation) = AsyncStream.makeStream(of: ScanAccounting.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task {
            let accountObserver = Task {
                for await update in accountUpdates { scanAccounting = update }
            }
            let observer = Task {
                for await update in updates { progress = update }
            }
            let downloadObserver = Task {
                for await update in downloadUpdates {
                    downloadProgress?.update(update)
                    #if os(iOS)
                    if case let .finished(id, available) = update,
                       UserDefaults.standard.bool(forKey: Self.interruptedScanKey) {
                        var remaining = Set(UserDefaults.standard.stringArray(forKey: Self.interruptedDownloadsKey) ?? [])
                        if available { remaining.remove(id.item) } else { remaining.insert(id.item) }
                        UserDefaults.standard.set(remaining.sorted(), forKey: Self.interruptedDownloadsKey)
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
            var downloadIssues: [AssetIssue] = []
            do {
                let next = try await engine.scan(selectedSources, refreshing: downloads, progress: { continuation.yield($0) }, accounting: { accountContinuation.yield($0) })
                try Task.checkCancellation()
                result = next
                restoreDecisions(next.groups)
                downloadIssues = next.issues
                resultsStale = libraryChangedDuringScan
                if resultsStale { errorMessage = "The photo library changed during the scan. Scan again before cleanup." }
                clearInterruptedScan()
            } catch is CancellationError {
                scanCancelled = true
                // A user cancellation keeps the previous scan issues available for retry.
            } catch {
                clearInterruptedScan()
                resultsStale = result != nil
                errorMessage = error.localizedDescription
            }
            accountContinuation.finish()
            await accountObserver.value
            downloadContinuation.finish()
            await downloadObserver.value
            downloadProgress?.reconcile(issues: downloadIssues, requested: downloads)
            downloadProgress?.end(cancelled: Task.isCancelled)
            if let download = downloadProgress, !download.cancelled, download.needsRetry, errorMessage == nil {
                errorMessage = "Some iCloud photos are still unavailable for this scan. Open Scan Issues to review the results and retry."
            }
        }
    }

    func cancelScan() {
        restoreRequested = false
        clearInterruptedScan()
        scanTask?.cancel()
    }

    private func clearInterruptedScan() {
        #if os(iOS)
        UserDefaults.standard.removeObject(forKey: Self.interruptedCloudPolicyKey)
        UserDefaults.standard.removeObject(forKey: Self.interruptedScanKey)
        UserDefaults.standard.removeObject(forKey: Self.interruptedDownloadsKey)
        #endif
    }

    #if os(iOS)
    private func resumeInterruptedScan() {
        guard inForeground, canScan, UserDefaults.standard.bool(forKey: Self.interruptedScanKey) else { return }
        let items = UserDefaults.standard.stringArray(forKey: Self.interruptedDownloadsKey) ?? []
        let downloads = photosEnabled && allowsPhotos ? Set(items.map { AssetID(source: photoSource.id, item: $0) }) : []
        startScan(downloads: downloads, allowsDownloads: UserDefaults.standard.bool(forKey: Self.interruptedCloudPolicyKey))
    }
    #endif

    func applyCleanup(_ pairs: [CleanupPair]) async {
        guard canClean, !pairs.isEmpty, pairs == cleanupGroups.flatMap(\.pairs) else { return }
        cleaning = true
        defer { cleaning = false }
        do {
            lastCleanup = try await cleanup.apply(pairs, sources: sources, protection: protection)
            let moved = Set((lastCleanup ?? []).filter { $0.status == .movedToTrash || $0.status == .movedToRecentlyDeleted }.map(\.id))
            var state = reviewState
            for group in result?.groups ?? [] {
                let ids = Set(([group.preferred] + group.duplicates.map(\.asset)).map(\.id))
                if !ids.isDisjoint(with: moved), let signature = try? group.reviewSignature() {
                    state.decisions.removeValue(forKey: signature)
                }
            }
            _ = saveState(state)
            if moved.isEmpty { restoreDecisions(result?.groups ?? []) }
            else { invalidateResults() }
        } catch {
            invalidateResults()
            errorMessage = error.localizedDescription
        }
    }

    func preview(for asset: PhotoAsset) async throws -> LoadedPreview {
        guard let source = sources.first(where: { $0.id == asset.id.source }) else {
            throw CleanupError.unavailableSource
        }
        let folder = folders.first { $0.id == asset.id.source }
        defer { withExtendedLifetime(folder) {} }
        let bytes: Int
        if let files = source as? FileSystemSource {
            bytes = try await files.byteCount(for: asset)
        } else {
            // Photos does not expose a reliable original size before requesting the data.
            bytes = 64 * 1024 * 1024
        }
        return try await galleryThumbnails.preview(estimatedBytes: bytes) {
            if let files = source as? FileSystemSource {
                let url = try files.currentURL(for: asset)
                let preview = try await LoadedPreview.load(asset: asset, file: url)
                _ = try files.currentURL(for: asset)
                return preview
            }
            return await LoadedPreview.load(asset: asset, input: try await source.image(for: asset))
        }
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


    func status(for group: DuplicateGroup) -> ReviewStatus {
        guard let signature = try? group.reviewSignature() else { return .pending }
        guard let decision = reviewState.decisions[signature], decision.invalidated != true else { return .pending }
        return decision.status
    }

    func isLocked(_ asset: PhotoAsset) -> Bool {
        !CleanupProtection(locked: reviewState.locked, lockedRevisions: reviewState.lockedRevisions ?? [:]).validateForReview(asset)
    }

    func isProtected(_ asset: PhotoAsset) -> Bool {
        asset.photoProperties?.hasAssociatedResources == true || isLocked(asset)
    }

    @discardableResult
    private func saveState(_ state: ReviewState) -> Bool {
        do {
            guard let stateStore else { throw CleanupError.unavailableProtection }
            try stateStore.save(state)
            reviewState = state
            return true
        } catch {
            protectionAvailable = false
            errorMessage = "This decision was not saved. Cleanup is disabled. \(error.localizedDescription)"
            return false
        }
    }

    func setLocked(_ asset: PhotoAsset, locked: Bool) {
        guard canEditSources, protectionAvailable else { return }
        var state = reviewState
        var revisions = state.lockedRevisions ?? [:]
        if locked {
            state.locked.insert(asset.id)
            revisions[asset.id] = asset.revision
        } else {
            state.locked.remove(asset.id)
            revisions.removeValue(forKey: asset.id)
        }
        state.lockedRevisions = revisions
        let nextProtection = CleanupProtection(locked: state.locked, lockedRevisions: revisions)
        if locked, let groups = result?.groups {
            for group in groups {
                let assets = [group.preferred] + group.duplicates.map(\.asset)
                guard let signature = try? group.reviewSignature(), var decision = state.decisions[signature] else { continue }
                if decision.deleteAll, assets.contains(where: { !nextProtection.validateForReview($0) }) {
                    decision = ReviewDecision(status: .pending)
                } else {
                    decision.removals = Set(assets.filter {
                        decision.removals.contains($0.id) && nextProtection.validateForReview($0)
                    }.map(\.id))
                }
                state.decisions[signature] = decision
            }
        }
        if saveState(state) { restoreDecisions(result?.groups ?? []) }
    }

    func setStatus(_ status: ReviewStatus, for group: DuplicateGroup) {
        guard canClean, let signature = try? group.reviewSignature() else { return }
        var state = reviewState
        var decision = state.decisions[signature].flatMap { $0.invalidated == true ? nil : $0 } ?? ReviewDecision(status: status)
        decision.status = status
        let assets = [group.preferred] + group.duplicates.map(\.asset)
        if status == .kept || status == .pending { decision = ReviewDecision(status: status) }
        decision.members = assets
        decision.invalidated = false
        state.decisions[signature] = decision
        if saveState(state) { restoreDecisions(result?.groups ?? []) }
    }

    func resetReviewProgress() {
        guard canEditSources, protectionAvailable else { return }
        var state = reviewState
        state.resetProgress()
        if saveState(state) { selections.removeAll(); reviewNotice = nil }
    }

    func rememberPosition(_ group: DuplicateGroup) {
        guard !cleaning, protectionAvailable, let signature = try? group.reviewSignature(),
              signature != reviewState.anchor else { return }
        var state = reviewState
        state.anchor = signature
        state.anchorIndex = result?.groups.firstIndex { $0.id == group.id }
        _ = saveState(state)
    }

    var resumeGroup: DuplicateGroup? {
        let groups = result?.groups ?? []
        if let anchor = groups.first(where: { (try? $0.reviewSignature()) == reviewState.anchor && status(for: $0) != .kept }) {
            return anchor
        }
        let pending = groups.enumerated().filter { status(for: $0.element) == .pending || status(for: $0.element) == .deferred }
        return pending.first { $0.offset >= (reviewState.anchorIndex ?? 0) }?.element ?? pending.first?.element
    }

    private func restoreDecisions(_ groups: [DuplicateGroup]) {
        selections.removeAll()
        guard protectionAvailable else { return }
        let signatures = Set(groups.compactMap { try? $0.reviewSignature() })
        let currentIDs = Set(groups.flatMap { [$0.preferred.id] + $0.duplicates.map(\.id) })
        var state = reviewState
        for (signature, decision) in state.decisions where !signatures.contains(signature) && decision.invalidated != true {
            if let members = decision.members, members.contains(where: { currentIDs.contains($0.id) }) {
                state.decisions[signature]?.invalidated = true
            }
        }
        if state != reviewState {
            guard saveState(state) else { return }
            reviewNotice = "Photos or group evidence changed. Affected decisions need review again; locks remain protected."
        }
        for group in groups {
            guard let signature = try? group.reviewSignature(), let decision = reviewState.decisions[signature],
                  decision.invalidated != true else { continue }
            let assets = [group.preferred] + group.duplicates.map(\.asset)
            let ids = Set(assets.map(\.id))
            guard decision.removals.isSubset(of: ids) else { continue }
            if decision.deleteAll {
                guard decision.removals == ids, assets.allSatisfy({ !isProtected($0) }) else { continue }
            } else {
                guard let keepID = decision.keepID, ids.contains(keepID), !decision.removals.contains(keepID) else { continue }
            }
            let removals = Set(assets.filter { decision.removals.contains($0.id) && !isProtected($0) }.map(\.id))
            selections[group.id] = GroupSelection(keepID: decision.keepID, selected: removals, deleteAll: decision.deleteAll)
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.folderKey)
    }
}


extension ReviewStatus {
    var title: String {
        switch self {
        case .pending: String(localized: "Needs Review")
        case .deferred: String(localized: "Later")
        case .confirmed: String(localized: "Confirmed")
        case .kept: String(localized: "Entire Group Kept")
        }
    }
}
