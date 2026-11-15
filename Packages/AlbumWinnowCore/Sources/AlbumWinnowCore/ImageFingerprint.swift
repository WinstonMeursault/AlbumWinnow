import BLAKE3
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
    let pixelHash: Data
    let width: Int
    let height: Int
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageReadError.unreadableImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageReadError.multipleImages }
        guard width > 0, height > 0, width <= 150_000_000 / height else {
            throw ImageReadError.unsupportedDimensions
        }

        let embedded = properties[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let override = orientation.flatMap { $0.rawValue == embedded ? nil : $0 }
        let image = try Self.orientedImage(source, longestSide: max(width, height), override: override)
        let pixelHasher = BLAKE3()
        try Self.render(image, width: image.width, height: image.height).withUnsafeBytes {
            pixelHasher.update(bytes: $0)
        }
        let sample = try Self.render(image, width: Self.comparisonSize, height: Self.comparisonSize)
        let luminance = Self.luminanceGrid(sample, columns: 32, rows: 32)

        fingerprint = ImageFingerprint(
            fileHash: Self.hash(data, orientationOverride: override),
            pixelHash: pixelHasher.finalizeData(),
            width: image.width,
            height: image.height,
            perceptualHash: Self.pHash(luminance),
            differenceHash: Self.dHash(Self.luminanceGrid(sample, columns: 9, rows: 8)),
            meanRGBA: Self.meanRGBA(sample),
            edgeDetail: Self.edgeDetail(luminance)
        )
        comparisonPixels = sample
    }

    private static func orientedImage(
        _ source: CGImageSource, longestSide: Int, override: CGImagePropertyOrientation?
    ) throws -> CGImage {
        if let override {
            guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageReadError.unreadableImage
            }
            if override == .up { return sourceImage }
            let rotated = CIImage(cgImage: sourceImage).oriented(override)
            guard let rendered = orientationContext.createCGImage(rotated, from: rotated.extent) else {
                throw ImageReadError.unreadableImage
            }
            return rendered
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageReadError.unreadableImage
        }
        return image
    }

    private static func hash(_ bytes: Data, orientationOverride: CGImagePropertyOrientation?) -> Data {
        let hasher = BLAKE3()
        hasher.update(data: bytes)
        if let orientationOverride {
            // Preserve a distinct identity when a photo source applies an orientation outside the file.
            let contentHash = hasher.finalizeData()
            let orientedHasher = BLAKE3()
            orientedHasher.update(buffer: [UInt8(orientationOverride.rawValue)])
            orientedHasher.update(data: contentHash)
            return orientedHasher.finalizeData()
        }
        return hasher.finalizeData()
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
