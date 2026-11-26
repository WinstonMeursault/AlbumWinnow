import XCTest

@MainActor
final class LocalizationUITests: XCTestCase {
    func testEnglishReviewAndDifferences() { exercise(language: "en", locale: "en_US", largest: false) }
    func testSimplifiedChineseAtLargestText() { exercise(language: "zh-Hans", locale: "zh_CN", largest: true) }
    func testJapaneseAtLargestTextInDarkAppearance() { exercise(language: "ja", locale: "ja_JP", largest: true) }

    private func launch(_ app: XCUIApplication, language: String, locale: String, largest: Bool = false, preserve: Bool = false) {
        app.launchArguments = ["-reviewAnimation", "none",
                               "-showReviewFilenames", "NO", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-UIPreferredContentSizeCategoryName", largest ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if language == "ja" { app.launchArguments.append("--dark-appearance") }
        if preserve { app.launchArguments.append("--preserve-review-state") }
        app.launch()
    }

    private func translated(_ language: String, _ en: String, _ zh: String, _ ja: String) -> String {
        language == "zh-Hans" ? zh : language == "ja" ? ja : en
    }

    private func exercise(language: String, locale: String, largest: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app, language: language, locale: locale, largest: largest)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars[translated(language, "Settings", "设置", "設定")].exists)
        let about = app.buttons["about-open-source"]
        for _ in 0..<20 {
            if about.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(about.isHittable, app.debugDescription)
        about.tap()
        XCTAssertTrue(app.navigationBars[translated(language, "About & Open Source", "关于与开源信息", "このアプリとオープンソース")].waitForExistence(timeout: 5))
        let source = app.descendants(matching: .any).matching(identifier: "release-source-code").firstMatch
        for _ in 0..<8 {
            if source.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.exists, app.debugDescription)
        XCTAssertEqual(source.label, translated(language, "Source Code for This Version", "此版本的源代码", "このバージョンのソースコード"))
        app.buttons["about-done"].tap()
        app.buttons["settings-done"].tap()
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts[translated(language, "Scan Complete", "扫描完成", "スキャン完了")].waitForExistence(timeout: 90))
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "duplicate-group-review-detail-")).firstMatch
        for _ in 0..<8 {
            if group.isHittable && group.frame.midY < app.frame.maxY - 160 { break }
            app.scrollViews["duplicate-gallery"].swipeUp()
        }
        XCTAssertTrue(group.isHittable, app.debugDescription)
        group.tap()
        let photo = app.buttons["review-photo-review-detail-a.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.tap()
        let selected = translated(language, "Selected", "已选保留", "残す写真に選択")
        XCTAssertTrue(photo.waitForReviewValue(selected))
        app.buttons["review-evidence"].tap()
        let differences = app.buttons["show-differences"]
        for _ in 0..<20 {
            if differences.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(differences.isHittable, app.debugDescription)
        differences.tap()
        XCTAssertTrue(app.navigationBars[translated(language, "Compare Photos", "比较照片", "写真を比較")].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["difference-reference-label"].exists)
        XCTAssertTrue(app.staticTexts["difference-comparison-label"].exists)
        let show = app.buttons["difference-show"]
        XCTAssertFalse(show.isEnabled)
        app.buttons["difference-reference"].tap()
        app.buttons[translated(language, "Photo 1", "照片 1", "写真1")].firstMatch.tap()
        XCTAssertFalse(show.isEnabled)
        app.buttons["difference-comparison"].tap()
        app.buttons[translated(language, "Photo 2", "照片 2", "写真2")].firstMatch.tap()
        XCTAssertTrue(show.isEnabled)
        show.tap()
        let count = app.staticTexts["difference-region-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<12 {
            if count.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(count.isHittable, app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(language) difference preview; largest text = \(largest)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.navigationBars[translated(language, "Compare Photos", "比较照片", "写真を比較")].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["evidence-done"].waitForExistence(timeout: 5))
        app.buttons["evidence-done"].tap()
        XCTAssertTrue(photo.waitForReviewValue(selected))
        XCTAssertTrue(app.buttons["review-confirm"].isEnabled)
    }

    func testLanguageChangesPreserveConfirmedPlanAndLocksWithoutDeleting() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app, language: "en", locale: "en_US")
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 15))
        app.buttons["start-scan"].tap()
        let cover = app.buttons["duplicate-group-gallery-landscape-a.png"]
        XCTAssertTrue(cover.waitForExistence(timeout: 90))
        cover.tap()
        let a = app.buttons["review-photo-gallery-landscape-a.png"]
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        a.tap()
        XCTAssertTrue(a.waitForReviewValue("Selected"))
        app.reviewContextAction("Lock Photo", on: a).tap()
        XCTAssertTrue(a.waitForReviewValue("Locked, must be kept"))
        app.buttons["review-confirm"].tap()
        XCTAssertTrue(a.waitForNonExistence(timeout: 10))
        closeReview(app)
        XCTAssertTrue(app.buttons["review-batch-cleanup"].waitForExistence(timeout: 10))
        for (language, locale, locked, title) in [("zh-Hans", "zh_CN", "已锁定，必须保留", "确认清理"), ("ja", "ja_JP", "ロック済み、必ず残します", "整理内容の確認")] {
            app.terminate()
            launch(app, language: language, locale: locale, preserve: true)
            let scan = app.buttons["start-scan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["review-batch-cleanup"].exists, "Relaunch requires an explicit scan before restoring candidates")
            scan.tap()
            XCTAssertTrue(app.buttons["review-batch-cleanup"].waitForExistence(timeout: 90), app.debugDescription)
            cover.tap()
            XCTAssertTrue(a.waitForReviewValue(locked))
            XCTAssertFalse(app.buttons["review-delete-all"].isEnabled)
            closeReview(app)
            app.buttons["review-batch-cleanup"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["confirm-cleanup"].isEnabled)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(language) restored manual cleanup plan"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["cleanup-cancel"].tap()
            XCTAssertTrue(app.buttons["review-batch-cleanup"].exists)
        }
    }

    private func closeReview(_ app: XCUIApplication) {
        if app.buttons["close-review"].exists { app.buttons["close-review"].tap() }
        else { app.navigationBars.firstMatch.buttons.firstMatch.tap() }
    }
}
