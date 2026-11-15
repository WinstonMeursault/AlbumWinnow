import AlbumWinnowCore
import Foundation

final class FolderScope: Identifiable {
    let source: FileSystemSource
    let bookmark: Data
    private let url: URL
    private let opened: Bool

    var id: String { source.id }
    var name: String { url.lastPathComponent }

    init(url: URL) throws {
        let opened = url.startAccessingSecurityScopedResource()
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = .minimalBookmark
            #endif
            bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if opened { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.url = url
        self.opened = opened
        source = FileSystemSource(directory: url)
    }

    convenience init(bookmark: Data) throws {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        try self.init(url: url)
    }

    deinit {
        if opened { url.stopAccessingSecurityScopedResource() }
    }
}
