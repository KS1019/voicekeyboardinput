import VoiceKeyboardModels
import XCTest

final class VoiceKeyboardLocaleTests: XCTestCase {
    func testStoresIdentifierByValue() {
        XCTAssertEqual(
            VoiceKeyboardLocale(identifier: "ja-JP"),
            VoiceKeyboardLocale(identifier: "ja-JP")
        )
        XCTAssertNotEqual(
            VoiceKeyboardLocale(identifier: "ja-JP"),
            VoiceKeyboardLocale(identifier: "en-US")
        )
    }
}
