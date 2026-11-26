import XCTest

@MainActor
final class PhotoFirstReviewTests: XCTestCase {
    func testReviewDecisionsAndHandPreference() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-reviewAnimation", "slide",
                               "-showReviewFilenames", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()

        XCTAssertFalse(app.buttons["Cleanup History"].exists)
        let confirm = app.buttons["review-confirm"]
        let skip = app.buttons["review-skip"]
        let deleteAll = app.buttons["review-delete-all"]
        let cleanup = app.buttons["review-batch-cleanup"]
        let scan = app.buttons["start-scan"]
        let landscape = app.buttons["duplicate-group-gallery-landscape-a.png"]
        let portrait = app.buttons["duplicate-group-gallery-portrait-a.png"]
        let landscapeA = app.buttons["review-photo-gallery-landscape-a.png"]
        let landscapeB = app.buttons["review-photo-gallery-landscape-b.png"]
        let portraitA = app.buttons["review-photo-gallery-portrait-a.png"]
        let portraitB = app.buttons["review-photo-gallery-portrait-b.png"]

        func configureHand(_ label: String, change: Bool = true) {
            app.buttons["Settings"].tap()
            let picker = app.buttons["review-hand"]
            for _ in 0..<12 {
                if picker.isHittable && picker.frame.midY < app.frame.maxY - 200 { break }
                app.swipeUp()
            }
            XCTAssertTrue(picker.isHittable, app.debugDescription)
            if change && !picker.label.contains(label) {
                picker.tap()
                app.buttons[label].firstMatch.tap()
            }
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", label), object: picker)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription)
            app.navigationBars["Settings"].buttons["Done"].tap()
        }

        func closeReview() {
            let close = app.buttons["Close Review"]
            if close.exists { close.tap() }
            else { app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap() }
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 8))
        }

        func position(_ left: XCUIElement, _ right: XCUIElement) {
            XCTAssertLessThan(left.frame.midX, skip.frame.midX)
            XCTAssertLessThan(skip.frame.midX, right.frame.midX)
            XCTAssertEqual(left.frame.midY, skip.frame.midY, accuracy: 3)
            XCTAssertEqual(right.frame.midY, skip.frame.midY, accuracy: 3)
        }

        configureHand("Left Hand")
        app.terminate()
        app.launchArguments.append("--preserve-review-state")
        app.launchInEnglish()
        configureHand("Left Hand", change: false)
        XCTAssertTrue(scan.waitForExistence(timeout: 15) && scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(landscape.waitForExistence(timeout: 15), app.debugDescription)
        landscape.tap()
        if !landscapeA.waitForExistence(timeout: 3) { landscape.tap() }
        XCTAssertTrue(landscapeA.waitForExistence(timeout: 8) && landscapeB.exists, app.debugDescription)
        XCTAssertTrue(landscapeA.label.contains("recommended to keep"))
        XCTAssertFalse(landscapeB.label.contains("recommended to keep"))
        XCTAssertTrue(landscapeA.waitForReviewValue(""))
        let metadataReady = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "PNG", "×")
        expectation(for: metadataReady, evaluatedWith: landscapeA)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(landscapeA.label.contains("unknown"), landscapeA.label)
        let metadataShot = XCTAttachment(screenshot: app.screenshot())
        metadataShot.name = "Image metadata below landscape previews"
        metadataShot.lifetime = .keepAlways
        add(metadataShot)
        position(confirm, deleteAll)
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(app.switches.firstMatch.exists)
        XCTAssertLessThan(landscapeA.frame.midY, landscapeB.frame.midY)
        XCTAssertLessThanOrEqual(landscapeB.frame.maxY, confirm.frame.minY)
        let aFrame = landscapeA.frame
        let bFrame = landscapeB.frame
        landscapeA.tap()
        XCTAssertTrue(landscapeA.waitForReviewValue("Selected"))
        XCTAssertTrue(landscapeA.label.contains("recommended to keep"))
        let recommended = XCTAttachment(screenshot: app.screenshot())
        recommended.name = "Recommended and selected"
        recommended.lifetime = .keepAlways
        add(recommended)
        XCTAssertTrue(confirm.isEnabled)
        landscapeA.tap()
        XCTAssertTrue(landscapeA.waitForReviewValue(""))
        XCTAssertFalse(confirm.isEnabled)
        landscapeA.tap()
        XCTAssertTrue(landscapeA.waitForReviewValue("Selected"))
        landscapeB.tap()
        XCTAssertTrue(landscapeB.waitForReviewValue("Selected"))
        XCTAssertTrue(landscapeA.waitForReviewValue(""))
        XCTAssertEqual(landscapeA.frame, aFrame)
        XCTAssertEqual(landscapeB.frame, bFrame)

        XCTAssertTrue(deleteAll.isEnabled, app.debugDescription)
        deleteAll.tap()
        XCTAssertTrue(landscapeA.waitForReviewValue("Marked for removal"))
        XCTAssertFalse(landscapeA.label.contains("recommended to keep"))
        XCTAssertTrue(landscapeB.waitForReviewValue("Marked for removal"))
        position(confirm, deleteAll)
        let red = XCTAttachment(screenshot: app.screenshot())
        red.name = "Whole group preview"
        red.lifetime = .keepAlways
        add(red)
        deleteAll.tap()
        XCTAssertTrue(landscapeB.waitForReviewValue("Selected"))
        deleteAll.tap()
        landscapeB.tap()
        XCTAssertTrue(landscapeB.waitForReviewValue("Selected"))
        XCTAssertTrue(deleteAll.waitForReviewValue("Off"))

        let review = app.scrollViews["group-review"]
        func swipe(_ left: Bool) {
            let start = review.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.34))
            let end = review.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.10 : 0.92, dy: 0.34))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        swipe(true)
        XCTAssertTrue(portraitA.waitForExistence(timeout: 8), app.debugDescription)
        swipe(false)
        XCTAssertTrue(landscapeA.waitForExistence(timeout: 8))
        XCTAssertFalse(confirm.isEnabled)
        landscapeB.tap()
        XCTAssertTrue(landscapeB.waitForReviewValue("Selected"))
        confirm.tap()
        XCTAssertTrue(portraitA.waitForExistence(timeout: 8))
        swipe(false)
        XCTAssertTrue(landscapeB.waitForExistence(timeout: 8))
        XCTAssertTrue(landscapeB.waitForReviewValue("Selected"))
        landscapeB.tap()
        XCTAssertTrue(landscapeB.waitForReviewValue(""))
        XCTAssertFalse(confirm.isEnabled)
        skip.tap()
        XCTAssertTrue(portraitA.waitForExistence(timeout: 8))
        XCTAssertLessThan(portraitA.frame.midX, portraitB.frame.midX)
        XCTAssertEqual(portraitA.frame.midY, portraitB.frame.midY, accuracy: 3)
        portraitA.tap()
        skip.tap()
        XCTAssertTrue(app.buttons["review-photo-gallery-long-a.png"].waitForExistence(timeout: 8))
        closeReview()
        XCTAssertEqual(cleanup.label, "Confirm Cleanup (1)")
        configureHand("Right Hand")
        XCTAssertTrue(portrait.isHittable, app.debugDescription)
        portrait.tap()
        XCTAssertTrue(portraitA.waitForExistence(timeout: 8))
        position(deleteAll, confirm)
        XCTAssertFalse(confirm.isEnabled)
        deleteAll.tap()
        confirm.tap()
        XCTAssertTrue(app.buttons["review-photo-gallery-long-a.png"].waitForExistence(timeout: 8))
        closeReview()
        XCTAssertEqual(cleanup.label, "Confirm Cleanup (3)")
        cleanup.tap()
        XCTAssertTrue(app.staticTexts["Delete entire group · 2 photos"].waitForExistence(timeout: 8), app.debugDescription)
        let kept = app.buttons["cleanup-keep-gallery-landscape-b.png"]
        let removed = app.buttons["cleanup-remove-gallery-landscape-a.png"]
        XCTAssertTrue(kept.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(removed.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["gallery-landscape-a.png"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertTrue(app.buttons["confirm-cleanup"].isEnabled)
        let ready = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "PNG", "×")
        expectation(for: ready, evaluatedWith: removed)
        waitForExpectations(timeout: 15)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup thumbnails with preserved toolbar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        removed.tap()
        XCTAssertTrue(app.navigationBars["Photo"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Confirm Cleanup"].waitForExistence(timeout: 8))
        let portraitRemoval = app.buttons["cleanup-remove-gallery-portrait-a.png"]
        for _ in 0..<4 {
            if portraitRemoval.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(portraitRemoval.isHittable, app.debugDescription)
        let portraitOther = app.buttons["cleanup-remove-gallery-portrait-b.png"]
        XCTAssertTrue(portraitOther.exists)
        XCTAssertEqual(portraitRemoval.frame.minY, portraitOther.frame.minY, accuracy: 3)
        XCTAssertLessThan(portraitRemoval.frame.maxX, portraitOther.frame.minX)
        XCTAssertFalse(app.buttons["cleanup-keep-gallery-portrait-a.png"].exists)
        app.navigationBars["Confirm Cleanup"].buttons["Cancel"].tap()
        portrait.tap()
        XCTAssertTrue(portraitA.waitForExistence(timeout: 8))
        XCTAssertTrue(portraitA.waitForReviewValue("Marked for removal"))
        deleteAll.tap()
        skip.tap()
        XCTAssertTrue(app.buttons["review-photo-gallery-long-a.png"].waitForExistence(timeout: 8))
        closeReview()
        XCTAssertEqual(cleanup.label, "Confirm Cleanup (3)")
    }
    func testClearScanCachePreservesSourcesAndAllowsScanningAgain() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        app.buttons["Settings"].tap()
        let clear = app.buttons["clear-scan-cache"]
        for _ in 0..<5 {
            if clear.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        let cleared = app.staticTexts["Scan cache cleared. The next scan will read all photos again."]
        for _ in 0..<3 {
            if cleared.waitForExistence(timeout: 2) { break }
            app.swipeUp()
        }
        XCTAssertTrue(cleared.waitForExistence(timeout: 30), app.debugDescription)
        app.navigationBars["Settings"].buttons["Done"].tap()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["duplicate-group-gallery-landscape-a.png"].exists)
    }

    func testCleanupFailuresShowPhotosAndReasonsWithoutHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showReviewFilenames", "NO",
                               "--cleanup-outcome-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        XCTAssertTrue(app.staticTexts["No Photos Moved"].waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Photos Not Moved"].exists)
        XCTAssertTrue(app.staticTexts["Failed"].exists)
        XCTAssertTrue(app.staticTexts["Skipped"].exists)
        XCTAssertTrue(app.staticTexts["This photo is no longer accessible from its source."].exists)
        XCTAssertTrue(app.staticTexts["This item has an associated video, an edit or an alternate original."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["cleanup-issue-preview-protected.png"].exists)
        XCTAssertFalse(app.buttons["Cleanup History"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup failures with photo previews and reasons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPanoramaCleanupUsesStackedRow() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-showReviewFilenames", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15) && scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
        let group = app.buttons["duplicate-group-gallery-wide-a.png"]
        for _ in 0..<4 {
            // A partly visible card can report hittable while its center is behind the bottom controls.
            if group.isHittable, group.frame.midY < scan.frame.minY - 12 { break }
            app.scrollViews["duplicate-gallery"].swipeUp()
        }
        XCTAssertTrue(group.isHittable, app.debugDescription)
        group.tap()
        let keepChoice = app.buttons["review-photo-gallery-wide-a.png"]
        if !keepChoice.waitForExistence(timeout: 3) { group.tap() }
        XCTAssertTrue(keepChoice.waitForExistence(timeout: 8), app.debugDescription)
        keepChoice.tap()
        XCTAssertTrue(keepChoice.waitForReviewValue("Selected"))
        app.buttons["review-confirm"].tap()
        // The panorama is the last fixture group. Confirm returns to the overview.
        let batch = app.buttons["review-batch-cleanup"]
        let readyForCleanup = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: batch)
        XCTAssertEqual(XCTWaiter.wait(for: [readyForCleanup], timeout: 8), .completed)
        batch.tap()
        let keep = app.buttons["cleanup-keep-gallery-wide-a.png"]
        let remove = app.buttons["cleanup-remove-gallery-wide-b.png"]
        let ready = NSPredicate(format: "label CONTAINS %@", "1000 × 240")
        expectation(for: ready, evaluatedWith: keep)
        expectation(for: ready, evaluatedWith: remove)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(keep.frame.minX, remove.frame.minX, accuracy: 3)
        XCTAssertLessThanOrEqual(keep.frame.maxY, remove.frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Panorama cleanup stacked for larger image area"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].tap()
    }

    func testSimilarityLabelsAndManualConfirmation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-showReviewFilenames", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15) && scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90), app.debugDescription)
        let exact = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(exact.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse((exact.value as? String ?? "").localizedCaseInsensitiveContains("similar"))
        XCTAssertFalse((exact.value as? String ?? "").localizedCaseInsensitiveContains("possible"))

        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                       "duplicate-group-review-detail-")).firstMatch
        XCTAssertTrue(similar.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(similar.value as? String, "Similar photos")
        similar.tap()
        let hint = app.staticTexts["Similar photos · Check differences before confirming."].firstMatch
        if !hint.waitForExistence(timeout: 3) { similar.tap() }
        XCTAssertTrue(hint.waitForExistence(timeout: 8), app.debugDescription)
        let photo = app.buttons["review-photo-review-detail-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        photo.tap()
        XCTAssertTrue(photo.waitForReviewValue("Selected"))
        XCTAssertTrue(app.buttons["review-confirm"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Similar photos retain manual review"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["review-confirm"].tap()
        let close = app.buttons["Close Review"]
        if close.exists { close.tap() }
        else {
            app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap()
        }
        let batch = app.buttons["review-batch-cleanup"]
        XCTAssertTrue(batch.waitForExistence(timeout: 8))
        XCTAssertEqual(batch.label, "Confirm Cleanup (1)")
        batch.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["confirm-cleanup"].isEnabled)
        let finalShot = XCTAttachment(screenshot: app.screenshot())
        finalShot.name = "Similarity warning before batch cleanup"
        finalShot.lifetime = .keepAlways
        add(finalShot)
        app.buttons["Cancel"].tap()
    }

    func testReviewAndCleanupAtAccessibilityTextSize() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-showReviewFilenames", "NO",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchInEnglish()
        let scan = app.buttons["start-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15) && scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.staticTexts["Scan Complete"].waitForExistence(timeout: 90))
        let group = app.buttons["duplicate-group-gallery-landscape-a.png"]
        for _ in 0..<6 {
            if group.isHittable, group.frame.midY < scan.frame.minY - 12 { break }
            app.scrollViews["duplicate-gallery"].swipeUp()
        }
        XCTAssertTrue(group.isHittable, app.debugDescription)
        group.tap()
        let first = app.buttons["review-photo-gallery-landscape-a.png"]
        if !first.waitForExistence(timeout: 3) { group.tap() }
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        let second = app.buttons["review-photo-gallery-landscape-b.png"]
        XCTAssertFalse(first.frame.intersects(second.frame))
        first.tap()
        XCTAssertTrue(first.waitForReviewValue("Selected"))
        let confirm = app.buttons["review-confirm"]
        XCTAssertTrue(confirm.isHittable && confirm.isEnabled)
        confirm.tap()
        let close = app.buttons["Close Review"]
        if close.exists { close.tap() }
        else { app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Group ")).firstMatch.buttons.firstMatch.tap() }
        app.buttons["review-batch-cleanup"].tap()
        let keep = app.buttons["cleanup-keep-gallery-landscape-a.png"]
        let remove = app.buttons["cleanup-remove-gallery-landscape-b.png"]
        XCTAssertTrue(keep.waitForExistence(timeout: 8) && remove.exists)
        XCTAssertEqual(keep.frame.minX, remove.frame.minX, accuracy: 3)
        XCTAssertLessThanOrEqual(keep.frame.maxY, remove.frame.minY)
        XCTAssertTrue(app.buttons["confirm-cleanup"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup at largest accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].tap()
    }

}
