import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AlbumWinnowCore

private struct DifferenceSource: AssetSource {
    let id = "difference-fixture"
    let images: [String: AssetImage]
    var beforeRead: @Sendable (PhotoAsset) async throws -> Void = { _ in }
    func snapshot() async throws -> AssetSnapshot { AssetSnapshot(assets: []) }
    func imageData(for asset: PhotoAsset) async throws -> Data { try await image(for: asset).data }
    func image(for asset: PhotoAsset) async throws -> AssetImage {
        try Task.checkCancellation()
        try await beforeRead(asset)
        return images[asset.id.item]!
    }
}

private enum DifferenceFixture {
    static let width = 512, height = 384
    static func image(seed: Int, changed: Bool = false, expression: Bool = false) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let glyphs = [[31, 1, 1, 31, 16, 16, 31], [31, 17, 17, 17, 17, 17, 31],
                      [31, 1, 1, 31, 16, 16, 31], changed && !expression ? [31, 1, 2, 4, 8, 8, 8] : [31, 16, 16, 31, 17, 17, 31]]
        for y in 0..<height {
            for x in 0..<width {
                let shade = ((x / 32 + y / 24 + seed) % 2) * 12 + x * 35 / width + y * 20 / height
                var rgb = [85 + shade + seed % 7, 110 + shade / 2, 150 - shade / 3]
                let dx = x - 128, dy = y - 212
                if dx * dx + dy * dy < 3600 { rgb = [220, 170, 70] }
                if (x - 108) * (x - 108) + (y - 190) * (y - 190) < 36 ||
                    (x - 148) * (x - 148) + (y - 190) * (y - 190) < 36 { rgb = [20, 20, 20] }
                let curve = 236 + (changed && expression ? -1 : 1) * dx * dx / 64
                if abs(dx) <= 32 && abs(y - curve) <= 3 { rgb = [20, 20, 20] }
                if (300..<444).contains(x), (100..<142).contains(y) {
                    let character = (x - 300) / 36, column = (x - 300) % 36 / 6, row = (y - 100) / 6
                    if character < 4, column < 5, glyphs[character][row] & (1 << (4 - column)) != 0 { rgb = [15, 15, 15] }
                }
                let index = (y * width + x) * 4
                for channel in 0..<3 { pixels[index + channel] = UInt8(rgb[channel]) }
            }
        }
        return self.image(pixels: pixels, width: width, height: height)
    }

    static func image(pixels: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func data(_ image: CGImage, jpeg: Double? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, (jpeg == nil ? "public.png" : "public.jpeg") as CFString, 1, nil)!
        let properties = jpeg.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func recolored(_ image: CGImage, seed: Int) -> CGImage {
        var pixels = Array(image.dataProvider!.data! as Data)
        let gain = seed.isMultiple(of: 2) ? 0.9 : 1.1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let offset = Double((seed + channel) % 5 - 2) * 5
                pixels[index + channel] = UInt8(clamping: Int((Double(pixels[index + channel]) * gain + offset).rounded()))
            }
        }
        return self.image(pixels: pixels, width: image.width, height: image.height)
    }

    static func compare(_ first: Data, _ second: Data) async throws -> PhotoDifference {
        let source = DifferenceSource(images: ["a": AssetImage(data: first), "b": AssetImage(data: second)])
        let a = PhotoAsset(id: AssetID(source: source.id, item: "a"), name: "a", revision: "1")
        let b = PhotoAsset(id: AssetID(source: source.id, item: "b"), name: "b", revision: "1")
        return try await PhotoDifference.compare(a, source: source, b, source: source)
    }
}

@Suite(.serialized)
struct PhotoDifferenceTests {
    @Test func suppressesJPEGResolutionAndGlobalColorChanges() async throws {
        var falseHints = 0, unavailable = 0
        for seed in 0..<20 {
            let image = DifferenceFixture.image(seed: seed)
            let original = DifferenceFixture.data(image)
            let variants = [DifferenceFixture.data(image, jpeg: [0.5, 0.65, 0.8][seed % 3]),
                DifferenceFixture.data(DifferenceFixture.resized(image, scale: [0.5, 0.75, 1.5][seed % 3])),
                DifferenceFixture.data(DifferenceFixture.recolored(image, seed: seed))]
            for variant in variants {
                let result = try await DifferenceFixture.compare(original, variant)
                if result.unavailableReason != nil { unavailable += 1 }
                if !result.regions.isEmpty { falseHints += 1 }
            }
        }
        print("DIFFERENCE_NEGATIVE total=60 false_hints=\(falseHints) alignment_abstentions=\(unavailable)")
        #expect(falseHints <= 3)
        #expect(unavailable <= 3, "Abstaining on every negative is not a valid noise-suppression result")
    }

    @Test func highlightsLabeledDigitAndExpressionShapeRegions() async throws {
        var hits = 0, unavailable = 0
        for seed in 0..<20 {
            for expression in [false, true] {
                let original = DifferenceFixture.data(DifferenceFixture.image(seed: seed, expression: expression))
                let changed = DifferenceFixture.data(DifferenceFixture.image(seed: seed, changed: true, expression: expression))
                let result = try await DifferenceFixture.compare(original, changed)
                if result.unavailableReason != nil { unavailable += 1 }
                let expected = expression ? CGRect(x: 96.0 / 512, y: 217.0 / 384, width: 65.0 / 512, height: 39.0 / 384) :
                    CGRect(x: 408.0 / 512, y: 100.0 / 384, width: 30.0 / 512, height: 42.0 / 384)
                if result.regions.contains(where: {
                    let intersection = $0.intersection(expected)
                    let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                    let union = $0.width * $0.height + expected.width * expected.height - overlap
                    return union > 0 && overlap / union >= 0.5
                }) { hits += 1 }
            }
        }
        print("DIFFERENCE_POSITIVE total=40 region_iou_at_least_0.5_hits=\(hits) misses=\(40 - hits) alignment_abstentions=\(unavailable)")
        #expect(hits >= 36)
    }

    @Test func declinesDifferentGeometryAndFlatImages() async throws {
        let image = DifferenceFixture.image(seed: 0)
        let crop = image.cropping(to: CGRect(x: 20, y: 0, width: image.width - 40, height: image.height))!
        let cropped = try await DifferenceFixture.compare(DifferenceFixture.data(image), DifferenceFixture.data(crop))
        #expect(cropped.unavailableReason != nil)
        #expect(cropped.regions.isEmpty)
        let flat = DifferenceFixture.image(pixels: [UInt8](repeating: 255, count: 256 * 256 * 4), width: 256, height: 256)
        let uniform = try await DifferenceFixture.compare(DifferenceFixture.data(flat), DifferenceFixture.data(flat))
        #expect(uniform.unavailableReason != nil)
        #expect(uniform.regions.isEmpty)
    }

    @Test func rejectsMalformedImagesAndIdenticalAssetIDs() async throws {
        let data = DifferenceFixture.data(DifferenceFixture.image(seed: 0))
        do { _ = try await DifferenceFixture.compare(data, Data("invalid".utf8)); Issue.record("Malformed image accepted") }
        catch is ImageReadError {}
        let source = DifferenceSource(images: ["a": AssetImage(data: data)])
        let asset = PhotoAsset(id: AssetID(source: source.id, item: "a"), name: "a", revision: "1")
        do { _ = try await PhotoDifference.compare(asset, source: source, asset, source: source); Issue.record("Same photo accepted as a comparison pair") }
        catch PhotoDifferenceError.invalidPair {}
    }

    @Test func normalizesLabeledOrientationAndCrossFormatCopies() async throws {
        let original = try Data(contentsOf: TestFiles.fixtures.appending(path: "burst-a.png"))
        for name in ["orientation.png", "pixel-copy.png", "pixel-copy.tiff"] {
            let other = try Data(contentsOf: TestFiles.fixtures.appending(path: name))
            let result = try await DifferenceFixture.compare(original, other)
            #expect(result.unavailableReason == nil, "Orientation/color normalization failed for \(name)")
            #expect(result.regions.isEmpty, "A labeled visual copy must not acquire local-change hints")
        }
    }

    @Test func locatesExistingLabeledLocalDifference() async throws {
        let first = try Data(contentsOf: TestFiles.fixtures.appending(path: "detail-a.png"))
        let second = try Data(contentsOf: TestFiles.fixtures.appending(path: "detail-b.png"))
        let result = try await DifferenceFixture.compare(first, second)
        #expect(result.unavailableReason == nil)
        #expect(!result.regions.isEmpty)
        print("DIFFERENCE_EXISTING_DETAIL regions=\(result.regions)")
    }

    @Test func declinesSameAspectCropsAndMirroredViews() async throws {
        let image = DifferenceFixture.image(seed: 0)
        let original = DifferenceFixture.data(image)
        let crop = image.cropping(to: CGRect(x: 16, y: 12, width: 480, height: 360))!
        let cropped = try await DifferenceFixture.compare(original, DifferenceFixture.data(crop))
        #expect(cropped.unavailableReason != nil)
        #expect(cropped.regions.isEmpty)
        let pixels = Array(image.dataProvider!.data! as Data)
        var mirrored = pixels
        for y in 0..<image.height {
            for x in 0..<image.width {
                for channel in 0..<4 {
                    mirrored[(y * image.width + x) * 4 + channel] = pixels[(y * image.width + image.width - x - 1) * 4 + channel]
                }
            }
        }
        let changed = DifferenceFixture.image(pixels: mirrored, width: image.width, height: image.height)
        let result = try await DifferenceFixture.compare(original, DifferenceFixture.data(changed))
        #expect(result.unavailableReason != nil)
        #expect(result.regions.isEmpty)
    }

    @Test func cancellationPropagatesThroughPreviewReads() async throws {
        let data = DifferenceFixture.data(DifferenceFixture.image(seed: 0))
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let source = DifferenceSource(images: ["a": AssetImage(data: data), "b": AssetImage(data: data)], beforeRead: { _ in
            signal.yield(())
            try await Task.sleep(for: .seconds(1))
        })
        let a = PhotoAsset(id: AssetID(source: source.id, item: "a"), name: "a", revision: "1")
        let b = PhotoAsset(id: AssetID(source: source.id, item: "b"), name: "b", revision: "1")
        let task = Task { try await PhotoDifference.compare(a, source: source, b, source: source) }
        for await _ in started { task.cancel(); break }
        do { _ = try await task.value; Issue.record("Cancelled preview returned difference evidence") }
        catch is CancellationError {}
    }

    @Test func freshPreviewsAreBoundedAndBothResourcesAreRevalidated() async throws {
        let scratch = TestFiles.root.appending(path: "difference-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let data = DifferenceFixture.data(DifferenceFixture.resized(DifferenceFixture.image(seed: 0), scale: 3))
        let referenceFile = scratch.appending(path: "reference.png")
        try data.write(to: referenceFile)
        let folder = FileSystemSource(directory: scratch)
        let reference = try #require(try await folder.snapshot().assets.first)
        let other = PhotoAsset(id: AssetID(source: "difference-fixture", item: "b"), name: "b", revision: "1")
        let source = DifferenceSource(images: ["b": AssetImage(data: data)])
        let result = try await PhotoDifference.compare(reference, source: folder, other, source: source)
        #expect(max(result.reference.width, result.reference.height) <= 512)
        #expect(max(result.comparison.width, result.comparison.height) <= 512)
        let mutating = DifferenceSource(images: ["b": AssetImage(data: data)], beforeRead: { _ in
            try Data("replacement".utf8).write(to: referenceFile)
        })
        do {
            _ = try await PhotoDifference.compare(reference, source: folder, other, source: mutating)
            Issue.record("Returned an overlay after its reference resource changed")
        } catch AssetAccessError.changedDuringScan {}
        #expect(FileManager.default.fileExists(atPath: referenceFile.path))
    }
}
