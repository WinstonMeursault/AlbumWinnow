import XCTest

@MainActor
final class V2SetupUITests: XCTestCase {
    func testFreshSetupNoticeRequiresAcknowledgementAndDoesNotRepeat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--v2-setup-notice", "-reviewAnimation", "none"]
        app.launchInEnglish()
        let notice = app.alerts["Set up AlbumWinnow 2"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(notice.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Previous data is left untouched")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["duplicate-gallery"].exists)
        notice.buttons["OK"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: scan)
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launchArguments.append("--preserve-review-state")
        app.launchInEnglish()
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 15))
        XCTAssertFalse(notice.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(app.otherElements["duplicate-gallery"].exists, "Reopening must not automatically scan or restore candidates")
    }
}
