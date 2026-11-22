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
}
