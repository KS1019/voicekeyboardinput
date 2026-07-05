import VoiceKeyboardModels
import XCTest

final class NormalizedInputLevelTests: XCTestCase {
    func testClampsFiniteValuesToDisplayRange() {
        XCTAssertEqual(NormalizedInputLevel(-0.2)?.value, 0)
        XCTAssertEqual(NormalizedInputLevel(0.4)?.value, 0.4)
        XCTAssertEqual(NormalizedInputLevel(1.2)?.value, 1)
    }

    func testRejectsNonFiniteValues() {
        XCTAssertNil(NormalizedInputLevel(.nan))
        XCTAssertNil(NormalizedInputLevel(.infinity))
        XCTAssertNil(NormalizedInputLevel(-.infinity))
    }
}
