import AlbumWinnowRust
import Foundation
import Testing
@testable import AlbumWinnowApple

@Test func nativeFolderFactsUseRegisteredOpaqueIdentityAndSeeNewCompanionsAndLinks() async throws {
    let base = TestFiles.root.appending(path: UUID().uuidString)
    let folder = base.appending(path: "photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = folder.appending(path: "photo.png")
    try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png")).write(to: file)
    let session = try RustReviewSession(databasePath: base.appending(path: "v2/review.sqlite").path, initialized: false)
    let record = try session.registerSource(expectedRevision: 1,
        input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
                               identity: FileSystemSource.sourceIdentity(directory: folder), bookmark: Data(), label: "Photos"))
    let source = FileSystemSource(directory: folder, id: record.id)
    let snapshot = try await source.snapshot()
    let asset = try #require(snapshot.assets.first)
    #expect(asset.id.source == record.id)
    let descriptor = try asset.reviewValue(kind: .fileSystem, nativeIdentity: source.nativeIdentity(for: asset), linkCount: source.linkCount(for: asset))
    let native = try AppleAssetSources(sources: [source], registered: [record])
    let protection = try AppleProtectionSnapshot(session: session)
    let before = try native.facts(for: descriptor, removing: true, protection: protection, cancellation: CancellationHandle())
    #expect(before.asset.nativeIdentity == descriptor.nativeIdentity)
    #expect(descriptor.nativeIdentity?.hasPrefix("darwin.file.v2:") == true)
    #expect(try FileSystemSource.sourceIdentity(directory: folder) == source.sourceIdentity())
    #expect(before.asset.linkCount == 1)
    #expect(before.independentlyRemovable)
    try Data("edit".utf8).write(to: folder.appending(path: "photo.png.xmp"))
    let associated = try native.facts(for: descriptor, removing: true, protection: protection, cancellation: CancellationHandle())
    #expect(associated.asset.properties == 2)
    #expect(!associated.independentlyRemovable)
    try FileManager.default.linkItem(at: file, to: folder.appending(path: "alias.png"))
    #expect(throws: AssetAccessError.changedDuringScan) { try source.linkCount(for: asset) }
    let refreshed = try await source.snapshot()
    let current = try #require(refreshed.assets.first { $0.name == asset.name })
    #expect(try source.linkCount(for: current) == 2)
}

@Test func nativeLockedPathIdentityTracksReplacementAndRootRetargetingFailsClosed() async throws {
    let base = TestFiles.root.appending(path: UUID().uuidString)
    let folder = base.appending(path: "photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = folder.appending(path: "photo.png")
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    try bytes.write(to: file)
    let source = FileSystemSource(directory: folder, id: "source.v2.opaque")
    let identity = try source.sourceIdentity()
    let snapshot = try await source.snapshot()
    let asset = try #require(snapshot.assets.first)
    let original = try source.nativeIdentity(for: asset)
    try bytes.write(to: file, options: .atomic)
    #expect(try source.protectionIdentity(for: asset.id) != original)
    #expect(throws: AssetAccessError.changedDuringScan) { try source.currentURL(for: asset) }
    try FileManager.default.moveItem(at: folder, to: base.appending(path: "saved"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(try source.sourceIdentity() != identity)
}
