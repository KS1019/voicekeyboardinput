import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class SpeechCapturePresentationSnapshotKeyboardStateTests: XCTestCase {
    func testListeningStateMapsToActiveCapture() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.listening)

        XCTAssertEqual(snapshot.transcriptText, "Listening...")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Stop")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.activeMicrophoneBars, .ready)
        XCTAssertEqual(snapshot.voiceActivityState, .listening(level: nil))
    }

    func testTranscribingStateShowsPartialTranscript() {
        let update = SpeechRecognitionUpdate(transcript: "hello wor", isFinal: false, inputLevel: 0.6)
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.transcribing(update))

        XCTAssertEqual(snapshot.transcriptText, "hello wor")
        XCTAssertEqual(snapshot.statusText, "Transcribing...")
        XCTAssertEqual(snapshot.microphoneTitle, "Stop")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.voiceActivityState, .listening(level: update.inputLevel))
    }

    func testInsertedStateShowsInsertedText() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.inserted("hello world"))

        XCTAssertEqual(snapshot.transcriptText, "hello world")
        XCTAssertEqual(snapshot.statusText, "Inserted.")
        XCTAssertEqual(snapshot.microphoneTitle, "Speak")
        XCTAssertEqual(snapshot.microphoneTone, .positive)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }

    func testRecognitionFailedStateShowsSpecificUnavailableReason() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
            .recognitionFailed(.speechRecognizerUnavailable)
        )

        XCTAssertEqual(snapshot.transcriptText, "Speech recognition is unavailable in this keyboard.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Speech unavailable")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.voiceActivityState, .unavailable)
    }

    func testRecognitionFailedStateShowsRetryableFailure() {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
            .recognitionFailed(.audioEngineStartFailed("engine failed"))
        )

        XCTAssertEqual(snapshot.transcriptText, "Voice input failed in this keyboard.")
        XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
        XCTAssertEqual(snapshot.microphoneTitle, "Retry")
        XCTAssertEqual(snapshot.microphoneTone, .critical)
        XCTAssertEqual(snapshot.voiceActivityState, .idle)
    }

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
