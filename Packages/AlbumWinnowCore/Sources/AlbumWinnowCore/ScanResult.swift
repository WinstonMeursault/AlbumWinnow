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

    public var id: AssetID { preferred.id }

    public var match: DuplicateMatch {
        if duplicates.contains(where: { $0.match == .similarPhoto }) { return .similarPhoto }
        if duplicates.contains(where: { $0.match == .visualDuplicate }) { return .visualDuplicate }
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
