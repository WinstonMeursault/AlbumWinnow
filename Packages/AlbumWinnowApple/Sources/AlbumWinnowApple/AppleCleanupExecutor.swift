import AlbumWinnowRust
import Foundation
import os
import Photos

public struct AppleCleanupDiagnostic: Sendable {
    public let reason: CoreCleanupReason?
    public let detail: String?
}

public struct AppleCleanupReceipt: Sendable {
    public let metadata: CoreReviewMetadata
    public let trashLocations: [CoreCleanupKey: URL]
    public let diagnostics: [CoreCleanupKey: AppleCleanupDiagnostic]
    public let interruption: String?
}

private struct CleanupRejection: LocalizedError {
    let reason: CoreCleanupReason
    var errorDescription: String? {
        switch reason {
        case .stalePlan, .changedAsset: CleanupError.changedAsset.errorDescription
        case .invalidSelection: CleanupError.invalidSelection.errorDescription
        case .unavailableSource: CleanupError.unavailableSource.errorDescription
        case .unavailableProtection: CleanupError.unavailableProtection.errorDescription
        case .protectedResources: CleanupError.protectedResources.errorDescription
        case .userProtected: CleanupError.userProtected.errorDescription
        case .readOnlySource: CleanupError.readOnlySource.errorDescription
        case .sameFile: CleanupError.sameFile.errorDescription
        case .noLongerDuplicate: CleanupError.noLongerDuplicate.errorDescription
        case .operationInProgress: CleanupError.operationInProgress.errorDescription
        case .inaccessible: "This photo is no longer accessible from its source."
        case .cancelled: "Cleanup was cancelled."
        }
    }
}
private struct NativeCleanupResult: Sendable {
    let keys: [CoreCleanupKey]
    let trashLocation: URL?
    let diagnostic: String?
}
private struct PhotoBatchState: Sendable {
    var ticket: CoreCleanupTicket?
    var error: (any Error)?
}

/// Executes only the core's transient plan. No permanently deleting fallback.
public actor AppleCleanupExecutor {
    private let session: RustReviewSession
    private var applying = false

    public init(session: RustReviewSession) { self.session = session }

    public func apply(operation: String, sources: AppleAssetSources,
                      cancellation: CancellationHandle = CancellationHandle()) async throws -> AppleCleanupReceipt {
        guard !applying else { throw CleanupError.operationInProgress }
        applying = true
        defer { applying = false }
        return try await withTaskCancellationHandler {
            try await execute(operation: operation, sources: sources, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    private func execute(operation: String, sources: AppleAssetSources,
                         cancellation: CancellationHandle) async throws -> AppleCleanupReceipt {
        _ = try session.cleanupHeader(operation: operation)
        var registered: [String: CoreSourceRecord] = [:]
        var sourceOffset: UInt64 = 0
        while true {
            let page = try session.sourcesPage(offset: sourceOffset, limit: 256)
            for record in page { registered[record.id] = record }
            sourceOffset += UInt64(page.count)
            if page.count < 256 { break }
        }
        guard registered == sources.registered else { throw CleanupError.unavailableSource }
        let scope = try session.header().settings.photoScope
        for source in sources.sources.values {
            if let photos = source as? PhotoLibrarySource, photos.scope.coreValue != scope { throw CleanupError.changedAsset }
        }
        let protection = try AppleProtectionSnapshot(session: session)
        var locations: [CoreCleanupKey: URL] = [:]
        var diagnostics: [CoreCleanupKey: AppleCleanupDiagnostic] = [:]
        var offset: UInt64 = 0
        var interruption: String?
        do {
            while true {
                try cancellation.check()
                let groups = try session.cleanupGroupsPage(operation: operation, offset: offset, limit: 256)
                for group in groups {
                    try cancellation.check()
                    if group.deleteAll {
                        do {
                            try Self.requirePass(session.beginCleanupPreflight(operation: operation, group: group.index))
                            var itemOffset: UInt64 = 0
                            while true {
                                let page = try session.cleanupItemsPage(operation: operation, group: group.index, offset: itemOffset, limit: 16)
                                let facts = try page.map { try sources.facts(for: $0.pair.remove, removing: true, protection: protection, cancellation: cancellation) }
                                try Self.requirePass(session.appendCleanupPreflight(operation: operation, group: group.index, facts: facts, cancellation: cancellation))
                                itemOffset += UInt64(page.count)
                                if page.count < 16 { break }
                            }
                            try Self.requirePass(session.finishCleanupPreflight(operation: operation, group: group.index))
                        } catch {
                            try skipGroup(operation: operation, group: group.index, error: error, diagnostics: &diagnostics)
                            try cancellation.check()
                            continue
                        }
                    }
                    var itemOffset: UInt64 = 0
                    while true {
                        try cancellation.check()
                        let page = try session.cleanupItemsPage(operation: operation, group: group.index, offset: itemOffset, limit: 16)
                        var photos: [(CoreCleanupItem, CoreComparisonProof)] = []
                        for item in page {
                            try cancellation.check()
                            do {
                                let proof = try await Self.proof(for: item, sources: sources, cancellation: cancellation)
                                switch try sources.source(for: item.pair.remove) {
                                case is FileSystemSource:
                                    let result = try Self.moveFile(item, operation: operation, proof: proof, session: session, sources: sources, protection: protection, cancellation: cancellation)
                                    if let url = result.trashLocation { locations[item.key] = url }
                                    if let diagnostic = result.diagnostic { diagnostics[item.key] = AppleCleanupDiagnostic(reason: nil, detail: diagnostic) }
                                case is PhotoLibrarySource: photos.append((item, proof))
                                default: throw CleanupError.unsupportedSource
                                }
                            } catch {
                                try skip(item.key, operation: operation, error: error, diagnostics: &diagnostics)
                                if error is RustCoreFailure || error is BridgeError { throw error }
                                if let rejection = error as? CleanupRejection, rejection.reason == .stalePlan { throw error }
                            }
                        }
                        if !photos.isEmpty {
                            do {
                                let result = try await Self.movePhotos(photos, operation: operation, session: session, sources: sources, protection: protection, cancellation: cancellation)
                                if let diagnostic = result.diagnostic { for key in result.keys { diagnostics[key] = AppleCleanupDiagnostic(reason: nil, detail: diagnostic) } }
                            } catch {
                                for (item, _) in photos { try skip(item.key, operation: operation, error: error, diagnostics: &diagnostics) }
                            }
                        }
                        itemOffset += UInt64(page.count)
                        if page.count < 16 { break }
                    }
                }
                offset += UInt64(groups.count)
                if groups.count < 256 { break }
            }
        } catch {
            try Self.requirePass(session.cancelCleanup(operation: operation))
            if !Self.isCancelled(error) { interruption = error.localizedDescription }
        }
        if Task.isCancelled { try Self.requirePass(session.cancelCleanup(operation: operation)) }
        let metadata = try session.finishCleanup(operation: operation)
        return AppleCleanupReceipt(metadata: metadata, trashLocations: locations, diagnostics: diagnostics, interruption: interruption)
    }

    private func skip(_ key: CoreCleanupKey, operation: String, error: any Error,
                      diagnostics: inout [CoreCleanupKey: AppleCleanupDiagnostic]) throws {
        switch Self.outcome(error) {
        case .failed: try Self.requirePass(session.failCleanupItem(operation: operation, key: key))
        case .skipped(let reason): try Self.requirePass(session.skipCleanupItem(operation: operation, key: key, reason: reason))
        default: throw BridgeError.InvalidState
        }
        diagnostics[key] = Self.diagnostic(error)
    }
    private func skipGroup(operation: String, group: UInt64, error: any Error,
                           diagnostics: inout [CoreCleanupKey: AppleCleanupDiagnostic]) throws {
        var offset: UInt64 = 0
        while true {
            let page = try session.cleanupItemsPage(operation: operation, group: group, offset: offset, limit: 16)
            for item in page { try skip(item.key, operation: operation, error: error, diagnostics: &diagnostics) }
            offset += UInt64(page.count)
            if page.count < 16 { break }
        }
    }
    private static func requirePass(_ reason: CoreCleanupReason?) throws {
        if let reason { throw CleanupRejection(reason: reason) }
    }
    private static func diagnostic(_ error: any Error) -> AppleCleanupDiagnostic {
        if let error = error as? ComparisonReadError { return diagnostic(error.underlying) }
        if let error = error as? RustCoreFailure { return diagnostic(error.underlying) }
        if error is AssetAccessError || error is CleanupError || error is CleanupRejection || isCancelled(error) {
            return AppleCleanupDiagnostic(reason: reason(error), detail: nil)
        }
        return AppleCleanupDiagnostic(reason: nil, detail: error.localizedDescription)
    }
    private static func isCancelled(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case BridgeError.Cancelled = error { return true }
        if let rejection = error as? CleanupRejection { return rejection.reason == .cancelled }
        return false
    }
    private static func reason(_ error: any Error) -> CoreCleanupReason {
        if let error = error as? ComparisonReadError { return reason(error.underlying) }
        if let error = error as? RustCoreFailure { return reason(error.underlying) }
        if let error = error as? CleanupRejection { return error.reason }
        if isCancelled(error) { return .cancelled }
        return switch error {
        case AssetAccessError.changedDuringScan, CleanupError.changedAsset: .changedAsset
        case CleanupError.userProtected: .userProtected
        case CleanupError.readOnlySource: .readOnlySource
        case CleanupError.protectedResources: .protectedResources
        case CleanupError.sameFile: .sameFile
        case CleanupError.noLongerDuplicate: .noLongerDuplicate
        case CleanupError.unavailableSource: .unavailableSource
        case CleanupError.unavailableProtection: .unavailableProtection
        default: .inaccessible
        }
    }
    private static func outcome(_ error: any Error) -> CoreCleanupOutcome {
        if let error = error as? ComparisonReadError { return outcome(error.underlying) }
        if let error = error as? RustCoreFailure { return outcome(error.underlying) }
        if isCancelled(error) { return .skipped(reason: .cancelled) }
        if let rejection = error as? CleanupRejection {
            switch rejection.reason {
            case .inaccessible, .unavailableSource, .invalidSelection, .operationInProgress: return .failed
            default: return .skipped(reason: rejection.reason)
            }
        }
        switch error {
        case AssetAccessError.changedDuringScan, CleanupError.changedAsset, CleanupError.userProtected,
             CleanupError.readOnlySource, CleanupError.unavailableProtection, CleanupError.protectedResources,
             CleanupError.noLongerDuplicate, CleanupError.sameFile: return .skipped(reason: reason(error))
        default: return .failed
        }
    }
    private static func report(_ ticket: CoreCleanupTicket, outcome: CoreCleanupOutcome,
                               session: RustReviewSession) throws {
        let report = try session.reportCleanup(ticket: ticket, outcomes: Array(repeating: outcome, count: ticket.items.count))
        try requirePass(report.rejection)
    }
    private static func authorize(_ items: [CoreCleanupValidation], operation: String,
                                  session: RustReviewSession, cancellation: CancellationHandle) throws -> CoreCleanupTicket {
        let response = try session.authorizeCleanup(operation: operation, items: items, cancellation: cancellation)
        try requirePass(response.rejection)
        guard let ticket = response.ticket else { throw BridgeError.InvalidState }
        return ticket
    }
    private static func proof(for item: CoreCleanupItem, sources: AppleAssetSources,
                              cancellation: CancellationHandle) async throws -> CoreComparisonProof {
        try cancellation.check()
        guard let keep = item.pair.keep else { return .wholeGroup }
        let first = PhotoAsset(keep), second = PhotoAsset(item.pair.remove)
        let firstSource = try sources.source(for: keep), secondSource = try sources.source(for: item.pair.remove)
        if let provider = item.pair.scene {
            guard provider == SceneFeature.provider else { throw CleanupRejection(reason: .noLongerDuplicate) }
            let left = try await firstSource.imageInput(for: first), right = try await secondSource.imageInput(for: second)
            let proof = try autoreleasepool {
                let firstFeature = try SceneFeature(input: left, cancellation: cancellation)
                let secondFeature = try SceneFeature(input: right, cancellation: cancellation)
                return CoreComparisonProof.scene(provider: SceneFeature.provider, first: firstFeature.quality.coreValue,
                    second: secondFeature.quality.coreValue, sharedBurst: first.burstIdentifier.map { !$0.isEmpty && $0 == second.burstIdentifier } == true,
                    distance: try firstFeature.distance(to: secondFeature))
            }
            try DuplicateDetector.validateComparisonImage(first, source: firstSource)
            try DuplicateDetector.validateComparisonImage(second, source: secondSource)
            return proof
        }
        let match = try await DuplicateDetector.compare(first, source: firstSource, second, source: secondSource, cancellation: cancellation)
        return .pixels(kind: match.coreValue)
    }
    private static func validation(_ item: CoreCleanupItem, proof: CoreComparisonProof, sources: AppleAssetSources,
                                   protection: AppleProtectionSnapshot, cancellation: CancellationHandle) throws -> CoreCleanupValidation {
        let keep = try item.pair.keep.map { try sources.facts(for: $0, removing: false, protection: protection, cancellation: cancellation) }
        let remove = try sources.facts(for: item.pair.remove, removing: true, protection: protection, cancellation: cancellation)
        return CoreCleanupValidation(key: item.key, facts: CorePairFacts(keep: keep, remove: remove, proof: proof))
    }
    private static func moveFile(_ item: CoreCleanupItem, operation: String, proof: CoreComparisonProof, session: RustReviewSession,
                                 sources: AppleAssetSources, protection: AppleProtectionSnapshot,
                                 cancellation: CancellationHandle) throws -> NativeCleanupResult {
        guard let folder = try sources.source(for: item.pair.remove) as? FileSystemSource else { throw CleanupError.unsupportedSource }
        let asset = PhotoAsset(item.pair.remove)
        let url = try folder.currentURL(for: asset)
        var coordinationError: NSError?
        var result: Result<NativeCleanupResult, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            result = Result {
                try cancellation.check()
                guard try folder.removableURL(for: asset).path == coordinatedURL.standardizedFileURL.path else { throw CleanupError.changedAsset }
                let input = try validation(item, proof: proof, sources: sources, protection: protection, cancellation: cancellation)
                let ticket = try authorize([input], operation: operation, session: session, cancellation: cancellation)
                let moved: Result<URL?, any Error> = Result {
                    try requirePass(session.validateCleanupTicket(ticket: ticket))
                    try cancellation.check()
                    var location: NSURL?
                    try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: &location)
                    return location.map { $0 as URL }
                }
                switch moved {
                case .success(let location):
                    try report(ticket, outcome: .movedToTrash, session: session)
                    return NativeCleanupResult(keys: [item.key], trashLocation: location, diagnostic: nil)
                case .failure(let error):
                    try report(ticket, outcome: outcome(error), session: session)
                    return NativeCleanupResult(keys: [item.key], trashLocation: nil, diagnostic: error.localizedDescription)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AssetAccessError.inaccessible }
        return try result.get()
    }
    private static func movePhotos(_ items: [(CoreCleanupItem, CoreComparisonProof)], operation: String, session: RustReviewSession,
                                   sources: AppleAssetSources, protection: AppleProtectionSnapshot,
                                   cancellation: CancellationHandle) async throws -> NativeCleanupResult {
        let state = OSAllocatedUnfairLock(initialState: PhotoBatchState())
        let nativeOutcome: Result<Void, any Error>
        do {
            try await PHPhotoLibrary.shared().performChanges {
                do {
                    try cancellation.check()
                    let inputs = try items.map { try validation($0.0, proof: $0.1, sources: sources, protection: protection, cancellation: cancellation) }
                    let assets = try items.map { item, _ in
                        guard let photos = try sources.source(for: item.pair.remove) as? PhotoLibrarySource else { throw CleanupError.unsupportedSource }
                        return try photos.removableAsset(for: PhotoAsset(item.pair.remove))
                    }
                    let ticket = try authorize(inputs, operation: operation, session: session, cancellation: cancellation)
                    state.withLock { $0.ticket = ticket }
                    try requirePass(session.validateCleanupTicket(ticket: ticket))
                    try cancellation.check()
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                } catch { state.withLock { $0.error = error } }
            }
            nativeOutcome = .success(())
        } catch { nativeOutcome = .failure(error) }
        let completed = state.withLock { $0 }
        guard let ticket = completed.ticket else {
            if let error = completed.error { throw error }
            try nativeOutcome.get()
            throw BridgeError.InvalidState
        }
        let failure: (any Error)? = completed.error ?? {
            if case .failure(let error) = nativeOutcome { return error }
            return nil
        }()
        try report(ticket, outcome: failure.map(outcome) ?? .movedToRecentlyDeleted, session: session)
        return NativeCleanupResult(keys: items.map { $0.0.key }, trashLocation: nil, diagnostic: failure?.localizedDescription)
    }
}
