import VoiceKeyboardModels
import XCTest

final class AudioCaptureProbeDurationTests: XCTestCase {
    func testAcceptsFinitePositiveDurations() {
        XCTAssertEqual(AudioCaptureProbeDuration(seconds: 1.5)?.seconds, 1.5)
    }

    func testRejectsZeroNegativeAndNonFiniteDurations() {
        XCTAssertNil(AudioCaptureProbeDuration(seconds: 0))
        XCTAssertNil(AudioCaptureProbeDuration(seconds: -0.1))
        XCTAssertNil(AudioCaptureProbeDuration(seconds: .nan))
        XCTAssertNil(AudioCaptureProbeDuration(seconds: .infinity))
        XCTAssertNil(AudioCaptureProbeDuration(seconds: -.infinity))
    }
}
