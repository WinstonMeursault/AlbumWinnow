import Foundation
import Testing
import AlbumWinnowRust

private func scanItem(_ source: String, _ item: String, hash: UInt8, distant: Bool = false) -> ScanItemInput {
    ScanItemInput(asset: CoreAssetKey(sourceId: source, itemId: item), revision: "revision",
                  fingerprint: CoreFingerprint(fileHash: Data(repeating: hash, count: 32), width: 1_000, height: 1_000,
                                               bitDepth: 8, wideColor: false, perceptualHash: distant ? .max : 0,
                                               differenceHash: distant ? .max : 0, meanRgba: Data([distant ? 0 : 128, 128, 128, 255]), edgeDetail: 0),
                  associatedResources: false, nativeIdentity: nil)
}

@Test func crossSideSessionKeepsRealEdgesAndRejectsStaleCallbacks() throws {
    let cancel = CancellationHandle()
    let session = try RustScanSession(operationId: "operation", sourceIds: ["left", "right"],
                                      sides: CoreComparisonSides(first: "left", second: "right"),
                                      preferredSource: "right", cancellation: cancel)
    let a = scanItem("left", "a", hash: 1)
    #expect(throws: BridgeError.InvalidValue) { try session.appendPrepared(items: Array(repeating: a, count: 17)) }
    try session.appendPrepared(items: [scanItem("right", "d", hash: 2, distant: true), a,
                                        scanItem("right", "c", hash: 1), scanItem("left", "b", hash: 1)])
    try session.completePreparation()
    let batch = try session.nextBatch(maximum: 16)
    #expect(batch.tasks.count == 1)
    #expect(batch.tasks[0].exactIdentity)
    #expect(batch.tasks[0].firstRevision == "revision")
    let result = CoreTaskResult(taskId: batch.tasks[0].taskId, outcome: .matched(kind: .exactDuplicate))
    #expect(throws: BridgeError.StaleOperation) { try session.submitResults(operationId: "old-operation", batchId: batch.batchId, results: [result]) }
    try session.submitResults(operationId: "operation", batchId: batch.batchId, results: [result])
    #expect(try session.nextBatch(maximum: 16).done)
    #expect(throws: BridgeError.InvalidState) { try session.groups() }
    let ids = try session.finalValidationIds()
    #expect(Set(ids.map(\.itemId)) == Set(["a", "b", "c"]))
    try session.submitFinalValidations(operationId: "operation", validations: ids.map { CoreAssetValidation(asset: $0, revision: "revision", accessible: true) })
    let groups = try session.groups()
    #expect(groups.count == 1)
    #expect(groups[0].preferred.itemId == "a")
    #expect(groups[0].recommended?.itemId == "c")
    #expect(Set(groups[0].duplicates.map(\.asset.itemId)) == Set(["b", "c"]))
    #expect(groups[0].edges?.count == 2)
    #expect(groups[0].edges?.allSatisfy { $0.first.sourceId != $0.second.sourceId } == true)
    #expect(throws: BridgeError.StaleOperation) { try session.submitResults(operationId: "operation", batchId: batch.batchId, results: [result]) }
    session.cancel()
    #expect(throws: BridgeError.Cancelled) { try session.groups() }
}

@Test func pixelClassificationAndOrientedIdentityStayInsideRust() throws {
    let cancel = CancellationHandle()
    let first = scanItem("left", "a", hash: 1).fingerprint
    let second = scanItem("right", "b", hash: 2).fingerprint
    #expect(try coreVisualCandidate(first: first, second: second))
    let pixels = PixelInput(width: 128, height: 128, stride: 512,
                            rgba: Data(Array(repeating: [UInt8(128),128,128,255], count: 128 * 128).flatMap { $0 }), decodePipeline: "test.srgb.premul.v1")
    var changed = pixels
    var bytes = Array(pixels.rgba)
    for y in 0..<8 { for x in 0..<8 { for channel in 0..<3 { bytes[(y * 128 + x) * 4 + channel] = 146 } } }
    changed.rgba = Data(bytes)
    #expect(try cancel.verifyPixels(first: pixels, second: pixels))
    #expect(try cancel.detailMatch(first: pixels, second: pixels) == .visualDuplicate)
    #expect(try cancel.detailMatch(first: pixels, second: changed) == .similarPhoto)
    let hasher = ByteHasher(cancellation: cancel)
    try hasher.update(bytes: Data("abc".utf8))
    let identities = try (1...8).map { try hasher.digestForOrientation(orientation: UInt8($0)) }
    #expect(Set(identities).count == 8)
    #expect(try identities[0] != hasher.digest())
    #expect(throws: BridgeError.InvalidValue) { try hasher.digestForOrientation(orientation: 0) }
}

@Test func runningScanSessionObservesCancellationAcrossThreads() async throws {
    let cancel = CancellationHandle()
    let session = try RustScanSession(operationId: "operation", sourceIds: ["left"], sides: nil, preferredSource: nil, cancellation: cancel)
    let (updates, continuation) = AsyncStream.makeStream(of: Void.self)
    let worker = Task.detached { () throws -> Void in
        defer { continuation.finish() }
        for start in stride(from: 0, to: 1_000, by: 16) {
            try session.appendPrepared(items: (start..<min(start + 16, 1_000)).map { scanItem("left", "item\($0)", hash: UInt8(truncatingIfNeeded: $0)) })
        }
        try session.completePreparation()
        var first = true
        while true {
            let batch = try session.nextBatch(maximum: 16)
            if batch.done { return }
            try session.submitResults(operationId: "operation", batchId: batch.batchId, results: batch.tasks.map {
                CoreTaskResult(taskId: $0.taskId, outcome: .matched(kind: $0.exactIdentity ? .exactDuplicate : .distinct))
            })
            if first { continuation.yield(()); first = false }
        }
    }
    var started = false
    for await _ in updates { started = true; break }
    #expect(started)
    let start = ContinuousClock.now
    session.cancel()
    do {
        try await worker.value
        Issue.record("Running scan did not observe cancellation")
    } catch BridgeError.Cancelled {
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}
