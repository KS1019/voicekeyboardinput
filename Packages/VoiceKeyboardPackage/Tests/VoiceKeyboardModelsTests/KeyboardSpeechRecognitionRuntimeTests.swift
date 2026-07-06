import VoiceKeyboardModels
import XCTest

final class KeyboardSpeechRecognitionRuntimeTests: XCTestCase {
    func testIOS26UsesLegacyAudioBufferRecognition() {
        XCTAssertEqual(
            KeyboardSpeechRecognitionRuntime.strategy(forOperatingSystemMajorVersion: 26),
            .legacyAudioBuffer
        )
    }

    func testIOS27UsesSpeechAnalyzerRecognition() {
        XCTAssertEqual(
            KeyboardSpeechRecognitionRuntime.strategy(forOperatingSystemMajorVersion: 27),
            .speechAnalyzer
        )
    }
}
