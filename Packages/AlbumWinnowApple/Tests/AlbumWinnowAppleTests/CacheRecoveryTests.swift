import Foundation
import Testing
@testable import AlbumWinnowApple

@Test(arguments: ["metadata", "sample"])
func damagedFingerprintIsRebuilt(column: String) async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appending(path: "image.png")
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")).write(to: image)
    let cache = directory.appending(path: "scan.sqlite")
    let source = FileSystemSource(fixture: directory)
    let engine = try FixtureScanEngine(cacheURL: cache)
    _ = try await engine.fixtureScan([source])
    let database = try FixtureDatabase(cache)
    // The parameter is restricted to the two column names declared by the test.
    try database.execute("UPDATE fingerprints SET \(column) = X'00'")
    let repaired = try await engine.fixtureScan([source])
    #expect(repaired.scanned == 1)
    #expect(repaired.reused == 0)
    #expect(repaired.issues.isEmpty)
    let warm = try await engine.fixtureScan([source])
    #expect(warm.scanned == 0)
    #expect(warm.reused == 1)
}

@Test func invalidDatabaseFileIsRecreated() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appending(path: "scan.sqlite")
    try Data("not a database".utf8).write(to: cache)
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        .write(to: directory.appending(path: "image.png"))
    let result = try await FixtureScanEngine(cacheURL: cache).fixtureScan([FileSystemSource(fixture: directory)])
    #expect(result.scanned == 1)
    #expect(result.issues.isEmpty)
}

@Test func cacheDropsInactiveSourcesWithoutSavingResults() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var sources: [FileSystemSource] = []
    for name in ["first", "second"] {
        let folder = directory.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
            .write(to: folder.appending(path: "image.png"))
        sources.append(FileSystemSource(fixture: folder))
    }
    let cache = directory.appending(path: "scan.sqlite")
    let engine = try FixtureScanEngine(cacheURL: cache)
    _ = try await engine.fixtureScan(sources)
    _ = try await engine.fixtureScan([sources[0]])
    let database = try FixtureDatabase(cache)
    let counts = (try database.integer("SELECT COUNT(*) FROM fingerprints"),
        try database.integer("SELECT COUNT(*) FROM sqlite_master WHERE name = 'scans'"))
    #expect(counts.0 == 1)
    #expect(counts.1 == 0)
}

@Test func v2CacheLeavesOldWorkspaceUntouched() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        .write(to: directory.appending(path: "image.png"))
    let oldCache = directory.appending(path: "scan.sqlite")
    let oldBytes = Data("old workspace must remain unopened and unchanged".utf8)
    try oldBytes.write(to: oldCache)
    let source = FileSystemSource(fixture: directory)
    let engine = try FixtureScanEngine(cacheURL: directory.appending(path: "v2/scan.sqlite"))
    let cold = try await engine.fixtureScan([source])
    #expect(cold.scanned == 1 && cold.reused == 0)
    let warm = try await engine.fixtureScan([source])
    #expect(warm.scanned == 0 && warm.reused == 1)
    #expect(try Data(contentsOf: oldCache) == oldBytes)
}

@Test func clearingCacheReclaimsDiskAndForcesColdScanWithoutChangingPhotos() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appending(path: "image.png")
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    try bytes.write(to: photo)
    let source = FileSystemSource(fixture: folder)
    let url = folder.appending(path: "scan.sqlite")
    let engine = try FixtureScanEngine(cacheURL: url)
    _ = try await engine.fixtureScan([source])
    let db = try FixtureDatabase(url)
    // Enlarge only a disposable derived cache. clearCache must remove these bytes without decoding them.
    try db.execute("UPDATE fingerprints SET sample = zeroblob(8388608)")
    let before = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    try await engine.clearCache()
    let after = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    #expect(before > 8_000_000)
    #expect(after < 100_000)
    #expect(try db.integer("SELECT COUNT(*) FROM fingerprints") == 0)
    #expect(try Data(contentsOf: photo) == bytes)
    let cold = try await engine.fixtureScan([source])
    #expect(cold.scanned == 1 && cold.reused == 0)
    let warm = try await engine.fixtureScan([source])
    #expect(warm.scanned == 0 && warm.reused == 1)
}

@Test(arguments: [-16, 64])
func invalidMeasuredBitDepthIsRebuiltBeforeShowingEvidence(depth: Int) async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for name in ["a.png", "b.png"] { try bytes.write(to: folder.appending(path: name)) }
    let url = folder.appending(path: "scan.sqlite")
    let engine = try FixtureScanEngine(cacheURL: url)
    let source = FileSystemSource(fixture: folder)
    _ = try await engine.fixtureScan([source])
    let database = try FixtureDatabase(url)
    for (item, bytes) in try database.namedBlobs("SELECT item, metadata FROM fingerprints") {
        var metadata = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        metadata["observed_bit_depth"] = depth
        try database.execute("UPDATE fingerprints SET metadata = ? WHERE item = ?",
            bindings: [.blob(try JSONSerialization.data(withJSONObject: metadata)), .text(item)])
    }
    let repaired = try await engine.fixtureScan([source])
    #expect(repaired.reused == 0 && repaired.scanned == 2)
    #expect(repaired.groups.first?.evidence?.values.allSatisfy { $0.bitDepth.map { (1...64).contains($0) } == true } == true)
}
