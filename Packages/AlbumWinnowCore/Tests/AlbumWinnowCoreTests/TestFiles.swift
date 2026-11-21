import Foundation

// All bundled images were generated for this project. No personal photos are included.
enum TestFiles {
    static let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
    static let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnowTests", directoryHint: .isDirectory)
}
