import VoiceKeyboardModels
import XCTest

final class SpeechRecognitionUpdateTests: XCTestCase {
    func testSpeechRecognitionErrorsCompareByValue() {
        XCTAssertEqual(
            SpeechRecognitionError.audioSessionActivationFailed("setActive failed"),
            .audioSessionActivationFailed("setActive failed")
        )
        XCTAssertNotEqual(
            SpeechRecognitionError.audioSessionActivationFailed("setActive failed"),
            .audioEngineStartFailed("engine failed")
        )
        XCTAssertEqual(SpeechRecognitionError.microphonePermissionDenied, .microphonePermissionDenied)
        XCTAssertEqual(SpeechRecognitionError.cancelled, .cancelled)
    }

    func testInputLevelIsOptional() {
        let update = SpeechRecognitionUpdate(transcript: "hello", isFinal: false)

        XCTAssertEqual(update.transcript, "hello")
        XCTAssertFalse(update.isFinal)
        XCTAssertNil(update.inputLevel)
    }

    func testStoresFieldsAndComparesByValue() {
        let update = SpeechRecognitionUpdate(transcript: "hello world", isFinal: true, inputLevel: 0.42)

        XCTAssertEqual(update.transcript, "hello world")
        XCTAssertTrue(update.isFinal)
        XCTAssertEqual(update.inputLevel, NormalizedInputLevel(0.42))
        XCTAssertEqual(update, SpeechRecognitionUpdate(transcript: "hello world", isFinal: true, inputLevel: 0.42))
        XCTAssertNotEqual(update, SpeechRecognitionUpdate(transcript: "hello world", isFinal: false, inputLevel: 0.42))
        XCTAssertNotEqual(update, SpeechRecognitionUpdate(transcript: "hello world", isFinal: true, inputLevel: 0.43))
    }

    func testInputLevelIsClamped() {
        XCTAssertEqual(
            SpeechRecognitionUpdate(transcript: "", isFinal: false, inputLevel: -0.2).inputLevel,
            NormalizedInputLevel(0)
        )
        XCTAssertEqual(
            SpeechRecognitionUpdate(transcript: "", isFinal: false, inputLevel: 1.2).inputLevel,
            NormalizedInputLevel(1)
        )
    }

    func testNonFiniteInputLevelIsDropped() {
        XCTAssertNil(SpeechRecognitionUpdate(transcript: "", isFinal: false, inputLevel: .nan).inputLevel)
        XCTAssertNil(SpeechRecognitionUpdate(transcript: "", isFinal: false, inputLevel: .infinity).inputLevel)
    }
}
