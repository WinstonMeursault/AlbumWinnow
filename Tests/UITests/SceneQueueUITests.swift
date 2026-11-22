import XCTest

@MainActor
final class SceneQueueUITests: XCTestCase {
    func testSceneQueueRequiresManualChoiceAndKeepsGlobalCleanupAcrossCollections() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--scene-fixture", "-AlbumWinnow.photosEnabled", "NO",
                               "-AlbumWinnow.reviewAnimation", "none", "-AlbumWinnow.showReviewFilenames", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90), app.debugDescription)
        let collection = app.segmentedControls["review-collection"]
        collection.buttons["Similar Photos"].tap()
        let cover = app.buttons["duplicate-group-scene-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["duplicate-group-gallery-landscape-a.png"].exists)
        cover.tap()
        let photo = app.buttons["review-photo-scene-b.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(photo.label.contains("recommended to keep"))
        XCTAssertFalse(app.buttons["review-confirm"].isEnabled)
        app.scrollViews["group-review"].swipeUp()
        photo.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Similar scene manual choice at largest text size"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(photo.waitForReviewValue("Selected"), app.debugDescription)
        app.buttons["review-evidence"].tap()
        XCTAssertTrue(app.navigationBars["Review Evidence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No established quality advantage. Choose according to your preference."].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        app.buttons["review-confirm"].tap()
        if app.buttons["Close Review"].waitForExistence(timeout: 2) { app.buttons["Close Review"].tap() }
        else if !collection.exists {
            app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap()
        }
        XCTAssertTrue(collection.waitForExistence(timeout: 10), app.debugDescription)
        collection.buttons["Duplicates"].tap()
        let batch = app.buttons["review-batch-cleanup"]
        XCTAssertTrue(batch.waitForExistence(timeout: 5))
        XCTAssertEqual(batch.label, "Confirm Cleanup (1)")
        batch.tap()
        XCTAssertTrue(app.buttons["cleanup-remove-scene-a.png"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["cleanup-remove-scene-b.png"].exists)
        app.buttons["Cancel"].tap()
    }
}
