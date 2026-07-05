import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class SpeechCapturePresentationSnapshotTests: XCTestCase {
    private let partialMicrophoneBars = ActiveMicrophoneBarCount(2)!

    func testStoresPresentationFields() {
        let snapshot = SpeechCapturePresentationSnapshot(
            transcriptText: "Transcript",
            statusText: "Status",
            microphoneTitle: "Mic",
            microphoneTone: .positive,
            activeMicrophoneBars: partialMicrophoneBars,
            voiceActivityState: .listening(level: 0.4)
        )

        XCTAssertEqual(snapshot.transcriptText, "Transcript")
        XCTAssertEqual(snapshot.statusText, "Status")
        XCTAssertEqual(snapshot.microphoneTitle, "Mic")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.activeMicrophoneBars, partialMicrophoneBars)
        XCTAssertEqual(snapshot.voiceActivityState, .listening(level: 0.4))
    }

    func testActiveMicrophoneBarCountRequiresVisibleRange() {
        XCTAssertEqual(ActiveMicrophoneBarCount.inactive.value, 0)
        XCTAssertEqual(ActiveMicrophoneBarCount.checking.value, 1)
        XCTAssertEqual(ActiveMicrophoneBarCount.ready.value, 3)
        XCTAssertEqual(ActiveMicrophoneBarCount(0)?.value, 0)
        XCTAssertEqual(ActiveMicrophoneBarCount(3)?.value, 3)
        XCTAssertNil(ActiveMicrophoneBarCount(-1))
        XCTAssertNil(ActiveMicrophoneBarCount(4))
    }

    func testKeyboardValidationPendingSnapshotDescribesDisabledCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardValidationPending

        XCTAssertEqual(
            snapshot.transcriptText,
            "Speech capture is disabled here. Test commands in the containing app."
        )
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Mic unavailable")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .inactive)
        XCTAssertEqual(snapshot.voiceActivityState, .unavailable)
    }
}
