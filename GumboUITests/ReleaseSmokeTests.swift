import XCTest

/// Offline sample journeys only. NAS playback, CloudKit and physical-device acceptance are separate.
nonisolated final class ReleaseSmokeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(tab: String = "settings", query: String? = nil, slowScan: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--sample-library", "--ui-preview", "--preview-tab", tab]
        if let query { app.launchArguments += ["--preview-query", query] }
        if slowScan { app.launchArguments += ["--preview-slow-scan"] }
        app.launch()
        XCTAssertTrue(app.navigationBars[tab.capitalized].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func tapSettingsRow(_ row: XCUIElement, in app: XCUIApplication) {
        // Native Forms create offscreen rows lazily, especially with accessibility text sizes.
        for _ in 0..<8 {
            if row.exists && row.isHittable {
                row.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Settings row could not be reached by scrolling: \(row)")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testSettingsKeepsMaintenanceUnderAdvanced() {
        let app = launch()
        XCTAssertFalse(app.buttons["Diagnostics"].exists)
        XCTAssertFalse(app.buttons["Refresh Song Information"].exists)
        capture(app, name: "Settings overview")
        tapSettingsRow(app.buttons["settings.advanced"], in: app)
        XCTAssertTrue(app.navigationBars["Advanced Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh Song Information"].exists)
        XCTAssertFalse(app.buttons["Refresh Song Information"].isEnabled, "Sample data must not trigger a NAS refresh")
        capture(app, name: "Advanced Settings")
        tapSettingsRow(app.buttons["Diagnostics"], in: app)
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
    }

    @MainActor func testSearchDoesNotLeakIntoOtherTabsWhileScrolling() {
        let app = launch(tab: "search")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        for title in ["Library", "Playlists", "Downloads", "Settings"] {
            let tab = app.tabBars.buttons[title]
            tab.tap()
            app.swipeUp()
            XCTAssertFalse(app.searchFields.firstMatch.exists, "Unexpected search field in \(title)")
            XCTAssertTrue(tab.isHittable, "Tab bar moved out of reach in \(title)")
        }
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testSearchTypingScrollingAndClearing() {
        let app = launch(tab: "search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("ana")
        XCTAssertTrue(app.staticTexts["Ana Kestrel"].firstMatch.waitForExistence(timeout: 5))
        // Drag the results, not the keyboard covering the lower half of the application.
        // The list extends behind the keyboard. Start inside the visible results and drag through it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        capture(app, name: "Search after dragging results")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(app.tabBars.buttons["Search"].isHittable)
        app.collectionViews.firstMatch.swipeDown()
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "zzzxnomatch\n")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
        field.tap()
        field.buttons["Clear text"].tap()
        XCTAssertTrue(app.staticTexts["Recent Searches"].waitForExistence(timeout: 5))
    }


    @MainActor func testAlbumOpensAndSampleTransportResponds() {
        let app = launch(tab: "search", query: "Parallel Lives")
        let album = app.staticTexts["Parallel Lives"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertFalse(app.buttons["Pause"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // The mini-player survives navigation, resumes and advances its simulated queue.
        app.buttons["Play"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let next = app.buttons["Next track"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.buttons["Pause"].exists)
    }

    @MainActor func testSettingsPagesNavigateAndReturn() {
        let app = launch()
        for (identifier, title) in [("general", "Appearance"), ("library", "Music Library"), ("server", "Music Server"), ("about", "About")] {
            tapSettingsRow(app.buttons["settings.\(identifier)"], in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        }
    }

    @MainActor func testReturningWhilePlayingKeepsBrowsingAndPlayerOpensOnTap() {
        let app = launch(tab: "search", query: "Parallel Lives")
        app.staticTexts["Parallel Lives"].firstMatch.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()

        for _ in 0..<2 {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["settings.general"].isHittable, "Returning while playing must leave Settings usable")
            XCTAssertFalse(app.buttons["Previous track"].exists, "The full player must only open on request")
            XCTAssertTrue(app.buttons["Pause"].isHittable, "The mini-player stays available")
        }
        capture(app, name: "Browsing after returning while playing")
        app.staticTexts["Ana Kestrel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Previous track"].waitForExistence(timeout: 5), "Tapping the mini-player should still open it")
        capture(app, name: "Player opened explicitly")
    }
}


extension ReleaseSmokeTests {
    @MainActor func testLibraryPullSettlesAndScrollingWorksDuringSlowScan() {
        let app = launch(tab: "library", slowScan: true)
        let header = app.staticTexts["Recently added"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let restingY = header.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
        let scanning = app.buttons["Library scanning"]
        XCTAssertTrue(scanning.waitForExistence(timeout: 5))
        let settled = NSPredicate { _, _ in abs(header.frame.minY - restingY) < 8 }
        expectation(for: settled, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        capture(app, name: "Pull settled while scan continues")

        // A repeated pull must also settle, with the existing catalogue still available.
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: settled, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.swipeUp()
        XCTAssertLessThan(header.frame.minY, restingY - 40, "The library must scroll while scanning")
        XCTAssertTrue(scanning.exists)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Recently added"].firstMatch.isHittable)
        // Opening scan details and dismissing them must not leave a blocking overlay.
        scanning.tap()
        XCTAssertTrue(app.navigationBars["Library Scan"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(scanning.waitForExistence(timeout: 5))
        app.buttons["See all"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Recently added"].waitForExistence(timeout: 5))
        capture(app, name: "Browsing albums during scan")
    }

    @MainActor func testMaintenanceScreensRequireARealLibraryBeforeChangingFiles() {
        let app = launch()
        tapSettingsRow(app.buttons["settings.advanced"], in: app)
        tapSettingsRow(app.buttons["Find Missing Genres"], in: app)
        XCTAssertTrue(app.navigationBars["Find Missing Genres"].waitForExistence(timeout: 5))
        for _ in 0..<8 where !app.buttons["Find Suggestions"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Find Suggestions"].exists)
        XCTAssertFalse(app.buttons["Find Suggestions"].isEnabled)
        capture(app, name: "Missing genres review")
        app.navigationBars.buttons.firstMatch.tap()
        tapSettingsRow(app.buttons["Problem Files"], in: app)
        XCTAssertTrue(app.navigationBars["Problem Files"].waitForExistence(timeout: 5))
        for _ in 0..<8 where !app.buttons["Check Files"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Check Files"].exists)
        XCTAssertFalse(app.buttons["Check Files"].isEnabled)
        XCTAssertFalse(app.buttons["Delete from NAS"].exists)
        capture(app, name: "Problem files review")
    }

    @MainActor func testMadeForYouPlaylistArtwork() {
        let app = launch(tab: "playlists")
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        capture(app, name: "Made for You artwork")
    }
}
