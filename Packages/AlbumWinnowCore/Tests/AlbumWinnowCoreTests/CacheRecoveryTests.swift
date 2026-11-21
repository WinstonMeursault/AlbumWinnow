import Foundation
import GRDB
import Testing
@testable import AlbumWinnowCore

@Test(arguments: ["signature", "sample"])
func damagedFingerprintIsRebuilt(column: String) async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appending(path: "image.png")
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")).write(to: image)
    let cache = directory.appending(path: "scan.sqlite")
    let source = FileSystemSource(directory: directory)
    let engine = try ScanEngine(cacheURL: cache)
    _ = try await engine.scan([source])
    let database = try DatabaseQueue(path: cache.path)
    try await database.write { db in
        // The parameter is restricted to the two column names declared by the test.
        try db.execute(sql: "UPDATE fingerprints SET \(column) = X'00'")
    }
    let repaired = try await engine.scan([source])
    #expect(repaired.scanned == 1)
    #expect(repaired.reused == 0)
    #expect(repaired.issues.isEmpty)
    let warm = try await engine.scan([source])
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
    let result = try await ScanEngine(cacheURL: cache).scan([FileSystemSource(directory: directory)])
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
        sources.append(FileSystemSource(directory: folder))
    }
    let cache = directory.appending(path: "scan.sqlite")
    let engine = try ScanEngine(cacheURL: cache)
    _ = try await engine.scan(sources)
    _ = try await engine.scan([sources[0]])
    let database = try DatabaseQueue(path: cache.path)
    let counts = try await database.read { db in
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fingerprints"),
         try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'scans'"))
    }
    #expect(counts.0 == 1)
    #expect(counts.1 == 0)
}

@Test func legacyResultCacheIsRemovedWithoutLosingFingerprints() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        .write(to: directory.appending(path: "image.png"))
    let cache = directory.appending(path: "scan.sqlite")
    let source = FileSystemSource(directory: directory)
    _ = try await ScanEngine(cacheURL: cache).scan([source])
    let database = try DatabaseQueue(path: cache.path)
    try await database.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'fingerprintsOnly'")
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS scans (scope BLOB PRIMARY KEY, version INTEGER, result BLOB)")
        try db.execute(sql: "INSERT OR REPLACE INTO scans VALUES (X'00', 4, X'00')")
    }
    let result = try await ScanEngine(cacheURL: cache).scan([source])
    #expect(result.scanned == 0)
    #expect(result.reused == 1)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'scans'") } == 0)
}

@Test func clearingCacheReclaimsDiskAndForcesColdScanWithoutChangingPhotos() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appending(path: "image.png")
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    try bytes.write(to: photo)
    let source = FileSystemSource(directory: folder)
    let url = folder.appending(path: "scan.sqlite")
    let engine = try ScanEngine(cacheURL: url)
    _ = try await engine.scan([source])
    let db = try DatabaseQueue(path: url.path)
    try await db.write { db in
        // Enlarge only a disposable derived cache. clearCache must remove these bytes without decoding them.
        try db.execute(sql: "UPDATE fingerprints SET sample = zeroblob(8388608)")
    }
    let before = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    try await engine.clearCache()
    let after = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    #expect(before > 8_000_000)
    #expect(after < 100_000)
    #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fingerprints") } == 0)
    #expect(try Data(contentsOf: photo) == bytes)
    let cold = try await engine.scan([source])
    #expect(cold.scanned == 1 && cold.reused == 0)
    let warm = try await engine.scan([source])
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
    let engine = try ScanEngine(cacheURL: url)
    let source = FileSystemSource(directory: folder)
    _ = try await engine.scan([source])
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        let rows = try Row.fetchAll(db, sql: "SELECT item, signature FROM fingerprints")
        for row in rows {
            var fingerprint = try JSONDecoder().decode(ImageFingerprint.self, from: row["signature"] as Data)
            fingerprint.observedBitDepth = depth
            try db.execute(sql: "UPDATE fingerprints SET signature = ? WHERE item = ?",
                           arguments: [try JSONEncoder().encode(fingerprint), row["item"] as String])
        }
    }
    let repaired = try await engine.scan([source])
    #expect(repaired.reused == 0 && repaired.scanned == 2)
    #expect(repaired.groups.first?.evidence?.values.allSatisfy { $0.bitDepth.map { (1...64).contains($0) } == true } == true)
}
