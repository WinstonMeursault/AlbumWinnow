import XCTest

@MainActor
final class ReviewToolsUITests: XCTestCase {
    func testFilteringKeepsGlobalConfirmedCandidates() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AlbumWinnow.reviewAnimation", "none",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let photo = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        app.buttons["review-confirm"].tap()
        XCTAssertTrue(photo.waitForNonExistence(timeout: 8))
        if app.buttons["Close Review"].exists { app.buttons["Close Review"].tap() }
        else { app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap() }
        app.buttons["Review Options"].tap()
        app.buttons["Filter and Sort"].tap()
        XCTAssertTrue(app.navigationBars["Filter and Sort"].waitForExistence(timeout: 5))
        app.buttons["result-status-filter"].tap()
        app.buttons["Entire Group Kept"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No groups match these filters."].waitForExistence(timeout: 5))
        let batch = app.buttons["review-batch-cleanup"]
        XCTAssertTrue(batch.exists)
        XCTAssertEqual(batch.label, "Confirm Cleanup (1)")
        batch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "outside the current filters")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cleanup-remove-gallery-landscape-b.png"].exists)
        app.buttons["Cancel"].tap()
    }

    func testEvidenceAndZoomDoNotChangeSelectionOrSwipeWhileZoomed() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AlbumWinnow.reviewAnimation", "none",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let photo = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.doubleTap()
        photo.pinch(withScale: 1.25, velocity: 1)
        XCTAssertNotEqual(photo.value as? String, "Selected")
        photo.swipeLeft()
        XCTAssertTrue(photo.exists, "Panning a zoomed image must not change the group")
        XCTAssertNotEqual(photo.value as? String, "Selected")
        app.buttons["Group Actions"].tap()
        app.buttons["Reset Zoom"].tap()
        photo.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        app.buttons["review-evidence"].tap()
        XCTAssertTrue(app.navigationBars["Review Evidence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["File bytes and effective orientation agree."].exists)
        XCTAssertTrue(app.staticTexts["No established quality advantage. Choose according to your preference."].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Structured matching and recommendation evidence"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].tap()
        XCTAssertEqual(photo.value as? String, "Selected")
        app.buttons["review-photo-gallery-landscape-b.png"].swipeLeft()
        XCTAssertTrue(photo.waitForNonExistence(timeout: 8), "Reset restores group navigation")
    }
}
