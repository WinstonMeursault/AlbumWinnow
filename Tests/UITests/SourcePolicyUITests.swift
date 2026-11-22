import XCTest

@MainActor
final class SourcePolicyUITests: XCTestCase {
    func testSettingsSourceReadOnlyBlocksConfirmedRemoval() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AlbumWinnow.reviewAnimation", "none",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 15))
        app.buttons["start-scan"].tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let photo = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        photo.tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        app.buttons["review-confirm"].tap()
        XCTAssertTrue(photo.waitForNonExistence(timeout: 8))
        if app.buttons["Close Review"].exists { app.buttons["Close Review"].tap() }
        else { app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap() }
        XCTAssertEqual(app.buttons["review-batch-cleanup"].label, "Confirm Cleanup (1)")
        app.buttons["Settings"].tap()
        let readonly = app.switches["Read-only · AppTestFixtures"]
        for _ in 0..<8 {
            if readonly.isHittable && readonly.frame.midY < app.frame.maxY - 140 { break }
            app.swipeUp()
        }
        XCTAssertTrue(readonly.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Read-only control before activation"
        before.lifetime = .keepAlways
        add(before)
        readonly.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Read-only control after activation"
        after.lifetime = .keepAlways
        add(after)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: readonly)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Source policy settings"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["review-batch-cleanup"].waitForNonExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(photo.waitForReviewValue("Read-only, must be kept"))
        XCTAssertFalse(app.buttons["review-delete-all"].isEnabled)
    }
}
