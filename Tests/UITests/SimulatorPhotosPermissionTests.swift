import XCTest

@MainActor
final class SimulatorPhotosPermissionTests: XCTestCase {
    func testAuthorizeOnlyTheDedicatedSimulatorFixtureHost() throws {
        guard ProcessInfo.processInfo.environment["ALBUMWINNOW_PHOTOS_FIXTURE"] == "1" else {
            throw XCTSkip("Photos fixtures require explicit dedicated-simulator opt-in")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO"]
        app.launchInEnglish()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let toggle = app.switches["photos-source"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        if toggle.value as? String != "1" {
            let predicate = NSPredicate(format: "label IN %@", ["Allow Full Access", "允许完全访问"])
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let permission = system.buttons.matching(predicate).firstMatch
            if permission.waitForExistence(timeout: 45) { permission.tap() }
            else {
                let localPermission = app.buttons.matching(predicate).firstMatch
                XCTAssertTrue(localPermission.waitForExistence(timeout: 5), app.debugDescription)
                localPermission.tap()
            }
        }
        let authorized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [authorized], timeout: 10), .completed)
    }
}
