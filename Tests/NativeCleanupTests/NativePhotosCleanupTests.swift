import XCTest

@MainActor
final class NativePhotosCleanupTests: XCTestCase {
    private func run(_ name: String) {
        continueAfterFailure = false
        XCTAssertEqual(ProcessInfo.processInfo.environment["ALBUMWINNOW_PHOTOS_FIXTURE"], "1")
        let app = XCUIApplication()
        app.launchEnvironment["ALBUMWINNOW_PHOTOS_FIXTURE"] = "1"
        app.launchArguments = ["-NativePhotosFixture", name, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let status = app.staticTexts["native-photos-fixture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if status.label == "passed" { return }
            XCTAssertFalse(status.label.hasPrefix("failed:"), status.label)
            let alert = system.alerts.matching(NSPredicate(format: "label CONTAINS %@", "CoreBridgeHost")).firstMatch
            let fullAccess = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Full Access", "允许完全访问"])).firstMatch
            let labels = name == "denied" ? ["Don't Allow", "Don’t Allow", "不允许"] : ["Delete", "删除"]
            let deletion = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if fullAccess.exists { fullAccess.tap() }
            else if deletion.exists { deletion.tap() }
            if status.waitForExistence(timeout: 1), status.label == "passed" { return }
        }
        XCTFail("Native Photos fixture did not finish: \(status.label); \(system.debugDescription)")
    }

    func testNativePhotoKitRecoveryKeepsTheRetainedFixture() { run("ordinary") }
    func testWholeGroupNativePhotoKitRecoveryOnlyTouchesGeneratedIdentifiers() { run("whole") }
    func testChangedAlbumMembershipPreventsNativeRecovery() { run("scope") }
    func testDecliningNativePhotoKitConfirmationKeepsBothFixturesAndTheManualChoice() { run("denied") }
}
