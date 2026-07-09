import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class SpeechCapturePresentationSnapshotSharedSessionStatusTests: XCTestCase {
    func testRecordingStatusShowsListeningState() {
        let snapshot = SpeechCapturePresentationSnapshot.sharedDictationSessionStatus(
            .recording(token: "token", startedAt: Date(), timeoutSeconds: 8)
        )

        XCTAssertEqual(snapshot.transcriptText, "Listening...")
        XCTAssertEqual(snapshot.statusText, "Listening from Voice Keyboard Input.")
        XCTAssertEqual(snapshot.microphoneTitle, "Stop")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .ready)
        XCTAssertEqual(snapshot.voiceActivityState, .listening)
    }

    func testTranscriptReadyStatusKeepsKeyboardWaitingForInsert() {
        let snapshot = SpeechCapturePresentationSnapshot.sharedDictationSessionStatus(
            .transcriptReady(token: "token")
        )

        XCTAssertEqual(snapshot.transcriptText, "Transcript ready.")
        XCTAssertEqual(snapshot.statusText, "Inserting transcript...")
        XCTAssertEqual(snapshot.microphoneTitle, "Speak")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
    }

    func testFailedStatusShowsRetryableFailure() {
        let snapshot = SpeechCapturePresentationSnapshot.sharedDictationSessionStatus(
            .failed(token: "token", message: "Microphone permission is denied.")
        )

        XCTAssertEqual(snapshot.transcriptText, "Microphone permission is denied.")
        XCTAssertEqual(snapshot.statusText, "Microphone permission is denied.")
        XCTAssertEqual(snapshot.microphoneTitle, "Retry")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }
}
