import AlbumWinnowRust
import Foundation
import Photos

extension PhotoScope {
    var coreValue: CorePhotoScope {
        CorePhotoScope(albums: albums, dates: dates.map { CoreCaptureRange(start: $0.start.timeIntervalSince1970,
            end: $0.end.timeIntervalSince1970, includesUnknown: $0.includesUnknown) })
    }
}

extension PhotoAsset {
    public init(_ value: CoreReviewAsset) {
        self.init(id: AssetID(value.id), name: value.name, revision: value.revision,
            photoProperties: value.properties.map { PhotoProperties(isLivePhoto: $0 & 1 != 0, hasEdits: $0 & 2 != 0, hasAlternatePhoto: $0 & 4 != 0) },
            byteCount: value.byteCount.flatMap(Int64.init(exactly:)), captureDate: value.captureDate.map(Date.init(timeIntervalSince1970:)), burstIdentifier: value.burst)
    }

    func reviewValue(kind: CoreSourceKind, nativeIdentity: String? = nil, linkCount: UInt64? = nil) -> CoreReviewAsset {
        CoreReviewAsset(id: id.coreValue, name: name, revision: revision, kind: kind,
            properties: photoProperties.map { ($0.isLivePhoto ? 1 : 0) | ($0.hasEdits ? 2 : 0) | ($0.hasAlternatePhoto ? 4 : 0) },
            byteCount: byteCount.flatMap(UInt64.init(exactly:)), captureDate: captureDate?.timeIntervalSince1970,
            burst: burstIdentifier, nativeIdentity: nativeIdentity, linkCount: linkCount)
    }
}

struct AppleProtectionSnapshot: Sendable {
    let locked: [CoreReviewAsset]
    let readOnlySources: Set<String>

    init(session: RustReviewSession) throws {
        readOnlySources = Set(try session.header().readOnlySources)
        var locked: [CoreReviewAsset] = []
        while true {
            let page = try session.lockedPage(offset: UInt64(locked.count), limit: 256)
            locked.append(contentsOf: page)
            if page.count < 256 { break }
        }
        self.locked = locked
    }
}

/// Native services and registered identities, including inactive protected roots.
/// The caller retains the corresponding security-scoped authorization leases.
public struct AppleAssetSources: Sendable {
    let sources: [String: any AssetSource]
    let registered: [String: CoreSourceRecord]
    let sourceOrder: [String]

    public init(sources: [any AssetSource], registered: [CoreSourceRecord]) throws {
        guard Set(sources.map(\.id)).count == sources.count,
              Set(registered.map(\.id)).count == registered.count else { throw CleanupError.invalidSelection }
        let records = Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0) })
        guard sources.allSatisfy({ records[$0.id] != nil }) else { throw CleanupError.unavailableSource }
        sourceOrder = sources.map(\.id)
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        self.registered = records
    }

    func validateScanSource(_ source: any AssetSource, settings: CoreReviewSettings) throws {
        guard let record = registered[source.id], record.active else { throw ScanError.invalidSourceSnapshot }
        switch source {
        case let folder as FileSystemSource:
            guard record.kind == .fileSystem, record.nativeNamespace == FileSystemSource.sourceIdentityNamespace,
                  try record.nativeIdentity == folder.sourceIdentity() else { throw ScanError.invalidSourceSnapshot }
        case let photos as PhotoLibrarySource:
            guard record.kind == .photoLibrary, record.nativeNamespace == PhotoLibrarySource.sourceIdentityNamespace,
                  record.nativeIdentity == PhotoLibrarySource.sourceIdentity,
                  photos.scope.coreValue == settings.photoScope else { throw ScanError.invalidSourceSnapshot }
        default:
            guard record.kind == .controlledTest else { throw ScanError.invalidSourceSnapshot }
        }
    }

    func source(for asset: CoreReviewAsset) throws -> any AssetSource {
        guard let source = sources[asset.id.sourceId] else { throw CleanupError.unavailableSource }
        return source
    }

    private func validRoot(_ folder: FileSystemSource, record: CoreSourceRecord) throws {
        guard record.kind == .fileSystem, record.nativeNamespace == FileSystemSource.sourceIdentityNamespace,
              try record.nativeIdentity == folder.sourceIdentity() else { throw CleanupError.unavailableSource }
    }

    func facts(for expected: CoreReviewAsset, removing: Bool, protection: AppleProtectionSnapshot,
               cancellation: CancellationHandle) throws -> CoreRemovalFacts {
        try cancellation.check()
        let source = try source(for: expected)
        guard let record = registered[expected.id.sourceId] else { throw CleanupError.unavailableSource }
        let asset = PhotoAsset(expected)
        switch source {
        case let folder as FileSystemSource:
            try validRoot(folder, record: record)
            let current = try folder.currentDescription(for: asset)
            let identity = try folder.nativeIdentity(for: current)
            let links = try folder.linkCount(for: current)
            let url = try folder.currentURL(for: current)
            var complete = true
            var insideReadOnlyRoot = false
            var matchesSavedLock = false
            if removing {
                for sourceID in protection.readOnlySources {
                    try cancellation.check()
                    guard let protectedRecord = registered[sourceID] else { complete = false; continue }
                    guard protectedRecord.kind == .fileSystem else { continue }
                    guard let root = sources[sourceID] as? FileSystemSource else { complete = false; continue }
                    do {
                        try validRoot(root, record: protectedRecord)
                        let path = root.directory.path
                        insideReadOnlyRoot = insideReadOnlyRoot || url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
                    } catch { complete = false }
                }
                for locked in protection.locked where locked.kind == .fileSystem {
                    try cancellation.check()
                    guard let root = sources[locked.id.sourceId] as? FileSystemSource,
                          let protectedRecord = registered[locked.id.sourceId] else { complete = false; continue }
                    do {
                        try validRoot(root, record: protectedRecord)
                        if let liveIdentity = try root.protectionIdentity(for: AssetID(locked.id)) {
                            matchesSavedLock = matchesSavedLock || liveIdentity == identity
                        } else if locked.nativeIdentity == nil { complete = false }
                    } catch { complete = false }
                }
            }
            let removable = !removing || (current.photoProperties?.hasAssociatedResources != true && FileManager.default.isDeletableFile(atPath: url.path))
            return CoreRemovalFacts(asset: current.reviewValue(kind: .fileSystem, nativeIdentity: identity, linkCount: links),
                sourceNamespace: FileSystemSource.sourceIdentityNamespace, sourceIdentity: try folder.sourceIdentity(),
                accessible: true, inScanScope: true, independentlyRemovable: removable, insideReadOnlyRoot: insideReadOnlyRoot,
                matchesSavedLock: matchesSavedLock, protectionComplete: complete)
        case let photos as PhotoLibrarySource:
            guard record.kind == .photoLibrary else { throw CleanupError.unsupportedSource }
            let current = try photos.currentDescription(for: asset)
            let nativeAsset = try photos.currentAsset(for: asset)
            let removable = !removing || (current.photoProperties?.hasAssociatedResources != true && nativeAsset.canPerform(.delete))
            return CoreRemovalFacts(asset: current.reviewValue(kind: .photoLibrary),
                sourceNamespace: PhotoLibrarySource.sourceIdentityNamespace, sourceIdentity: PhotoLibrarySource.sourceIdentity,
                accessible: true, inScanScope: true, independentlyRemovable: removable, insideReadOnlyRoot: false,
                matchesSavedLock: false, protectionComplete: true)
        default: throw CleanupError.unsupportedSource
        }
    }
}

extension PhotoScope {
    public init(_ value: CorePhotoScope) throws {
        self.init()
        albums = value.albums
        dates = try value.dates.map(CaptureRange.init)
    }
}

extension CaptureRange {
    init(_ value: CoreCaptureRange) throws {
        _ = try coreResult { try coreCaptureRangeContains(range: value, date: nil) }
        start = Date(timeIntervalSince1970: value.start)
        end = Date(timeIntervalSince1970: value.end)
        includesUnknown = value.includesUnknown
    }
}
