import AlbumWinnowRust
import Foundation
@testable import AlbumWinnowApple

// Test-only projections of bounded core pages. Production scans return AppleScanReceipt.
struct ImageDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct DuplicateMember: Equatable, Sendable, Identifiable {
    let asset: PhotoAsset
    let match: DuplicateMatch

    var id: AssetID { asset.id }
}

struct DuplicateGroup: Equatable, Sendable, Identifiable {
    let preferred: PhotoAsset
    let duplicates: [DuplicateMember]
    let preferredDimensions: ImageDimensions?
    var sceneRecommendationReason: CoreRecommendationReason? = nil
    var sceneAlgorithm: String? = nil
    var sceneEvidence: [SceneMatchEvidence]? = nil
    var sceneQuality: [AssetID: SceneQuality]? = nil
    var hasQualityRecommendation: Bool? = nil
    var edges: [MatchEdge]? = nil
    var comparisonSides: ComparisonSides? = nil
    var recommendedID: AssetID? = nil
    var evidence: [AssetID: PhotoEvidence]? = nil

    var id: AssetID { preferred.id }

    var match: DuplicateMatch = .exactDuplicate
    var assets: [PhotoAsset] { [preferred] + duplicates.map(\.asset) }
    var recommendation: PhotoAsset { assets.first { $0.id == recommendedID } ?? preferred }
}

struct ScanResult: Equatable, Sendable {
    let groups: [DuplicateGroup]
    let issues: [AssetIssue]
    let scanned: Int
    let reused: Int
}

