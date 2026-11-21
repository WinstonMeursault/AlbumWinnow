import Darwin
import Foundation

public struct CleanupProtection: Sendable {
    public let locked: Set<AssetID>
    public let available: Bool
    public let comparisonSides: ComparisonSides?
    public let readOnlySources: Set<String>
    private let readOnlyIdentities: Set<String>
    private let lockedRevisions: [AssetID: String]

    public init(locked: Set<AssetID> = [], available: Bool = true, lockedRevisions: [AssetID: String] = [:], readOnlySources: Set<String> = [], readOnlyRevisions: [AssetID: String] = [:], comparisonSides: ComparisonSides? = nil) {
        self.comparisonSides = comparisonSides
        self.readOnlySources = readOnlySources
        self.readOnlyIdentities = Set(readOnlyRevisions.filter { readOnlySources.contains($0.key.source) }.values.map { $0.split(separator: ":").prefix(2).joined(separator: ":") })
        self.locked = locked
        self.available = available
        self.lockedRevisions = lockedRevisions
    }

    public func validateForReview(_ asset: PhotoAsset) -> Bool {
        do { try validate(asset); return true } catch { return false }
    }

    func validatePair(_ pair: CleanupPair) throws {
        try validate(pair.remove)
        if let keep = pair.keep, let comparisonSides, !comparisonSides.permits(keep.id, pair.remove.id) {
            throw CleanupError.invalidSelection
        }
    }

    public func isReadOnly(_ asset: PhotoAsset) -> Bool {
        do { try validateReadOnly(asset); return false } catch { return true }
    }

    private func validateReadOnly(_ asset: PhotoAsset) throws {
        guard !readOnlySources.contains(asset.id.source) else { throw CleanupError.readOnlySource }
        guard asset.id.source.hasPrefix("folder:") else { return }
        let url = URL(fileURLWithPath: asset.id.item)
        let roots = readOnlySources.filter { $0.hasPrefix("folder:") }.map { String($0.dropFirst(7)) }
        if !roots.isEmpty {
            for root in roots {
                if url.path == root || url.path.hasPrefix(root + "/") { throw CleanupError.readOnlySource }
                guard FileManager.default.isReadableFile(atPath: root) else { throw CleanupError.unavailableProtection }
            }
            if readOnlyIdentities.contains(asset.revision.split(separator: ":").prefix(2).joined(separator: ":")) {
                throw CleanupError.readOnlySource
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw CleanupError.unavailableProtection }
            // New hardlinks can appear after the protected source snapshot.
            guard info.st_nlink <= 1 else { throw CleanupError.readOnlySource }
        }
    }

    func validate(_ asset: PhotoAsset) throws {
        guard available else { throw CleanupError.unavailableProtection }
        try validateReadOnly(asset)
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
