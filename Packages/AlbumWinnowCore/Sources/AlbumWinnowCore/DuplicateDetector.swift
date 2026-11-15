import Foundation

public enum DuplicateMatch: String, Codable, Sendable {
    case exactDuplicate
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
        let left = try PreparedImage(data: first.data, orientation: first.orientation)
        if first.data == second.data, first.orientation == second.orientation { return .exactDuplicate }
        let right = try PreparedImage(data: second.data, orientation: second.orientation)
        return Self.compare(left, right)
    }

    static func compare(_ left: PreparedImage, _ right: PreparedImage) -> DuplicateMatch {
        let a = left.fingerprint
        let b = right.fingerprint
        if a.width == b.width, a.height == b.height, a.pixelHash == b.pixelHash {
            return .exactDuplicate
        }
        guard isVisualCandidate(a, b),
              verifyPixels(left.comparisonPixels, right.comparisonPixels) else {
            return .distinct
        }
        return .visualDuplicate
    }

    static func isVisualCandidate(_ a: ImageFingerprint, _ b: ImageFingerprint) -> Bool {
        abs(a.aspectRatio - b.aspectRatio) <= 0.006 * max(a.aspectRatio, b.aspectRatio)
            && ((a.perceptualHash ^ b.perceptualHash).nonzeroBitCount <= perceptualRadius
                || (a.differenceHash ^ b.differenceHash).nonzeroBitCount <= differenceRadius)
            && zip(a.meanRGBA, b.meanRGBA).allSatisfy { abs(Int($0) - Int($1)) <= 5 }
    }

    static func verifyPixels(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let size = PreparedImage.comparisonSize
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
