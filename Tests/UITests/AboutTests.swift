import XCTest

@MainActor
final class AboutTests: XCTestCase {
    func testSettingsProvidesVersionAndOfflineLicenseTexts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchInEnglish()
        app.buttons["Settings"].tap()

        let about = app.buttons["about-open-source"]
        for _ in 0..<5 {
            if about.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(about.isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["Privacy Policy"].exists || app.links["Privacy Policy"].exists, app.debugDescription)
        about.tap()
        let screen = app.navigationBars["About & Open Source"]
        XCTAssertTrue(screen.waitForExistence(timeout: 8), app.debugDescription)
        let expectedVersion = Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(expectedVersion)
        XCTAssertTrue(app.staticTexts["Version, \(expectedVersion ?? "missing")"].exists, app.debugDescription)
        let source = app.descendants(matching: .any).matching(identifier: "release-source-code").firstMatch
        XCTAssertTrue(source.exists, app.debugDescription)

        let agpl = app.buttons["AGPL-3.0 License"].firstMatch
        XCTAssertTrue(agpl.isHittable, app.debugDescription)
        agpl.tap()
        let license = app.staticTexts["license-document"]
        XCTAssertTrue(license.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(license.label.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
        let bar = app.navigationBars["AGPL-3.0 License"]
        XCTAssertTrue(bar.exists)
        bar.buttons.firstMatch.tap()

        let notices = app.buttons["Third-Party Notices"].firstMatch
        XCTAssertTrue(notices.isHittable, app.debugDescription)
        notices.tap()
        XCTAssertTrue(license.waitForExistence(timeout: 8), app.debugDescription)
        for text in ["rusqlite 0.37.0", "blake3 1.8.2", "uniffi 0.29.4", "Mozilla Public License Version 2.0", "CC0 1.0 Universal"] {
            XCTAssertTrue(license.label.contains(text), text)
        }
        XCTAssertFalse(license.label.contains("GRDB.swift"))
        XCTAssertFalse(license.label.contains("BLAKE3 Swift"))
    }
}
