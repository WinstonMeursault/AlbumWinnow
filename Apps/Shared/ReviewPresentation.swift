import AlbumWinnowApple
import AlbumWinnowRust
import Foundation

// These values format committed core output. They never infer decisions or plans.
struct ReviewGroupSummary: Equatable, Identifiable, Sendable {
    let core: CoreGroupSummary
    var id: AssetID { AssetID(core.preferred) }
    var signature: String { core.signature }
    var match: CoreMatch { core.kind }
    var preferred: PhotoAsset { PhotoAsset(core.previewAssets[0]) }
    var preview: PhotoAsset { PhotoAsset(core.previewAssets.last!) }
    var preferredDimensions: CoreReviewEvidence? { core.preferredEvidence }
    var count: Int { Int(core.memberCount) }
    var selectedCount: Int { Int(core.savedRemovalCount) }
}

struct ReviewGroupDetail: Equatable, Identifiable, Sendable {
    struct Member: Equatable, Identifiable, Sendable {
        let asset: PhotoAsset
        let match: CoreMatch
        var id: AssetID { asset.id }
    }
    let core: CoreGroupDetail
    let preferred: PhotoAsset
    let duplicates: [Member]
    let recommendation: PhotoAsset
    let evidence: [AssetID: CoreReviewEvidence]?
    let sceneQuality: [AssetID: CoreSceneQuality]?

    init(_ core: CoreGroupDetail) throws {
        let members = Dictionary(uniqueKeysWithValues: core.group.members.map { ($0.id, PhotoAsset($0)) })
        guard let preferred = members[core.group.preferred],
              let recommendation = members[core.group.recommendation ?? core.group.preferred] else {
            throw ScanError.invalidSourceSnapshot
        }
        self.core = core
        self.preferred = preferred
        self.recommendation = recommendation
        duplicates = try core.group.duplicates.map {
            guard let asset = members[$0.asset] else { throw ScanError.invalidSourceSnapshot }
            return Member(asset: asset, match: $0.kind)
        }
        evidence = Dictionary(uniqueKeysWithValues: core.group.evidence.map { (AssetID($0.asset), $0) })
        sceneQuality = Dictionary(uniqueKeysWithValues: core.group.sceneQuality.map { (AssetID($0.asset), $0.quality) })
    }

    var id: AssetID { preferred.id }
    var signature: String { core.summary.signature }
    var assets: [PhotoAsset] { [preferred] + duplicates.map(\.asset) }
    var match: CoreMatch { core.summary.kind }
    var preferredDimensions: CoreReviewEvidence? { core.summary.preferredEvidence }
    var comparisonSides: CoreComparisonSides? { core.group.sides }
    var sceneAlgorithm: CoreSceneProvider? { core.group.scene }
    var sceneEvidence: [CoreSceneEdge]? { core.group.scene == nil ? nil : core.group.sceneMatches }
    var hasQualityRecommendation: Bool { core.group.hasQualityRecommendation }
    var recommendationReasons: [CoreRecommendationReason] { core.reasons }
}

struct ReviewScanPresentation: Equatable, Sendable {
    let receipt: AppleScanReceipt
    var issues: [AssetIssue] { receipt.issues }
    var scanned: Int { receipt.scanned }
    var reused: Int { receipt.reused }
}

struct ReviewFolder: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ReviewCleanupGroup: Identifiable, Sendable {
    let core: CoreCleanupGroupSummary
    var id: UInt64 { core.index }
}

struct ReviewCleanupPreview: Sendable {
    let keep: PhotoAsset?
    let retained: [PhotoAsset]
    let removing: [PhotoAsset]
    let match: CoreMatch
}

struct ReviewCleanupOutcome: Equatable, Identifiable, Sendable {
    let core: CoreCleanupResult
    let failureReason: CoreCleanupReason?
    let detail: String?
    let trashLocation: URL?
    var id: CoreCleanupKey { core.item.key }
    var asset: PhotoAsset { PhotoAsset(core.item.pair.remove) }
    var moved: Bool {
        switch core.outcome {
        case .movedToTrash, .movedToRecentlyDeleted: true
        case .skipped, .failed: false
        }
    }
    var skipped: Bool { if case .skipped = core.outcome { true } else { false } }
}

extension AssetID {
    init(_ key: CoreAssetKey) { self.init(source: key.sourceId, item: key.itemId) }
    var core: CoreAssetKey { CoreAssetKey(sourceId: source, itemId: item) }
}

extension CoreReviewStatusFilter {
    static let allCases: [Self] = [.active, .all, .pending, .confirmed, .deferred, .kept]
}
extension CoreReviewSort {
    static let allCases: [Self] = [.stable, .newest, .oldest, .count, .bytes]
}
extension CoreReviewStatus {
    var title: String {
        switch self {
        case .pending: L10n.text("app_needs_review")
        case .confirmed: L10n.text("app_confirmed")
        case .deferred: L10n.text("app_later")
        case .kept: L10n.text("app_entire_group_kept")
        }
    }
}
