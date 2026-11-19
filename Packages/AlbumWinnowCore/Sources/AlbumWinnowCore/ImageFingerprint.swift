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

    var aspectRatio: Double { Double(width) / Double(height) }
}

struct PreparedImage: Sendable {
    static let comparisonSize = 128
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let orientationContext = CIContext(options: [.cacheIntermediates: false])

    let fingerprint: ImageFingerprint
    let comparisonPixels: [UInt8]

    init(data: Data, orientation: CGImagePropertyOrientation? = nil) throws {
        try self.init(input: .bytes(AssetImage(data: data, orientation: orientation)))
    }

    init(input: ImageInput) throws {
        let source = try input.source()
        let metadata = try input.metadata(for: source)
        try self.init(source: source, metadata: metadata,
                      fileHash: input.fileHash(orientationOverride: metadata.orientationOverride))
    }

    init(source: CGImageSource, metadata: ImageMetadata, fileHash: Data) throws {
        let image = try Self.orientedImage(source, longestSide: 256, override: metadata.orientationOverride)
        let sample = try Self.render(image, width: Self.comparisonSize, height: Self.comparisonSize)
        let luminance = Self.luminanceGrid(sample, columns: 32, rows: 32)
        fingerprint = ImageFingerprint(
            fileHash: fileHash,
            width: metadata.width,
            height: metadata.height,
            bitDepth: metadata.bitDepth,
            hasWideColor: image.colorSpace?.isWideGamutRGB == true,
            perceptualHash: Self.pHash(luminance),
            differenceHash: Self.dHash(Self.luminanceGrid(sample, columns: 9, rows: 8)),
            meanRGBA: Self.meanRGBA(sample),
            edgeDetail: Self.edgeDetail(luminance)
        )
        comparisonPixels = sample
    }

    static func verificationPixels(source: CGImageSource, metadata: ImageMetadata, size: Int) throws -> [UInt8] {
        let aspect = Double(metadata.width) / Double(metadata.height)
        let longestSide = min(2_048, max(size, Int(ceil(Double(size) * max(aspect, 1 / aspect)))))
        let image = try orientedImage(source, longestSide: longestSide, override: metadata.orientationOverride)
        return try render(image, width: size, height: size)
    }

    private static func orientedImage(
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

    private static func meanRGBA(_ sample: [UInt8]) -> [UInt8] {
        var totals = [0, 0, 0, 0]
        for index in sample.indices { totals[index % 4] += Int(sample[index]) }
        let count = sample.count / 4
        return totals.map { UInt8(($0 + count / 2) / count) }
    }

    // Estimate sharpness on the same thumbnail grid for all encodings.
    private static func edgeDetail(_ luminance: [Double]) -> Double {
        var total = 0.0
        for row in 1..<31 {
            for column in 1..<31 {
                let index = row * 32 + column
                let horizontal = luminance[index + 1] - luminance[index - 1]
                let vertical = luminance[index + 32] - luminance[index - 32]
                total += horizontal * horizontal + vertical * vertical
            }
        }
        return total / 900
    }

    private static func render(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
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

    private static func luminanceGrid(_ pixels: [UInt8], columns: Int, rows: Int) -> [Double] {
        let size = comparisonSize
        var values = [Double]()
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let yRange = (row * size / rows)..<((row + 1) * size / rows)
            for column in 0..<columns {
                let xRange = (column * size / columns)..<((column + 1) * size / columns)
                var total = 0
                for y in yRange {
                    for x in xRange {
                        let i = (y * size + x) * 4
                        total += 77 * Int(pixels[i]) + 150 * Int(pixels[i + 1]) + 29 * Int(pixels[i + 2])
                    }
                }
                values.append(Double(total) / Double(256 * xRange.count * yRange.count))
            }
        }
        return values
    }

    private static let cosine: [[Double]] = (0..<8).map { frequency in
        (0..<32).map { offset in cos(.pi * Double((2 * offset + 1) * frequency) / 64) }
    }

    private static func pHash(_ luminance: [Double]) -> UInt64 {
        var horizontal = [Double](repeating: 0, count: 32 * 8)
        for y in 0..<32 {
            for u in 0..<8 {
                for x in 0..<32 {
                    horizontal[y * 8 + u] += luminance[y * 32 + x] * cosine[u][x]
                }
            }
        }
        var coefficients = [Double]()
        for v in 0..<8 {
            for u in 0..<8 where u != 0 || v != 0 {
                var coefficient = 0.0
                for y in 0..<32 {
                    coefficient += horizontal[y * 8 + u] * cosine[v][y]
                }
                let scale = u == 0 || v == 0 ? 1 / sqrt(2.0) : 1
                coefficients.append((coefficient * scale / 16 * 100).rounded() / 100)
            }
        }
        let median = coefficients.sorted()[coefficients.count / 2]
        return coefficients.reduce(0) { ($0 << 1) | ($1 > median ? 1 : 0) }
    }

    private static func dHash(_ luminance: [Double]) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let i = y * 9 + x
                hash = (hash << 1) | (luminance[i] > luminance[i + 1] ? 1 : 0)
            }
        }
        return hash
    }
}
