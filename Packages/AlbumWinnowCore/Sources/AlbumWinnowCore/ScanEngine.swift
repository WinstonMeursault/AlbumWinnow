import Foundation

public actor ScanEngine {
    private struct IndexedAsset: Sendable {
        let asset: PhotoAsset
        let fingerprint: ImageFingerprint
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

    public func scan(
        _ sources: [any AssetSource],
        refreshing: Set<AssetID> = [],
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanResult {
        guard !scanning else { throw ScanError.scanInProgress }
        let sourceIDs = sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else { throw ScanError.duplicateSourceID }
        scanning = true
        defer { scanning = false }

        var allIDs = Set<AssetID>()
        var indexedPaths = Set<String>()
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
                if source is FileSystemSource, !indexedPaths.insert(asset.id.item).inserted { continue }
                if !refreshing.contains(asset.id), let entry = previouslyIndexed[asset.id.item], asset.revision == entry.revision {
                    indexed.append(IndexedAsset(asset: asset, fingerprint: entry.signature))
                } else {
                    pending.append((source, asset))
                }
            }
        }

        let reused = indexed.count
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
                    completed += 1
                case .cancelled:
                    break
                }
            }
            try cache.store(prepared)
            progress(.fingerprinting(completed: completed, total: total))
        }

        try Task.checkCancellation()
        let (groups, comparisonIssues) = try await findGroups(indexed, sources: sources, progress: progress)
        issues.append(contentsOf: comparisonIssues)
        let result = ScanResult(
            groups: groups,
            issues: issues.sorted { Self.precedes($0.id, $1.id) },
            scanned: indexed.count - reused, reused: reused
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
        } catch AssetAccessError.changedDuringScan {
            return .failed(AssetIssue(id: asset.id, reason: .changedDuringScan))
        } catch AssetAccessError.cloudDownloadRequired {
            return .failed(AssetIssue(id: asset.id, reason: .cloudDownloadRequired))
        } catch let error as PhotoLibraryDownloadError {
            return .failed(AssetIssue(id: asset.id, reason: .cloudDownloadFailed, detail: error.localizedDescription))
        } catch AssetAccessError.cloudDownloadFailed {
            return .failed(AssetIssue(id: asset.id, reason: .cloudDownloadFailed))
        } catch ImageReadError.unreadableImage {
            return .failed(AssetIssue(id: asset.id, reason: .unreadableImage))
        } catch is ImageReadError {
            return .failed(AssetIssue(id: asset.id, reason: .unsupportedImage))
        } catch {
            return .failed(AssetIssue(id: asset.id, reason: .inaccessible))
        }
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
                            issues.append(AssetIssue(id: failedID, reason: .cloudDownloadRequired))
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
            }
            if !duplicates.isEmpty {
                let dimensions = ImageDimensions(width: representative.fingerprint.width,
                                                 height: representative.fingerprint.height)
                groups.append(DuplicateGroup(preferred: representative.asset, duplicates: duplicates,
                                             preferredDimensions: dimensions))
            }
        }
        progress(.comparing(completed: ordered.count, total: ordered.count))
        return (groups, issues)
    }

    private static func precedes(_ lhs: AssetID, _ rhs: AssetID) -> Bool {
        lhs.source == rhs.source ? lhs.item < rhs.item : lhs.source < rhs.source
    }
}
