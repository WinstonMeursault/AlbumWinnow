import Foundation

public struct PhotoEvidence: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitDepth: Int?
    public let hasWideColor: Bool
    public let edgeContrast: Double?
    public var captureDate: Date? = nil

    var pixelArea: Int64? {
        guard width > 0, height > 0 else { return nil }
        let (area, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        return overflow ? nil : area
    }
}

public enum RecommendationReason: String, Codable, Sendable {
    case associatedResources, higherResolution, higherBitDepth, wideColor, edgeContrast, noQualityAdvantage
}

public struct SizeEstimate: Equatable, Sendable {
    public private(set) var knownBytes: Int64 = 0
    public private(set) var knownCount = 0
    public private(set) var unknownCount = 0
    public private(set) var overflowed = false
    public var hasKnownAmount: Bool { knownCount > 0 || unknownCount == 0 }

    mutating func add(_ bytes: Int64?) {
        guard let bytes, bytes >= 0 else { unknownCount += 1; return }
        knownCount += 1
        let (total, overflow) = knownBytes.addingReportingOverflow(bytes)
        overflowed = overflowed || overflow
        knownBytes = overflow ? Int64.max : total
    }
}

public extension DuplicateGroup {
    var assets: [PhotoAsset] { [preferred] + duplicates.map(\.asset) }

    var latestCaptureDate: Date? {
        assets.compactMap { $0.captureDate ?? evidence?[$0.id]?.captureDate }
            .filter { $0.timeIntervalSince1970.isFinite }.max()
    }

    func sizeEstimate(removing ids: Set<AssetID>) -> SizeEstimate {
        var estimate = SizeEstimate()
        for asset in assets where ids.contains(asset.id) { estimate.add(asset.byteCount) }
        return estimate
    }

    var recommendationReasons: [RecommendationReason] {
        let others = duplicates.map(\.asset)
        var reasons: [RecommendationReason] = []
        if preferred.photoProperties?.hasAssociatedResources == true,
           others.contains(where: { $0.photoProperties?.hasAssociatedResources != true }) {
            reasons.append(.associatedResources)
        }
        guard let selected = evidence?[preferred.id] else { return reasons.isEmpty ? [.noQualityAdvantage] : reasons }
        let compared = others.compactMap { evidence?[$0.id] }
        if let area = selected.pixelArea, !compared.isEmpty,
           compared.allSatisfy({ $0.pixelArea.map { $0 <= area } == true }),
           compared.contains(where: { $0.pixelArea.map { $0 < area } == true }) {
            reasons.append(.higherResolution)
        }
        let knownDepths = compared.compactMap(\.bitDepth)
        if let depth = selected.bitDepth, !knownDepths.isEmpty,
           knownDepths.allSatisfy({ $0 <= depth }), knownDepths.contains(where: { $0 < depth }) {
            reasons.append(.higherBitDepth)
        }
        if selected.hasWideColor, compared.contains(where: { !$0.hasWideColor }) { reasons.append(.wideColor) }
        if reasons.isEmpty, let contrast = selected.edgeContrast, contrast.isFinite,
           !compared.isEmpty, compared.allSatisfy({ $0.edgeContrast.map { $0 < contrast } == true }) {
            reasons.append(.edgeContrast)
        }
        return reasons.isEmpty ? [.noQualityAdvantage] : reasons
    }
}

public enum ReviewStatusFilter: String, Codable, Sendable, CaseIterable {
    case active, all, pending, confirmed, deferred, kept

    func includes(_ status: ReviewStatus) -> Bool {
        switch self {
        case .active: status != .kept
        case .all: true
        case .pending: status == .pending
        case .confirmed: status == .confirmed
        case .deferred: status == .deferred
        case .kept: status == .kept
        }
    }
}

public enum ReviewSort: String, Codable, Sendable, CaseIterable {
    case stable, newest, oldest, count, bytes
}

public struct ReviewResultQuery: Codable, Equatable, Sendable {
    public var status = ReviewStatusFilter.active
    public var match: DuplicateMatch?
    public var source: String?
    public var sort = ReviewSort.stable

    public init() {}

    public func apply(to groups: [DuplicateGroup], statuses: [AssetID: ReviewStatus] = [:],
                      removals: [AssetID: Set<AssetID>] = [:]) -> [DuplicateGroup] {
        groups.enumerated().filter { _, group in
            status.includes(statuses[group.id] ?? .pending) && (match == nil || group.match == match) &&
                (source == nil || group.assets.contains { $0.id.source == source })
        }.sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            switch sort {
            case .stable: break
            case .newest, .oldest:
                let left = a.latestCaptureDate, right = b.latestCaptureDate
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return sort == .newest ? left > right : left < right
                }
            case .count:
                if a.assets.count != b.assets.count { return a.assets.count > b.assets.count }
            case .bytes:
                let left = a.sizeEstimate(removing: removals[a.id] ?? Set(a.duplicates.filter { $0.asset.photoProperties?.hasAssociatedResources != true }.map(\.id)))
                let right = b.sizeEstimate(removing: removals[b.id] ?? Set(b.duplicates.filter { $0.asset.photoProperties?.hasAssociatedResources != true }.map(\.id)))
                if left.hasKnownAmount != right.hasKnownAmount { return left.hasKnownAmount }
                if left.knownBytes != right.knownBytes { return left.knownBytes > right.knownBytes }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
