import Foundation

public actor ScanEngine {
    private struct IndexedAsset: Sendable {
        let asset: PhotoAsset
        let fingerprint: ImageFingerprint

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
        _ sources: [any AssetSource],
        refreshing: Set<AssetID> = [],
        progress: @Sendable (ScanProgress) -> Void = { _ in },
        accounting: @Sendable (ScanAccounting) -> Void = { _ in }
    ) async throws -> ScanResult {
        guard !scanning else { throw ScanError.scanInProgress }
        let sourceIDs = sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else { throw ScanError.duplicateSourceID }
        scanning = true
        defer { scanning = false }

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
            let previouslyIndexed = try cache.signatures(source: source.id)
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
            let output = await prepare(batch)
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
                }
            }
            try cache.store(prepared)
            accounting(ScanAccounting(processed: indexed.count, skipped: skippedIDs.count, failed: failedIDs.count,
                                      unfinished: max(0, expected - indexed.count - skippedIDs.count - failedIDs.count)))
            progress(.fingerprinting(completed: completed, total: total))
        }

        try Task.checkCancellation()
        let (groups, comparisonIssues) = try await findGroups(indexed, sources: sources, progress: progress)
        issues.append(contentsOf: comparisonIssues)
        skippedIDs = Set(issues.filter { $0.reason == .cloudSkipped }.map(\.id))
        failedIDs = Set(issues.filter { $0.reason != .cloudSkipped }.map(\.id)).subtracting(skippedIDs)
        let successfulIDs = Set(indexed.map { $0.asset.id }).subtracting(skippedIDs).subtracting(failedIDs)
        accounting(ScanAccounting(processed: successfulIDs.count, skipped: skippedIDs.count, failed: failedIDs.count, unfinished: 0))
        let successfulReused = successfulIDs.intersection(reusedIDs).count
        let result = ScanResult(
            groups: groups,
            issues: Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                .values.sorted { Self.precedes($0.id, $1.id) },
            scanned: successfulIDs.count - successfulReused, reused: successfulReused
        )
        try Task.checkCancellation()
        try cache.finish(assetIDs: allIDs, sources: sourceIDs)
        return result
    }

    private func prepare(_ batch: ArraySlice<(source: any AssetSource, asset: PhotoAsset)>) async -> [Preparation] {
        let concurrency = parallelism
        return await withTaskGroup(of: Preparation.self) { group in
            var remaining = batch.makeIterator()
            for _ in 0..<concurrency {
                guard let next = remaining.next() else { break }
                group.addTask { await Self.prepare(next.asset, using: next.source) }
            }
            var results = [Preparation]()
            for await result in group {
                results.append(result)
                if let next = remaining.next() {
                    _ = group.addTaskUnlessCancelled { await Self.prepare(next.asset, using: next.source) }
                }
            }
            return results
        }
    }

    private static func prepare(_ asset: PhotoAsset, using source: any AssetSource) async -> Preparation {
        do {
            try Task.checkCancellation()
            let input = try await source.imageInput(for: asset)
            try Task.checkCancellation()
            let image = try autoreleasepool { try PreparedImage(input: input) }
            try source.validateImage(for: asset)
            return .ready(asset, image)
        } catch is CancellationError {
            return Task.isCancelled ? .cancelled : .failed(AssetIssue(id: asset.id, reason: .inaccessible))
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
        _ assets: [IndexedAsset], sources: [any AssetSource], progress: (ScanProgress) -> Void
    ) async throws -> ([DuplicateGroup], [AssetIssue]) {
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var issues = [AssetIssue]()
        let ordered = assets.sorted { lhs, rhs in
            let leftProtected = lhs.asset.photoProperties?.hasAssociatedResources == true
            let rightProtected = rhs.asset.photoProperties?.hasAssociatedResources == true
            if leftProtected != rightProtected { return leftProtected }
            let leftArea = lhs.fingerprint.width * lhs.fingerprint.height
            let rightArea = rhs.fingerprint.width * rhs.fingerprint.height
            if leftArea != rightArea { return leftArea > rightArea }
            if lhs.fingerprint.bitDepth != rhs.fingerprint.bitDepth {
                return lhs.fingerprint.bitDepth > rhs.fingerprint.bitDepth
            }
            if lhs.fingerprint.hasWideColor != rhs.fingerprint.hasWideColor {
                return lhs.fingerprint.hasWideColor
            }
            if lhs.fingerprint.edgeDetail != rhs.fingerprint.edgeDetail {
                return lhs.fingerprint.edgeDetail > rhs.fingerprint.edgeDetail
            }
            return Self.precedes(lhs.asset.id, rhs.asset.id)
        }
        let index = CandidateIndex(ordered.map(\.fingerprint))
        var assigned = Set<Int>()
        var groups = [DuplicateGroup]()
        for (position, representative) in ordered.enumerated() {
            try Task.checkCancellation()
            if position.isMultiple(of: 32) {
                progress(.comparing(completed: position, total: ordered.count))
            }
            guard !assigned.contains(position) else { continue }
            var duplicates = [DuplicateMember]()
            var evidence = [representative.asset.id: representative.evidence]
            var sample: [UInt8]?
            for candidate in index.candidates(for: representative.fingerprint, after: position)
                where !assigned.contains(candidate) {
                try Task.checkCancellation()
                let other = ordered[candidate]
                let match: DuplicateMatch
                let a = representative.fingerprint
                let b = other.fingerprint
                if a.fileHash == b.fileHash {
                    match = .exactDuplicate
                } else {
                    guard DuplicateDetector.isVisualCandidate(a, b) else { continue }
                    let left = try sample ?? cache.sample(for: representative.asset)
                    sample = left
                    let right = try cache.sample(for: other.asset)
                    guard DuplicateDetector.verifyPixels(left, right) else { continue }
                    guard let firstSource = byID[representative.asset.id.source],
                          let secondSource = byID[other.asset.id.source] else { throw ScanError.invalidSourceSnapshot }
                    do {
                        match = try await DuplicateDetector.compare(
                            representative.asset, source: firstSource, other.asset, source: secondSource
                        )
                        guard match != .distinct else { continue }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let context = error as? ComparisonReadError
                        let failedID = context?.assetID ?? other.asset.id
                        let error = context?.underlying ?? error
                        if let error = error as? PhotoLibraryDownloadError {
                            issues.append(AssetIssue(id: failedID, reason: .cloudDownloadFailed, detail: error.localizedDescription))
                        } else if case AssetAccessError.cloudDownloadRequired = error {
                            issues.append(AssetIssue(id: failedID, reason: byID[failedID.source]?.skipsCloudAsset(failedID) == true ? .cloudSkipped : .cloudDownloadRequired))
                        } else if case AssetAccessError.cloudDownloadFailed = error {
                            issues.append(AssetIssue(id: failedID, reason: .cloudDownloadFailed))
                        } else if case AssetAccessError.changedDuringScan = error {
                            issues.append(AssetIssue(id: failedID, reason: .changedDuringScan))
                        } else {
                            issues.append(AssetIssue(id: failedID, reason: .inaccessible))
                        }
                        continue
                    }
                }
                assigned.insert(candidate)
                duplicates.append(DuplicateMember(asset: other.asset, match: match))
                evidence[other.asset.id] = other.evidence
            }
            if !duplicates.isEmpty {
                let dimensions = ImageDimensions(width: representative.fingerprint.width,
                                                 height: representative.fingerprint.height)
                var group = DuplicateGroup(preferred: representative.asset, duplicates: duplicates,
                                           preferredDimensions: dimensions)
                group.evidence = evidence
                groups.append(group)
            }
        }
        progress(.comparing(completed: ordered.count, total: ordered.count))
        return (groups, issues)
    }

    private static func precedes(_ lhs: AssetID, _ rhs: AssetID) -> Bool {
        lhs.source == rhs.source ? lhs.item < rhs.item : lhs.source < rhs.source
    }
}
