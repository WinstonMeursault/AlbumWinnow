import AlbumWinnowRust
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

    func fileHash(orientation: CGImagePropertyOrientation, cancellation: CancellationHandle = CancellationHandle()) throws -> Data {
        let hasher = ByteHasher(cancellation: cancellation)
        switch self {
        case .bytes(let image):
            for start in stride(from: 0, to: image.data.count, by: 1_048_576) {
                try Task.checkCancellation()
                try coreResult { try hasher.update(bytes: image.data.subdata(in: start..<min(start + 1_048_576, image.data.count))) }
            }
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try coreResult { try hasher.update(bytes: chunk) }
            }
        }
        return try coreResult { try hasher.digestForOrientation(orientation: UInt8(orientation.rawValue)) }
    }
}

struct ImageMetadata {
    let width: Int
    let height: Int
    let bitDepth: Int
    let observedBitDepth: Int?
    let captureDate: Date?
    let orientationOverride: CGImagePropertyOrientation?
    let effectiveOrientation: CGImagePropertyOrientation

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
        effectiveOrientation = effective
        self.width = effective.rawValue >= 5 ? height : width
        self.height = effective.rawValue >= 5 ? width : height
        observedBitDepth = (properties[kCGImagePropertyDepth] as? Int).flatMap { (1...64).contains($0) ? $0 : nil }
        bitDepth = observedBitDepth ?? 8
        captureDate = Self.captureDate(exif: properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:])
        orientationOverride = orientation.flatMap { $0 == embeddedOrientation ? nil : $0 }
    }

    static func captureDate(exif: [CFString: Any]) -> Date? {
        guard let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
              offset.range(of: "^(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        formatter.isLenient = false
        return formatter.date(from: date + offset)
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
