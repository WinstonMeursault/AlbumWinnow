import Foundation
import Testing
@testable import AlbumWinnowCore

@Test(arguments: ["IMG_0001.MOV", "img_0001.mP4", "IMG_0001.AAE", "IMG_0001.png.XMP", "img_0001.dng"])
func folderCompanionsProtectImagesBeforeAndAfterScanning(companion: String) async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for name in ["IMG_0001.png", "keep.png"] { try bytes.write(to: folder.appending(path: name)) }
    let source = FileSystemSource(directory: folder)
    let original = try await source.snapshot()
    let remove = try #require(original.assets.first { $0.name == "IMG_0001.png" })
    let keep = try #require(original.assets.first { $0.name == "keep.png" })
    #expect(remove.photoProperties?.hasAssociatedResources != true)
    try Data("associated resource".utf8).write(to: folder.appending(path: companion))
    let updated = try await source.snapshot()
    #expect(updated.assets.first { $0.id == remove.id }?.photoProperties?.hasAssociatedResources == true)
    // A sidecar added after the scan must also prevent moving a previously unprotected image.
    let outcome = try await AssetMutationService().apply([CleanupPair(keep: keep, remove: remove)], sources: [source])
    #expect(outcome.map(\.status) == [.skipped])
    #expect(outcome.first?.detail == CleanupError.protectedResources.localizedDescription)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "IMG_0001.png").path))
    #expect(try Data(contentsOf: folder.appending(path: companion)) == Data("associated resource".utf8))
}

@Test func ordinaryCrossFormatCopiesRemainRemovableAndNestedCompanionsStayLocal() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    let nested = folder.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
    for name in ["same.png", "same.jpg"] { try bytes.write(to: folder.appending(path: name)) }
    try Data([0]).write(to: nested.appending(path: "same.MOV"))
    let source = FileSystemSource(directory: folder)
    let assets = try await source.snapshot().assets
    #expect(assets.count == 2)
    #expect(assets.allSatisfy { $0.photoProperties?.hasAssociatedResources != true })
    try await AssetMutationService.validateRemovals(assets, sources: [source])
}

@Test func rawAndRenderedPairAreBothProtected() async throws {
    let folder = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["image.DNG", "image.JPG"] { try Data([0]).write(to: folder.appending(path: name)) }
    let assets = try await FileSystemSource(directory: folder).snapshot().assets
    #expect(assets.count == 2)
    #expect(assets.allSatisfy { $0.photoProperties?.hasAlternatePhoto == true })
}
