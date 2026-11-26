import AlbumWinnowApple
import Foundation

// All bundled images were generated for this project. No personal photos are included.
enum TestFiles {
    #if SWIFT_PACKAGE
    static let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
    #else
    static let fixtures = Bundle.main.resourceURL!.appending(path: "Fixtures")
    #endif
    static let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnowTests", directoryHint: .isDirectory)
}

// Readable IDs exist only at the recognition-fixture boundary; FixtureScanEngine
// registers them with Rust before production scan preparation.
extension FileSystemSource {
    init(fixture directory: URL) {
        self.init(directory: directory, id: "controlled.fixture.folder:\(directory.standardizedFileURL.resolvingSymlinksInPath().path)")
    }
}
