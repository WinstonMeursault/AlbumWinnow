import SwiftUI
import AlbumWinnowRust
import Photos

@main
struct BridgeHost: App {
    @State private var photosAuthorized = false
    @State private var fixtureStatus = "running"
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(coreVersion())
                Button("Authorize generated Photos fixtures") {
                    Task { photosAuthorized = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized }
                }.accessibilityIdentifier("authorize-photos-fixtures")
                Text(photosAuthorized ? "Photos authorized" : "Photos not authorized")
                    .accessibilityIdentifier("photos-authorization")
                Text(fixtureStatus).accessibilityIdentifier("native-photos-fixture-status")
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard let index = arguments.firstIndex(of: "-NativePhotosFixture"), index + 1 < arguments.count else { return }
                let name = arguments[index + 1]
                fixtureStatus = await Task.detached {
                    do { try await NativePhotosCleanupFixture.run(name); return "passed" }
                    catch { return "failed: \(error.localizedDescription)" }
                }.value
            }
        }
    }
}
