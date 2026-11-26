import AlbumWinnowRust
import CoreFoundation
import Foundation

public struct AppleSourceIssue: Equatable, Sendable {
    public let source: String
    public let diagnostic: String
}

/// Owns native authorization leases. No native source is assigned a persisted
/// identity until Rust has registered its namespace/key.
private final class FolderAuthorization {
    let url: URL
    let bookmark: Data
    private let opened: Bool

    init(url: URL) throws {
        opened = url.startAccessingSecurityScopedResource()
        self.url = url
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = .minimalBookmark
            #endif
            bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if opened { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    convenience init(bookmark: Data) throws {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        try self.init(url: url)
    }

    deinit { if opened { url.stopAccessingSecurityScopedResource() } }
}

/// The application's only review owner. All Rust/SQLite work runs on this actor,
/// and native authorization leases remain alive across scan/cleanup suspension.
public actor AppleReviewOwner {
    public static let preferencesSuite = "io.github.winstonmeursault.albumwinnow.v2"
    private let core: RustReviewSession
    private let engine: ScanEngine
    private let cleanup: AppleCleanupExecutor
    private let preferences: UserDefaults
    private var folders: [String: FolderAuthorization] = [:]
    private var issues: [AppleSourceIssue] = []
    private var working = false

    public static func open(directory: URL = URL.applicationSupportDirectory.appending(path: "AlbumWinnow-v2"),
                            preferencesSuite: String = AppleReviewOwner.preferencesSuite) async throws -> AppleReviewOwner {
        // Explicit detached creation keeps startup database/bookmark work off the
        // caller's MainActor too, independent of its concurrency build settings.
        let owner = try await Task.detached {
            try AppleReviewOwner(directory: directory, preferencesSuite: preferencesSuite)
        }.value
        try await owner.restoreAuthorizations()
        return owner
    }

    private init(directory: URL, preferencesSuite: String) throws {
        guard preferencesSuite != "", let preferences = UserDefaults(suiteName: preferencesSuite) else {
            throw CleanupError.unavailableProtection
        }
        let marker = preferences.object(forKey: "initialized")
        if let marker {
            guard let flag = marker as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else {
                throw CleanupError.unavailableProtection
            }
        }
        let core = try coreResult {
            try RustReviewSession(databasePath: directory.appending(path: "review.sqlite").path,
                                  initialized: marker != nil)
        }
        engine = try ScanEngine(cacheURL: directory.appending(path: "scan.sqlite"))
        cleanup = AppleCleanupExecutor(session: core)
        self.core = core
        self.preferences = preferences
        preferences.register(defaults: ["skipCloud": true])
        // Written only after the identified v2 store and derived cache opened.
        // Losing the database after this point must fail closed, never reset it.
        preferences.set(true, forKey: "initialized")
    }

    public func header() throws -> CoreReviewHeader { try coreResult { try core.header() } }
    public func isHealthy() -> Bool { core.isHealthy() }
    public func sourceIssues() -> [AppleSourceIssue] { issues }
    public func queryCount() throws -> UInt64 { try coreResult { try core.queryCount() } }
    public func queryPage(offset: UInt64, limit: UInt32) throws -> [CoreGroupSummary] {
        try coreResult { try core.queryPage(offset: offset, limit: limit) }
    }
    public func reviewPage(mode: CoreReviewPageMode, offset: UInt64, limit: UInt32) throws -> CoreReviewPage {
        try coreResult { try core.reviewPage(mode: mode, offset: offset, limit: limit) }
    }
    public func lockOwnersPage(asset: CoreReviewAsset, offset: UInt64, limit: UInt32) throws -> [CoreAssetKey] {
        try coreResult { try core.lockOwnersPage(asset: asset, offset: offset, limit: limit) }
    }
    public func groupDetail(signature: String) throws -> CoreGroupDetail {
        try coreResult { try core.groupDetail(signature: signature) }
    }
    public func resumeSignature() throws -> String? { try coreResult { try core.resumeSignature() } }
    public func sourcesPage(offset: UInt64, limit: UInt32) throws -> [CoreSourceRecord] {
        try coreResult { try core.sourcesPage(offset: offset, limit: limit) }
    }
    public func lockedPage(offset: UInt64, limit: UInt32) throws -> [CoreReviewAsset] {
        try coreResult { try core.lockedPage(offset: offset, limit: limit) }
    }
    public func saveSettings(expectedRevision: UInt64, settings: CoreReviewSettings) throws -> CoreReviewMetadata {
        try coreResult { try core.saveSettings(expectedRevision: expectedRevision, settings: settings) }
    }
    public func applyIntent(expectedRevision: UInt64, signature: String, commandID: String,
                            intent: CoreReviewIntent) throws -> CoreReviewDelta {
        try coreResult { try core.applyIntent(expectedRevision: expectedRevision, signature: signature, commandId: commandID, intent: intent) }
    }
    public func savePosition(expectedRevision: UInt64, sequence: UInt64, anchor: String?, position: UInt64?) throws {
        try coreResult { try core.savePosition(expectedRevision: expectedRevision, sequence: sequence, anchor: anchor, position: position) }
    }
    public func setLocked(expectedRevision: UInt64, asset: CoreReviewAsset, locked: Bool) throws -> CoreReviewMetadata {
        try coreResult { try core.setLocked(expectedRevision: expectedRevision, asset: asset, locked: locked) }
    }
    public func removeSavedLock(expectedRevision: UInt64, asset: CoreAssetKey) throws -> CoreReviewMetadata {
        try coreResult { try core.removeSavedLock(expectedRevision: expectedRevision, asset: asset) }
    }
    public func resetProgress(expectedRevision: UInt64) throws -> CoreReviewMetadata {
        try coreResult { try core.resetProgress(expectedRevision: expectedRevision) }
    }
    public func removeInvalidDecisions(expectedRevision: UInt64) throws -> CoreReviewMetadata {
        try coreResult { try core.removeInvalidDecisions(expectedRevision: expectedRevision) }
    }

    public func needsSetupNotice() -> Bool { !preferences.bool(forKey: "setupNoticeAcknowledged") }
    public func acknowledgeSetupNotice() { preferences.set(true, forKey: "setupNoticeAcknowledged") }
    public func skipsCloudPhotos() -> Bool { preferences.bool(forKey: "skipCloud") }
    public func setSkipCloudPhotos(_ skip: Bool) throws {
        try requireIdle()
        preferences.set(skip, forKey: "skipCloud")
    }

    public func setReadOnly(expectedRevision: UInt64, source: String, enabled: Bool) async throws -> CoreReviewMetadata {
        try requireIdle()
        if !enabled { return try coreResult { try core.removeReadOnly(expectedRevision: expectedRevision, source: source) } }
        working = true
        defer { working = false }
        guard let record = try catalog().first(where: { $0.id == source }) else { throw CleanupError.unavailableSource }
        let operation = UUID().uuidString
        let cancellation = CancellationHandle()
        try coreResult { try core.beginReadOnlySnapshot(expectedRevision: expectedRevision, operationId: operation, source: source) }
        defer { try? core.discardReadOnlySnapshot(operationId: operation) }
        return try await withTaskCancellationHandler {
            var complete = record.kind == .photoLibrary
            if record.kind == .fileSystem, let authorization = folders[source] {
                let folder = FileSystemSource(directory: authorization.url, id: source)
                do {
                    guard record.nativeNamespace == FileSystemSource.sourceIdentityNamespace,
                          try folder.sourceIdentity() == record.nativeIdentity else { throw CleanupError.unavailableSource }
                    let snapshot = try await folder.snapshot()
                    complete = snapshot.issues.isEmpty
                    for start in stride(from: 0, to: snapshot.assets.count, by: 16) {
                        try Task.checkCancellation()
                        let members = try snapshot.assets[start..<min(start + 16, snapshot.assets.count)].map { asset in
                            try asset.reviewValue(kind: .fileSystem, nativeIdentity: folder.nativeIdentity(for: asset),
                                                  linkCount: folder.linkCount(for: asset))
                        }
                        try coreResult { try core.appendReadOnlySnapshot(operationId: operation, members: members, cancellation: cancellation) }
                    }
                    guard try folder.sourceIdentity() == record.nativeIdentity else { throw CleanupError.unavailableSource }
                } catch is CancellationError { throw CancellationError() }
                catch let error as RustCoreFailure { throw error }
                catch {
                    complete = false
                    issues.removeAll { $0.source == source }
                    issues.append(AppleSourceIssue(source: source, diagnostic: error.localizedDescription))
                }
            }
            try Task.checkCancellation()
            return try coreResult { try core.finishReadOnlySnapshot(operationId: operation, complete: complete, cancellation: cancellation) }
        } onCancel: { cancellation.cancel() }
    }

    private func requireIdle() throws { guard !working else { throw CleanupError.operationInProgress } }

    private func catalog() throws -> [CoreSourceRecord] {
        var result = [CoreSourceRecord]()
        while true {
            let page = try coreResult { try core.sourcesPage(offset: UInt64(result.count), limit: 256) }
            result.append(contentsOf: page)
            if page.count < 256 { return result }
        }
    }

    private func restoreAuthorizations() throws {
        issues = []
        for record in try catalog() where record.kind == .fileSystem {
            do {
                let authorization = try FolderAuthorization(bookmark: record.bookmark)
                let source = FileSystemSource(directory: authorization.url, id: record.id)
                guard record.nativeNamespace == FileSystemSource.sourceIdentityNamespace,
                      try record.nativeIdentity == source.sourceIdentity() else { throw CleanupError.unavailableSource }
                folders[record.id] = authorization
            } catch { issues.append(AppleSourceIssue(source: record.id, diagnostic: error.localizedDescription)) }
        }
    }

    public func retryAuthorizations() throws {
        try requireIdle()
        try restoreAuthorizations()
    }

    public func addFolder(_ url: URL, expectedRevision: UInt64) throws -> CoreSourceRecord {
        try requireIdle()
        let authorization = try FolderAuthorization(url: url)
        let identity = try FileSystemSource.sourceIdentity(directory: authorization.url)
        let input = CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
            identity: identity, bookmark: authorization.bookmark, label: url.lastPathComponent)
        let record = try coreResult { try core.registerSource(expectedRevision: expectedRevision, input: input) }
        folders[record.id] = authorization
        issues.removeAll { $0.source == record.id }
        return record
    }

    public func enablePhotoLibrary(expectedRevision: UInt64) throws -> CoreSourceRecord {
        try requireIdle()
        return try coreResult {
            try core.registerSource(expectedRevision: expectedRevision, input: CoreSourceInput(kind: .photoLibrary,
                namespace: PhotoLibrarySource.sourceIdentityNamespace, identity: PhotoLibrarySource.sourceIdentity,
                bookmark: Data(), label: "Photos"))
        }
    }

    public func setSourceActive(expectedRevision: UInt64, source: String, active: Bool) throws -> CoreSourceRecord {
        try requireIdle()
        // Inactive authorizations remain retained for saved locks/read-only aliases.
        return try coreResult { try core.setSourceActive(expectedRevision: expectedRevision, source: source, active: active) }
    }

    // Preview/difference/cleanup reads never inherit scan download consent.
    private func nativeSources(downloads: Set<AssetID> = [], allowsDownloads: Bool = false,
                               downloadUpdate: @escaping @Sendable (PhotoLibrarySource.DownloadUpdate) -> Void = { _ in }) throws -> AppleAssetSources {
        let records = try catalog()
        let settings = try coreResult { try core.header().settings }
        var services = [any AssetSource]()
        for record in records {
            if record.kind == .fileSystem, let authorization = folders[record.id] {
                services.append(FileSystemSource(directory: authorization.url, id: record.id))
            } else if record.kind == .photoLibrary {
                let status = PhotoLibrarySource.authorizationStatus()
                if status == .authorized || status == .limited {
                    services.append(PhotoLibrarySource(scope: try PhotoScope(settings.photoScope), includeBurstMembers: settings.similarScenesEnabled, downloads: downloads,
                        allowsDownloads: allowsDownloads, id: record.id, downloadUpdate: downloadUpdate))
                }
            }
        }
        return try AppleAssetSources(sources: services, registered: records)
    }

    /// Native image work may suspend on another executor. Retain only the
    /// requested authorizations until it returns, then reject changed scopes.
    public func withAssetSources<Value: Sendable>(assets: [PhotoAsset],
        read: @Sendable ([String: any AssetSource]) async throws -> Value) async throws -> Value {
        try requireIdle()
        guard !assets.isEmpty, assets.count <= 16 else { throw CleanupError.invalidSelection }
        let header = try coreResult { try core.header() }
        let context = try nativeSources()
        var selected = [String: any AssetSource]()
        for asset in assets {
            guard context.registered[asset.id.source]?.active == true,
                  let source = context.sources[asset.id.source] else { throw CleanupError.unavailableSource }
            try context.validateScanSource(source, settings: header.settings)
            try source.validateImage(for: asset)
            selected[source.id] = source
        }
        let access = selected.keys.compactMap { folders[$0] }
        defer { withExtendedLifetime(access) {} }
        let value = try await read(selected)
        try Task.checkCancellation()
        guard try coreResult({ try core.header().metadata.scopeEpoch }) == header.metadata.scopeEpoch else {
            throw AssetAccessError.changedDuringScan
        }
        for asset in assets {
            guard let source = selected[asset.id.source] else { throw CleanupError.unavailableSource }
            try context.validateScanSource(source, settings: header.settings)
            try source.validateImage(for: asset)
        }
        return value
    }

    /// Availability feedback for the delete-all control, never deletion authority.
    public func validateRemovability(assets: [PhotoAsset]) async throws {
        guard !assets.isEmpty else { throw CleanupError.invalidSelection }
        for start in stride(from: 0, to: assets.count, by: 16) {
            let page = Array(assets[start..<min(start + 16, assets.count)])
            try await withAssetSources(assets: page) { sources in
                for asset in page {
                    if let folder = sources[asset.id.source] as? FileSystemSource {
                        let url = try folder.removableURL(for: asset)
                        guard FileManager.default.isDeletableFile(atPath: url.path) else { throw AssetAccessError.inaccessible }
                    } else if let photos = sources[asset.id.source] as? PhotoLibrarySource {
                        _ = try photos.removableAsset(for: asset)
                    } else { throw CleanupError.unavailableSource }
                }
            }
        }
    }

    public func scan(downloads: Set<AssetID> = [],
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in },
                     accounting: @escaping @Sendable (ScanAccounting) -> Void = { _ in },
                     downloadUpdate: @escaping @Sendable (PhotoLibrarySource.DownloadUpdate) -> Void = { _ in }) async throws -> AppleScanReceipt {
        try requireIdle()
        working = true
        defer { working = false }
        return try await engine.scan(nativeSources(downloads: downloads, allowsDownloads: !preferences.bool(forKey: "skipCloud"),
            downloadUpdate: downloadUpdate), review: core,
            refreshing: downloads, progress: progress, accounting: accounting)
    }

    public func clearCache() async throws {
        try requireIdle()
        try await engine.clearCache()
    }

    public func prepareCleanup(expectedRevision: UInt64) throws -> CoreCleanupHeader {
        try requireIdle()
        return try coreResult { try core.startCleanup(expectedRevision: expectedRevision) }
    }

    public func cleanupGroups(operation: String, offset: UInt64, limit: UInt32) throws -> [CoreCleanupGroupSummary] {
        try coreResult { try core.cleanupGroupsPage(operation: operation, offset: offset, limit: limit) }
    }

    public func cleanupItems(operation: String, group: UInt64, offset: UInt64, limit: UInt32) throws -> [CoreCleanupItem] {
        try coreResult { try core.cleanupItemsPage(operation: operation, group: group, offset: offset, limit: limit) }
    }

    public func cancelPreparedCleanup(operation: String) throws {
        try requireIdle()
        _ = try coreResult { try core.cancelCleanup(operation: operation) }
    }

    public func applyPreparedCleanup(operation: String) async throws -> AppleCleanupReceipt {
        try requireIdle()
        working = true
        defer { working = false }
        return try await cleanup.apply(operation: operation, sources: nativeSources())
    }

    public func applyCleanup(expectedRevision: UInt64) async throws -> (operation: String, receipt: AppleCleanupReceipt) {
        let plan = try prepareCleanup(expectedRevision: expectedRevision)
        let receipt = try await applyPreparedCleanup(operation: plan.operation)
        return (plan.operation, receipt)
    }

    public func cleanupResults(operation: String, offset: UInt64, limit: UInt32) throws -> [CoreCleanupResult] {
        try coreResult { try core.cleanupResultsPage(operation: operation, completed: true, offset: offset, limit: limit) }
    }
}
