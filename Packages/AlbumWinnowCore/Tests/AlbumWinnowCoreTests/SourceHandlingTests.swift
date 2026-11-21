import AlbumWinnowCore
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
    let engine = try ScanEngine(cacheURL: folder.appending(path: "scan.sqlite"))
    let offline = try await engine.scan([CloudFixture(data: nil)])
    #expect(offline.issues.map(\.reason) == [.cloudDownloadRequired])
    #expect(offline.scanned == 0)
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    let available = try await engine.scan([CloudFixture(data: bytes)])
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
    let engine = try ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    let source = RequestedImages(bytes: try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")))
    _ = try await engine.scan([source])
    let selected = AssetID(source: source.id, item: "one")
    let retry = try await engine.scan([source], refreshing: [selected])
    #expect(retry.scanned == 1)
    #expect(retry.reused == 1)
    #expect(retry.issues.isEmpty)
    #expect(retry.groups.count == 1)
    let reads = await source.reads
    #expect(reads.count == 3)
    #expect(reads.last == selected)
}
