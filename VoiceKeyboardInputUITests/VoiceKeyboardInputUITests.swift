import XCTest

final class VoiceKeyboardInputUITests: XCTestCase {
    func testContainingAppQASurfaceIsAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Turn Allow Full Access on for Voice Keyboard."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setup.voiceInputInstructions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keyboard Extension QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["keyboard.qa.textField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["keyboard.qa.instructions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.openButton"].waitForExistence(timeout: 5))
    }

    func testOnboardingCanBeDeferredAndReopened() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "NO"]
        app.launch()

        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 5))
        app.buttons["onboarding.laterButton"].tap()
        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))

        let reopen = app.buttons["onboarding.openButton"]
        if !reopen.isHittable { app.swipeUp() }
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 5))
    }

    func testOnboardingCompletionPersistsAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 1 of 3")
        XCTAssertFalse(app.buttons["onboarding.finishButton"].exists)
        app.buttons["onboarding.nextButton"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 2 of 3")
        app.buttons["onboarding.backButton"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 1 of 3")
        app.buttons["onboarding.nextButton"].tap()
        app.swipeLeft()
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 3 of 3")
        app.swipeRight()
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 2 of 3")
        app.buttons["onboarding.nextButton"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.progress"].label, "Step 3 of 3")
        let finish = app.buttons["onboarding.finishButton"]
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onboarding.title"].exists)
    }

}
