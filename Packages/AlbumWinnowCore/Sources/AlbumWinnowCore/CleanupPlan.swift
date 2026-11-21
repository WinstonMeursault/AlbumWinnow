import Foundation

public struct CleanupPair: Equatable, Sendable, Identifiable {
    public let keep: PhotoAsset?
    public let remove: PhotoAsset
    public let wholeGroupID: AssetID?

    public var id: AssetID { remove.id }

    public init(keep: PhotoAsset, remove: PhotoAsset) {
        self.keep = keep
        self.remove = remove
        self.wholeGroupID = nil
    }

    public init(remove: PhotoAsset, fromWholeGroup groupID: AssetID) {
        self.keep = nil
        self.remove = remove
        self.wholeGroupID = groupID
    }
}

public enum CleanupStatus: Sendable {
    case movedToTrash
    case movedToRecentlyDeleted
    case skipped
    case failed
}

public struct CleanupItem: Equatable, Sendable, Identifiable {
    public let pair: CleanupPair
    public let status: CleanupStatus
    public let detail: String?

    public var id: AssetID { pair.id }
}

public enum CleanupError: LocalizedError, Equatable, Sendable {
    case invalidSelection
    case operationInProgress
    case unavailableSource
    case readOnlySource
    case userProtected
    case unavailableProtection
    case protectedResources
    case changedAsset
    case noLongerDuplicate
    case sameFile
    case unsupportedSource

    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "Every item must appear once and have a copy to keep."
        case .operationInProgress: "A cleanup operation is already in progress."
        case .unavailableSource: "The original source is no longer available."
        case .readOnlySource: "This source is read-only, or this file may alias a read-only source."
        case .userProtected: "This photo is locked and must be kept."
        case .unavailableProtection: "Protection could not be loaded. Cleanup is disabled."
        case .protectedResources: "This item has an associated video, an edit or an alternate original."
        case .changedAsset: "The photo or the copy to keep has changed. Scan again before cleanup."
        case .noLongerDuplicate: "The photo no longer matches the selected copy to keep."
        case .sameFile: "Both entries point to the same file."
        case .unsupportedSource: "This source does not support recoverable cleanup."
        }
    }
}
