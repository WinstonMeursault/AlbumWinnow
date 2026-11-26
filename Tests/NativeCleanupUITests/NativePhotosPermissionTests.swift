import XCTest

@MainActor
final class NativePhotosPermissionTests: XCTestCase {
    func testAuthorizeDedicatedGeneratedFixtureHost() {
        continueAfterFailure = false
        XCTAssertEqual(ProcessInfo.processInfo.environment["ALBUMWINNOW_PHOTOS_FIXTURE"], "1")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let authorize = app.buttons["authorize-photos-fixtures"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 20))
        authorize.tap()
        let granted = app.staticTexts["Photos authorized"]
        if !granted.waitForExistence(timeout: 2) {
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let predicate = NSPredicate(format: "label IN %@", ["Allow Full Access", "允许完全访问"])
            let allow = system.buttons.matching(predicate).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
            else {
                let local = app.buttons.matching(predicate).firstMatch
                XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
                local.tap()
            }
        }
        XCTAssertTrue(granted.waitForExistence(timeout: 10))
    }
}
