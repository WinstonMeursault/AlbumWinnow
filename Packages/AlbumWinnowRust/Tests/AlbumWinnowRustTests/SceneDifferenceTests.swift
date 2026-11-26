import AlbumWinnowRust
import Foundation
import Testing

private final class SceneFixtureBundle: NSObject {}
private func fixtureRoot(_ directory: String) throws -> URL {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle(for: SceneFixtureBundle.self)
    #endif
    return try #require(bundle.resourceURL).appending(path: "CoreFixtures/\(directory)")
}
private struct DifferenceReference: Decodable {
    struct Region: Decodable { let x, y, width, height: Double }
    struct Pair: Decodable {
        let first, second: String
        let first_width, first_height, second_width, second_height: UInt32
        let unavailable: String?
        let regions: [Region]
    }
    let cases: [Pair]
}
@Test func frozenDifferenceResultsCrossSwiftFFI() throws {
    let root = try fixtureRoot("difference")
    let reference = try JSONDecoder().decode(DifferenceReference.self, from: Data(contentsOf: root.appending(path: "reference.json")))
    func pixels(_ name: String) throws -> PixelInput {
        PixelInput(width: 256, height: 256, stride: 1024, rgba: try Data(contentsOf: root.appending(path: name)), decodePipeline: "apple-reference-v1")
    }
    let cancel = CancellationHandle()
    for pair in reference.cases {
        let result = try cancel.photoDifference(first: pixels(pair.first), firstWidth: pair.first_width, firstHeight: pair.first_height,
                                                second: pixels(pair.second), secondWidth: pair.second_width, secondHeight: pair.second_height)
        let reason = result.unavailable.map { reason in
            switch reason { case .geometry: "geometry"; case .insufficientDetail: "insufficientDetail"; case .alignment: "alignment" }
        }
        #expect(reason == pair.unavailable)
        #expect(result.regions.count == pair.regions.count)
        for (actual, expected) in zip(result.regions, pair.regions) {
            #expect(actual.x == expected.x && actual.y == expected.y && actual.width == expected.width && actual.height == expected.height)
        }
    }
    cancel.cancel()
    let pixels = try pixels(reference.cases[0].first)
    #expect(throws: BridgeError.Cancelled) { try cancel.photoDifference(first: pixels, firstWidth: 512, firstHeight: 384,
                                                                      second: pixels, secondWidth: 512, secondHeight: 384) }
}

private func controlledSceneAsset(_ id: String, provider: CoreSceneProvider) -> CoreSceneAsset {
    CoreSceneAsset(asset: CoreAssetKey(sourceId: "controlled", itemId: id), revision: "revision", provider: provider,
                   quality: CoreSceneQuality(meanLuminance: 0.5, textureVariance: 0.1, focusEnergy: 0.01, darkClipping: 0, brightClipping: 0),
                   keys: [1, 2, 3, 4], width: 512, height: 384, bitDepth: 8, wideColor: false, edgeDetail: 1,
                   associatedResources: false, nativeIdentity: nil, burst: nil, date: nil)
}
@Test func controlledSceneProviderPreservesCliqueAndRejectsStaleWork() throws {
    let provider = CoreSceneProvider(providerId: "controlled-test", modelRevision: "1", preprocessing: "fixed", platformCompatibility: "tests-only")
    let cancel = CancellationHandle()
    let session = try RustSceneSession(operationId: "scene", provider: provider, sides: nil, preferredSource: nil, cancellation: cancel)
    var incompatible = controlledSceneAsset("x", provider: provider)
    incompatible.provider.modelRevision = "other"
    #expect(throws: BridgeError.InvalidValue) { try session.appendPrepared(items: [incompatible]) }
    try session.appendPrepared(items: ["c", "a", "b"].map { controlledSceneAsset($0, provider: provider) })
    try session.completePreparation()
    #expect(throws: BridgeError.InvalidState) { try session.groups() }
    while let task = try session.nextWork().request {
        #expect(task.firstRevision == "revision" && task.secondRevision == "revision")
        #expect(throws: BridgeError.StaleOperation) { try session.submitDistance(operationId: "old", taskId: task.taskId, distance: 0) }
        let distance: Float = task.first.itemId == "c" && task.second.itemId == "a" ? 0.25 : 0.1
        try session.submitDistance(operationId: "scene", taskId: task.taskId, distance: distance)
        #expect(throws: BridgeError.StaleOperation) { try session.submitDistance(operationId: "scene", taskId: task.taskId, distance: distance) }
    }
    let groups = try session.groups()
    #expect(groups.count == 1)
    #expect(groups[0].members.map(\.itemId) == ["a", "b"])
    session.cancel()
    #expect(throws: BridgeError.Cancelled) { try session.nextWork() }
}
