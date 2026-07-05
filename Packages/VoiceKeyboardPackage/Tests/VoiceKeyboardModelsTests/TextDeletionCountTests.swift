import VoiceKeyboardModels
import XCTest

final class TextDeletionCountTests: XCTestCase {
    func testRequiresPositiveCount() {
        XCTAssertEqual(TextDeletionCount(1)?.value, 1)
        XCTAssertNil(TextDeletionCount(0))
        XCTAssertNil(TextDeletionCount(-1))
    }
}
