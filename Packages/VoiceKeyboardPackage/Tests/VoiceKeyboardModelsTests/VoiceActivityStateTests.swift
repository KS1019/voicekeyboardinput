import VoiceKeyboardModels
import XCTest

final class VoiceActivityStateTests: XCTestCase {
    func testClampsInputLevelToDisplayRangeWhenPresent() {
        XCTAssertEqual(
            VoiceActivityState.listening(level: -0.4).inputLevel,
            NormalizedInputLevel(0)
        )
        XCTAssertEqual(
            VoiceActivityState.listening(level: 1.4).inputLevel,
            NormalizedInputLevel(1)
        )
    }

    func testRejectsNonFiniteInputLevels() {
        XCTAssertNil(VoiceActivityState.listening(level: .nan).inputLevel)
        XCTAssertNil(VoiceActivityState.listening(level: .infinity).inputLevel)
        XCTAssertNil(VoiceActivityState.listening(level: -.infinity).inputLevel)
    }

    func testOnlyListeningConvenienceCanExposeInputLevel() {
        XCTAssertNil(VoiceActivityState.unavailable.inputLevel)
        XCTAssertNil(VoiceActivityState.idle.inputLevel)
        XCTAssertNil(VoiceActivityState.processing.inputLevel)
        XCTAssertEqual(VoiceActivityState.listening(level: 1).inputLevel, NormalizedInputLevel(1))
    }

    func testConvenienceStatesOnlyExposeRealInputLevels() {
        XCTAssertNil(VoiceActivityState.unavailable.inputLevel)
        XCTAssertNil(VoiceActivityState.idle.inputLevel)
        XCTAssertNil(VoiceActivityState.listening.inputLevel)
        XCTAssertNil(VoiceActivityState.processing.inputLevel)
        XCTAssertEqual(VoiceActivityState.listening(level: 0.35).inputLevel, NormalizedInputLevel(0.35))
    }
}
