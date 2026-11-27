import XCTest

@MainActor
final class ProtectionManagementUITests: XCTestCase {
    func testUnavailableSourceCanRetryAndBeExplicitlyRemoved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--unavailable-folder-fixture", ]
        app.launchInEnglish()
        let settings = app.navigationBars.buttons["open-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let alert = app.alerts["Scan Sources"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["OK"].tap()
        let retry = app.buttons["Retry Saved Folders"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        // A failed retry preserves the record and reports unavailability again.
        let retryAlert = app.alerts["Scan Sources"]
        XCTAssertTrue(retryAlert.waitForExistence(timeout: 5))
        retryAlert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Choose Folder Again…"].exists)
        app.buttons["Remove Record"].tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        app.buttons["settings-done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 8))
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
    }

    func testCancellingSavedLockRemovalPreservesFinalProtection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-reviewAnimation", "none"]
        app.launchInEnglish()
        app.buttons["start-scan"].tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let photo = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        app.reviewContextAction("Lock Photo", on: photo).tap()
        XCTAssertTrue(photo.waitForReviewValue("Locked, must be kept"))
        if app.buttons["close-review"].exists { app.buttons["close-review"].tap() }
        else { app.navigationBars.firstMatch.buttons.firstMatch.tap() }
        app.navigationBars.buttons["open-settings"].firstMatch.tap()
        let remove = app.buttons["Remove This Saved Lock"]
        for _ in 0..<15 {
            if remove.isHittable && remove.frame.midY < app.frame.maxY - 140 { break }
            app.swipeUp()
        }
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        let confirmation = app.sheets["Remove This Saved Lock"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap() }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        app.buttons["settings-done"].tap()
        cover.tap()
        XCTAssertTrue(photo.waitForReviewValue("Locked, must be kept"))
        XCTAssertFalse(app.buttons["review-delete-all"].isEnabled)
    }
}
