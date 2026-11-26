import XCTest

final class VoiceKeyboardInputUITests: XCTestCase {
    @MainActor
    func testCompositionLabLiteralAndExplicitLanguageCommand() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES"]
        app.launch()
        let details = app.buttons["Developer Details"]
        for _ in 0..<4 where !details.isHittable { app.swipeUp() }
        details.tap()
        let open = app.buttons["composition.open"]
        if !open.isHittable { app.swipeUp() }
        open.tap()
        let input = app.textFields["composition.transcript"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("new line")
        app.buttons["composition.preview"].tap()
        XCTAssertEqual(app.staticTexts["composition.output"].label, "Nothing inserted")
        app.buttons["composition.commit"].tap()
        XCTAssertEqual(app.staticTexts["composition.output"].label, "new line")
        app.swipeDown()
        app.buttons["Command"].tap()
        input.tap()
        input.typeText("switch to japanese")
        app.buttons["composition.commit"].tap()
        app.swipeUp()
        XCTAssertEqual(app.staticTexts["composition.language"].label, "ja-JP")
        XCTAssertEqual(app.staticTexts["composition.output"].label, "new line")
    }

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

    func testStartVoiceInputRemainsResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES"]
        app.launch()
        let start = app.buttons["voiceInput.startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Start Voice Input")
        start.tap()
        // Starting audio must not prevent scrolling, focusing or typing.
        app.swipeUp()
        let field = app.textFields["keyboard.qa.textField"]
        field.tap()
        field.typeText("responsive during startup")
        XCTAssertTrue((field.value as? String)?.contains("responsive during startup") == true)
        app.swipeDown()
        if start.label.contains("Stop") { start.tap() }
    }

    func testQAFieldRemainsResponsiveAfterFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES"]
        app.launch()
        let field = app.textFields["keyboard.qa.textField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText("QA remains responsive")
        XCTAssertTrue((field.value as? String)?.contains("QA remains responsive") == true)
        app.swipeDown()
        let setup = app.buttons["onboarding.openButton"]
        if !setup.isHittable { app.swipeDown() }
        setup.tap()
        XCTAssertTrue(app.buttons["onboarding.laterButton"].waitForExistence(timeout: 5))
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
