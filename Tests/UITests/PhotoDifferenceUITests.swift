import XCTest

@MainActor
final class PhotoDifferenceUITests: XCTestCase {
    func testExplicitPairAndOverlayControlsPreserveTheGroupKeepChoice() {
        exercise(size: "UICTContentSizeCategoryL", checkBackground: false)
    }

    func testLargestTextAndBackgroundingRequireExplicitRecomparison() {
        exercise(size: "UICTContentSizeCategoryAccessibilityXXXL", checkBackground: true)
    }

    private func exercise(size: String, checkBackground: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AlbumWinnow.reviewAnimation", "none",
                               "-AlbumWinnow.showReviewFilenames", "NO", "-UIPreferredContentSizeCategoryName", size]
        app.launch()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "duplicate-group-review-detail-")).firstMatch
        for _ in 0..<6 {
            if group.isHittable { break }
            app.scrollViews["duplicate-gallery"].swipeUp()
        }
        XCTAssertTrue(group.isHittable, app.debugDescription)
        group.tap()
        let photo = app.buttons["review-photo-review-detail-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        app.buttons["review-evidence"].tap()
        let differences = app.buttons["show-differences"]
        for _ in 0..<8 {
            if differences.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(differences.isHittable, app.debugDescription)
        differences.tap()
        XCTAssertTrue(app.navigationBars["Compare Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["difference-reference-label"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["difference-comparison-label"].exists, app.debugDescription)
        let show = app.buttons["difference-show"]
        XCTAssertFalse(show.isEnabled)
        XCTAssertFalse(app.segmentedControls["difference-display"].exists)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Difference preview starts without a pair or overlay"
        initial.lifetime = .keepAlways
        add(initial)
        app.buttons["difference-reference"].tap()
        app.buttons["Photo 1"].firstMatch.tap()
        XCTAssertFalse(show.isEnabled)
        app.buttons["difference-comparison"].tap()
        app.buttons["Photo 2"].firstMatch.tap()
        XCTAssertEqual(app.buttons["difference-reference"].value as? String, "Photo 1")
        XCTAssertEqual(app.buttons["difference-comparison"].value as? String, "Photo 2")
        XCTAssertTrue(show.isEnabled)
        show.tap()
        let count = app.staticTexts["difference-region-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(count.label.contains("Local Change Region"), count.label)
        if checkBackground {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(count.waitForNonExistence(timeout: 5))
            XCTAssertTrue(show.isEnabled, app.debugDescription)
            show.tap()
            XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription)
        }
        let display = app.segmentedControls["difference-display"]
        display.buttons["Original"].tap()
        XCTAssertFalse(app.sliders["difference-opacity"].exists)
        display.buttons["Differences"].tap()
        let opacity = app.sliders["difference-opacity"]
        for _ in 0..<5 {
            if opacity.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(opacity.isHittable, app.debugDescription)
        opacity.adjust(toNormalizedSliderPosition: 0.6)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pairwise difference regions and opacity"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars["Compare Photos"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        XCTAssertTrue(app.buttons["review-confirm"].isEnabled)
    }
}
