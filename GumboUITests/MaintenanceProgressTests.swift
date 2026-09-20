import XCTest

/// Render the real progress component with an offline sample; no NAS write is started.
nonisolated final class MaintenanceProgressTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func exercise(dark: Bool = false, largeText: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["--sample-library", "--ui-preview", "--preview-tab", "settings", "--preview-genre-progress"]
        if dark { app.launchArguments += ["--preview-dark"] }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))

        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 {
                if element.exists && element.isHittable { return }
                app.swipeUp()
            }
            XCTFail("Could not reach \(element)")
        }
        let advanced = app.buttons["settings.advanced"]
        reveal(advanced)
        advanced.tap()
        let missing = app.buttons["settings.missingGenres"]
        reveal(missing)
        missing.tap()
        XCTAssertTrue(app.navigationBars["Find Missing Genres"].waitForExistence(timeout: 5))
        let suggestions = app.buttons["Find Suggestions"]
        reveal(suggestions)
        XCTAssertFalse(suggestions.isEnabled, "The layout fixture must not enable NAS maintenance")
        let stop = app.buttons["operation.stop"]
        reveal(stop)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44, "Stop must retain a usable touch target")
        XCTAssertTrue(app.progressIndicators.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Saving song tags"].exists, "The old duplicate heading should be gone")
        XCTAssertTrue(app.staticTexts["4 of 15 songs"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Maintenance progress \(dark ? "dark" : "light")\(largeText ? " large text" : "")"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if !largeText {
            let card = app.cells.containing(.button, identifier: "operation.stop").firstMatch
            if card.exists {
                let detail = XCTAttachment(screenshot: card.screenshot())
                detail.name = "Progress card \(dark ? "dark" : "light")"
                detail.lifetime = .keepAlways
                add(detail)
            }
        }

        stop.tap()
        XCTAssertTrue(app.staticTexts["Stopping…"].waitForExistence(timeout: 3))
        XCTAssertFalse(stop.isEnabled, "Repeated stop taps should be prevented while cancellation settles")
        XCTAssertTrue(app.staticTexts["4 of 15 songs"].exists, "Stopping should retain progress until the operation returns")
    }

    @MainActor func testCompactProgressLight() { exercise() }
    @MainActor func testCompactProgressDark() { exercise(dark: true) }
    @MainActor func testProgressWithAccessibilityText() { exercise(largeText: true) }
}
