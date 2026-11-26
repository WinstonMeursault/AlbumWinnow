import AlbumWinnowApple
import AlbumWinnowRust
import XCTest
@testable import AlbumWinnowAcceptance

// Test-only lifecycle helper. Each workspace has an independent v2 suite and
// opens one production owner at a time; no legacy state or compatibility adapter.
@MainActor
final class ModelWorkspace {
    let root = URL.acceptanceDocumentsDirectory.appending(path: UUID().uuidString)
    let suite = "org.albumwinnow.model-tests.v2.\(UUID().uuidString)"
    var data: URL { root.appending(path: "v2") }
    var preferences: UserDefaults { UserDefaults(suiteName: suite)! }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func dispose() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func folder(_ name: String = "photos", files: [String] = ["a.png", "b.png"], fixture: String = "burst-a.png") throws -> URL {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appending(path: "Fixtures/\(fixture)"))
        for file in files { try bytes.write(to: folder.appending(path: file)) }
        return folder
    }

    func open() async throws -> ReviewModel {
        let model = ReviewModel(dataDirectory: data, preferencesSuite: suite)
        await model.bootstrap()
        guard model.protectionAvailable else {
            XCTFail(model.errorMessage ?? "v2 model did not initialize")
            throw CleanupError.unavailableProtection
        }
        await model.acknowledgeSetupNotice()
        return model
    }

    func withModel<Value>(_ action: (ReviewModel) async throws -> Value) async throws -> Value {
        let model = try await open()
        return try await action(model)
    }
}

@MainActor
func awaitModel(_ model: ReviewModel) async throws {
    for _ in 0..<1_000 {
        if !model.running && !model.updatingPolicy && !model.cleaning && !model.clearingCache { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for v2 model operation")
    throw CocoaError(.userCancelled)
}

@MainActor
func scannedGroup(_ model: ReviewModel, matching: (ReviewGroupSummary) -> Bool = { _ in true }) async throws -> ReviewGroupDetail {
    let summary = try XCTUnwrap(model.visibleGroups.first(where: matching), model.errorMessage ?? "No visible group")
    await model.loadDetails(for: [summary])
    return try XCTUnwrap(model.details[summary.id], model.errorMessage ?? "No group detail")
}

@MainActor
func preparedPreviews(_ model: ReviewModel) async throws -> [ReviewCleanupPreview] {
    await model.prepareCleanup()
    var previews = [ReviewCleanupPreview]()
    for group in model.cleanupGroups { previews.append(try await model.cleanupPreview(group)) }
    await model.cancelCleanup()
    return previews
}

@MainActor
func waitForModelCondition(_ ready: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for v2 model state")
    throw CocoaError(.userCancelled)
}
