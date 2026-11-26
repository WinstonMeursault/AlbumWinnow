import AlbumWinnowApple
import AlbumWinnowRust
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
    static let showReviewFilenamesKey = "showReviewFilenames"

    struct GroupSelection {
        let keepID: AssetID?
        let selectedCount: Int
        let deleteAll: Bool
    }

    private(set) var result: ReviewScanPresentation?
    private(set) var visibleGroups: [ReviewGroupSummary] = []
    private(set) var overview: CoreReviewOverview?
    private(set) var header: CoreReviewHeader?
    private(set) var registeredSources: [CoreSourceRecord] = []
    private(set) var savedLocks: [AssetID] = []
    private(set) var unavailableFolders: [String] = []
    private(set) var details: [AssetID: ReviewGroupDetail] = [:]
    // Committed status labels survive neighbor-detail eviction in a review session.
    private var statusLabels: [AssetID: CoreReviewStatus] = [:]
    private(set) var resumeGroup: ReviewGroupSummary?
    private(set) var scanAccounting: ScanAccounting?
    private(set) var scanCancelled = false
    private(set) var progress: ScanProgress?
    private(set) var downloadProgress: CloudDownloadProgress?
    private(set) var lastCleanup: [ReviewCleanupOutcome]?
    private(set) var cleanupPlan: CoreCleanupHeader?
    private(set) var cleanupGroups: [ReviewCleanupGroup] = []
    private(set) var updatingPolicy = false
    private(set) var running = false
    private(set) var cleaning = false
    private(set) var clearingCache = false
    private(set) var cacheStatus: String?
    private(set) var resultsStale = false
    private(set) var reviewNotice: String?
    private(set) var protectionAvailable = false
    private(set) var skipCloudPhotos = true
    private(set) var showingSetupNotice = false
    private(set) var authorization = PhotoLibrarySource.authorizationStatus()
    var errorMessage: String?
    var sourceErrorMessage: String?

    @ObservationIgnored private var owner: AppleReviewOwner?
    @ObservationIgnored private let dataDirectory: URL?
    @ObservationIgnored private let preferencesSuite: String
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let galleryThumbnails = GalleryThumbnails()
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var libraryChangedDuringScan = false
    @ObservationIgnored private var detailRequests = Set<AssetID>()
    @ObservationIgnored private var navigationSequence: UInt64 = 0
    #if os(iOS)
    @ObservationIgnored private var inForeground = false
    #endif

    init(dataDirectory: URL? = nil, preferencesSuite: String = AppleReviewOwner.preferencesSuite) {
        self.dataDirectory = dataDirectory
        self.preferencesSuite = preferencesSuite
        preferences = UserDefaults(suiteName: preferencesSuite)!
    }

    func bootstrap() async {
        if let bootstrapTask { await bootstrapTask.value; return }
        let task = Task { await initialize() }
        bootstrapTask = task
        await task.value
    }

    private func initialize() async {
        do {
            if let dataDirectory {
                owner = try await AppleReviewOwner.open(directory: dataDirectory, preferencesSuite: preferencesSuite)
            } else { owner = try await AppleReviewOwner.open(preferencesSuite: preferencesSuite) }
            guard let owner else { return }
            try await refresh()
            if !unavailableFolders.isEmpty {
                errorMessage = L10n.text("app_a_saved_folder_is_unavailable_select_it_again_to_restore_access")
            }
            skipCloudPhotos = await owner.skipsCloudPhotos()
            showingSetupNotice = await owner.needsSetupNotice()
            watchLibrary()
        } catch { await fail(error) }
    }

    func acknowledgeSetupNotice() async {
        guard let owner else { return }
        await owner.acknowledgeSetupNotice()
        showingSetupNotice = false
    }

    var preferenceStore: UserDefaults { preferences }
    var allowsPhotos: Bool { authorization == .authorized || authorization == .limited }
    var photoSourceID: String? { registeredSources.first { $0.kind == .photoLibrary }?.id }
    var photosEnabled: Bool { registeredSources.contains { $0.kind == .photoLibrary && $0.active } }
    var folders: [ReviewFolder] {
        registeredSources.filter { $0.kind == .fileSystem && $0.active && !unavailableFolders.contains($0.id) }
            .map { ReviewFolder(id: $0.id, name: $0.label) }
    }
    var hasScanSources: Bool { !folders.isEmpty || (photosEnabled && allowsPhotos) }
    var canEditSources: Bool { owner != nil && protectionAvailable && !updatingPolicy && !running && !cleaning && !clearingCache && cleanupPlan == nil }
    var canScan: Bool { canEditSources && hasScanSources && !showingSetupNotice }
    var canClean: Bool { protectionAvailable && !updatingPolicy && !running && !cleaning && !clearingCache && !resultsStale && result != nil }
    var selectedCount: Int { result == nil ? 0 : Int(overview?.savedRemovals ?? 0) }
    var hiddenCandidateCount: Int { Int(overview?.hiddenSavedRemovals ?? 0) }
    var totalGroupCount: Int { Int((overview?.duplicateGroups ?? 0) + (overview?.sceneGroups ?? 0)) }
    var collectionGroupCount: Int { Int(reviewCollection == .similarScenes ? overview?.sceneGroups ?? 0 : overview?.duplicateGroups ?? 0) }
    var pendingDownloadCount: Int { pendingDownloadIDs.count }
    var invalidDecisionCount: Int { Int(header?.invalidDecisionCount ?? 0) }
    var readOnlySources: Set<String> { Set(header?.readOnlySources ?? []) }
    var similarScenesEnabled: Bool { header?.settings.similarScenesEnabled ?? false }
    var resultQuery: CoreReviewQuery {
        header?.settings.query ?? CoreReviewQuery(collection: .duplicates, status: .active, kind: nil, source: nil, sort: .stable)
    }
    var reviewCollection: CoreReviewCollection { resultQuery.collection }
    var photoScope: PhotoScope { (try? header.map { try PhotoScope($0.settings.photoScope) }) ?? PhotoScope() }
    var comparisonSides: ComparisonSides? { header?.settings.sides.map { ComparisonSides(first: $0.first, second: $0.second) } }
    var preferredSource: String? { header?.settings.preferredSource }
    var title: String { L10n.text("app_duplicates") }

    private func refresh() async throws {
        guard let owner else { throw CleanupError.unavailableProtection }
        var sources = [CoreSourceRecord]()
        while true {
            let page = try await owner.sourcesPage(offset: UInt64(sources.count), limit: 256)
            sources.append(contentsOf: page)
            if page.count < 256 { break }
        }
        var locks = [AssetID]()
        while true {
            let page = try await owner.lockedPage(offset: UInt64(locks.count), limit: 256)
            locks.append(contentsOf: page.map { AssetID($0.id) })
            if page.count < 256 { break }
        }
        let latest = try await owner.header()
        var groups = [ReviewGroupSummary]()
        var counts: CoreReviewOverview?
        if result != nil {
            while true {
                let page = try await owner.reviewPage(mode: .visible, offset: UInt64(groups.count), limit: 256)
                guard page.header.metadata == latest.metadata else { throw AssetAccessError.changedDuringScan }
                counts = page.overview
                groups.append(contentsOf: page.groups.map(ReviewGroupSummary.init(core:)))
                if UInt64(groups.count) >= page.total { break }
            }
        }
        let requested = detailRequests
        var currentDetails = [AssetID: ReviewGroupDetail]()
        for id in requested {
            if let signature = details[id]?.signature ?? groups.first(where: { $0.id == id })?.signature {
                currentDetails[id] = try ReviewGroupDetail(await owner.groupDetail(signature: signature))
            }
        }
        let resume = result == nil ? nil : try await owner.resumeSignature()
        registeredSources = sources
        savedLocks = locks
        let unavailable = await owner.sourceIssues().map(\.source) + (result?.receipt.unavailableSources ?? [])
        unavailableFolders = Array(Set(unavailable)).filter { id in
            sources.contains { $0.id == id && $0.active && $0.kind == .fileSystem }
        }
        header = latest
        navigationSequence = max(navigationSequence, latest.navigationSequence)
        overview = counts
        visibleGroups = groups
        for group in groups { statusLabels[group.id] = group.core.status }
        for detail in currentDetails.values { statusLabels[detail.id] = detail.core.summary.status }
        if requested == detailRequests { details = currentDetails }
        resumeGroup = groups.first { $0.signature == resume }
        protectionAvailable = latest.healthy
        skipCloudPhotos = await owner.skipsCloudPhotos()
    }

    private func fail(_ error: any Error) async {
        protectionAvailable = await owner?.isHealthy() ?? false
        errorMessage = protectionAvailable ? L10n.error(error) :
            L10n.text("app_protection_could_not_be_loaded_cleanup_is_disabled_arg1", L10n.error(error))
    }

    private func edit(invalidatesScan: Bool = false,
                      _ operation: @escaping @Sendable (AppleReviewOwner, UInt64) async throws -> Void) {
        guard canEditSources, let owner, let revision = header?.metadata.revision else { return }
        updatingPolicy = true
        Task {
            defer { updatingPolicy = false }
            do {
                try await operation(owner, revision)
                if invalidatesScan { invalidateResults() }
                try await refresh()
            } catch { await fail(error) }
        }
    }

    private func changeSettings(invalidatesScan: Bool = false, _ change: (inout CoreReviewSettings) -> Void) {
        guard var settings = header?.settings else { return }
        change(&settings)
        let next = settings
        edit(invalidatesScan: invalidatesScan) { owner, revision in
            _ = try await owner.saveSettings(expectedRevision: revision, settings: next)
        }
    }

    func setResultQuery(_ query: CoreReviewQuery) { changeSettings { $0.query = query } }
    func setReviewCollection(_ collection: CoreReviewCollection) {
        changeSettings { $0.query.collection = collection; $0.query.kind = nil }
    }
    func clearResultFilters() {
        changeSettings { $0.query = CoreReviewQuery(collection: $0.query.collection, status: .active, kind: nil, source: nil, sort: .stable) }
    }
    func setSimilarScenesEnabled(_ enabled: Bool) { changeSettings(invalidatesScan: true) { $0.similarScenesEnabled = enabled } }
    func enableScenesAndScan() async {
        guard canEditSources, let owner, var settings = header?.settings, let revision = header?.metadata.revision else { return }
        updatingPolicy = true
        do {
            settings.similarScenesEnabled = true
            _ = try await owner.saveSettings(expectedRevision: revision, settings: settings)
            invalidateResults()
            try await refresh()
            updatingPolicy = false
            scan()
        } catch { updatingPolicy = false; await fail(error) }
    }
    func setPhotoScope(_ scope: PhotoScope) {
        let value = CorePhotoScope(albums: scope.albums,
            dates: scope.dates.map { CoreCaptureRange(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970, includesUnknown: $0.includesUnknown) })
        changeSettings(invalidatesScan: true) { $0.photoScope = value }
    }
    func setComparisonSides(_ sides: ComparisonSides?) {
        changeSettings(invalidatesScan: true) { $0.sides = sides.map { CoreComparisonSides(first: $0.first, second: $0.second) } }
    }
    func setPreferredSource(_ source: String?) { changeSettings(invalidatesScan: true) { $0.preferredSource = source } }

    func addFolder(_ url: URL) {
        edit(invalidatesScan: true) { owner, revision in _ = try await owner.addFolder(url, expectedRevision: revision) }
    }
    func removeFolder(_ id: String) {
        edit(invalidatesScan: true) { owner, revision in _ = try await owner.setSourceActive(expectedRevision: revision, source: id, active: false) }
    }
    func removeUnavailableFolder(_ id: String) { removeFolder(id) }
    func reconnectFolder(_ id: String, to url: URL) {
        edit(invalidatesScan: true) { owner, revision in
            let added = try await owner.addFolder(url, expectedRevision: revision)
            if added.id != id {
                _ = try await owner.setSourceActive(expectedRevision: owner.header().metadata.revision, source: id, active: false)
            }
        }
    }
    func retryFolders() {
        guard canEditSources, let owner else { return }
        updatingPolicy = true
        Task {
            defer { updatingPolicy = false }
            do {
                try await owner.retryAuthorizations()
                invalidateResults()
                try await refresh()
                if !unavailableFolders.isEmpty {
                    sourceErrorMessage = L10n.text("app_a_saved_folder_is_unavailable_select_it_again_to_restore_access")
                }
            } catch { await fail(error) }
        }
    }
    func setPhotosEnabled(_ enabled: Bool) async {
        guard canEditSources, let owner else { return }
        updatingPolicy = true
        defer { updatingPolicy = false }
        if enabled && authorization == .notDetermined { authorization = await PhotoLibrarySource.requestAuthorization() }
        else { authorization = PhotoLibrarySource.authorizationStatus() }
        do {
            let revision = try await owner.header().metadata.revision
            if enabled {
                guard allowsPhotos else {
                    sourceErrorMessage = L10n.text("app_allow_access_to_photos_in_system_settings_to_include_the_photo_library")
                    return
                }
                _ = try await owner.enablePhotoLibrary(expectedRevision: revision)
            } else if let photoSourceID {
                _ = try await owner.setSourceActive(expectedRevision: revision, source: photoSourceID, active: false)
            }
            invalidateResults()
            try await refresh()
            watchLibrary()
        } catch { await fail(error) }
    }
    func setReadOnly(_ source: String, enabled: Bool) async {
        guard canEditSources, let owner, let revision = header?.metadata.revision else { return }
        updatingPolicy = true
        defer { updatingPolicy = false }
        do {
            _ = try await owner.setReadOnly(expectedRevision: revision, source: source, enabled: enabled)
            try await refresh()
        } catch { await fail(error) }
    }
    func setSkipCloudPhotos(_ skip: Bool) {
        edit(invalidatesScan: true) { owner, _ in try await owner.setSkipCloudPhotos(skip) }
    }
    func clearScanCache() async {
        guard canEditSources, let owner else { return }
        clearingCache = true
        cacheStatus = nil
        defer { clearingCache = false }
        do {
            try await owner.clearCache()
            invalidateResults()
            lastCleanup = nil
            downloadProgress = nil
            cacheStatus = L10n.text("app_scan_cache_cleared_the_next_scan_will_read_all_photos_again")
        } catch { sourceErrorMessage = L10n.error(error) }
    }

    func status(for group: ReviewGroupSummary) -> CoreReviewStatus {
        statusLabels[group.id] ?? group.core.status
    }
    func status(for group: ReviewGroupDetail) -> CoreReviewStatus { statusLabels[group.id] ?? group.core.summary.status }
    func selection(for id: AssetID) -> GroupSelection {
        guard let detail = details[id] else { return GroupSelection(keepID: nil, selectedCount: 0, deleteAll: false) }
        let decision = detail.core.decision.flatMap { $0.invalidated ? nil : $0 }
        return GroupSelection(keepID: decision?.keep.map(AssetID.init), selectedCount: Int(detail.core.summary.savedRemovalCount), deleteAll: decision?.deleteAll ?? false)
    }
    func confirmSelection(in group: ReviewGroupDetail, keepID: AssetID?, deleteAll: Bool) async -> Bool {
        guard canClean, cleanupPlan == nil, !Task.isCancelled, let owner, let revision = header?.metadata.revision else { return false }
        let intent: CoreReviewIntent
        if deleteAll { intent = .confirmDeleteAll }
        else if let keepID { intent = .confirmKeep(keep: keepID.core) }
        else { return false }
        updatingPolicy = true
        defer { updatingPolicy = false }
        do {
            _ = try await owner.applyIntent(expectedRevision: revision, signature: group.signature, commandID: UUID().uuidString, intent: intent)
            try await refresh()
            return true
        } catch { await fail(error); return false }
    }
    func setStatus(_ status: CoreReviewStatus, for group: ReviewGroupDetail) async -> Bool {
        guard canClean, cleanupPlan == nil, let owner, let revision = header?.metadata.revision else { return false }
        updatingPolicy = true
        defer { updatingPolicy = false }
        do {
            _ = try await owner.applyIntent(expectedRevision: revision, signature: group.signature, commandID: UUID().uuidString, intent: .setStatus(status: status))
            try await refresh()
            return true
        } catch { await fail(error); return false }
    }
    func resetReviewProgress() {
        edit { owner, revision in _ = try await owner.resetProgress(expectedRevision: revision) }
    }
    func removeInvalidDecisions() {
        edit { owner, revision in _ = try await owner.removeInvalidDecisions(expectedRevision: revision) }
    }
    func removeSavedLock(_ id: AssetID) {
        edit { owner, revision in _ = try await owner.removeSavedLock(expectedRevision: revision, asset: id.core) }
    }
    private func coreAsset(_ asset: PhotoAsset) -> CoreReviewAsset? {
        details.values.lazy.flatMap { $0.core.group.members }.first { $0.id == asset.id.core }
    }
    func isLocked(_ asset: PhotoAsset) -> Bool { details.values.contains { $0.core.locked.contains(asset.id.core) } }
    func isReadOnly(_ asset: PhotoAsset) -> Bool { details.values.contains { $0.core.readOnly.contains(asset.id.core) } }
    func isProtected(_ asset: PhotoAsset) -> Bool { !protectionAvailable || details.values.contains { $0.core.protected.contains(asset.id.core) } }
    func setLocked(_ asset: PhotoAsset, locked: Bool) {
        guard let value = coreAsset(asset) else { return }
        edit { owner, revision in _ = try await owner.setLocked(expectedRevision: revision, asset: value, locked: locked) }
    }
    func lockOwners(for asset: PhotoAsset) async -> [AssetID] {
        guard let owner, let value = coreAsset(asset) else { return [] }
        do {
            var result = [AssetID]()
            while true {
                let page = try await owner.lockOwnersPage(asset: value, offset: UInt64(result.count), limit: 256)
                result.append(contentsOf: page.map(AssetID.init))
                if page.count < 256 { return result }
            }
        } catch { await fail(error); return [] }
    }
    @discardableResult
    func rememberPosition(_ group: ReviewGroupSummary) -> Task<Void, Never>? {
        guard let owner, let revision = header?.metadata.revision else { return nil }
        navigationSequence += 1
        let sequence = navigationSequence
        let position = visibleGroups.firstIndex { $0.id == group.id }.map(UInt64.init)
        return Task {
            do {
                try await owner.savePosition(expectedRevision: revision, sequence: sequence, anchor: group.signature, position: position)
                guard navigationSequence == sequence else { return }
                let signature = try await owner.resumeSignature()
                resumeGroup = visibleGroups.first { $0.signature == signature }
            } catch let failure as RustCoreFailure where (failure.underlying as? BridgeError) == .StaleOperation {
                // A later committed edit or navigation has already won.
                return
            } catch { await fail(error) }
        }
    }
    func pendingReview(limit: Int) async -> [ReviewGroupSummary] {
        guard canClean, let owner else { return [] }
        do { return try await owner.reviewPage(mode: .pending, offset: 0, limit: UInt32(min(256, max(1, limit)))).groups.map(ReviewGroupSummary.init(core:)) }
        catch { await fail(error); return [] }
    }
    func loadDetails(for groups: [ReviewGroupSummary]) async {
        guard let owner else { return }
        let requested = Set(groups.map(\.id))
        detailRequests = requested
        do {
            var next = [AssetID: ReviewGroupDetail]()
            for group in groups {
                let value = try ReviewGroupDetail(await owner.groupDetail(signature: group.signature))
                try Task.checkCancellation()
                next[group.id] = value
            }
            guard detailRequests == requested else { return }
            details = next
            for detail in next.values { statusLabels[detail.id] = detail.core.summary.status }
        } catch is CancellationError { return }
        catch { await fail(error) }
    }
    func releaseDetails() { detailRequests = []; details = [:] }

    func deleteAllUnavailableReason(for assets: [PhotoAsset]) async -> String? {
        guard let owner, assets.allSatisfy({ !isProtected($0) }) else { return L10n.text("app_at_least_one_photo_cannot_be_moved_from_its_source") }
        do {
            try await owner.validateRemovability(assets: assets)
            return nil
        } catch { return L10n.error(error) }
    }

    func prepareCleanup() async {
        guard canClean, cleanupPlan == nil, let owner, let revision = header?.metadata.revision else { return }
        updatingPolicy = true
        defer { updatingPolicy = false }
        do {
            let plan = try await owner.prepareCleanup(expectedRevision: revision)
            cleanupPlan = plan
            var groups = [ReviewCleanupGroup]()
            while true {
                let page = try await owner.cleanupGroups(operation: plan.operation, offset: UInt64(groups.count), limit: 256)
                groups.append(contentsOf: page.map(ReviewCleanupGroup.init(core:)))
                if UInt64(groups.count) >= plan.groupCount { break }
            }
            cleanupGroups = groups
        } catch {
            await cancelCleanup()
            await fail(error)
        }
    }
    func cleanupPreview(_ group: ReviewCleanupGroup) async throws -> ReviewCleanupPreview {
        guard let owner, let plan = cleanupPlan else { throw CleanupError.invalidSelection }
        let detail = try await owner.groupDetail(signature: group.core.signature)
        var items = [CoreCleanupItem]()
        while true {
            let page = try await owner.cleanupItems(operation: plan.operation, group: group.id, offset: UInt64(items.count), limit: 16)
            items.append(contentsOf: page)
            if UInt64(items.count) >= group.core.removalCount { break }
        }
        let removing = Set(items.map { $0.pair.remove.id })
        return ReviewCleanupPreview(keep: items.first?.pair.keep.map(PhotoAsset.init),
            retained: detail.group.members.filter { !removing.contains($0.id) }.map(PhotoAsset.init),
            removing: items.map { PhotoAsset($0.pair.remove) }, match: group.core.kind)
    }
    func cancelCleanup() async {
        guard !cleaning, let owner, let cleanupPlan else { return }
        do {
            try await owner.cancelPreparedCleanup(operation: cleanupPlan.operation)
            self.cleanupPlan = nil
            cleanupGroups = []
        } catch { await fail(error) }
    }
    func applyCleanup() async {
        guard canClean, let owner, let plan = cleanupPlan else { return }
        cleaning = true
        defer { cleaning = false; cleanupPlan = nil; cleanupGroups = [] }
        do {
            let receipt = try await owner.applyPreparedCleanup(operation: plan.operation)
            var results = [ReviewCleanupOutcome]()
            while true {
                let page = try await owner.cleanupResults(operation: plan.operation, offset: UInt64(results.count), limit: 16)
                results.append(contentsOf: page.map { ReviewCleanupOutcome(core: $0, failureReason: receipt.diagnostics[$0.item.key]?.reason,
                    detail: receipt.diagnostics[$0.item.key]?.detail, trashLocation: receipt.trashLocations[$0.item.key]) })
                if page.count < 16 { break }
            }
            lastCleanup = results
            if results.contains(where: \.moved) { invalidateResults() }
            try await refresh()
            if let interruption = receipt.interruption { errorMessage = interruption }
        } catch { invalidateResults(); await fail(error) }
    }

    func preview(for asset: PhotoAsset) async throws -> LoadedPreview {
        guard let owner else { throw CleanupError.unavailableSource }
        let thumbnails = galleryThumbnails
        return try await owner.withAssetSources(assets: [asset]) { sources in
            guard let source = sources[asset.id.source] else { throw CleanupError.unavailableSource }
            let bytes = try await (source as? FileSystemSource)?.byteCount(for: asset) ?? 64 * 1024 * 1024
            return try await thumbnails.preview(estimatedBytes: bytes) {
                if let folder = source as? FileSystemSource {
                    return try await LoadedPreview.load(asset: asset, file: folder.currentURL(for: asset))
                }
                return await LoadedPreview.load(asset: asset, input: try await source.image(for: asset))
            }
        }
    }
    func thumbnail(for asset: PhotoAsset, pixelSize: Int) async throws -> CGImage {
        guard let owner else { throw CleanupError.unavailableSource }
        let thumbnails = galleryThumbnails
        return try await owner.withAssetSources(assets: [asset]) { sources in
            guard let source = sources[asset.id.source] else { throw CleanupError.unavailableSource }
            return try await thumbnails.image(for: GalleryThumbnailKey(asset: asset, pixelSize: pixelSize)) {
                if let folder = source as? FileSystemSource { return try await folder.thumbnail(for: asset, maxPixelSize: pixelSize) }
                if let photos = source as? PhotoLibrarySource { return try await photos.thumbnail(for: asset, maxPixelSize: pixelSize) }
                throw CleanupError.unsupportedSource
            }
        }
    }
    func difference(reference: PhotoAsset, comparison: PhotoAsset) async throws -> PhotoDifference {
        guard canClean, let owner else { throw AssetAccessError.changedDuringScan }
        guard details.values.contains(where: { $0.assets.contains(reference) && $0.assets.contains(comparison) }) else { throw PhotoDifferenceError.invalidPair }
        do {
            return try await owner.withAssetSources(assets: [reference, comparison]) { sources in
                guard let first = sources[reference.id.source], let second = sources[comparison.id.source] else { throw CleanupError.unavailableSource }
                return try await PhotoDifference.compare(reference, source: first, comparison, source: second)
            }
        } catch let error as AssetAccessError {
            invalidateResults()
            throw error
        } catch ScopeError.unavailableAlbum {
            invalidateResults()
            throw ScopeError.unavailableAlbum
        }
    }
    func sourceLabel(_ id: String) -> String {
        guard let source = registeredSources.first(where: { $0.id == id }) else { return L10n.text("app_unavailable_source") }
        return source.kind == .photoLibrary ? L10n.text("app_photos") : source.label
    }
    private func invalidateResults() {
        if result != nil || running { resultsStale = true }
        result = nil
        visibleGroups = []
        overview = nil
        statusLabels = [:]
        resumeGroup = nil
        releaseDetails()
        Task { await galleryThumbnails.clear() }
        scanTask?.cancel()
    }
    func libraryDidChange() {
        if running { libraryChangedDuringScan = true; resultsStale = true }
        else { invalidateResults() }
    }
    private func watchLibrary() {
        libraryTask?.cancel()
        guard photosEnabled, allowsPhotos, let photoSourceID else { return }
        let source = PhotoLibrarySource(id: photoSourceID)
        libraryTask = Task { [weak self] in
            for await _ in source.changes() {
                guard let self, !Task.isCancelled else { return }
                libraryDidChange()
            }
        }
    }
    func sceneChanged(_ phase: ScenePhase) {
        #if os(iOS)
        inForeground = phase == .active
        if phase == .background { scanTask?.cancel() }
        #endif
        guard phase == .active else { return }
        Task {
            await bootstrap()
            let latest = PhotoLibrarySource.authorizationStatus()
            if latest != authorization { authorization = latest; invalidateResults(); watchLibrary() }
            #if os(iOS)
            resumeInterruptedScan()
            #endif
        }
    }
    private var pendingDownloadIDs: Set<AssetID> {
        Set((result?.issues ?? []).filter {
            $0.id.source == photoSourceID && ($0.reason == .cloudSkipped || $0.reason == .cloudDownloadRequired || $0.reason == .cloudDownloadFailed)
        }.map(\.id))
    }
    func scan() { startScan(downloads: []) }
    func downloadPendingPhotos() { if !pendingDownloadIDs.isEmpty { startScan(downloads: pendingDownloadIDs) } }
    func downloadAndRescan(_ asset: PhotoAsset) {
        guard asset.id.source == photoSourceID else { return }
        startScan(downloads: [asset.id])
    }
    func startScan(downloads: Set<AssetID>) {
        guard canScan, let owner else { return }
        let previousInvalidDecisions = header?.invalidDecisionCount ?? 0
        running = true
        scanAccounting = nil
        reviewNotice = nil
        scanCancelled = false
        libraryChangedDuringScan = false
        lastCleanup = nil
        if downloads.isEmpty {
            result = nil
            visibleGroups = []
            overview = nil
            statusLabels = [:]
            resultsStale = false
        } else if result != nil { resultsStale = true }
        releaseDetails()
        downloadProgress = downloads.isEmpty && skipCloudPhotos ? nil : CloudDownloadProgress(total: downloads.count)
        preferences.set(true, forKey: "interruptedScan")
        preferences.set(try? JSONEncoder().encode(downloads), forKey: "interruptedDownloads")
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let (accounts, accountContinuation) = AsyncStream.makeStream(of: ScanAccounting.self, bufferingPolicy: .bufferingNewest(1))
        let (downloadsStream, downloadContinuation) = AsyncStream.makeStream(of: PhotoLibrarySource.DownloadUpdate.self)
        scanTask = Task {
            let progressObserver = Task { for await update in updates { progress = update } }
            let accountObserver = Task { for await update in accounts { scanAccounting = update } }
            let downloadObserver = Task {
                for await update in downloadsStream {
                    downloadProgress?.update(update)
                    if case let .finished(id, available) = update, preferences.bool(forKey: "interruptedScan") {
                        var remaining = preferences.data(forKey: "interruptedDownloads").flatMap { try? JSONDecoder().decode(Set<AssetID>.self, from: $0) } ?? []
                        if available { remaining.remove(id) } else { remaining.insert(id) }
                        preferences.set(try? JSONEncoder().encode(remaining), forKey: "interruptedDownloads")
                    }
                }
            }
            defer {
                running = false
                progress = nil
                scanTask = nil
                #if os(iOS)
                resumeInterruptedScan()
                #endif
            }
            var issues = [AssetIssue]()
            do {
                // Record the new scan consent before responding to background
                // cancellation; it supersedes an earlier user-cancelled scan.
                var before = try await owner.header()
                var settings = before.settings
                settings.scanCancelledByUser = false
                before.metadata = try await owner.saveSettings(expectedRevision: before.metadata.revision, settings: settings)
                before.settings = settings
                header = before
                try Task.checkCancellation()
                // Refresh native alias facts before every scan, without moving the
                // authority for protection or candidate pruning into this model.
                for source in try await owner.header().readOnlySources {
                    _ = try await owner.setReadOnly(expectedRevision: owner.header().metadata.revision, source: source, enabled: true)
                }
                let receipt = try await owner.scan(downloads: downloads, progress: { continuation.yield($0) },
                    accounting: { accountContinuation.yield($0) }, downloadUpdate: { downloadContinuation.yield($0) })
                result = ReviewScanPresentation(receipt: receipt)
                issues = receipt.issues
                resultsStale = libraryChangedDuringScan
                clearInterruptedScan()
                try await refresh()
                if (header?.invalidDecisionCount ?? 0) > previousInvalidDecisions {
                    reviewNotice = L10n.text("app_photos_or_group_evidence_changed_affected_decisions_need_review_again_locks_remain_protected")
                }
                if resultsStale { errorMessage = L10n.text("app_the_photo_library_changed_during_the_scan_scan_again_before_cleanup") }
                if !receipt.unavailableSources.isEmpty { reviewNotice = L10n.text("app_a_saved_folder_is_unavailable_select_it_again_to_restore_access") }
                if case let .failed(message) = receipt.cacheMaintenance { reviewNotice = message }
            } catch is CancellationError { scanCancelled = true; resultsStale = true }
            catch { clearInterruptedScan(); await fail(error) }
            continuation.finish()
            accountContinuation.finish()
            downloadContinuation.finish()
            await progressObserver.value
            await accountObserver.value
            await downloadObserver.value
            downloadProgress?.reconcile(issues: issues, requested: downloads)
            downloadProgress?.end(cancelled: Task.isCancelled)
        }
    }
    func cancelScan() {
        clearInterruptedScan()
        let active = scanTask
        active?.cancel()
        guard !updatingPolicy, let owner else { return }
        updatingPolicy = true
        Task {
            defer { updatingPolicy = false }
            // The scan may still be committing its own settings/receipt. Await
            // that operation before persisting the user's cancellation policy.
            await active?.value
            do {
                let before = try await owner.header()
                var settings = before.settings
                settings.scanCancelledByUser = true
                _ = try await owner.saveSettings(expectedRevision: before.metadata.revision, settings: settings)
                header = try await owner.header()
            } catch { await fail(error) }
        }
    }
    private func clearInterruptedScan() {
        preferences.removeObject(forKey: "interruptedScan")
        preferences.removeObject(forKey: "interruptedDownloads")
    }
    #if os(iOS)
    private func resumeInterruptedScan() {
        guard inForeground, canScan, header?.settings.scanCancelledByUser != true,
              preferences.bool(forKey: "interruptedScan") else { return }
        let downloads = preferences.data(forKey: "interruptedDownloads").flatMap { try? JSONDecoder().decode(Set<AssetID>.self, from: $0) } ?? []
        startScan(downloads: downloads)
    }
    #endif
}
