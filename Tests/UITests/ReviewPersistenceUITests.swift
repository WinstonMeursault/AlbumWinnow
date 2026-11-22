import XCTest

@MainActor
final class ReviewPersistenceUITests: XCTestCase {
    func testConfirmedPlanSurvivesRelaunchAndLockCancelsRemoval() {
        verifyRestore(animation: "none")
    }

    func testFadeAllowsConfirmationAndRestoresLocks() {
        verifyRestore(animation: "fade")
    }

    private func verifyRestore(animation: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AlbumWinnow.reviewAnimation", animation, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let a = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        a.tap()
        XCTAssertTrue(a.waitForReviewValue("Selected"))
        XCTAssertTrue(app.buttons["review-confirm"].isEnabled)
        app.buttons["review-confirm"].tap()
        XCTAssertTrue(a.waitForNonExistence(timeout: 10), app.debugDescription)
        if app.buttons["Close Review"].exists { app.buttons["Close Review"].tap() }
        else { app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap() }
        XCTAssertTrue(app.buttons["review-batch-cleanup"].waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()

        app.launchArguments.append("--preserve-review-state")
        app.launchInEnglish()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["review-batch-cleanup"].exists, "Relaunch should restore the plan without executing it")
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        cover.tap()
        let b = app.buttons["review-photo-gallery-landscape-b.png"]
        XCTAssertTrue(b.waitForExistence(timeout: 10))
        b.press(forDuration: 1)
        app.buttons["Lock Photo"].tap()
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertTrue(b.waitForReviewValue("Locked, must be kept"))
        XCTAssertEqual(a.value as? String, "Selected", "Protection changes must preserve the manual keep choice")
        XCTAssertFalse(app.buttons["review-delete-all"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Restored review with locked photo"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
