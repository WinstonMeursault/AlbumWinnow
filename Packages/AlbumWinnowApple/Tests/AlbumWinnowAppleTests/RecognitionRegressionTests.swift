import AlbumWinnowRust
import Foundation
import ImageIO
import Testing
@testable import AlbumWinnowApple

@Test func differentSixteenBitPixelsAreMarkedForReview() throws {
    let first = try Data(contentsOf: TestFiles.fixtures.appending(path: "depth16-a.png"))
    let second = try Data(contentsOf: TestFiles.fixtures.appending(path: "depth16-b.png"))
    #expect(first != second)
    let prepared = try PreparedImage(data: second)
    #expect(prepared.fingerprint.bitDepth == 16)
    #expect(try DuplicateDetector().compare(first, first) == .exactDuplicate)
    #expect(try DuplicateDetector().compare(first, second) == .visualDuplicate)
}

@Test func localChangesRemainExplicitlySimilar() throws {
    let first = try Data(contentsOf: TestFiles.fixtures.appending(path: "detail-a.png"))
    let second = try Data(contentsOf: TestFiles.fixtures.appending(path: "detail-b.png"))
    #expect(try DuplicateDetector().compare(first, second) == .similarPhoto)
    #expect(try DuplicateDetector().compare(second, first) == .similarPhoto)
}

@Test func fullResolutionMetadataSurvivesBoundedDecoding() throws {
    let input = ImageInput.file(TestFiles.fixtures.appending(path: "48mp.png"))
    let prepared = try autoreleasepool { try PreparedImage(input: input) }
    #expect(prepared.fingerprint.width == 8_000)
    #expect(prepared.fingerprint.height == 6_000)
    #expect(prepared.comparisonPixels.count == 128 * 128 * 4)
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "48mp.png"))
    #expect(try DuplicateDetector().compare(bytes, bytes) == .exactDuplicate)
}

@Test func fileAndMemoryInputsAgreeIncludingExternalOrientation() throws {
    let url = TestFiles.fixtures.appending(path: "burst-a.png")
    let data = try Data(contentsOf: url)
    let file = try PreparedImage(input: .file(url))
    let memory = try PreparedImage(data: data)
    #expect(file.fingerprint.fileHash == memory.fingerprint.fileHash)
    #expect(file.comparisonPixels == memory.comparisonPixels)
    let rotated = try PreparedImage(data: data, orientation: .right)
    #expect(rotated.fingerprint.width == memory.fingerprint.height)
    #expect(rotated.fingerprint.height == memory.fingerprint.width)
    #expect(rotated.fingerprint.fileHash != memory.fingerprint.fileHash)
    #expect(try DuplicateDetector().compare(AssetImage(data: data), AssetImage(data: data, orientation: .right)) == .distinct)
}

@Test func higherBitDepthWinsOtherwiseEquivalentRecommendations() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let low = directory.appending(path: "a-low.png")
    let high = directory.appending(path: "z-high.png")
    let bytes = try Data(contentsOf: TestFiles.fixtures.appending(path: "depth16-a.png"))
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 128,
    ] as CFDictionary))
    var pixels = [UInt8](repeating: 128, count: 128 * 128 * 4)
    let encoded = NSMutableData()
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: 128, height: 128, bitsPerComponent: 8,
                                bytesPerRow: 128 * 4, space: PreparedImage.colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let output = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(output))
    }
    try (encoded as Data).write(to: low)
    try bytes.write(to: high)
    let result = try await FixtureScanEngine(cacheURL: directory.appending(path: "scan.sqlite")).fixtureScan([
        FileSystemSource(fixture: directory)
    ])
    #expect(result.groups.first?.preferred.name == "z-high.png")
    #expect(result.groups.first?.duplicates.first?.match == .visualDuplicate)
}

@Test func wideGamutWinsOtherwiseEquivalentRecommendations() async throws {
    let directory = TestFiles.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, spaceName) in [("a-srgb.png", CGColorSpace.sRGB), ("z-p3.png", CGColorSpace.displayP3)] {
        let space = try #require(CGColorSpace(name: spaceName))
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                            bytesPerRow: 128 * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: directory.appending(path: name))
    }
    let wide = try PreparedImage(input: .file(directory.appending(path: "z-p3.png")))
    #expect(wide.fingerprint.hasWideColor)
    let result = try await FixtureScanEngine(cacheURL: directory.appending(path: "scan.sqlite")).fixtureScan([
        FileSystemSource(fixture: directory)
    ])
    #expect(result.groups.first?.preferred.name == "z-p3.png")
    #expect(result.groups.first?.duplicates.first?.match == .visualDuplicate)
}

@Test func similarGroupKeepsItsWarningAndSupportsManualCleanup() async throws {
    let fixture = try NativeCleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    for (name, input) in [("keep0.png", "detail-a.png"), ("remove0.png", "detail-b.png")] {
        try Data(contentsOf: TestFiles.fixtures.appending(path: input)).write(to: fixture.source.directory.appending(path: name))
    }
    _ = try await ScanEngine(cacheURL: fixture.base.appending(path: "scan.sqlite"))
        .scan(fixture.context(), review: fixture.session)
    let summary = try #require(fixture.session.queryPage(offset: 0, limit: 1).first)
    #expect(summary.kind == .similarPhoto)
    let group = try fixture.session.groupDetail(signature: summary.signature).group
    let member = try #require(group.duplicates.first)
    #expect(member.kind == .similarPhoto)
    let removedURL = URL(fileURLWithPath: member.asset.itemId)
    let original = try Data(contentsOf: removedURL)
    #expect(try fixture.session.groupDetail(signature: summary.signature).decision == nil)
    _ = try fixture.session.applyIntent(expectedRevision: fixture.session.header().metadata.revision,
        signature: summary.signature, commandId: "manual-similar", intent: .confirmKeep(keep: group.preferred))
    let plan = try fixture.session.startCleanup(expectedRevision: fixture.session.header().metadata.revision)
    let receipt = try await AppleCleanupExecutor(session: fixture.session).apply(operation: plan.operation, sources: fixture.context())
    let result = try #require(fixture.results(plan.operation).first)
    #expect(result.outcome == .movedToTrash)
    let moved = try #require(receipt.trashLocations[result.item.key])
    try FileManager.default.moveItem(at: moved, to: removedURL)
    #expect(try Data(contentsOf: removedURL) == original)
    #expect(FileManager.default.fileExists(atPath: group.preferred.itemId))
}
