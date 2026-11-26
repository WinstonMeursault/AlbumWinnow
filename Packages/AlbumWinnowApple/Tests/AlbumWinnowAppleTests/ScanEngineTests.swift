import AlbumWinnowRust
import AlbumWinnowApple
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

    let source = FileSystemSource(fixture: directory)
    let engine = try FixtureScanEngine(cacheURL: db)
    let first = try await engine.fixtureScan([source])
    #expect(first.scanned == 4)
    #expect(first.reused == 0)
    #expect(first.issues.map(\.reason) == [.unreadableImage])
    #expect(first.groups.count == 1)
    #expect(first.groups.first?.preferred.name == "landscape.jpg")
    #expect(first.groups.first?.duplicates.map(\.match) == [.visualDuplicate])

    let unchanged = try await engine.fixtureScan([source])
    #expect(unchanged.reused == 4)
    #expect(unchanged.scanned == 0)
    #expect(unchanged.groups == first.groups)
    #expect(unchanged.issues == first.issues)

    let replacement = try Data(contentsOf: fixtures.appending(path: "flat-a.png"))
    try replacement.write(to: directory.appending(path: "landscape.jpg"), options: .atomic)
    try files.removeItem(at: directory.appending(path: "burst-b.png"))
    try files.copyItem(at: fixtures.appending(path: "pixel-copy.png"),
                       to: directory.appending(path: "burst-copy.png"))
    let incremental = try await engine.fixtureScan([source])
    let cold = try await FixtureScanEngine(cacheURL: scratch.appending(path: "fresh.sqlite")).fixtureScan([source])
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
    let engine = try FixtureScanEngine(cacheURL: db)
    let (updates, stream) = AsyncStream.makeStream(of: ScanProgress.self)
    let scan = Task {
        defer { stream.finish() }
        return try await engine.fixtureScan([source]) { stream.yield($0) }
    }
    for await update in updates {
        if case .fingerprinting(let completed, _) = update, completed >= 16 {
            await #expect(throws: ScanError.scanInProgress) { try await engine.clearCache() }
            scan.cancel()
            break
        }
    }
    await #expect(throws: CancellationError.self) { try await scan.value }
    let resumed = try await FixtureScanEngine(cacheURL: db).fixtureScan([SlowSource(contents: contents, pause: .zero)])
    #expect(resumed.reused >= 16)
    #expect(resumed.scanned + resumed.reused == 48)
    #expect(resumed.groups.first?.duplicates.count == 47)
}

@Test func coreGroupsWithoutEvidenceKeepPreviewDimensionsUnknown() throws {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    let group = try fixtureReviewGroup(session)
    try commitFixtureGroups([group], to: session)
    let summary = try #require(session.queryPage(offset: 0, limit: 1).first)
    #expect(summary.preferredEvidence == nil)
    #expect(try session.groupDetail(signature: summary.signature).group.evidence.isEmpty)
}
