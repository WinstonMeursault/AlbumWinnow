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

    public func lastResult(sources: [String]) throws -> ScanResult? {
        try cache.lastResult(sources: sources)
    }

    public func scan(
        _ sources: [any AssetSource],
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
                if let entry = previouslyIndexed[asset.id.item], asset.revision == entry.revision {
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
        let groups = try findGroups(indexed, progress: progress)
        let result = ScanResult(
            groups: groups,
            issues: issues.sorted { Self.precedes($0.id, $1.id) },
            scanned: indexed.count - reused, reused: reused
        )
        try Task.checkCancellation()
        try cache.finish(result, assetIDs: allIDs, sources: sourceIDs)
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
            let image = try await source.image(for: asset)
            try Task.checkCancellation()
            return try .ready(asset, PreparedImage(data: image.data, orientation: image.orientation))
        } catch is CancellationError {
            return Task.isCancelled ? .cancelled : .failed(AssetIssue(id: asset.id, reason: .inaccessible))
        } catch AssetAccessError.changedDuringScan {
            return .failed(AssetIssue(id: asset.id, reason: .changedDuringScan))
        } catch AssetAccessError.cloudDownloadRequired {
            return .failed(AssetIssue(id: asset.id, reason: .cloudDownloadRequired))
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

    private func findGroups(_ assets: [IndexedAsset], progress: (ScanProgress) -> Void) throws -> [DuplicateGroup] {
        let ordered = assets.sorted { lhs, rhs in
            let leftProtected = lhs.asset.photoProperties?.hasAssociatedResources == true
            let rightProtected = rhs.asset.photoProperties?.hasAssociatedResources == true
            if leftProtected != rightProtected { return leftProtected }
            let leftArea = lhs.fingerprint.width * lhs.fingerprint.height
            let rightArea = rhs.fingerprint.width * rhs.fingerprint.height
            if leftArea != rightArea { return leftArea > rightArea }
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
                if a.fileHash == b.fileHash || CandidateIndex.PixelKey(a) == CandidateIndex.PixelKey(b) {
                    match = .exactDuplicate
                } else {
                    guard DuplicateDetector.isVisualCandidate(a, b) else { continue }
                    let left = try sample ?? cache.sample(for: representative.asset)
                    sample = left
                    let right = try cache.sample(for: other.asset)
                    guard DuplicateDetector.verifyPixels(left, right) else { continue }
                    match = .visualDuplicate
                }
                assigned.insert(candidate)
                duplicates.append(DuplicateMember(asset: other.asset, match: match))
            }
            if !duplicates.isEmpty {
                groups.append(DuplicateGroup(preferred: representative.asset, duplicates: duplicates))
            }
        }
        progress(.comparing(completed: ordered.count, total: ordered.count))
        return groups
    }

    private static func precedes(_ lhs: AssetID, _ rhs: AssetID) -> Bool {
        lhs.source == rhs.source ? lhs.item < rhs.item : lhs.source < rhs.source
    }
}
