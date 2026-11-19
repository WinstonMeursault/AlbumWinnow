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
