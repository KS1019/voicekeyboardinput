import VoiceKeyboardModels
import XCTest

final class KeyboardDictationTapDecisionTests: XCTestCase {
    func testStopDirectWinsOverEverySharedInteractionBarrier() {
        for (decisionInFlight, recovering, cancelling, sharedSessionActive) in [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
            (true, true, true, true)
        ] {
            XCTAssertEqual(
                KeyboardDictationTapDecision.evaluate(
                    isVisible: true,
                    directRecognitionIsActive: true,
                    sharedInteractionIsBlocked: decisionInFlight || recovering || cancelling,
                    sharedSessionIsActive: sharedSessionActive
                ),
                .finishDirect
            )
        }
    }

    func testHiddenKeyboardIgnoresTapEvenWhenDirectRecognitionIsActive() {
        XCTAssertEqual(
            KeyboardDictationTapDecision.evaluate(
                isVisible: false,
                directRecognitionIsActive: true,
                sharedInteractionIsBlocked: false,
                sharedSessionIsActive: false
            ),
            .ignore
        )
    }

    func testSharedBarrierStillBlocksSharedStopOrNewStart() {
        for sharedSessionIsActive in [false, true] {
            XCTAssertEqual(
                KeyboardDictationTapDecision.evaluate(
                    isVisible: true,
                    directRecognitionIsActive: false,
                    sharedInteractionIsBlocked: true,
                    sharedSessionIsActive: sharedSessionIsActive
                ),
                .ignore
            )
        }
    }

    func testAnUnblockedTapStopsSharedSessionOrStartsDictation() {
        for sharedSessionIsActive in [false, true] {
            XCTAssertEqual(
                KeyboardDictationTapDecision.evaluate(
                    isVisible: true,
                    directRecognitionIsActive: false,
                    sharedInteractionIsBlocked: false,
                    sharedSessionIsActive: sharedSessionIsActive
                ),
                sharedSessionIsActive ? .stopShared : .start
            )
        }
    }
}
