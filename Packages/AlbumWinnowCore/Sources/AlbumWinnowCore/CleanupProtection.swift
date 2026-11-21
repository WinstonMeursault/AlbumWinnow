import Foundation

public struct CleanupProtection: Sendable {
    public let locked: Set<AssetID>
    public let available: Bool
    private let lockedRevisions: [AssetID: String]

    public init(locked: Set<AssetID> = [], available: Bool = true, lockedRevisions: [AssetID: String] = [:]) {
        self.locked = locked
        self.available = available
        self.lockedRevisions = lockedRevisions
    }

    public func validateForReview(_ asset: PhotoAsset) -> Bool {
        do { try validate(asset); return true } catch { return false }
    }

    func validate(_ asset: PhotoAsset) throws {
        guard available else { throw CleanupError.unavailableProtection }
        guard !locked.contains(asset.id) else { throw CleanupError.userProtected }
        guard asset.id.source.hasPrefix("folder:") else { return }
        let url = URL(fileURLWithPath: asset.id.item)
        for id in locked where id.source.hasPrefix("folder:") {
            if let revision = lockedRevisions[id],
               revision.split(separator: ":").prefix(2) == asset.revision.split(separator: ":").prefix(2) {
                throw CleanupError.userProtected
            }
            let protectedURL = URL(fileURLWithPath: id.item)
            if protectedURL.standardizedFileURL == url.standardizedFileURL { throw CleanupError.userProtected }
            if FileManager.default.fileExists(atPath: protectedURL.path),
               try FileSystemSource.referToSameFile(protectedURL, url) { throw CleanupError.userProtected }
        }
    }
}
