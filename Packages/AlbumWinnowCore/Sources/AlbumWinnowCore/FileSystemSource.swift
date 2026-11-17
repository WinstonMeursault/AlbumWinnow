import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct FileSystemSource: AssetSource {
    public let directory: URL
    public var id: String { "folder:\(directory.path)" }

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func snapshot() async throws -> AssetSnapshot {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AssetAccessError.inaccessible
        }
        var issues: [AssetIssue] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                issues.append(AssetIssue(id: identifier(for: url), reason: .inaccessible))
                return true
            }
        ) else {
            throw AssetAccessError.inaccessible
        }

        var assets: [PhotoAsset] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true,
                      UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                    continue
                }
                assets.append(PhotoAsset(
                    id: identifier(for: url), name: url.lastPathComponent,
                    revision: try Self.revision(of: url)
                ))
            } catch {
                issues.append(AssetIssue(id: identifier(for: url), reason: .inaccessible))
            }
        }
        if issues.contains(where: { $0.id == identifier(for: directory) }) {
            throw AssetAccessError.inaccessible
        }
        return AssetSnapshot(assets: assets, issues: issues)
    }

    public func imageData(for asset: PhotoAsset) async throws -> Data {
        let url = try currentURL(for: asset)
        let data = try Data(contentsOf: url)
        _ = try currentURL(for: asset)
        return data
    }

    public func thumbnail(for asset: PhotoAsset, maxPixelSize: Int) async throws -> CGImage {
        try Task.checkCancellation()
        let url = try currentURL(for: asset)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageReadError.unreadableImage
        }
        try Task.checkCancellation()
        _ = try currentURL(for: asset)
        return thumbnail
    }

    public func currentURL(for asset: PhotoAsset) throws -> URL {
        let url = URL(fileURLWithPath: asset.id.item).standardizedFileURL
        let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard asset.id.source == id, url.path.hasPrefix(root),
              url.resolvingSymlinksInPath().path == url.path else {
            throw AssetAccessError.inaccessible
        }
        guard try Self.revision(of: url) == asset.revision else {
            throw AssetAccessError.changedDuringScan
        }
        return url
    }

    private func identifier(for url: URL) -> AssetID {
        AssetID(source: id, item: url.standardizedFileURL.path)
    }

    static func referToSameFile(_ first: URL, _ second: URL) throws -> Bool {
        let a = try metadata(of: first)
        let b = try metadata(of: second)
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func metadata(of url: URL) throws -> stat {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &metadata) } ?? -1
        }
        guard result == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw AssetAccessError.inaccessible
        }
        return metadata
    }

    private static func revision(of url: URL) throws -> String {
        let metadata = try metadata(of: url)
        let modified = metadata.st_mtimespec
        let changed = metadata.st_ctimespec
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):"
            + "\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }
}
