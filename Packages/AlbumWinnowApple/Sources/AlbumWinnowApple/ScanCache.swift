import AlbumWinnowRust
import Foundation

// Storage, compression, validation and pruning have one owner in Rust.
struct ScanCache: Sendable {
    private static let pipeline = "apple.imageio.coreimage.srgb.premul.v1"
    private let store: RustCacheStore

    init(url: URL) throws {
        store = try coreResult { try RustCacheStore(databasePath: url.path) }
    }

    func signatures(source: String, cancellation: CancellationHandle = CancellationHandle()) throws -> [String: (revision: String, signature: ImageFingerprint)] {
        var result = [String: (revision: String, signature: ImageFingerprint)]()
        var offset: UInt64 = 0
        while true {
            let count = try autoreleasepool {
                let page = try coreResult { try store.signaturesPage(source: source, pipeline: Self.pipeline, offset: offset, limit: 256, cancellation: cancellation) }
                for record in page { result[record.asset.itemId] = (record.revision, ImageFingerprint(record)) }
                return page.count
            }
            offset += UInt64(count)
            if count < 256 { return result }
        }
    }

    func sample(for asset: PhotoAsset) throws -> [UInt8] {
        guard let sample = try coreResult({ try store.sample(asset: asset.id.coreValue, revision: asset.revision, pipeline: Self.pipeline) }) else {
            throw AssetAccessError.changedDuringScan
        }
        return Array(sample)
    }

    func store(_ prepared: [(PhotoAsset, PreparedImage)], cancellation: CancellationHandle = CancellationHandle()) throws {
        let records = try prepared.map { asset, image in
            let observed: UInt16?
            if let depth = image.fingerprint.observedBitDepth {
                guard let value = UInt16(exactly: depth) else { throw RustCoreFailure(underlying: BridgeError.InvalidValue) }
                observed = value
            } else { observed = nil }
            return CorePreparedCacheEntry(metadata: CoreCachedFingerprint(asset: asset.id.coreValue, revision: asset.revision,
                                    fingerprint: try image.fingerprint.coreValue,
                                    observedBitDepth: observed,
                                    captureDate: image.fingerprint.captureDate?.timeIntervalSince1970), sample: Data(image.comparisonPixels))
        }
        try coreResult { try store.store(entries: records, pipeline: Self.pipeline, cancellation: cancellation) }
    }

    func sceneFeature(for asset: PhotoAsset) throws -> SceneFeature? {
        guard let record = try coreResult({ try store.scene(asset: asset.id.coreValue, revision: asset.revision, provider: SceneFeature.provider) }) else { return nil }
        do {
            return try autoreleasepool { try SceneFeature(archive: record.archive, quality: SceneQuality(record.quality)) }
        } catch let failure as RustCoreFailure { throw failure }
        catch {
            try coreResult { try store.removeScene(asset: asset.id.coreValue) }
            return nil
        }
    }

    func storeSceneFeature(_ feature: SceneFeature, for asset: PhotoAsset) throws {
        let archive = try autoreleasepool { try feature.archive() }
        try coreResult {
            try store.storeScene(asset: asset.id.coreValue, revision: asset.revision,
                                 scene: CoreCachedScene(provider: SceneFeature.provider, quality: feature.quality.coreValue, archive: archive))
        }
    }

    func finish(assetIDs: Set<AssetID>, sources: [String], cancellation: CancellationHandle = CancellationHandle()) throws {
        try coreResult { try store.finish(assets: assetIDs.map(\.coreValue), sources: sources, cancellation: cancellation) }
    }

    func clear() throws { try coreResult { try store.clear() } }
}
