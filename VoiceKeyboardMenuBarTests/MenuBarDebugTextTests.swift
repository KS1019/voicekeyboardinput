@testable import VoiceKeyboardMenuBar
import VoiceKeyboardCommandPipeline
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
}
