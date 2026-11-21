import Foundation
import Testing
@testable import AlbumWinnowCore

private actor RewritingSource: AssetSource {
    nonisolated let id = "rewriting-source"
    let data: Data
    let target: URL
    let replacement: Data
    private var reads = 0

    init(data: Data, target: URL, replacement: Data) {
        self.data = data
        self.target = target
        self.replacement = replacement
    }

    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: [PhotoAsset(id: AssetID(source: id, item: "small"), name: "small", revision: "1")])
    }

    func imageData(for asset: PhotoAsset) async throws -> Data {
        reads += 1
        if reads == 2 { try replacement.write(to: target, options: .atomic) }
        return data
    }
}

@Test func postComparisonChangeIsAttributedToTheChangedRepresentative() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "scene.png"))
    let target = folder.appending(path: "large.png")
    try bytes.write(to: target)
    let files = FileSystemSource(directory: folder)
    let asset = try #require(try await files.snapshot().assets.first)
    let other = RewritingSource(data: try Data(contentsOf: TestFiles.fixtures.appending(path: "scene-small.jpg")),
                                target: target, replacement: bytes)
    let result = try await ScanEngine(cacheURL: folder.appending(path: "scan.sqlite")).scan([files, other])
    #expect(result.groups.isEmpty)
    #expect(result.issues == [AssetIssue(id: asset.id, reason: .changedDuringScan)])
}

@Test(arguments: ["first.png", "second.png"])
func postComparisonValidationPreservesEitherAssetIdentity(name: String) async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for file in ["first.png", "second.png"] { try bytes.write(to: folder.appending(path: file)) }
    let source = FileSystemSource(directory: folder)
    let assets = try await source.snapshot().assets
    let asset = try #require(assets.first { $0.name == name })
    try bytes.write(to: folder.appending(path: name), options: .atomic)
    do {
        try DuplicateDetector.validateComparisonImage(asset, source: source)
        Issue.record("A changed asset must fail validation")
    } catch let error as ComparisonReadError {
        #expect(error.assetID == asset.id)
        #expect(error.underlying is AssetAccessError)
    }
}
