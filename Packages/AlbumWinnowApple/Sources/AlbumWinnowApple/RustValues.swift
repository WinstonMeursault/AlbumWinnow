import AlbumWinnowRust
import Foundation

public struct RustCoreFailure: Error {
    public let underlying: any Error
}

// A backend failure is a scan failure, never a negative match or an asset issue.
func coreResult<Value>(_ operation: () throws -> Value) throws -> Value {
    do { return try operation() }
    catch BridgeError.Cancelled { throw CancellationError() }
    catch let failure as RustCoreFailure { throw failure }
    catch { throw RustCoreFailure(underlying: error) }
}

extension AssetID {
    var coreValue: CoreAssetKey { CoreAssetKey(sourceId: source, itemId: item) }
    init(_ value: CoreAssetKey) { self.init(source: value.sourceId, item: value.itemId) }
}

extension ImageFingerprint {
    var coreValue: CoreFingerprint {
        get throws {
            guard let width = UInt32(exactly: width), let height = UInt32(exactly: height),
                  let depth = UInt16(exactly: bitDepth) else {
                throw RustCoreFailure(underlying: BridgeError.InvalidValue)
            }
            return CoreFingerprint(fileHash: fileHash, width: width, height: height, bitDepth: depth,
                                   wideColor: hasWideColor, perceptualHash: perceptualHash,
                                   differenceHash: differenceHash, meanRgba: Data(meanRGBA), edgeDetail: edgeDetail)
        }
    }
}

extension DuplicateMatch {
    init(_ value: CoreMatch) {
        switch value {
        case .sceneSimilar: self = .sceneSimilar
        case .exactDuplicate: self = .exactDuplicate
        case .similarPhoto: self = .similarPhoto
        case .visualDuplicate: self = .visualDuplicate
        case .distinct: self = .distinct
        }
    }

    var coreValue: CoreMatch {
        switch self {
        case .sceneSimilar: .sceneSimilar
        case .exactDuplicate: .exactDuplicate
        case .similarPhoto: .similarPhoto
        case .visualDuplicate: .visualDuplicate
        case .distinct: .distinct
        }
    }
}

func corePixels(_ pixels: [UInt8], size: Int) throws -> PixelInput {
    guard let size = UInt32(exactly: size), size > 0, size <= 1_024 else {
        throw RustCoreFailure(underlying: BridgeError.InvalidPixels)
    }
    return PixelInput(width: size, height: size, stride: size * 4, rgba: Data(pixels),
                      decodePipeline: "apple.imageio.coreimage.srgb.premul.v1")
}

extension SceneQuality {
    var coreValue: CoreSceneQuality {
        CoreSceneQuality(meanLuminance: meanLuminance, textureVariance: textureVariance, focusEnergy: focusEnergy,
                         darkClipping: darkClipping, brightClipping: brightClipping)
    }
}

extension ImageFingerprint {
    init(_ record: CoreCachedFingerprint) {
        let value = record.fingerprint
        self.init(fileHash: value.fileHash, width: Int(value.width), height: Int(value.height), bitDepth: Int(value.bitDepth),
                  hasWideColor: value.wideColor, perceptualHash: value.perceptualHash, differenceHash: value.differenceHash,
                  meanRGBA: Array(value.meanRgba), edgeDetail: value.edgeDetail,
                  observedBitDepth: record.observedBitDepth.map(Int.init), captureDate: record.captureDate.map(Date.init(timeIntervalSince1970:)))
    }
}

extension SceneQuality {
    init(_ value: CoreSceneQuality) {
        meanLuminance = value.meanLuminance
        textureVariance = value.textureVariance
        focusEnergy = value.focusEnergy
        darkClipping = value.darkClipping
        brightClipping = value.brightClipping
    }
}
