import AlbumWinnowRust
import Foundation
import Testing
@testable import AlbumWinnowApple

@Test(arguments: ["REMOVE0.MOV", "remove0.mP4", "REMOVE0.AAE", "REMOVE0.png.XMP", "remove0.dng"])
func folderCompanionsProtectImagesBeforeAndAfterScanning(companion: String) async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.source
    let operation = try await fixture.prepare()
    let original = try await source.snapshot()
    let remove = try #require(original.assets.first { $0.name == "remove0.png" })
    #expect(remove.photoProperties?.hasAssociatedResources != true)
    let companionURL = source.directory.appending(path: companion)
    try Data("associated resource".utf8).write(to: companionURL)
    let updated = try await source.snapshot()
    #expect(updated.assets.first { $0.id == remove.id }?.photoProperties?.hasAssociatedResources == true)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: operation, sources: fixture.context())
    #expect(receipt.trashLocations.isEmpty)
    #expect(try fixture.results(operation).map(\.outcome) == [.skipped(reason: .protectedResources)])
    #expect(FileManager.default.fileExists(atPath: remove.id.item))
    #expect(try Data(contentsOf: companionURL) == Data("associated resource".utf8))
}

@Test func ordinaryCrossFormatCopiesRemainRemovableAndNestedCompanionsStayLocal() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    let nested = folder.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for name in ["same.png", "same.jpg"] { try bytes.write(to: folder.appending(path: name)) }
    try Data([0]).write(to: nested.appending(path: "same.MOV"))
    let source = FileSystemSource(fixture: folder)
    let assets = try await source.snapshot().assets
    #expect(assets.count == 2)
    #expect(assets.allSatisfy { $0.photoProperties?.hasAssociatedResources != true })
    for asset in assets { #expect(try source.removableURL(for: asset).path == asset.id.item) }
}

@Test func rawAndRenderedPairAreBothProtected() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["image.DNG", "image.JPG"] { try Data([0]).write(to: folder.appending(path: name)) }
    let assets = try await FileSystemSource(fixture: folder).snapshot().assets
    #expect(assets.count == 2)
    #expect(assets.allSatisfy { $0.photoProperties?.hasAlternatePhoto == true })
}
