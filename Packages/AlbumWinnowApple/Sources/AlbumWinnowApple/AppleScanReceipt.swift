import AlbumWinnowRust
import Foundation

public enum ScanCacheMaintenance: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

/// A scan is acknowledged only after the Rust review transaction commits.
public struct AppleScanReceipt: Equatable, Sendable {
    public let metadata: CoreReviewMetadata
    public let issues: [AssetIssue]
    public let scanned: Int
    public let reused: Int
    public let unavailableSources: [String]
    public let cacheMaintenance: ScanCacheMaintenance
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
