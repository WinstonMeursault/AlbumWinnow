import AlbumWinnowRust
import CoreGraphics
import Foundation

public enum PhotoDifferenceError: Error, Sendable { case invalidPair }

public enum DifferenceUnavailableReason: Sendable {
    case geometry, insufficientDetail, alignment
}

public struct PhotoDifference: Sendable {
    public let reference: CGImage
    public let comparison: CGImage
    /// Approximate rectangles in image-relative coordinates, with the origin at the top left.
    public let regions: [CGRect]
    public let unavailableReason: DifferenceUnavailableReason?

    public static func compare(_ first: PhotoAsset, source firstSource: any AssetSource,
                               _ second: PhotoAsset, source secondSource: any AssetSource) async throws -> PhotoDifference {
        guard first.id != second.id, first.id.source == firstSource.id, second.id.source == secondSource.id else {
            throw PhotoDifferenceError.invalidPair
        }
        try Task.checkCancellation()
        let left = try await preview(first, source: firstSource)
        let right = try await preview(second, source: secondSource)
        try firstSource.validateImage(for: first)
        try secondSource.validateImage(for: second)
        let cancellation = CancellationHandle()
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try analyze(left, right, cancellation: cancellation) }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { cancellation.cancel(); task.cancel() }
        try Task.checkCancellation()
        try firstSource.validateImage(for: first)
        try secondSource.validateImage(for: second)
        return result
    }

    private static func preview(_ asset: PhotoAsset, source: any AssetSource) async throws -> CGImage {
        try source.validateImage(for: asset)
        if let photos = source as? PhotoLibrarySource {
            let image = try await photos.thumbnail(for: asset, maxPixelSize: 512)
            return try bounded(image)
        }
        let input = try await source.imageInput(for: asset)
        return try autoreleasepool {
            let imageSource = try input.source()
            let metadata = try input.metadata(for: imageSource)
            return try PreparedImage.orientedImage(imageSource, longestSide: 512, override: metadata.orientationOverride)
        }
    }

    private static func bounded(_ image: CGImage) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > 512 else { return image }
        let width = max(1, image.width * 512 / longest), height = max(1, image.height * 512 / longest)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageReadError.unreadableImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageReadError.unreadableImage }
        return result
    }

    private static func analyze(_ first: CGImage, _ second: CGImage, cancellation: CancellationHandle) throws -> PhotoDifference {
        try Task.checkCancellation()
        let left = try corePixels(PreparedImage.render(first, width: 256, height: 256), size: 256)
        let right = try corePixels(PreparedImage.render(second, width: 256, height: 256), size: 256)
        let result = try coreResult {
            try cancellation.photoDifference(first: left, firstWidth: UInt32(first.width), firstHeight: UInt32(first.height),
                                             second: right, secondWidth: UInt32(second.width), secondHeight: UInt32(second.height))
        }
        let reason: DifferenceUnavailableReason? = result.unavailable.map {
            switch $0 {
            case .geometry: .geometry
            case .insufficientDetail: .insufficientDetail
            case .alignment: .alignment
            }
        }
        return PhotoDifference(reference: first, comparison: second,
                               regions: result.regions.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                               unavailableReason: reason)
    }
}
