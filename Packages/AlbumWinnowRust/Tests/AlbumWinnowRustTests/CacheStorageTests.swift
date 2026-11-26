import AlbumWinnowRust
import Foundation
import Testing

@Test func v2CacheRoundtripsAndClearsOnlyDerivedDataThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-cache-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "v2/scan.sqlite").path
    let cancel = CancellationHandle()
    let asset = CoreAssetKey(sourceId: "opaque-source", itemId: "opaque-item")
    let sample = Data(repeating: 127, count: 65_536)
    let fingerprint = CoreFingerprint(fileHash: Data(repeating: 1, count: 32), width: 512, height: 384, bitDepth: 8,
                                      wideColor: false, perceptualHash: 42, differenceHash: 123, meanRgba: Data([127, 127, 127, 255]),
                                      edgeDetail: 429.4753860339191)
    let metadata = CoreCachedFingerprint(asset: asset, revision: "nanosecond-revision", fingerprint: fingerprint,
                                         observedBitDepth: 8, captureDate: 1_795_000_000.123)
    do {
        let store = try RustCacheStore(databasePath: path)
        try store.store(entries: [CorePreparedCacheEntry(metadata: metadata, sample: sample)], pipeline: "test-decode.1", cancellation: cancel)
    }
    let store = try RustCacheStore(databasePath: path)
    let restored = try store.signaturesPage(source: "opaque-source", pipeline: "test-decode.1", offset: 0, limit: 256, cancellation: cancel)
    #expect(restored.count == 1)
    #expect(try store.signaturesPage(source: "opaque-source", pipeline: "test-decode.1", offset: 1, limit: 256, cancellation: cancel).isEmpty)
    #expect(throws: BridgeError.InvalidBuffer) {
        try store.signaturesPage(source: "opaque-source", pipeline: "test-decode.1", offset: 0, limit: 257, cancellation: cancel)
    }
    #expect(restored[0].fingerprint.edgeDetail.bitPattern == fingerprint.edgeDetail.bitPattern)
    #expect(restored[0].captureDate == metadata.captureDate)
    #expect(try store.sample(asset: asset, revision: "nanosecond-revision", pipeline: "test-decode.1") == sample)
    #expect(try store.sample(asset: asset, revision: "changed", pipeline: "test-decode.1") == nil)
    cancel.cancel()
    #expect(throws: BridgeError.Cancelled) { try store.finish(assets: [], sources: [], cancellation: cancel) }
    #expect(try store.sample(asset: asset, revision: "nanosecond-revision", pipeline: "test-decode.1") == sample)
    try store.clear()
    #expect(try store.sample(asset: asset, revision: "nanosecond-revision", pipeline: "test-decode.1") == nil)
}
