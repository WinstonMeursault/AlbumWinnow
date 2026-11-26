import AlbumWinnowRust
import Foundation
import ImageIO

public enum DuplicateMatch: String, Codable, Sendable {
    case sceneSimilar
    case exactDuplicate
    case similarPhoto
    case visualDuplicate
    case distinct
}

public struct DuplicateDetector: Sendable {
    // Increment by two when matching semantics change: normal/cross-side decisions use adjacent versions.
    // Fingerprint cache versions are independent and do not invalidate manual decisions.

    public init() {}

    public func compare(_ first: Data, _ second: Data) throws -> DuplicateMatch {
        try compare(AssetImage(data: first), AssetImage(data: second))
    }

    public func compare(_ first: AssetImage, _ second: AssetImage) throws -> DuplicateMatch {
        try Self.compare(.bytes(first), .bytes(second))
    }

    static func compare(_ first: ImageInput, _ second: ImageInput, cancellation: CancellationHandle = CancellationHandle()) throws -> DuplicateMatch {
        try autoreleasepool {
            let firstSource = try first.source()
            let firstMetadata = try first.metadata(for: firstSource)
            let secondSource = try second.source()
            let secondMetadata = try second.metadata(for: secondSource)
            let firstHash = try first.fileHash(orientation: firstMetadata.effectiveOrientation, cancellation: cancellation)
            let secondHash = try second.fileHash(orientation: secondMetadata.effectiveOrientation, cancellation: cancellation)
            if try coreResult({ try coreByteIdentitiesMatch(first: firstHash, second: secondHash) }) { return .exactDuplicate }
            let left = try PreparedImage(source: firstSource, metadata: firstMetadata, fileHash: firstHash, cancellation: cancellation)
            let right = try PreparedImage(source: secondSource, metadata: secondMetadata, fileHash: secondHash, cancellation: cancellation)
            guard try isVisualCandidate(left.fingerprint, right.fingerprint),
                  try verifyPixels(left.comparisonPixels, right.comparisonPixels, cancellation: cancellation) else { return .distinct }

            // Local changes that survive only at higher resolution remain explicitly similar.
            let shortestSide = min(firstMetadata.width, firstMetadata.height, secondMetadata.width, secondMetadata.height)
            let size = max(8, min(1_024, shortestSide) / 8 * 8)
            let firstPixels = try PreparedImage.verificationPixels(source: firstSource, metadata: firstMetadata, size: size)
            let secondPixels = try PreparedImage.verificationPixels(source: secondSource, metadata: secondMetadata, size: size)
            return try coreResult { DuplicateMatch(try cancellation.detailMatch(first: corePixels(firstPixels, size: size), second: corePixels(secondPixels, size: size))) }
        }
    }

    static func compare(_ first: PhotoAsset, source firstSource: any AssetSource,
                        _ second: PhotoAsset, source secondSource: any AssetSource, cancellation: CancellationHandle = CancellationHandle()) async throws -> DuplicateMatch {
        let firstInput = try await comparisonInput(first, source: firstSource)
        let secondInput = try await comparisonInput(second, source: secondSource)
        let match = try compare(firstInput, secondInput, cancellation: cancellation)
        try validateComparisonImage(first, source: firstSource)
        try validateComparisonImage(second, source: secondSource)
        return match
    }

    static func validateComparisonImage(_ asset: PhotoAsset, source: any AssetSource) throws {
        do {
            try source.validateImage(for: asset)
        } catch {
            throw ComparisonReadError(assetID: asset.id, underlying: error)
        }
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

    static func isVisualCandidate(_ a: ImageFingerprint, _ b: ImageFingerprint) throws -> Bool {
        try coreResult { try coreVisualCandidate(first: a.coreValue, second: b.coreValue) }
    }

    static func verifyPixels(_ a: [UInt8], _ b: [UInt8], size: Int = PreparedImage.comparisonSize,
                             cancellation: CancellationHandle = CancellationHandle()) throws -> Bool {
        try coreResult { try cancellation.verifyPixels(first: corePixels(a, size: size), second: corePixels(b, size: size)) }
    }

}

struct ComparisonReadError: LocalizedError {
    let assetID: AssetID
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}
