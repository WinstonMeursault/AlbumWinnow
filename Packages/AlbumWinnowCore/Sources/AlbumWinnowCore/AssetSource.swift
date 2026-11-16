import Foundation
import ImageIO

public struct AssetID: Codable, Hashable, Sendable {
    public let source: String
    public let item: String

    public init(source: String, item: String) {
        self.source = source
        self.item = item
    }
}

public struct PhotoAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: AssetID
    public let name: String
    public let revision: String
    public let photoProperties: PhotoProperties?

    public init(id: AssetID, name: String, revision: String, photoProperties: PhotoProperties? = nil) {
        self.id = id
        self.name = name
        self.revision = revision
        self.photoProperties = photoProperties
    }
}

public struct PhotoProperties: Codable, Equatable, Sendable {
    public let isLivePhoto: Bool
    public let hasEdits: Bool
    public let hasAlternatePhoto: Bool

    public var hasAssociatedResources: Bool { isLivePhoto || hasEdits || hasAlternatePhoto }
}

public struct AssetImage: Sendable {
    public let data: Data
    public let orientation: CGImagePropertyOrientation?

    public init(data: Data, orientation: CGImagePropertyOrientation? = nil) {
        self.data = data
        self.orientation = orientation
    }
}

public enum AssetIssueReason: String, Codable, Sendable {
    case inaccessible
    case changedDuringScan
    case unreadableImage
    case unsupportedImage
    case cloudDownloadRequired
    case cloudDownloadFailed
}

public struct AssetIssue: Codable, Equatable, Sendable {
    public let id: AssetID
    public let reason: AssetIssueReason

    public init(id: AssetID, reason: AssetIssueReason) {
        self.id = id
        self.reason = reason
    }
}

public enum AssetAccessError: Error, Sendable {
    case inaccessible
    case changedDuringScan
    case cloudDownloadRequired
    case cloudDownloadFailed
}

public struct AssetSnapshot: Sendable {
    public let assets: [PhotoAsset]
    public let issues: [AssetIssue]

    public init(assets: [PhotoAsset], issues: [AssetIssue] = []) {
        self.assets = assets
        self.issues = issues
    }
}

public protocol AssetSource: Sendable {
    var id: String { get }
    func snapshot() async throws -> AssetSnapshot
    func imageData(for asset: PhotoAsset) async throws -> Data
    func image(for asset: PhotoAsset) async throws -> AssetImage
}

public extension AssetSource {
    func image(for asset: PhotoAsset) async throws -> AssetImage {
        try await AssetImage(data: imageData(for: asset))
    }
}
