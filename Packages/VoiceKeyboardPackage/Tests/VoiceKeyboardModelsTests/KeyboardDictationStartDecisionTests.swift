import VoiceKeyboardModels
import XCTest

final class KeyboardDictationStartDecisionTests: XCTestCase {
    func testDirectKeyboardRecognitionWinsWhenValidated() {
        XCTAssertEqual(
            KeyboardDictationStartDecision.evaluate(
                directKeyboardRecognitionReady: true,
                hasSessionStore: true,
                appHeartbeatIsFresh: false
            ),
            .startDirectKeyboardRecognition
        )
    }

    func testUsesSharedCommandWhenAppHeartbeatIsFresh() {
        XCTAssertEqual(
            KeyboardDictationStartDecision.evaluate(
                directKeyboardRecognitionReady: false,
                hasSessionStore: true,
                appHeartbeatIsFresh: true
            ),
            .writeSharedStartCommand
        )
    }

    func testOpensContainingAppWhenHeartbeatIsStale() {
        XCTAssertEqual(
            KeyboardDictationStartDecision.evaluate(
                directKeyboardRecognitionReady: false,
                hasSessionStore: true,
                appHeartbeatIsFresh: false
            ),
            .openContainingApp
        )
    }

    func testShowsSharedStorageUnavailableWhenStoreIsMissing() {
        XCTAssertEqual(
            KeyboardDictationStartDecision.evaluate(
                directKeyboardRecognitionReady: false,
                hasSessionStore: false,
                appHeartbeatIsFresh: true
            ),
            .showSharedStorageUnavailable
        )
    }
}
