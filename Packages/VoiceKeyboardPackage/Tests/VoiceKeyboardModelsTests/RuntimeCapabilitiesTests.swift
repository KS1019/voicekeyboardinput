import VoiceKeyboardModels
import XCTest

final class RuntimeCapabilitiesTests: XCTestCase {
    func testUnavailableCapabilitiesAreAllFalse() {
        let capabilities = RuntimeCapabilities(
            microphoneCaptureAvailable: false,
            speechRecognitionAvailable: false,
            textCleanupAvailable: false
        )

        XCTAssertFalse(capabilities.microphoneCaptureAvailable)
        XCTAssertFalse(capabilities.speechRecognitionAvailable)
        XCTAssertFalse(capabilities.textCleanupAvailable)
    }
}
