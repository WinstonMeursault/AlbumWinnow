import BLAKE3
import Foundation
import ImageIO

enum ImageInput: Sendable {
    case bytes(AssetImage)
    case file(URL)

    func source() throws -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        switch self {
        case .bytes(let image):
            source = CGImageSourceCreateWithData(image.data as CFData, options)
        case .file(let url):
            source = CGImageSourceCreateWithURL(url as CFURL, options)
        }
        guard let source, CGImageSourceGetStatus(source) == .statusComplete else {
            throw ImageReadError.unreadableImage
        }
        return source
    }

    func metadata(for source: CGImageSource) throws -> ImageMetadata {
        let orientation: CGImagePropertyOrientation?
        if case .bytes(let image) = self { orientation = image.orientation } else { orientation = nil }
        return try ImageMetadata(source: source, orientation: orientation)
    }

    func fileHash(orientationOverride: CGImagePropertyOrientation?) throws -> Data {
        let hasher = BLAKE3()
        switch self {
        case .bytes(let image):
            hasher.update(data: image.data)
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        }
        let digest = hasher.finalizeData()
        guard let orientationOverride else { return digest }
        let oriented = BLAKE3()
        oriented.update(buffer: [UInt8(orientationOverride.rawValue)])
        oriented.update(data: digest)
        return oriented.finalizeData()
    }
}

struct ImageMetadata {
    let width: Int
    let height: Int
    let bitDepth: Int
    let orientationOverride: CGImagePropertyOrientation?

    init(source: CGImageSource, orientation: CGImagePropertyOrientation?) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageReadError.unreadableImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageReadError.multipleImages }
        guard width > 0, height > 0, width <= 150_000_000 / height else {
            throw ImageReadError.unsupportedDimensions
        }
        let embedded = properties[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let embeddedOrientation = CGImagePropertyOrientation(rawValue: embedded) ?? .up
        let effective = orientation ?? embeddedOrientation
        self.width = effective.rawValue >= 5 ? height : width
        self.height = effective.rawValue >= 5 ? width : height
        bitDepth = properties[kCGImagePropertyDepth] as? Int ?? 8
        orientationOverride = orientation.flatMap { $0 == embeddedOrientation ? nil : $0 }
    }
}

extension AssetSource {
    func imageInput(for asset: PhotoAsset) async throws -> ImageInput {
        if let folder = self as? FileSystemSource {
            return .file(try folder.currentURL(for: asset))
        }
        return .bytes(try await image(for: asset))
    }

    func validateImage(for asset: PhotoAsset) throws {
        if let folder = self as? FileSystemSource {
            _ = try folder.currentURL(for: asset)
        } else if let photos = self as? PhotoLibrarySource {
            _ = try photos.currentAsset(for: asset)
        }
    }
}
