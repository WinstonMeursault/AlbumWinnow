import AlbumWinnowRust
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum ImageReadError: Error, Equatable, Sendable {
    case unreadableImage
    case multipleImages
    case unsupportedDimensions
}

struct ImageFingerprint: Codable, Sendable {
    let fileHash: Data
    let width: Int
    let height: Int
    let bitDepth: Int
    let hasWideColor: Bool
    let perceptualHash: UInt64
    let differenceHash: UInt64
    let meanRGBA: [UInt8]
    let edgeDetail: Double
    var observedBitDepth: Int? = nil
    var captureDate: Date? = nil

    var aspectRatio: Double { Double(width) / Double(height) }
}

struct PreparedImage: Sendable {
    static let comparisonSize = 128
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let orientationContext = CIContext(options: [.cacheIntermediates: false])

    let fingerprint: ImageFingerprint
    let comparisonPixels: [UInt8]

    init(data: Data, orientation: CGImagePropertyOrientation? = nil, cancellation: CancellationHandle = CancellationHandle()) throws {
        try self.init(input: .bytes(AssetImage(data: data, orientation: orientation)), cancellation: cancellation)
    }

    init(input: ImageInput, cancellation: CancellationHandle = CancellationHandle()) throws {
        let source = try input.source()
        let metadata = try input.metadata(for: source)
        try self.init(source: source, metadata: metadata,
                      fileHash: input.fileHash(orientation: metadata.effectiveOrientation, cancellation: cancellation), cancellation: cancellation)
    }

    init(source: CGImageSource, metadata: ImageMetadata, fileHash: Data, cancellation: CancellationHandle = CancellationHandle()) throws {
        let image = try Self.orientedImage(source, longestSide: 256, override: metadata.orientationOverride)
        let sample = try Self.render(image, width: Self.comparisonSize, height: Self.comparisonSize)
        let metrics = try coreResult { try cancellation.fingerprintPixels(pixels: PixelInput(
            width: UInt32(Self.comparisonSize), height: UInt32(Self.comparisonSize),
            stride: UInt32(Self.comparisonSize * 4), rgba: Data(sample),
            decodePipeline: "apple.imageio.coreimage.srgb.premul.v1"
        )) }
        var measured = ImageFingerprint(
            fileHash: fileHash,
            width: metadata.width,
            height: metadata.height,
            bitDepth: metadata.bitDepth,
            hasWideColor: image.colorSpace?.isWideGamutRGB == true,
            perceptualHash: metrics.perceptualHash,
            differenceHash: metrics.differenceHash,
            meanRGBA: Array(metrics.meanRgba),
            edgeDetail: metrics.edgeDetail
        )
        measured.observedBitDepth = metadata.observedBitDepth
        measured.captureDate = metadata.captureDate
        self.fingerprint = measured
        comparisonPixels = sample
    }

    static func verificationPixels(source: CGImageSource, metadata: ImageMetadata, size: Int) throws -> [UInt8] {
        let aspect = Double(metadata.width) / Double(metadata.height)
        let longestSide = min(2_048, max(size, Int(ceil(Double(size) * max(aspect, 1 / aspect)))))
        let image = try orientedImage(source, longestSide: longestSide, override: metadata.orientationOverride)
        return try render(image, width: size, height: size)
    }

    static func orientedImage(
        _ source: CGImageSource, longestSide: Int, override: CGImagePropertyOrientation?
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: override == nil,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageReadError.unreadableImage
        }
        guard let override, override != .up else { return image }
        let rotated = CIImage(cgImage: image).oriented(override)
        guard let rendered = orientationContext.createCGImage(rotated, from: rotated.extent) else {
            throw ImageReadError.unreadableImage
        }
        return rendered
    }

    static func render(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                throw ImageReadError.unreadableImage
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

}
