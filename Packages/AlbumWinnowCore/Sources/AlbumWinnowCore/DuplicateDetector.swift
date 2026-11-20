import Foundation
import ImageIO

public enum DuplicateMatch: String, Codable, Sendable {
    case exactDuplicate
    case similarPhoto
    case visualDuplicate
    case distinct
}

public struct DuplicateDetector: Sendable {
    static let perceptualRadius = 12
    static let differenceRadius = 10
    private static let maximumMeanError = 0.018

    public init() {}

    public func compare(_ first: Data, _ second: Data) throws -> DuplicateMatch {
        try compare(AssetImage(data: first), AssetImage(data: second))
    }

    public func compare(_ first: AssetImage, _ second: AssetImage) throws -> DuplicateMatch {
        try Self.compare(.bytes(first), .bytes(second))
    }

    static func compare(_ first: ImageInput, _ second: ImageInput) throws -> DuplicateMatch {
        try autoreleasepool {
            let firstSource = try first.source()
            let firstMetadata = try first.metadata(for: firstSource)
            let secondSource = try second.source()
            let secondMetadata = try second.metadata(for: secondSource)
            let firstHash = try first.fileHash(orientationOverride: firstMetadata.orientationOverride)
            let secondHash = try second.fileHash(orientationOverride: secondMetadata.orientationOverride)
            if firstHash == secondHash { return .exactDuplicate }
            let left = try PreparedImage(source: firstSource, metadata: firstMetadata, fileHash: firstHash)
            let right = try PreparedImage(source: secondSource, metadata: secondMetadata, fileHash: secondHash)
            guard isVisualCandidate(left.fingerprint, right.fingerprint),
                  verifyPixels(left.comparisonPixels, right.comparisonPixels) else { return .distinct }

            // Local changes that survive only at higher resolution remain explicitly similar.
            let shortestSide = min(firstMetadata.width, firstMetadata.height, secondMetadata.width, secondMetadata.height)
            let size = max(8, min(1_024, shortestSide) / 8 * 8)
            let firstPixels = try PreparedImage.verificationPixels(source: firstSource, metadata: firstMetadata, size: size)
            let secondPixels = try PreparedImage.verificationPixels(source: secondSource, metadata: secondMetadata, size: size)
            return verifyPixels(firstPixels, secondPixels, size: size) ? .visualDuplicate : .similarPhoto
        }
    }

    static func compare(_ first: PhotoAsset, source firstSource: any AssetSource,
                        _ second: PhotoAsset, source secondSource: any AssetSource) async throws -> DuplicateMatch {
        let firstInput = try await comparisonInput(first, source: firstSource)
        let secondInput = try await comparisonInput(second, source: secondSource)
        let match = try compare(firstInput, secondInput)
        try firstSource.validateImage(for: first)
        try secondSource.validateImage(for: second)
        return match
    }

    private static func comparisonInput(_ asset: PhotoAsset, source: any AssetSource) async throws -> ImageInput {
        do {
            return try await source.imageInput(for: asset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComparisonReadError(assetID: asset.id, underlying: error)
        }
    }

    static func isVisualCandidate(_ a: ImageFingerprint, _ b: ImageFingerprint) -> Bool {
        abs(a.aspectRatio - b.aspectRatio) <= 0.006 * max(a.aspectRatio, b.aspectRatio)
            && ((a.perceptualHash ^ b.perceptualHash).nonzeroBitCount <= perceptualRadius
                || (a.differenceHash ^ b.differenceHash).nonzeroBitCount <= differenceRadius)
            && zip(a.meanRGBA, b.meanRGBA).allSatisfy { abs(Int($0) - Int($1)) <= 5 }
    }

    static func verifyPixels(_ a: [UInt8], _ b: [UInt8], size: Int = PreparedImage.comparisonSize) -> Bool {
        guard size > 0, size.isMultiple(of: 8),
              a.count == size * size * 4, b.count == a.count else { return false }
        let blockSize = 8
        let blockPixels = Double(blockSize * blockSize)
        var totalError = 0.0
        var totalSSIM = 0.0

        // A local color-error limit prevents a small changed subject from being averaged away.
        for y in stride(from: 0, to: size, by: blockSize) {
            for x in stride(from: 0, to: size, by: blockSize) {
                var error = 0
                var sumA = 0.0
                var sumB = 0.0
                var squareA = 0.0
                var squareB = 0.0
                var product = 0.0
                for row in y..<y + blockSize {
                    for column in x..<x + blockSize {
                        let i = (row * size + column) * 4
                        var pixelError = 0
                        for channel in 0..<4 {
                            pixelError = max(pixelError, abs(Int(a[i + channel]) - Int(b[i + channel])))
                        }
                        error += pixelError
                        let lumaA = luminance(a, at: i)
                        let lumaB = luminance(b, at: i)
                        sumA += lumaA
                        sumB += lumaB
                        squareA += lumaA * lumaA
                        squareB += lumaB * lumaB
                        product += lumaA * lumaB
                    }
                }

                let localError = Double(error) / (255 * blockPixels)
                guard localError <= 0.07 else { return false }
                totalError += localError

                let meanA = sumA / blockPixels
                let meanB = sumB / blockPixels
                let varianceA = max(0, squareA / blockPixels - meanA * meanA)
                let varianceB = max(0, squareB / blockPixels - meanB * meanB)
                let covariance = product / blockPixels - meanA * meanB
                let c1 = 0.01 * 0.01
                let c2 = 0.03 * 0.03
                totalSSIM += ((2 * meanA * meanB + c1) * (2 * covariance + c2))
                    / ((meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2))
            }
        }

        let blocks = Double(size * size) / blockPixels
        return totalError / blocks <= maximumMeanError && totalSSIM / blocks >= 0.97
    }

    private static func luminance(_ pixels: [UInt8], at offset: Int) -> Double {
        let value = 77 * Int(pixels[offset]) + 150 * Int(pixels[offset + 1]) + 29 * Int(pixels[offset + 2])
        return Double(value) / (256 * 255)
    }
}

struct ComparisonReadError: LocalizedError {
    let assetID: AssetID
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}
