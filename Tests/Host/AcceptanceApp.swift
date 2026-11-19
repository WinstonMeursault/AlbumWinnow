import SwiftUI

// Simulator reinstalls can move the data container. Rebind fixture bookmarks at launch.
@main struct AcceptanceApp: App {
    @State private var model: ReviewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
}
