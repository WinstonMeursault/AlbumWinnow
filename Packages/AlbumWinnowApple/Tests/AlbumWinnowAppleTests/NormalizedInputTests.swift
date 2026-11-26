import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AlbumWinnowApple

private func quadrantPNG() throws -> Data {
    let colors: [[UInt8]] = [[240, 20, 30, 255], [30, 220, 40, 255],
                             [40, 50, 230, 255], [220, 210, 60, 255]]
    var pixels = [UInt8]()
    for y in 0..<16 {
        for x in 0..<32 { pixels.append(contentsOf: colors[(y >= 8 ? 2 : 0) + (x >= 16 ? 1 : 0)]) }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: 32, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: 32 * 4, space: PreparedImage.colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return encoded as Data
}

@Test(arguments: [
    (UInt32(1), [0, 1, 2, 3]), (UInt32(2), [1, 0, 3, 2]),
    (UInt32(3), [3, 2, 1, 0]), (UInt32(4), [2, 3, 0, 1]),
    (UInt32(5), [0, 2, 1, 3]), (UInt32(6), [2, 0, 3, 1]),
    (UInt32(7), [3, 1, 2, 0]), (UInt32(8), [1, 3, 0, 2]),
])
func normalizedRowsAndAllEightOrientationsRemainExplicit(raw: UInt32, corners: [Int]) throws {
    let data = try quadrantPNG()
    let orientation = try #require(CGImagePropertyOrientation(rawValue: raw))
    let prepared = try PreparedImage(data: data, orientation: orientation)
    #expect(prepared.fingerprint.width == (raw >= 5 ? 16 : 32))
    #expect(prepared.fingerprint.height == (raw >= 5 ? 32 : 16))
    let colors: [[UInt8]] = [[240, 20, 30, 255], [30, 220, 40, 255],
                             [40, 50, 230, 255], [220, 210, 60, 255]]
    for (offset, expected) in zip([0, 127 * 4, 127 * 128 * 4, (128 * 128 - 1) * 4], corners) {
        let actual = Array(prepared.comparisonPixels[offset..<offset + 4])
        #expect(zip(actual, colors[expected]).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "orientation \(raw), corner \(expected)")
    }
}

@Test func transparentPixelsStayPremultipliedAndFileAndMemoryAgree() throws {
    var pixels = [UInt8]()
    for y in 0..<128 {
        for _ in 0..<128 { pixels.append(contentsOf: y < 64 ? [100, 40, 10, 128] : [0, 0, 0, 0]) }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: 512, space: PreparedImage.colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let file = FileManager.default.temporaryDirectory.appending(path: "v2-alpha-\(UUID()).png")
    try (encoded as Data).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let memory = try PreparedImage(data: encoded as Data)
    let disk = try PreparedImage(input: .file(file))
    #expect(memory.comparisonPixels == disk.comparisonPixels)
    #expect(memory.fingerprint.fileHash == disk.fingerprint.fileHash)
    #expect(memory.comparisonPixels.prefix(4) == [100, 40, 10, 128])
    #expect(memory.comparisonPixels.suffix(4) == [0, 0, 0, 0])
}
