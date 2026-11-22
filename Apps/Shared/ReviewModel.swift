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
    private(set) var updatingPolicy = false
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var clearingCache = false
    private(set) var cacheStatus: String?
    private(set) var resultsStale = false
    private(set) var reviewNotice: String?
    private(set) var reviewState = ReviewState()
    private(set) var protectionAvailable = false
    private(set) var skipCloudPhotos = true
    private var currentProtection = CleanupProtection(available: false)
    private var stateStore: ReviewStateStore?
    private var restoreRequested = false
    private var selections: [AssetID: GroupSelection] = [:]
    private var groupSignatures: [AssetID: String] = [:]
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
    var canEditSources: Bool { !updatingPolicy && !running && !cleaning && !clearingCache }
    var canScan: Bool { canEditSources && hasScanSources && engine != nil }
    var canClean: Bool { protectionAvailable && canEditSources && !resultsStale && result != nil }
    var protection: CleanupProtection { protectionAvailable ? currentProtection : CleanupProtection(available: false) }
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
            let pairs = group.removalPairs(keeping: keep.id, protection: protection)
                .filter { selection.selected.contains($0.remove.id) }
            let removing = Set(pairs.map { $0.remove.id })
            return pairs.isEmpty ? nil : CleanupGroup(id: group.id, keep: keep, retained: assets.filter { !removing.contains($0.id) }, pairs: pairs, match: group.match)
        }
    }

    var resultQuery: ReviewResultQuery { reviewState.resultQuery ?? ReviewResultQuery() }

    func setResultQuery(_ query: ReviewResultQuery) {
        guard canEditSources else { return }
        var state = reviewState
        state.resultQuery = query
        _ = saveState(state)
    }

    func estimatedRemovals(for group: DuplicateGroup) -> Set<AssetID> {
        if status(for: group) == .kept { return [] }
        if let selection = selections[group.id] {
            return Set(group.assets.filter { selection.selected.contains($0.id) && !isProtected($0) }.map(\.id))
        }
        guard group.hasQualityRecommendation != false else { return [] }
        return Set(group.removalPairs(keeping: group.recommendation.id, protection: protection).map { $0.remove.id })
    }

    var collectionGroups: [DuplicateGroup] {
        (result?.groups ?? []).filter { reviewCollection == .similarScenes ? $0.match == .sceneSimilar : $0.match != .sceneSimilar }
    }

    var visibleGroups: [DuplicateGroup] {
        let groups = result?.groups ?? []
        let statuses = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, status(for: $0)) })
        let removals = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, estimatedRemovals(for: $0)) })
        return resultQuery.apply(to: groups, statuses: statuses, removals: removals)
    }

    var hiddenCandidateCount: Int {
        let visible = Set(visibleGroups.map(\.id))
        return cleanupGroups.filter { !visible.contains($0.id) }.reduce(0) { $0 + $1.pairs.count }
    }

    func selection(for groupID: AssetID) -> GroupSelection {
        selections[groupID] ?? GroupSelection()
    }

    func confirmSelection(in group: DuplicateGroup, keepID: AssetID?, deleteAll: Bool) async -> Bool {
        guard canClean, !Task.isCancelled, result?.groups.contains(group) == true else { return false }
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
            let pairs = group.removalPairs(keeping: keepID, protection: protection)
            selections[group.id] = GroupSelection(keepID: keepID, selected: Set(pairs.map { $0.remove.id }))
        }
        guard let selection = selections[group.id] else { return false }
        var state = reviewState
        do {
            state.decisions[try group.reviewSignature()] = ReviewDecision(status: .confirmed,
                keepID: selection.keepID, removals: selection.selected, deleteAll: selection.deleteAll, members: assets, sceneAlgorithm: group.sceneAlgorithm)
        } catch { errorMessage = L10n.error(error); return false }
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
            return L10n.text("app_at_least_one_photo_cannot_be_moved_from_its_source")
        } catch AssetAccessError.changedDuringScan {
            return L10n.error(CleanupError.changedAsset)
        } catch {
            return L10n.error(error)
        }
    }

    init(dataDirectory: URL? = nil) {
        let data = dataDirectory ?? URL.applicationSupportDirectory.appending(path: "AlbumWinnow", directoryHint: .isDirectory)
        do {
            let store = try ReviewStateStore(url: data.appending(path: "review.sqlite"))
            let saved = try store.load()
            reviewState = saved
            currentProtection = Self.makeProtection(saved)
            stateStore = store
            protectionAvailable = true
            restoreRequested = (!saved.decisions.isEmpty || saved.anchor != nil) && saved.scanCancelledByUser != true
        } catch {
            errorMessage = L10n.text("app_protection_could_not_be_loaded_cleanup_is_disabled_arg1", L10n.error(error))
        }
        do {
            engine = try ScanEngine(cacheURL: data.appending(path: "scan.sqlite"))
        } catch {
            engine = nil
            errorMessage = L10n.error(error)
        }
        do {
            for name in ["cleanup.sqlite", "cleanup.sqlite-wal", "cleanup.sqlite-shm"] {
                let legacyHistory = data.appending(path: name)
                if FileManager.default.fileExists(atPath: legacyHistory.path) {
                    try FileManager.default.removeItem(at: legacyHistory)
                }
            }
        } catch {
            errorMessage = L10n.error(error)
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
                errorMessage = L10n.text("app_a_saved_folder_is_unavailable_select_it_again_to_restore_access")
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
            sourceErrorMessage = L10n.error(error)
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
            sourceErrorMessage = L10n.text("app_allow_access_to_photos_in_system_settings_to_include_the_photo_library")
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
            cacheStatus = L10n.text("app_scan_cache_cleared_the_next_scan_will_read_all_photos_again")
        } catch {
            sourceErrorMessage = L10n.error(error)
        }
    }

    func downloadPendingPhotos() {
        let pending = pendingDownloadIDs
        guard !pending.isEmpty, photosEnabled, allowsPhotos else { return }
        startScan(downloads: pending, allowsDownloads: false)
    }

    func downloadAndRescan(_ asset: PhotoAsset) {
        guard asset.id.source == photoSource.id, photosEnabled, allowsPhotos else { return }
        startScan(downloads: [asset.id], allowsDownloads: false)
    }

    private var pendingDownloadIDs: Set<AssetID> {
        Set((result?.issues ?? []).filter {
            $0.id.source == photoSource.id && ($0.reason == .cloudSkipped || $0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
        }.map(\.id))
    }

    func startScan(downloads: Set<AssetID>, allowsDownloads: Bool? = nil) {
        let allowsDownloads = allowsDownloads ?? !skipCloudPhotos
        guard canScan, let engine else { return }
        if reviewState.scanCancelledByUser == true {
            var state = reviewState
            state.scanCancelledByUser = false
            _ = saveState(state)
        }
        let (downloadUpdates, downloadContinuation) = AsyncStream.makeStream(of: PhotoLibrarySource.DownloadUpdate.self)
        let selectedSources = sources.map { source -> any AssetSource in
            guard source.id == photoSource.id else { return source }
            return PhotoLibrarySource(scope: reviewState.photoScope ?? PhotoScope(), includeBurstMembers: similarScenesEnabled, downloads: downloads, allowsDownloads: allowsDownloads) { update in downloadContinuation.yield(update) }
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
        } else if result != nil {
            resultsStale = true
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
                try await refreshReadOnlyRevisions()
                try Task.checkCancellation()
                let next = try await engine.scan(selectedSources, refreshing: downloads,
                    comparisonSides: reviewState.comparisonSides, preferredSource: reviewState.preferredSource, includeSimilarScenes: similarScenesEnabled, progress: { continuation.yield($0) }, accounting: { accountContinuation.yield($0) })
                try Task.checkCancellation()
                groupSignatures = Dictionary(uniqueKeysWithValues: try next.groups.map { ($0.id, try $0.reviewSignature()) })
                result = next
                restoreDecisions(next.groups)
                downloadIssues = next.issues
                resultsStale = libraryChangedDuringScan
                if resultsStale { errorMessage = L10n.text("app_the_photo_library_changed_during_the_scan_scan_again_before_cleanup") }
                clearInterruptedScan()
            } catch is CancellationError {
                scanCancelled = true
                // Saved plans remain visible, but a cancelled supplement cannot validate old results.
                if let result { restoreDecisions(result.groups) }
            } catch {
                clearInterruptedScan()
                resultsStale = result != nil
                errorMessage = L10n.error(error)
            }
            accountContinuation.finish()
            await accountObserver.value
            downloadContinuation.finish()
            await downloadObserver.value
            downloadProgress?.reconcile(issues: downloadIssues, requested: downloads)
            downloadProgress?.end(cancelled: Task.isCancelled)
            if let download = downloadProgress, !download.cancelled, download.needsRetry, errorMessage == nil {
                errorMessage = L10n.text("app_some_icloud_photos_are_still_unavailable_for_this_scan_open_scan_issues_to_review_the_results_and_retry")
            }
        }
    }

    func cancelScan() {
        var state = reviewState
        state.scanCancelledByUser = true
        if protectionAvailable { _ = saveState(state) }
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
                if !ids.isDisjoint(with: moved), let signature = reviewSignature(for: group) {
                    state.decisions.removeValue(forKey: signature)
                }
            }
            _ = saveState(state)
            if moved.isEmpty { restoreDecisions(result?.groups ?? []) }
            else { invalidateResults() }
        } catch {
            invalidateResults()
            errorMessage = L10n.error(error)
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

    func difference(reference: PhotoAsset, comparison: PhotoAsset) async throws -> PhotoDifference {
        guard !running, !cleaning, !resultsStale else { throw AssetAccessError.changedDuringScan }
        guard result?.groups.contains(where: { group in
            group.assets.contains(reference) && group.assets.contains(comparison)
        }) == true else { throw PhotoDifferenceError.invalidPair }
        guard let first = sources.first(where: { $0.id == reference.id.source }),
              let second = sources.first(where: { $0.id == comparison.id.source }) else {
            invalidateResults()
            throw CleanupError.unavailableSource
        }
        let access = folders
        defer { withExtendedLifetime(access) {} }
        do { return try await PhotoDifference.compare(reference, source: first, comparison, source: second) }
        catch let error as AssetAccessError {
            switch error {
            case .changedDuringScan, .inaccessible: invalidateResults()
            default: break
            }
            throw error
        } catch ScopeError.unavailableAlbum {
            invalidateResults()
            throw ScopeError.unavailableAlbum
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
        if id == photoSource.id { return L10n.text("app_photos") }
        return folders.first(where: { $0.id == id })?.name ?? L10n.text("app_folder")
    }

    private var sources: [any AssetSource] {
        var selected: [any AssetSource] = folders.map(\.source)
        if photosEnabled && allowsPhotos { selected.append(PhotoLibrarySource(scope: photoScope, includeBurstMembers: similarScenesEnabled)) }
        return selected
    }

    private func invalidateResults() {
        if result != nil || running { resultsStale = true }
        selections.removeAll()
        result = nil
        groupSignatures.removeAll()
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


    private func reviewSignature(for group: DuplicateGroup) -> String? {
        groupSignatures[group.id] ?? (try? group.reviewSignature())
    }

    func status(for group: DuplicateGroup) -> ReviewStatus {
        guard let signature = reviewSignature(for: group) else { return .pending }
        guard let decision = reviewState.decisions[signature], decision.invalidated != true else { return .pending }
        return decision.status
    }

    func isLocked(_ asset: PhotoAsset) -> Bool {
        !CleanupProtection(locked: reviewState.locked, lockedRevisions: reviewState.lockedRevisions ?? [:]).validateForReview(asset)
    }

    func isReadOnly(_ asset: PhotoAsset) -> Bool { protection.isReadOnly(asset) }

    func isProtected(_ asset: PhotoAsset) -> Bool {
        asset.photoProperties?.hasAssociatedResources == true || !protection.validateForReview(asset)
    }

    private static func makeProtection(_ state: ReviewState) -> CleanupProtection {
        CleanupProtection(locked: state.locked, lockedRevisions: state.lockedRevisions ?? [:],
            readOnlySources: state.readOnlySources ?? [], readOnlyRevisions: state.readOnlyRevisions ?? [:], comparisonSides: state.comparisonSides)
    }

    @discardableResult
    private func saveState(_ state: ReviewState) -> Bool {
        do {
            guard let stateStore else { throw CleanupError.unavailableProtection }
            try stateStore.save(state)
            reviewState = state
            currentProtection = Self.makeProtection(state)
            return true
        } catch {
            protectionAvailable = false
            errorMessage = L10n.text("app_this_decision_was_not_saved_cleanup_is_disabled_arg1", L10n.error(error))
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
        let nextProtection = CleanupProtection(locked: state.locked, lockedRevisions: revisions,
            readOnlySources: state.readOnlySources ?? [], readOnlyRevisions: state.readOnlyRevisions ?? [:], comparisonSides: state.comparisonSides)
        if locked, let groups = result?.groups {
            for group in groups {
                let assets = [group.preferred] + group.duplicates.map(\.asset)
                guard let signature = reviewSignature(for: group), var decision = state.decisions[signature] else { continue }
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
        guard canClean, let signature = reviewSignature(for: group) else { return }
        var state = reviewState
        var decision = state.decisions[signature].flatMap { $0.invalidated == true ? nil : $0 } ?? ReviewDecision(status: status)
        decision.status = status
        decision.sceneAlgorithm = group.sceneAlgorithm
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
        guard !cleaning, protectionAvailable, let signature = reviewSignature(for: group),
              signature != reviewState.anchor else { return }
        var state = reviewState
        state.anchor = signature
        state.anchorIndex = result?.groups.firstIndex { $0.id == group.id }
        _ = saveState(state)
    }

    var resumeGroup: DuplicateGroup? {
        let groups = visibleGroups
        if let anchor = groups.first(where: { reviewSignature(for: $0) == reviewState.anchor && status(for: $0) != .kept }) {
            return anchor
        }
        let pending = groups.enumerated().filter { status(for: $0.element) == .pending || status(for: $0.element) == .deferred }
        return pending.first { $0.offset >= (reviewState.anchorIndex ?? 0) }?.element ?? pending.first?.element
    }

    private func restoreDecisions(_ groups: [DuplicateGroup]) {
        selections.removeAll()
        guard protectionAvailable else { return }
        let signatures = Set(groups.compactMap { reviewSignature(for: $0) })
        let currentIDs = Set(groups.flatMap { [$0.preferred.id] + $0.duplicates.map(\.id) })
        var state = reviewState
        for (signature, decision) in state.decisions where !signatures.contains(signature) && decision.invalidated != true {
            if decision.sceneAlgorithm != nil && !similarScenesEnabled { continue }
            if let members = decision.members, members.contains(where: { currentIDs.contains($0.id) }) {
                state.decisions[signature]?.invalidated = true
            }
        }
        if state != reviewState {
            guard saveState(state) else { return }
            reviewNotice = L10n.text("app_photos_or_group_evidence_changed_affected_decisions_need_review_again_locks_remain_protected")
        }
        for group in groups {
            guard let signature = reviewSignature(for: group), let decision = reviewState.decisions[signature],
                  decision.invalidated != true else { continue }
            let assets = [group.preferred] + group.duplicates.map(\.asset)
            let ids = Set(assets.map(\.id))
            guard decision.removals.isSubset(of: ids) else { continue }
            if decision.deleteAll {
                guard decision.removals == ids, assets.allSatisfy({ !isProtected($0) }) else { continue }
            } else {
                guard let keepID = decision.keepID, ids.contains(keepID), !decision.removals.contains(keepID) else { continue }
            }
            let valid = decision.deleteAll ? ids : Set(group.removalPairs(keeping: decision.keepID!, protection: protection).map { $0.remove.id })
            let removals = Set(assets.filter { valid.contains($0.id) && decision.removals.contains($0.id) && !isProtected($0) }.map(\.id))
            selections[group.id] = GroupSelection(keepID: decision.keepID, selected: removals, deleteAll: decision.deleteAll)
        }
    }

    var similarScenesEnabled: Bool { reviewState.similarScenesEnabled == true }
    var reviewCollection: ReviewCollection { resultQuery.collection ?? .duplicates }

    func setSimilarScenesEnabled(_ enabled: Bool) {
        guard canEditSources, enabled != similarScenesEnabled else { return }
        var state = reviewState
        state.similarScenesEnabled = enabled
        if saveState(state) { invalidateResults() }
    }

    func setReviewCollection(_ collection: ReviewCollection) {
        var query = resultQuery
        query.collection = collection
        query.match = nil
        setResultQuery(query)
    }

    func clearResultFilters() {
        var query = ReviewResultQuery()
        query.collection = resultQuery.collection
        setResultQuery(query)
    }

    var photoScope: PhotoScope { reviewState.photoScope ?? PhotoScope() }
    var comparisonSides: ComparisonSides? { reviewState.comparisonSides }
    var preferredSource: String? { reviewState.preferredSource }
    var readOnlySources: Set<String> { reviewState.readOnlySources ?? [] }

    func setPhotoScope(_ scope: PhotoScope) {
        guard canEditSources, scope != photoScope else { return }
        do {
            if let dates = scope.dates { _ = try dates.contains(nil) }
            var state = reviewState
            state.photoScope = scope
            if saveState(state) { invalidateResults() }
        } catch { sourceErrorMessage = L10n.text("app_choose_a_valid_capture_date_range") }
    }

    func setComparisonSides(_ sides: ComparisonSides?) {
        guard canEditSources, sides != comparisonSides else { return }
        do {
            try sides?.validate(sources: Set(sources.map(\.id)))
            var state = reviewState
            state.comparisonSides = sides
            if saveState(state) { invalidateResults() }
        } catch { sourceErrorMessage = L10n.text("app_choose_two_different_available_sources") }
    }

    func setPreferredSource(_ source: String?) {
        guard canEditSources, source != preferredSource, source == nil || sources.contains(where: { $0.id == source }) else { return }
        var state = reviewState
        state.preferredSource = source
        if saveState(state) { invalidateResults() }
    }

    func setReadOnly(_ source: String, enabled: Bool) async {
        guard canEditSources, protectionAvailable else { return }
        updatingPolicy = true
        defer { updatingPolicy = false }
        var state = reviewState
        var protected = state.readOnlySources ?? []
        if enabled { protected.insert(source) } else { protected.remove(source) }
        state.readOnlySources = protected
        state.readOnlyRevisions = state.readOnlyRevisions ?? [:]
        guard saveState(state) else { return }
        do { try await refreshReadOnlyRevisions() }
        catch { resultsStale = result != nil; sourceErrorMessage = L10n.text("app_read_only_protection_needs_a_successful_rescan") + L10n.error(error) }
        trimProtectedDecisions()
    }

    private func refreshReadOnlyRevisions() async throws {
        var revisions = reviewState.readOnlyRevisions ?? [:]
        for folder in folders where readOnlySources.contains(folder.id) {
            let snapshot = try await folder.source.snapshot()
            guard snapshot.issues.isEmpty else { throw CleanupError.unavailableProtection }
            for asset in snapshot.assets { revisions[asset.id] = asset.revision }
        }
        var state = reviewState
        state.readOnlyRevisions = revisions
        guard saveState(state) else { throw CleanupError.unavailableProtection }
    }

    private func trimProtectedDecisions() {
        var state = reviewState
        for group in result?.groups ?? [] {
            guard let signature = reviewSignature(for: group), var decision = state.decisions[signature] else { continue }
            if decision.deleteAll && group.assets.contains(where: isProtected) { decision = ReviewDecision(status: .pending) }
            else { decision.removals = Set(group.assets.filter { decision.removals.contains($0.id) && !isProtected($0) }.map(\.id)) }
            state.decisions[signature] = decision
        }
        if saveState(state) { restoreDecisions(result?.groups ?? []) }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.folderKey)
    }
}


extension ReviewStatus {
    var title: String {
        switch self {
        case .pending: L10n.text("app_needs_review")
        case .deferred: L10n.text("app_later")
        case .confirmed: L10n.text("app_confirmed")
        case .kept: L10n.text("app_entire_group_kept")
        }
    }
}
