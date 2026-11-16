import SwiftUI

@main struct AlbumWinnowApp: App {
    @State private var model = ReviewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("AlbumWinnow") {
            LibraryView(model: model)
                .task { model.sceneChanged(scenePhase) }
                .onChange(of: scenePhase) { _, phase in
                    model.sceneChanged(phase)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 760)
        #endif
        #if os(macOS)
        Settings {
            ScanSourcesView(model: model)
                .frame(width: 460, height: 400)
        }
        #endif
    }
}
