import XCTest

/// UI flows with screenshots (kept as test attachments; CI exports them).
/// The app runs in demo mode (--ui-demo): a canned conversation, no Wine.
final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo", screen]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        s.name = "\(device)-\(name)"
        s.lifetime = .keepAlways
        add(s)
    }

    private func appearanceName(_ a: XCUIDevice.Appearance) -> String { a == .dark ? "dark" : "light" }

    func testChatFlows() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let app = launch("chat")
                XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 20) ||
                              app.textFields["composer"].waitForExistence(timeout: 5))
                sleep(2)
                let o = orientation == .portrait ? "portrait" : "landscape"
                shot("chat-\(appearanceName(appearance))-\(o)")

                if orientation == .portrait {
                    app.buttons["settings"].tap()
                    sleep(1)
                    shot("settings-\(appearanceName(appearance))")
                    app.buttons["Done"].firstMatch.tap()
                    sleep(1)
                    if app.buttons["diagnostics"].exists {
                        app.buttons["diagnostics"].tap()
                        sleep(2)
                        shot("diagnostics-\(appearanceName(appearance))")
                        app.buttons["Done"].firstMatch.tap()
                        sleep(1)
                    }
                    if app.buttons["sessions"].exists {
                        app.buttons["sessions"].tap()
                        sleep(1)
                        shot("sessions-\(appearanceName(appearance))")
                    }
                }
                app.terminate()
            }
        }
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
    }

    func testSetupScreen() {
        XCUIDevice.shared.orientation = .portrait
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let app = launch("setup")
            XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 20))
            sleep(1)
            shot("setup-\(appearanceName(appearance))")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    func testComposerTyping() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("chat")
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("Explain the diff in README.md")
        sleep(1)
        shot("composer-keyboard")
        XCTAssertTrue(app.buttons["send"].isEnabled)
    }
}
