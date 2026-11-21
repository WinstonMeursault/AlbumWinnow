import AlbumWinnowCore
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
                .task {
                    model.sceneChanged(scenePhase)
                    if ProcessInfo.processInfo.arguments.contains("--cleanup-outcome-fixture") {
                        await prepareCleanupOutcome()
                    }
                }
                .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
        }
    }

    @MainActor
    private func prepareCleanupOutcome() async {
        do {
            for folder in model.folders { model.removeFolder(folder.id) }
            let folder = URL.documentsDirectory.appending(path: "CleanupOutcomeFixture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["missing.png", "protected.png.AAE"] {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            let fixture = try Self.require(Bundle.main.resourceURL).appending(path: "Fixtures/burst-a.png")
            let bytes = try Data(contentsOf: fixture)
            for name in ["keep.png", "missing.png", "protected.png"] { try bytes.write(to: folder.appending(path: name)) }
            model.addFolder(folder)
            model.scan()
            while model.running { try await Task.sleep(for: .milliseconds(20)) }
            let group = try Self.require(model.result?.groups.first)
            let keep = try Self.require(([group.preferred] + group.duplicates.map(\.asset)).first { $0.name == "keep.png" })
            guard await model.confirmSelection(in: group, keepID: keep.id, deleteAll: false) else { return }
            let pairs = model.cleanupGroups.flatMap(\.pairs)
            try FileManager.default.removeItem(at: folder.appending(path: "missing.png"))
            try Data([0]).write(to: folder.appending(path: "protected.png.AAE"))
            await model.applyCleanup(pairs)
        } catch { model.errorMessage = error.localizedDescription }
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
