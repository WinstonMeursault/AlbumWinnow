import CoreGraphics
import ImageIO
import SwiftUI

// Simulator reinstalls can move the data container. Rebind fixture bookmarks at launch.
@main struct AcceptanceApp: App {
    @State private var model: ReviewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { try Self.prepareFixtures() } catch { fatalError("Test fixture setup failed: \(error)") }
        let folder = URL.documentsDirectory.appending(path: "AppTestFixtures", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path), let scope = try? FolderScope(url: folder) {
            UserDefaults.standard.set([scope.bookmark], forKey: "AlbumWinnow.folderBookmarks")
        }
        _model = State(initialValue: ReviewModel())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .task { model.sceneChanged(scenePhase) }
                .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
        }
    }

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private static func prepareFixtures() throws {
        let folder = URL.documentsDirectory.appending(path: "AppTestFixtures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: folder.appending(path: "review-detail-b.png").path) { return }
        for (name, width, height, red, green, blue) in [
            ("landscape", 1600, 900, 0.2, 0.5, 0.9),
            ("portrait", 360, 1800, 0.9, 0.3, 0.2),
            ("long", 144, 2200, 0.2, 0.8, 0.3),
            ("wide", 1000, 240, 0.8, 0.3, 0.8),
        ] {
            let context = try require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3))
            let bytes = NSMutableData()
            let destination = try require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try require(context.makeImage()), nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            for suffix in ["a", "b"] {
                try (bytes as Data).write(to: folder.appending(path: "gallery-\(name)-\(suffix).png"))
            }
        }
        let fixtures = try require(Bundle.main.resourceURL).appending(path: "Fixtures")
        for suffix in ["a", "b"] {
            try Data(contentsOf: fixtures.appending(path: "detail-\(suffix).png"))
                .write(to: folder.appending(path: "review-detail-\(suffix).png"))
        }
    }
}
