import AlbumWinnowCore
import CoreGraphics
import ImageIO
import XCTest
@testable import AlbumWinnowAcceptance

final class FixtureSeedTests: XCTestCase {
    @MainActor
    func testPrepareIsolatedFolderFixtures() throws {
        let folder = URL.documentsDirectory.appending(path: "AppTestFixtures", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, width, height, red, green, blue) in [
            ("landscape", 1600, 900, 0.2, 0.5, 0.9),
            ("portrait", 360, 1800, 0.9, 0.3, 0.2),
            ("long", 144, 2200, 0.2, 0.8, 0.3),
            ("wide", 1000, 240, 0.8, 0.3, 0.8),
        ] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3))
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            for suffix in ["a", "b"] {
                try (bytes as Data).write(to: folder.appending(path: "gallery-\(name)-\(suffix).png"))
            }
        }
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appending(path: "Fixtures")
        for suffix in ["a", "b"] {
            try Data(contentsOf: fixtures.appending(path: "detail-\(suffix).png"))
                .write(to: folder.appending(path: "review-detail-\(suffix).png"))
        }
        UserDefaults.standard.set(false, forKey: "AlbumWinnow.photosEnabled")
        UserDefaults.standard.removeObject(forKey: "AlbumWinnow.interruptedScan")
        let model = ReviewModel()
        for source in model.folders { model.removeFolder(source.id) }
        model.addFolder(folder)
        XCTAssertEqual(model.folders.map(\.name), ["AppTestFixtures"])
        XCTAssertTrue(model.canScan)
        XCTAssertTrue(UserDefaults.standard.synchronize())
    }
}
