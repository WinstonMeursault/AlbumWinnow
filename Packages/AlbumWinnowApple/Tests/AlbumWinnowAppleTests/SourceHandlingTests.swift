import AlbumWinnowApple
import Foundation
import Testing

private let root = TestFiles.root

private struct CloudFixture: AssetSource {
    let id = "cloud-fixture"
    let data: Data?

    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: [PhotoAsset(id: AssetID(source: id, item: "one"), name: "one", revision: "1")])
    }

    func imageData(for asset: PhotoAsset) async throws -> Data {
        guard let data else { throw AssetAccessError.cloudDownloadRequired }
        return data
    }
}

@Test func pendingCloudAssetCanBeIndexedWhenAvailable() async throws {
    let folder = root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try FixtureScanEngine(cacheURL: folder.appending(path: "scan.sqlite"))
    let offline = try await engine.fixtureScan([CloudFixture(data: nil)])
    #expect(offline.issues.map(\.reason) == [.cloudDownloadRequired])
    #expect(offline.scanned == 0)
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    let available = try await engine.fixtureScan([CloudFixture(data: bytes)])
    #expect(available.issues.isEmpty)
    #expect(available.scanned == 1)
    #expect(available.reused == 0)
}

private actor RequestedImages: AssetSource {
    nonisolated let id = "refresh-fixture"
    private(set) var reads: [AssetID] = []
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: ["one", "two"].map {
            PhotoAsset(id: AssetID(source: id, item: $0), name: $0, revision: "unchanged")
        })
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        reads.append(asset.id)
        return bytes
    }
}

@Test func explicitDownloadRetryReadsSelectedAssetsEvenWhenFingerprintsAreCached() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let source = RequestedImages(bytes: try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")))
    _ = try await engine.fixtureScan([source])
    let selected = AssetID(source: source.id, item: "one")
    let retry = try await engine.fixtureScan([source], refreshing: [selected])
    #expect(retry.scanned == 1)
    #expect(retry.reused == 1)
    #expect(retry.issues.isEmpty)
    #expect(retry.groups.count == 1)
    let reads = await source.reads
    #expect(reads.count == 3)
    #expect(reads.last == selected)
}

private struct AvailabilityFixture: AssetSource {
    let id = "availability-fixture"
    let cloudOnly: Bool
    let downloadAllowed: Bool
    func skipsCloudAsset(_ id: AssetID) -> Bool { !downloadAllowed }
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: [PhotoAsset(id: AssetID(source: id, item: "one"), name: "one", revision: "unchanged")])
    }
    func validateCachedAvailability(for asset: PhotoAsset) async throws {
        if cloudOnly && !downloadAllowed { throw AssetAccessError.cloudDownloadRequired }
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        try await validateCachedAvailability(for: asset)
        return try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    }
}

@Test func cloudEvictionDoesNotTreatCachedFingerprintAsLocalAvailability() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let first = try await engine.fixtureScan([AvailabilityFixture(cloudOnly: false, downloadAllowed: false)])
    #expect(first.scanned == 1)
    let evicted = try await engine.fixtureScan([AvailabilityFixture(cloudOnly: true, downloadAllowed: false)])
    #expect(evicted.reused == 0)
    #expect(evicted.scanned == 0)
    #expect(evicted.issues.map(\.reason) == [.cloudSkipped])
    let oneTime = try await engine.fixtureScan([AvailabilityFixture(cloudOnly: true, downloadAllowed: true)])
    #expect(oneTime.reused == 1)
    #expect(oneTime.issues.isEmpty)
    let again = try await engine.fixtureScan([AvailabilityFixture(cloudOnly: true, downloadAllowed: false)])
    #expect(again.issues.map(\.reason) == [.cloudSkipped])
}

private struct AccountingFixture: AssetSource {
    let id = "accounting-fixture"
    func skipsCloudAsset(_ id: AssetID) -> Bool { true }
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: (0..<48).map {
            PhotoAsset(id: AssetID(source: id, item: "\($0)"), name: "\($0)", revision: "1")
        })
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        try await Task.sleep(for: .milliseconds(5))
        if asset.id.item == "0" { throw AssetAccessError.cloudDownloadRequired }
        if asset.id.item == "1" { throw ImageReadError.unreadableImage }
        return try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    }
}

@Test func cancellationKeepsSkippedFailedAndUnfinishedCountsSeparate() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"), parallelism: 1)
    let (updates, continuation) = AsyncStream.makeStream(of: ScanAccounting.self)
    let task = Task {
        defer { continuation.finish() }
        return try await engine.fixtureScan([AccountingFixture()], accounting: { continuation.yield($0) })
    }
    for await counts in updates where counts.processed > 0 {
        #expect(counts.processed == 14)
        #expect(counts.skipped == 1)
        #expect(counts.failed == 1)
        #expect(counts.unfinished == 32)
        task.cancel()
        break
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
