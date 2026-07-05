import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class SpeechCapturePresentationSnapshotKeyboardStateTests: XCTestCase {
    func testReadyStateMapsToIdlePositiveCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.ready)

        XCTAssertEqual(snapshot.transcriptText, "Microphone probe passed.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Check again")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .ready)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }

    func testUnavailableReasonMapsToCriticalCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
            .unavailable(.microphoneCaptureUnavailable)
        )

        XCTAssertEqual(snapshot.transcriptText, "Microphone capture is unavailable in this keyboard.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Mic unavailable")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .inactive)
        XCTAssertEqual(snapshot.voiceActivityState, .unavailable)
    }

    func testContainingAppLaunchRequiredMapsToEnabledWarningCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.containingAppLaunchRequired)

        XCTAssertEqual(snapshot.transcriptText, "Open the app for microphone setup.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Open app")
        XCTAssertEqual(snapshot.microphoneTone, .warning)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .checking)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }

    func testProbeFailedMapsToCriticalCaptureWithoutClaimingReason() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
            .probeFailed(.unavailableInCurrentProcess)
        )

        XCTAssertEqual(snapshot.transcriptText, "Microphone check failed here.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Retry check")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .inactive)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }

    func testProbingStateMapsToProcessingWarningCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.probing)

        XCTAssertEqual(snapshot.transcriptText, "Checking microphone...")
        XCTAssertEqual(snapshot.microphoneTitle, "Checking mic")
        XCTAssertEqual(snapshot.microphoneTone, .warning)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .checking)
        XCTAssertEqual(snapshot.voiceActivityState, .processing)
    }

    func testProbeNeededStateMapsToIdleWarningCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.probeNeeded)

        XCTAssertEqual(snapshot.transcriptText, "Microphone check needed.")
        XCTAssertEqual(snapshot.microphoneTitle, "Check mic")
        XCTAssertEqual(snapshot.microphoneTone, .warning)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .checking)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }
}
