@testable import VoiceKeyboardMenuBar
import VoiceKeyboardModels
import XCTest

final class MenuBarDebugTextTests: XCTestCase {
    func testElementDescriptionEscapesControlCharactersAndQuotes() {
        XCTAssertEqual(
            MenuBarDebugText.elementDescription(.text("line\n\t\"quoted\"")),
            #"text("line\n\t\"quoted\"")"#
        )
    }

    func testCommandDescriptionEscapesInsertedTextValue() {
        XCTAssertEqual(
            MenuBarDebugText.commandDescription(.insertText("\t")),
            #"insertText("\t")"#
        )
    }

    func testOperationDescriptionEscapesInsertedTextValue() {
        XCTAssertEqual(
            MenuBarDebugText.operationDescription(.insertText("\n")),
            #"insertText("\n")"#
        )
    }

    func testLongInsertedTextIsBoundedForMenuBarRendering() {
        let value = String(repeating: "あ", count: 32_768)

        let description = MenuBarDebugText.operationDescription(.insertText(value))

        XCTAssertLessThan(description.count, 2_200)
        XCTAssertTrue(description.contains("more characters"))
        XCTAssertTrue(description.hasPrefix("insertText(\"あ"))
    }

    func testMenuBarInputIsBoundedBeforePreview() {
        let value = String(repeating: "😀", count: 100_000)

        let bounded = MenuBarInputLimits.bounded(value)

        XCTAssertTrue(VoiceKeyboardTextLimits.isValid(bounded))
        XCTAssertEqual(bounded.count, VoiceKeyboardTextLimits.maximumCharacterCount)
    }

    func testMenuBarInputBoundsAnOversizedSingleGraphemeWithoutScanningTheWholeValue() {
        let value = "a" + String(
            repeating: "\u{301}",
            count: VoiceKeyboardTextLimits.maximumUnicodeScalarCount + 1_024
        )

        let bounded = MenuBarInputLimits.bounded(value)

        XCTAssertFalse(bounded.isEmpty)
        XCTAssertTrue(VoiceKeyboardTextLimits.isValid(bounded))
        XCTAssertLessThan(bounded.unicodeScalars.count, value.unicodeScalars.count)
    }
}
