import XCTest

extension XCUIElement {
    // Single selection deliberately waits for the double-tap recognition window.
    func waitForReviewValue(_ expected: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}

@MainActor
extension XCUIApplication {
    func launchInEnglish() {
        launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launch()
    }

    func reviewContextAction(_ title: String, on photo: XCUIElement) -> XCUIElement {
        photo.press(forDuration: 1)
        let action = descendants(matching: .any).matching(identifier: title).firstMatch
        // Simulator input can miss the first long press while the card settles.
        // Retry only that gesture; the action and resulting protection still must pass.
        if !action.waitForExistence(timeout: 2) { photo.press(forDuration: 2) }
        XCTAssertTrue(action.waitForExistence(timeout: 5), debugDescription)
        return action
    }
}
