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

@Test func cacheDropsInactiveSourcesAndOlderResultScopes() async throws {
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
         try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scans"))
    }
    #expect(counts.0 == 1)
    #expect(counts.1 == 1)
    #expect(try await engine.lastResult(sources: sources.map(\.id)) == nil)
}
