import SwiftUI

@main struct AlbumWinnowApp: App {
    @State private var model = ReviewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("AlbumWinnow") {
            LibraryView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshAuthorization() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 760)
        #endif
    }
}
