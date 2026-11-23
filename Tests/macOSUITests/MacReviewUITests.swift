import XCTest

@MainActor
final class MacReviewUITests: XCTestCase {
    func testThreeLanguagesSettingsAndScanNeverStartCleanup() {
        continueAfterFailure = false
        for (language, locale, complete, protection) in [("en", "en_US", "Scan Complete", "Saved Protection"), ("zh-Hans", "zh_CN", "扫描完成", "已保存的保护"), ("ja", "ja_JP", "スキャン完了", "保存済みの保護")] {
            let app = XCUIApplication()
            app.launchArguments = ["-AlbumWinnow.photosEnabled", "NO", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            let scan = app.buttons["start-scan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 20), app.debugDescription)
            scan.click()
            XCTAssertTrue(app.staticTexts[complete].waitForExistence(timeout: 90), app.debugDescription)
            XCTAssertFalse(app.buttons["confirm-cleanup"].exists)
            app.buttons["open-settings"].click()
            let title = language == "en" ? "Settings" : language == "zh-Hans" ? "设置" : "設定"
            let settings = app.windows[title]
            let label = settings.staticTexts[protection]
            for _ in 0..<15 {
                if label.isHittable { break }
                settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            }
            XCTAssertTrue(label.isHittable, app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "macOS \(language) protection settings"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
