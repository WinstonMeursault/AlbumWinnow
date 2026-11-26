import Foundation
import Testing
import AlbumWinnowRust

@Test func scalarAndNestedValuesSurviveTheBridge() throws {
    let value = BridgeProbe(value: UInt64.max, date: nil,
                            identity: BridgeIdentity(sourceId: "source-v2", itemId: "opaque:照片/é", revision: nil))
    #expect(try roundTrip(probe: value) == value)
    let dated = BridgeProbe(value: 0, date: -0.25,
                            identity: BridgeIdentity(sourceId: "", itemId: "", revision: "nanoseconds:123456789"))
    #expect(try roundTrip(probe: dated) == dated)
    #expect(coreVersion() == "2.0.1")
    #expect(try !sqliteProbe().isEmpty)
}

@Test func hashingAndTypedErrorsWorkOffMainActor() async throws {
    try await Task.detached { () throws -> Void in
        let handle = CancellationHandle()
        #expect(try handle.hashBuffer(bytes: Data("abc".utf8)) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
        #expect(throws: BridgeError.InvalidBuffer) {
            try handle.hashBuffer(bytes: Data(repeating: 0, count: 4 * 1024 * 1024 + 1))
        }
        handle.cancel()
        handle.cancel()
        #expect(throws: BridgeError.Cancelled) {
            try handle.hashBuffer(bytes: Data())
        }
        for _ in 0..<1_000 {
            let temporary = CancellationHandle()
            #expect(try temporary.hashBuffer(bytes: Data()).count == 64)
        }
    }.value
}

@Test func cancellationCanEnterWhileAWorkerIsHashing() async throws {
    let handle = CancellationHandle()
    let (updates, continuation) = AsyncStream.makeStream(of: Void.self)
    let worker = Task.detached { () throws -> Void in
        let bytes = Data(repeating: 19, count: 4 * 1024 * 1024)
        for iteration in 0..<10_000 {
            _ = try handle.hashBuffer(bytes: bytes)
            if iteration == 0 { continuation.yield(()) }
        }
    }
    for await _ in updates { break }
    let start = ContinuousClock.now
    handle.cancel()
    do {
        try await worker.value
        Issue.record("Worker finished without observing cancellation")
    } catch BridgeError.Cancelled {
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
    continuation.finish()
}
