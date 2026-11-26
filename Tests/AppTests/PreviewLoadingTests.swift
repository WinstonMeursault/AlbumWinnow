import AlbumWinnowApple
import Foundation
import XCTest
@testable import AlbumWinnowAcceptance

private actor LoadCounter {
    private(set) var active = 0
    private(set) var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

final class PreviewLoadingTests: XCTestCase {
    func testLargeFilePreviewReadsMetadataAndBoundsDecodedDimensions() async throws {
        let url = URL.acceptanceDocumentsDirectory.appending(path: "large-preview-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/48mp.png")
        try FileManager.default.copyItem(at: fixture, to: url)
        // Sparse trailing bytes make accidental full-Data reads expensive without allocating a huge test fixture.
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 128 * 1024 * 1024)
        try file.close()
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: url.path), name: "large", revision: "1")
        let preview = try await LoadedPreview.load(asset: asset, file: url)
        let image = try XCTUnwrap(preview.image)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1024)
        XCTAssertEqual(preview.dimensions, "8000 × 6000")
        XCTAssertEqual(preview.format, "PNG")
        XCTAssertEqual(preview.byteCount, 128 * 1024 * 1024)
    }

    func testPreviewPreservesExternalOrientation() async throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/scene.png")
        let bytes = try Data(contentsOf: url)
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: "scene"), name: "scene", revision: "1")
        let original = await LoadedPreview.load(asset: asset, input: AssetImage(data: bytes))
        let rotated = await LoadedPreview.load(asset: asset, input: AssetImage(data: bytes, orientation: .right))
        let first = try XCTUnwrap(original.image)
        let second = try XCTUnwrap(rotated.image)
        XCTAssertEqual(first.width, second.height)
        XCTAssertEqual(first.height, second.width)
        XCTAssertEqual(rotated.dimensions, original.dimensions?.components(separatedBy: " × ").reversed().joined(separator: " × "))
    }

    func testLargePreviewsRunExclusively() async throws {
        let queue = GalleryThumbnails()
        let counter = LoadCounter()
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: "large"), name: "large", revision: "1")
        let tasks = (0..<6).map { _ in
            Task {
                try await queue.preview(estimatedBytes: 150 * 1024 * 1024) {
                    await counter.begin()
                    try await Task.sleep(for: .milliseconds(20))
                    await counter.end()
                    return LoadedPreview(asset: asset, image: nil, format: nil, byteCount: nil, dimensions: nil)
                }
            }
        }
        for task in tasks { _ = try await task.value }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
    }

    func testZoomDetailsRunExclusivelyAndAreNotRetainedByCache() async throws {
        let queue = GalleryThumbnails()
        let counter = LoadCounter()
        let url = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/scene.png")
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: "detail"), name: "detail", revision: "1")
        let preview = try await LoadedPreview.load(asset: asset, file: url)
        let image = try XCTUnwrap(preview.image)
        let key = GalleryThumbnailKey(asset: asset, pixelSize: 2560)
        let tasks = (0..<6).map { _ in
            Task {
                try await queue.image(for: key) {
                    await counter.begin()
                    try await Task.sleep(for: .milliseconds(20))
                    await counter.end()
                    return image
                }
            }
        }
        for task in tasks { _ = try await task.value }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
        // A released view must not leave its detail image in the ordinary thumbnail cache.
        do {
            _ = try await queue.image(for: key) { throw AssetAccessError.inaccessible }
            XCTFail("Detail unexpectedly survived in cache")
        } catch AssetAccessError.inaccessible {}
    }

    func testPreviewQueueIsBoundedAndCancelledWaitersReleaseTheirPlaces() async throws {
        let queue = GalleryThumbnails()
        let counter = LoadCounter()
        let asset = PhotoAsset(id: AssetID(source: "fixture", item: "one"), name: "one", revision: "1")
        let tasks = (0..<16).map { _ in
            Task {
                try await queue.preview {
                    await counter.begin()
                    do { try await Task.sleep(for: .milliseconds(60)) }
                    catch { await counter.end(); throw error }
                    await counter.end()
                    return LoadedPreview(asset: asset, image: nil, format: nil, byteCount: nil, dimensions: nil)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        for task in tasks.suffix(8) { task.cancel() }
        for task in tasks { _ = try? await task.value }
        let peak = await counter.peak
        let active = await counter.active
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(active, 0)
        let final = try await queue.preview {
            LoadedPreview(asset: asset, image: nil, format: "PNG", byteCount: nil, dimensions: nil)
        }
        XCTAssertEqual(final.format, "PNG")
    }
}
