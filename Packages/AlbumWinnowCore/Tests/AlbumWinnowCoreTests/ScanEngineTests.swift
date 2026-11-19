import AlbumWinnowCore
import Foundation
import Testing

private let root = TestFiles.root
private let fixtures = TestFiles.fixtures

@Test func folderScanReusesAndInvalidatesFingerprints() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let directory = scratch.appending(path: "photos")
    let db = scratch.appending(path: "cache.sqlite")
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    for name in ["landscape.jpg", "landscape-small.png", "burst-a.png", "burst-b.png", "unreadable.png"] {
        try files.copyItem(at: fixtures.appending(path: name), to: directory.appending(path: name))
    }
    try files.createSymbolicLink(at: directory.appending(path: "linked.png"),
                                 withDestinationURL: fixtures.appending(path: "scene.png"))

    let source = FileSystemSource(directory: directory)
    let engine = try ScanEngine(cacheURL: db)
    let first = try await engine.scan([source])
    #expect(first.scanned == 4)
    #expect(first.reused == 0)
    #expect(first.issues.map(\.reason) == [.unreadableImage])
    #expect(first.groups.count == 1)
    #expect(first.groups.first?.preferred.name == "landscape.jpg")
    #expect(first.groups.first?.duplicates.map(\.match) == [.visualDuplicate])
    #expect(try await engine.lastResult(sources: [source.id]) == first)

    let unchanged = try await engine.scan([source])
    #expect(unchanged.reused == 4)
    #expect(unchanged.scanned == 0)
    #expect(unchanged.groups == first.groups)
    #expect(unchanged.issues == first.issues)

    let replacement = try Data(contentsOf: fixtures.appending(path: "flat-a.png"))
    try replacement.write(to: directory.appending(path: "landscape.jpg"), options: .atomic)
    try files.removeItem(at: directory.appending(path: "burst-b.png"))
    try files.copyItem(at: fixtures.appending(path: "pixel-copy.png"),
                       to: directory.appending(path: "burst-copy.png"))
    let incremental = try await engine.scan([source])
    let cold = try await ScanEngine(cacheURL: scratch.appending(path: "fresh.sqlite")).scan([source])
    #expect(incremental.reused == 2)
    #expect(incremental.scanned == 2)
    #expect(incremental.groups == cold.groups)
    #expect(incremental.issues == cold.issues)
    #expect(incremental.groups.first?.preferred.name == "burst-a.png")
    #expect(incremental.groups.first?.duplicates.map(\.match) == [.visualDuplicate])
}

private struct SlowSource: AssetSource {
    let id = "slow"
    let contents: Data
    let pause: Duration

    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: (0..<48).map { number in
            PhotoAsset(id: AssetID(source: id, item: "\(number)"), name: "\(number)", revision: "initial")
        })
    }

    func imageData(for asset: PhotoAsset) async throws -> Data {
        try await Task.sleep(for: pause)
        return contents
    }
}

@Test func scanResumesCommittedFingerprintsAfterCancellation() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let db = scratch.appending(path: "cache.sqlite")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let contents = try Data(contentsOf: fixtures.appending(path: "flat-a.png"))
    let source = SlowSource(contents: contents, pause: .milliseconds(20))
    let engine = try ScanEngine(cacheURL: db)
    let (updates, stream) = AsyncStream.makeStream(of: ScanProgress.self)
    let scan = Task {
        defer { stream.finish() }
        return try await engine.scan([source]) { stream.yield($0) }
    }
    for await update in updates {
        if case .fingerprinting(let completed, _) = update, completed >= 16 {
            scan.cancel()
            break
        }
    }
    await #expect(throws: CancellationError.self) { try await scan.value }
    #expect(try await engine.lastResult(sources: [source.id]) == nil)
    let resumed = try await ScanEngine(cacheURL: db).scan([SlowSource(contents: contents, pause: .zero)])
    #expect(resumed.reused >= 16)
    #expect(resumed.scanned + resumed.reused == 48)
    #expect(resumed.groups.first?.duplicates.count == 47)
}

@Test func acceptsResultsSavedBeforeGalleryDimensions() throws {
    let json = """
    {"groups":[{"preferred":{"id":{"source":"fixture","item":"photo"},"name":"photo","revision":"1"},"duplicates":[]}],
     "issues":[],"scanned":1,"reused":0}
    """
    let cached = try JSONDecoder().decode(ScanResult.self, from: Data(json.utf8))
    #expect(cached.groups.count == 1)
    #expect(cached.groups.first?.preferredDimensions == nil)
}
