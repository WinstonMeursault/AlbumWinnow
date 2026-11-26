import AlbumWinnowRust
import Foundation

public actor ScanEngine {
    private struct IndexedAsset: Sendable {
        let asset: PhotoAsset
        let fingerprint: ImageFingerprint

        func coreValue(nativeIdentity: String? = nil) throws -> ScanItemInput {
            ScanItemInput(asset: asset.id.coreValue, revision: asset.revision, fingerprint: try fingerprint.coreValue,
                          associatedResources: asset.photoProperties?.hasAssociatedResources == true, nativeIdentity: nativeIdentity)
        }

        var evidence: PhotoEvidence {
            var evidence = PhotoEvidence(width: fingerprint.width, height: fingerprint.height,
                bitDepth: fingerprint.observedBitDepth, hasWideColor: fingerprint.hasWideColor,
                edgeContrast: fingerprint.edgeDetail)
            evidence.captureDate = asset.captureDate ?? fingerprint.captureDate
            return evidence
        }
    }

    private enum Preparation: Sendable {
        case ready(PhotoAsset, PreparedImage)
        case failed(AssetIssue)
        case cancelled
        case coreFailed(RustCoreFailure)
    }

    private let cache: ScanCache
    private let parallelism: Int
    private var scanning = false

    public init(cacheURL: URL, parallelism: Int = 2) throws {
        cache = try ScanCache(url: cacheURL)
        self.parallelism = min(4, max(1, parallelism))
    }

    public func clearCache() throws {
        guard !scanning else { throw ScanError.scanInProgress }
        try cache.clear()
    }

    public func scan(
        _ native: AppleAssetSources,
        review: RustReviewSession,
        refreshing: Set<AssetID> = [],
        progress: @Sendable (ScanProgress) -> Void = { _ in },
        accounting: @Sendable (ScanAccounting) -> Void = { _ in }
    ) async throws -> AppleScanReceipt {
        guard !scanning else { throw ScanError.scanInProgress }
        let header = try coreResult { try review.header() }
        var registered = [String: CoreSourceRecord]()
        var offset: UInt64 = 0
        while true {
            let page = try coreResult { try review.sourcesPage(offset: offset, limit: 256) }
            for record in page { registered[record.id] = record }
            offset += UInt64(page.count)
            if page.count < 256 { break }
        }
        guard registered == native.registered else { throw ScanError.invalidSourceSnapshot }
        let comparisonSides = header.settings.sides.map { ComparisonSides(first: $0.first, second: $0.second) }
        let preferredSource = header.settings.preferredSource
        let includeSimilarScenes = header.settings.similarScenesEnabled
        let active = registered.values.filter(\.active)
        let unavailable = active.filter { native.sources[$0.id] == nil }.map(\.id).sorted()
        let sources = try native.sourceOrder.compactMap { id -> (any AssetSource)? in
            guard registered[id]?.active == true else { return nil }
            if let sides = comparisonSides, id != sides.first && id != sides.second { return nil }
            guard let source = native.sources[id] else { throw ScanError.invalidSourceSnapshot }
            try native.validateScanSource(source, settings: header.settings)
            return source
        }
        let sourceIDs = sources.map(\.id)
        try comparisonSides?.validate(sources: Set(sourceIDs))
        let operationID = UUID().uuidString
        try coreResult { try review.beginScan(expectedRevision: header.metadata.revision, operationId: operationID) }
        defer { try? review.discardScan(operationId: operationID) }
        scanning = true
        defer { scanning = false }

        let cancellation = CancellationHandle()
        return try await withTaskCancellationHandler {
            var allIDs = Set<AssetID>()
            var indexedPaths = Set<String>()
            var ignoredCount = 0
            var issues = [AssetIssue]()
            var indexed = [IndexedAsset]()
            var pending: [(source: any AssetSource, asset: PhotoAsset)] = []

            for source in sources {
                try Task.checkCancellation()
                let snapshot = try await source.snapshot()
                issues.append(contentsOf: snapshot.issues)
                let previouslyIndexed = try cache.signatures(source: source.id, cancellation: cancellation)
                for asset in snapshot.assets {
                    guard asset.id.source == source.id, allIDs.insert(asset.id).inserted else {
                        throw ScanError.invalidSourceSnapshot
                    }
                    if source is FileSystemSource, !indexedPaths.insert(asset.id.item).inserted {
                        ignoredCount += 1
                        continue
                    }
                    if !refreshing.contains(asset.id), let entry = previouslyIndexed[asset.id.item], asset.revision == entry.revision {
                        do {
                            try await source.validateCachedAvailability(for: asset)
                            indexed.append(IndexedAsset(asset: asset, fingerprint: entry.signature))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            issues.append(Self.issue(for: asset.id, error: error, source: source))
                        }
                    } else {
                        pending.append((source, asset))
                    }
                }
            }

            let reusedIDs = Set(indexed.map { $0.asset.id })
            let reused = indexed.count
            let expected = allIDs.count - ignoredCount + Set(issues.map(\.id)).subtracting(allIDs).count
            var skippedIDs = Set(issues.filter { $0.reason == .cloudSkipped }.map(\.id))
            var failedIDs = Set(issues.filter { $0.reason != .cloudSkipped }.map(\.id))
            accounting(ScanAccounting(processed: indexed.count, skipped: skippedIDs.count, failed: failedIDs.count,
                                      unfinished: max(0, expected - indexed.count - skippedIDs.count - failedIDs.count)))
            var completed = reused
            let total = reused + pending.count
            progress(.fingerprinting(completed: completed, total: total))
            let batchSize = 16
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = pending[start..<min(start + batchSize, pending.count)]
                let output = await prepare(batch, cancellation: cancellation)
                var prepared: [(PhotoAsset, PreparedImage)] = []
                for item in output {
                    switch item {
                    case let .ready(asset, image):
                        prepared.append((asset, image))
                        indexed.append(IndexedAsset(asset: asset, fingerprint: image.fingerprint))
                        completed += 1
                    case let .failed(issue):
                        issues.append(issue)
                        if issue.reason == .cloudSkipped { skippedIDs.insert(issue.id) } else { failedIDs.insert(issue.id) }
                        completed += 1
                    case .cancelled:
                        break
                    case let .coreFailed(failure):
                        throw failure
                    }
                }
                try cache.store(prepared, cancellation: cancellation)
                accounting(ScanAccounting(processed: indexed.count, skipped: skippedIDs.count, failed: failedIDs.count,
                                          unfinished: max(0, expected - indexed.count - skippedIDs.count - failedIDs.count)))
                progress(.fingerprinting(completed: completed, total: total))
            }

            pending.removeAll(keepingCapacity: false)
            indexedPaths.removeAll(keepingCapacity: false)
            try Task.checkCancellation()
            let (detection, comparisonIssues) = try await findGroups(indexed, sources: sources, review: review, registered: registered, operationID: operationID, sides: comparisonSides, preferredSource: preferredSource, cancellation: cancellation, progress: progress)
            var sceneSession: RustSceneSession?
            if includeSimilarScenes {
                var candidates = Set<AssetID>()
                var offset: UInt64 = 0
                while true {
                    let page = try coreResult { try detection.sceneCandidatePage(offset: offset, limit: 16) }
                    if page.isEmpty { break }
                    candidates.formUnion(page.map(AssetID.init))
                    offset += UInt64(page.count)
                }
                let (scenes, sceneIssues) = try await findScenes(indexed.filter { candidates.contains($0.asset.id) }, sources: sources,
                    refreshing: refreshing, operationID: operationID, sides: comparisonSides, preferredSource: preferredSource, cancellation: cancellation, progress: progress)
                sceneSession = scenes
                issues.append(contentsOf: sceneIssues)
            }
            issues.append(contentsOf: comparisonIssues)
            skippedIDs = Set(issues.filter { $0.reason == .cloudSkipped }.map(\.id))
            failedIDs = Set(issues.filter { $0.reason != .cloudSkipped }.map(\.id)).subtracting(skippedIDs)
            let successfulIDs = Set(indexed.map { $0.asset.id }).subtracting(skippedIDs).subtracting(failedIDs)
            accounting(ScanAccounting(processed: successfulIDs.count, skipped: skippedIDs.count, failed: failedIDs.count, unfinished: 0))
            let successfulReused = successfulIDs.intersection(reusedIDs).count
            try Task.checkCancellation()
            for source in sources { try native.validateScanSource(source, settings: header.settings) }
            let metadata = try coreResult {
                try review.finishDetectedScan(operationId: operationID, detection: detection, scenes: sceneSession,
                                              cancellation: cancellation)
            }
            // Separate databases cannot share a transaction. Prune derived data
            // only after review commits, and always acknowledge that commit.
            let maintenance: ScanCacheMaintenance
            do {
                try cache.finish(assetIDs: allIDs, sources: sourceIDs, cancellation: cancellation)
                maintenance = .completed
            } catch is CancellationError {
                maintenance = .cancelled
            } catch {
                maintenance = .failed(((error as? RustCoreFailure)?.underlying ?? error).localizedDescription)
            }
            return AppleScanReceipt(metadata: metadata,
                issues: Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    .values.sorted { Self.precedes($0.id, $1.id) },
                scanned: successfulIDs.count - successfulReused, reused: successfulReused, unavailableSources: unavailable, cacheMaintenance: maintenance)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func prepare(_ batch: ArraySlice<(source: any AssetSource, asset: PhotoAsset)>, cancellation: CancellationHandle) async -> [Preparation] {
        let concurrency = parallelism
        return await withTaskGroup(of: Preparation.self) { group in
            var remaining = batch.makeIterator()
            for _ in 0..<concurrency {
                guard let next = remaining.next() else { break }
                group.addTask { await Self.prepare(next.asset, using: next.source, cancellation: cancellation) }
            }
            var results = [Preparation]()
            for await result in group {
                results.append(result)
                if let next = remaining.next() {
                    _ = group.addTaskUnlessCancelled { await Self.prepare(next.asset, using: next.source, cancellation: cancellation) }
                }
            }
            return results
        }
    }

    private static func prepare(_ asset: PhotoAsset, using source: any AssetSource, cancellation: CancellationHandle) async -> Preparation {
        do {
            try Task.checkCancellation()
            let input = try await source.imageInput(for: asset)
            try Task.checkCancellation()
            let image = try autoreleasepool { try PreparedImage(input: input, cancellation: cancellation) }
            try source.validateImage(for: asset)
            return .ready(asset, image)
        } catch is CancellationError {
            return Task.isCancelled ? .cancelled : .failed(AssetIssue(id: asset.id, reason: .inaccessible))
        } catch let failure as RustCoreFailure {
            return .coreFailed(failure)
        } catch {
            return .failed(issue(for: asset.id, error: error, source: source))
        }
    }

    private static func issue(for id: AssetID, error: any Error, source: any AssetSource) -> AssetIssue {
        let reason: AssetIssueReason
        switch error {
        case AssetAccessError.changedDuringScan: reason = .changedDuringScan
        case AssetAccessError.cloudDownloadRequired: reason = source.skipsCloudAsset(id) ? .cloudSkipped : .cloudDownloadRequired
        case is PhotoLibraryDownloadError, AssetAccessError.cloudDownloadFailed: reason = .cloudDownloadFailed
        case ImageReadError.unreadableImage: reason = .unreadableImage
        case is ImageReadError: reason = .unsupportedImage
        default: reason = .inaccessible
        }
        return AssetIssue(id: id, reason: reason, detail: (error as? PhotoLibraryDownloadError)?.localizedDescription)
    }

    private func findGroups(
        _ assets: [IndexedAsset], sources: [any AssetSource], review: RustReviewSession,
        registered: [String: CoreSourceRecord], operationID: String, sides: ComparisonSides?, preferredSource: String?,
        cancellation: CancellationHandle, progress: (ScanProgress) -> Void
    ) async throws -> (RustScanSession, [AssetIssue]) {
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.asset.id, $0) })
        let session = try coreResult {
            try RustScanSession(operationId: operationID, sourceIds: sources.map(\.id),
                                sides: sides.map { CoreComparisonSides(first: $0.first, second: $0.second) },
                                preferredSource: preferredSource, cancellation: cancellation)
        }
        var issues = [AssetIssue]()
        for start in stride(from: 0, to: assets.count, by: 16) {
            try Task.checkCancellation()
            var items = [ScanItemInput]()
            var metadata = [CoreScanReviewAsset]()
            for indexed in assets[start..<min(start + 16, assets.count)] {
                do {
                    let item = try autoreleasepool {
                        guard let source = sourcesByID[indexed.asset.id.source],
                              let record = registered[indexed.asset.id.source] else { throw ScanError.invalidSourceSnapshot }
                        try source.validateImage(for: indexed.asset)
                        let folder = source as? FileSystemSource
                        let identity = try folder?.nativeIdentity(for: indexed.asset)
                        let links = try folder?.linkCount(for: indexed.asset)
                        let evidence = indexed.evidence
                        let item = try indexed.coreValue(nativeIdentity: identity)
                        metadata.append(CoreScanReviewAsset(asset: indexed.asset.reviewValue(kind: record.kind,
                            nativeIdentity: identity, linkCount: links), evidence: CoreReviewEvidence(
                                asset: indexed.asset.id.coreValue, width: UInt32(evidence.width), height: UInt32(evidence.height),
                                bitDepth: evidence.bitDepth.flatMap(UInt16.init(exactly:)), wideColor: evidence.hasWideColor,
                                edgeDetail: evidence.edgeContrast, captureDate: evidence.captureDate?.timeIntervalSince1970)))
                        return item
                    }
                    items.append(item)
                } catch is CancellationError { throw CancellationError() }
                catch let failure as RustCoreFailure { throw failure }
                catch {
                    guard let source = sourcesByID[indexed.asset.id.source] else { throw ScanError.invalidSourceSnapshot }
                    issues.append(Self.issue(for: indexed.asset.id, error: error, source: source))
                }
            }
            try coreResult { try session.appendPrepared(items: items) }
            try coreResult { try review.appendScanAssets(operationId: operationID, assets: metadata, cancellation: cancellation) }
        }
        try coreResult { try session.completePreparation() }
        while true {
            try Task.checkCancellation()
            let batch = try coreResult { try session.nextBatch(maximum: 16) }
            progress(.comparing(completed: Int(clamping: batch.completed), total: Int(clamping: batch.total)))
            if batch.done { break }
            var results = [CoreTaskResult]()
            for task in batch.tasks {
                let firstID = AssetID(task.first), secondID = AssetID(task.second)
                guard let first = assetsByID[firstID], let second = assetsByID[secondID],
                      let firstSource = sourcesByID[firstID.source], let secondSource = sourcesByID[secondID.source],
                      first.asset.revision == task.firstRevision, second.asset.revision == task.secondRevision else {
                    throw ScanError.invalidSourceSnapshot
                }
                do {
                    try autoreleasepool {
                        try DuplicateDetector.validateComparisonImage(first.asset, source: firstSource)
                        try DuplicateDetector.validateComparisonImage(second.asset, source: secondSource)
                    }
                    let match: DuplicateMatch
                    if task.exactIdentity { match = .exactDuplicate }
                    else if try autoreleasepool(invoking: {
                        try DuplicateDetector.verifyPixels(cache.sample(for: first.asset), cache.sample(for: second.asset), cancellation: cancellation)
                    }) {
                        match = try await DuplicateDetector.compare(first.asset, source: firstSource, second.asset,
                                                                     source: secondSource, cancellation: cancellation)
                    } else { match = .distinct }
                    try autoreleasepool {
                        try DuplicateDetector.validateComparisonImage(first.asset, source: firstSource)
                        try DuplicateDetector.validateComparisonImage(second.asset, source: secondSource)
                    }
                    results.append(CoreTaskResult(taskId: task.taskId, outcome: .matched(kind: match.coreValue)))
                } catch is CancellationError { throw CancellationError() }
                catch let failure as RustCoreFailure { throw failure }
                catch {
                    let context = error as? ComparisonReadError
                    let failedID = context?.assetID ?? secondID
                    let source = sourcesByID[failedID.source] ?? secondSource
                    issues.append(Self.issue(for: failedID, error: context?.underlying ?? error, source: source))
                    results.append(CoreTaskResult(taskId: task.taskId, outcome: .failed(asset: failedID.coreValue)))
                }
            }
            try coreResult { try session.submitResults(operationId: operationID, batchId: batch.batchId, results: results) }
        }
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let validations = try coreResult { try session.finalValidationPage(offset: offset, limit: 16) }
            if validations.isEmpty { break }
            var facts = [CoreAssetValidation]()
            for key in validations {
                let id = AssetID(key)
                guard let indexed = assetsByID[id], let source = sourcesByID[id.source] else { throw ScanError.invalidSourceSnapshot }
                do {
                    try autoreleasepool { try source.validateImage(for: indexed.asset) }
                    facts.append(CoreAssetValidation(asset: key, revision: indexed.asset.revision, accessible: true))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    issues.append(Self.issue(for: id, error: error, source: source))
                    facts.append(CoreAssetValidation(asset: key, revision: nil, accessible: false))
                }
            }
            try coreResult { try session.submitFinalValidations(operationId: operationID, validations: facts) }
            offset += UInt64(validations.count)
        }
        return (session, issues)
    }

    private func findScenes(_ assets: [IndexedAsset], sources: [any AssetSource], refreshing: Set<AssetID>,
                            operationID: String, sides: ComparisonSides?, preferredSource: String?, cancellation: CancellationHandle,
                            progress: (ScanProgress) -> Void) async throws -> (RustSceneSession, [AssetIssue]) {
        let sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var items: [SceneItem] = []
        var issues: [AssetIssue] = []
        for (position, indexed) in assets.enumerated() {
            try Task.checkCancellation()
            progress(.similarity(completed: position, total: assets.count * 2))
            guard let source = sources[indexed.asset.id.source] else { throw ScanError.invalidSourceSnapshot }
            do {
                let cached = refreshing.contains(indexed.asset.id) ? nil : try cache.sceneFeature(for: indexed.asset)
                let feature: SceneFeature
                if let cached { feature = cached }
                else {
                    let input = try await source.imageInput(for: indexed.asset)
                    feature = try autoreleasepool { try SceneFeature(input: input, cancellation: cancellation) }
                    try source.validateImage(for: indexed.asset)
                    try cache.storeSceneFeature(feature, for: indexed.asset)
                }
                try source.validateImage(for: indexed.asset)
                items.append(SceneItem(asset: indexed.asset, evidence: indexed.evidence, feature: feature,
                                       nativeIdentity: try (source as? FileSystemSource)?.nativeIdentity(for: indexed.asset),
                                       bitDepth: indexed.fingerprint.bitDepth))
            } catch is CancellationError { throw CancellationError() }
            catch let failure as RustCoreFailure { throw failure }
            catch {
                let issue = Self.issue(for: indexed.asset.id, error: error, source: source)
                let reason: AssetIssueReason = [AssetIssueReason.cloudSkipped, .cloudDownloadRequired, .cloudDownloadFailed, .changedDuringScan].contains(issue.reason) ? issue.reason : .sceneAnalysisFailed
                issues.append(AssetIssue(id: issue.id, reason: reason, detail: issue.detail ?? error.localizedDescription))
            }
        }
        let session = try SceneGrouping.detect(items, operation: operationID, sides: sides, preferredSource: preferredSource, cancellation: cancellation, validate: { asset in
            guard let source = sources[asset.id.source] else { throw ScanError.invalidSourceSnapshot }
            try DuplicateDetector.validateComparisonImage(asset, source: source)
        }) { progress(.similarity(completed: assets.count + $0, total: assets.count + items.count)) }
        return (session, issues)
    }

    private static func precedes(_ lhs: AssetID, _ rhs: AssetID) -> Bool {
        lhs.source == rhs.source ? lhs.item < rhs.item : lhs.source < rhs.source
    }
}
