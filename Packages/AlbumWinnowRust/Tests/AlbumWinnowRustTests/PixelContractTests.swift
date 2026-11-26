import Foundation
import Testing
import AlbumWinnowRust

private final class FixtureBundle: NSObject {}

private struct Reference: Decodable {
    struct Image: Decodable {
        let name: String
        let pixels: String
        let phash: String
        let dhash: String
        let mean_rgba: [UInt8]
        let edge_detail: Double
    }
    let metric_absolute_tolerance: Double
    let images: [Image]
}

@Test func fixedPixelsMatchTheSwiftBaselineThroughFFI() throws {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle(for: FixtureBundle.self)
    #endif
    let root = try #require(bundle.resourceURL).appending(path: "CoreFixtures")
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: root.appending(path: "swift-v1-fingerprints.json")))
    let handle = CancellationHandle()
    for row in reference.images {
        let bytes = try Data(contentsOf: root.appending(path: row.pixels))
        let result = try handle.fingerprintPixels(pixels: PixelInput(width: 128, height: 128, stride: 512, rgba: bytes,
                                                                    decodePipeline: "apple.imageio.v1.reference"))
        #expect(String(result.perceptualHash) == row.phash, "\(row.name)")
        #expect(String(result.differenceHash) == row.dhash, "\(row.name)")
        #expect(Array(result.meanRgba) == row.mean_rgba, "\(row.name)")
        #expect(abs(result.edgeDetail - row.edge_detail) <= reference.metric_absolute_tolerance, "\(row.name)")
    }
}

@Test func pixelsAndDatesRejectMalformedInputs() throws {
    let handle = CancellationHandle()
    let invalid = PixelInput(width: UInt32.max, height: UInt32.max, stride: UInt32.max, rgba: Data([0]), decodePipeline: "reference")
    #expect(throws: BridgeError.InvalidPixels) { try handle.fingerprintPixels(pixels: invalid) }
    let invalidDate = BridgeProbe(value: 0, date: .nan, identity: BridgeIdentity(sourceId: "a", itemId: "b", revision: nil))
    #expect(throws: BridgeError.InvalidValue) { try roundTrip(probe: invalidDate) }
}

@Test func streamedBytesHaveTheSameDigestAndCancelIndependently() throws {
    let cancel = CancellationHandle()
    let hasher = ByteHasher(cancellation: cancel)
    try hasher.update(bytes: Data("a".utf8))
    try hasher.update(bytes: Data("bc".utf8))
    #expect(try hasher.digest().map { String(format: "%02x", $0) }.joined() == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    cancel.cancel()
    #expect(throws: BridgeError.Cancelled) { try hasher.update(bytes: Data()) }
    #expect(throws: BridgeError.Cancelled) { try hasher.digest() }
}
