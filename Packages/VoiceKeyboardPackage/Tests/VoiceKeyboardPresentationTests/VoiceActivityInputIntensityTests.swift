import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class VoiceActivityInputIntensityTests: XCTestCase {
    func testNonListeningStatesHaveNoInputIntensity() {
        XCTAssertEqual(VoiceActivityInputIntensity(state: .unavailable), .none)
        XCTAssertEqual(VoiceActivityInputIntensity(state: .idle), .none)
        XCTAssertEqual(VoiceActivityInputIntensity(state: .processing), .none)
    }

    func testListeningWithoutInputLevelHasNoInputIntensity() {
        XCTAssertEqual(VoiceActivityInputIntensity(state: .listening), .none)
    }

    func testListeningInputLevelMapsToIntensity() {
        XCTAssertEqual(VoiceActivityInputIntensity(state: .listening(level: 0)), .low)
        XCTAssertEqual(VoiceActivityInputIntensity(state: .listening(level: 0.34)), .medium)
        XCTAssertEqual(VoiceActivityInputIntensity(state: .listening(level: 0.67)), .high)
    }

}
