import XCTest

final class VoiceKeyboardInputUITests: XCTestCase {
    func testContainingAppQASurfaceIsAvailable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Turn Allow Full Access on for Voice Keyboard."].waitForExistence(timeout: 5))
        let appGroupFallbackText = app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@",
            "shared App Group"
        )).firstMatch
        XCTAssertTrue(appGroupFallbackText.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keyboard Extension QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["keyboard.qa.textField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["keyboard.qa.instructions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.openButton"].waitForExistence(timeout: 5))
    }
}
