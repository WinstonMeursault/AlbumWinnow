import AlbumWinnowCore
import Foundation
import Testing

private let root = TestFiles.root

@Test func cleanupValidatesAssetsAndReturnsPartialOutcome() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let folder = scratch.appending(path: "photos")
    let db = scratch.appending(path: "cleanup.sqlite")
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    let fixture = TestFiles.fixtures.appending(path: "burst-a.png")
    let different = TestFiles.fixtures.appending(path: "burst-b.png")
    for name in ["keep.png", "changed.png", "copy.png"] {
        try files.copyItem(at: fixture, to: folder.appending(path: name))
    }
    try files.copyItem(at: different, to: folder.appending(path: "unrelated.png"))
    let source = FileSystemSource(directory: folder)
    let snapshot = try await source.snapshot()
    let byName = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.name, $0) })
    let keep = try #require(byName["keep.png"])
    let copy = try #require(byName["copy.png"])
    let changed = try #require(byName["changed.png"])
    let unrelated = try #require(byName["unrelated.png"])
    try Data(contentsOf: different).write(to: folder.appending(path: changed.name), options: .atomic)

    let service = AssetMutationService()
    let run = try await service.apply([
        CleanupPair(keep: keep, remove: changed),
        CleanupPair(keep: keep, remove: unrelated),
        CleanupPair(keep: keep, remove: copy),
    ], sources: [source])

    #expect(run.map(\.status) == [.skipped, .skipped, .movedToTrash])
    #expect(!files.fileExists(atPath: db.path))
    #expect(files.fileExists(atPath: keep.id.item))
    #expect(files.fileExists(atPath: changed.id.item))
    #expect(files.fileExists(atPath: unrelated.id.item))
    #expect(!files.fileExists(atPath: copy.id.item))
    let trashPath = try #require(run.last?.detail)
    let trash = URL(fileURLWithPath: trashPath)
    try files.moveItem(at: trash, to: folder.appending(path: copy.name))
    #expect(try Data(contentsOf: folder.appending(path: copy.name)) == Data(contentsOf: fixture))
}

@Test func missingKeepPreventsRemoval() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let folder = scratch.appending(path: "photos")
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    for name in ["keep.png", "copy.png"] {
        try files.copyItem(at: TestFiles.fixtures.appending(path: "burst-a.png"), to: folder.appending(path: name))
    }
    let source = FileSystemSource(directory: folder)
    let snapshot = try await source.snapshot()
    let keep = try #require(snapshot.assets.first { $0.name == "keep.png" })
    let copy = try #require(snapshot.assets.first { $0.name == "copy.png" })
    let service = AssetMutationService()
    await #expect(throws: CleanupError.invalidSelection) {
        try await service.apply([CleanupPair(keep: copy, remove: copy)], sources: [source])
    }
    try files.removeItem(at: folder.appending(path: keep.name))
    let run = try await service.apply([CleanupPair(keep: keep, remove: copy)], sources: [source])
    #expect(run.map(\.status) == [.failed])
    #expect(files.fileExists(atPath: copy.id.item))
}

@Test func overlappingFoldersCannotMoveTheSoleCopy() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let parent = scratch.appending(path: "photos")
    let child = parent.appending(path: "nested")
    let files = FileManager.default
    try files.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    let file = child.appending(path: "only.png")
    try files.copyItem(at: TestFiles.fixtures.appending(path: "burst-a.png"), to: file)
    let outer = FileSystemSource(directory: parent)
    let inner = FileSystemSource(directory: child)
    let kept = try #require(try await outer.snapshot().assets.first)
    let candidate = try #require(try await inner.snapshot().assets.first)
    let scan = try await ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite")).scan([outer, inner])
    #expect(scan.scanned == 1)
    #expect(scan.groups.isEmpty)
    let service = AssetMutationService()
    let run = try await service.apply([CleanupPair(keep: kept, remove: candidate)], sources: [outer, inner])
    #expect(run.map(\.status) == [.skipped])
    #expect(files.fileExists(atPath: file.path))
}

@Test func wholeGroupCleanupRequiresCurrentAssetsAndMovesEveryCopy() async throws {
    let scratch = root.appending(path: "scratch/\(UUID())")
    let folder = scratch.appending(path: "photos")
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    let fixture = TestFiles.fixtures.appending(path: "burst-a.png")
    let fileA = folder.appending(path: "a.png")
    let fileB = folder.appending(path: "b.png")
    for url in [fileA, fileB] { try files.copyItem(at: fixture, to: url) }
    let source = FileSystemSource(directory: folder)
    let engine = try ScanEngine(cacheURL: scratch.appending(path: "scan.sqlite"))
    func plan() async throws -> [CleanupPair] {
        let result = try await engine.scan([source])
        let group = try #require(result.groups.first)
        return ([group.preferred] + group.duplicates.map(\.asset)).map {
            CleanupPair(remove: $0, fromWholeGroup: group.id)
        }
    }

    let service = AssetMutationService()
    let original = try await plan()
    let excluded = try #require(original.last)
    let liveProperties = try JSONDecoder().decode(PhotoProperties.self, from:
        Data(#"{"isLivePhoto":true,"hasEdits":false,"hasAlternatePhoto":false}"#.utf8))
    let protected = PhotoAsset(id: excluded.remove.id, name: excluded.remove.name,
                               revision: excluded.remove.revision, photoProperties: liveProperties)
    #expect(throws: CleanupError.protectedResources) {
        try AssetMutationService.validateRemovals([protected], sources: [source])
    }
    await #expect(throws: CleanupError.invalidSelection) {
        try await service.apply(Array(original.prefix(1)), sources: [source])
    }
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-b.png")).write(to: fileB, options: .atomic)
    let rejected = try await service.apply(original, sources: [source])
    #expect(rejected.map(\.status) == [.skipped, .skipped])
    #expect(files.fileExists(atPath: fileA.path) && files.fileExists(atPath: fileB.path))

    try Data(contentsOf: fixture).write(to: fileB, options: .atomic)
    let refreshed = try await plan()
    let applied = try await service.apply(refreshed, sources: [source])
    #expect(applied.map(\.status) == [.movedToTrash, .movedToTrash])
    #expect(!files.fileExists(atPath: fileA.path) && !files.fileExists(atPath: fileB.path))
    for item in applied where item.status == .movedToTrash {
        let trash = URL(fileURLWithPath: try #require(item.detail))
        let original = URL(fileURLWithPath: item.pair.remove.id.item)
        try files.moveItem(at: trash, to: original)
        #expect(try Data(contentsOf: original) == Data(contentsOf: fixture))
    }
}
