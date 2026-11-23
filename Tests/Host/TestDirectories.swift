import Foundation

extension URL {
    static var acceptanceDocumentsDirectory: URL {
        #if os(macOS)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".local/mac-test-data")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #else
        return .documentsDirectory
        #endif
    }
}
