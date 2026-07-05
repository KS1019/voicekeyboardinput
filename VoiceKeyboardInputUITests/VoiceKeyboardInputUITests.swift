import XCTest

final class VoiceKeyboardInputUITests: XCTestCase {
    func testContainingAppQASurfaceIsAvailable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Keyboard Extension QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["keyboard.qa.textField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["keyboard.qa.instructions"].waitForExistence(timeout: 5))
    }
}
