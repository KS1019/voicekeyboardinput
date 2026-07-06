import XCTest

final class VoiceKeyboardInputUITests: XCTestCase {
    func testContainingAppQASurfaceIsAvailable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Keyboard-first voice input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Turn Allow Full Access on for Voice Keyboard."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["iOS 26 uses the legacy Speech audio-buffer path; iOS 27 can use the SpeechAnalyzer path."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keyboard Extension QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["keyboard.qa.textField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["keyboard.qa.instructions"].waitForExistence(timeout: 5))
    }
}
