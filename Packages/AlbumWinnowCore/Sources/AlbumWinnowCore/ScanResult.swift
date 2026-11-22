import Foundation

public struct ImageDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
}

public struct DuplicateMember: Codable, Equatable, Sendable, Identifiable {
    public let asset: PhotoAsset
    public let match: DuplicateMatch

    public var id: AssetID { asset.id }
}

public struct DuplicateGroup: Codable, Equatable, Sendable, Identifiable {
    public let preferred: PhotoAsset
    public let duplicates: [DuplicateMember]
    public let preferredDimensions: ImageDimensions?
    public var sceneRecommendationReason: RecommendationReason? = nil
    public var sceneAlgorithm: String? = nil
    public var sceneEvidence: [SceneMatchEvidence]? = nil
    public var sceneQuality: [AssetID: SceneQuality]? = nil
    public var hasQualityRecommendation: Bool? = nil
    public var edges: [MatchEdge]? = nil
    public var comparisonSides: ComparisonSides? = nil
    public var recommendedID: AssetID? = nil
    public var evidence: [AssetID: PhotoEvidence]? = nil

    public var id: AssetID { preferred.id }

    public var match: DuplicateMatch {
        if sceneAlgorithm != nil { return .sceneSimilar }
        if edges?.contains(where: { $0.match == .similarPhoto }) == true || duplicates.contains(where: { $0.match == .similarPhoto }) { return .similarPhoto }
        if edges?.contains(where: { $0.match == .visualDuplicate }) == true || duplicates.contains(where: { $0.match == .visualDuplicate }) { return .visualDuplicate }
        return .exactDuplicate
    }
}

public struct ScanResult: Codable, Equatable, Sendable {
    public let groups: [DuplicateGroup]
    public let issues: [AssetIssue]
    public let scanned: Int
    public let reused: Int
}

public enum ScanProgress: Equatable, Sendable {
    case fingerprinting(completed: Int, total: Int)
    case comparing(completed: Int, total: Int)
    case similarity(completed: Int, total: Int)
}

public enum ScanError: Error, Equatable, Sendable {
    case scanInProgress
    case duplicateSourceID
    case invalidSourceSnapshot
}


public struct ScanAccounting: Equatable, Sendable {
    public let processed: Int
    public let skipped: Int
    public let failed: Int
    public let unfinished: Int
}
