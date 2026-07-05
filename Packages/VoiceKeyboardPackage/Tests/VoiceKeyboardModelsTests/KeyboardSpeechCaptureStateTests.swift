import VoiceKeyboardModels
import XCTest

final class KeyboardSpeechCaptureStateTests: XCTestCase {
    private let stateMachine = KeyboardSpeechCaptureStateMachine()

    func testMissingMicrophoneCapabilityTakesPrecedenceWhenBothCapabilitiesAreUnavailable() {
        let state = stateMachine.state(capabilities: RuntimeCapabilities(
            microphoneCaptureAvailable: false,
            speechRecognitionAvailable: false,
            textCleanupAvailable: true
        ))

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testMissingSpeechRecognitionCapabilityNeedsProbeWhenMicrophoneIsAvailable() {
        let state = stateMachine.state(capabilities: RuntimeCapabilities(
            microphoneCaptureAvailable: true,
            speechRecognitionAvailable: false,
            textCleanupAvailable: true
        ))

        XCTAssertEqual(state, .probeNeeded)
    }

    func testMissingMicrophoneCapabilityBlocksAfterSpeechRecognition() {
        let state = stateMachine.state(capabilities: RuntimeCapabilities(
            microphoneCaptureAvailable: false,
            speechRecognitionAvailable: true,
            textCleanupAvailable: true
        ))

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testAvailableCapabilitiesNeedProbeWhenNoProbeDataExists() {
        let state = stateMachine.state(capabilities: availableCapabilities)

        XCTAssertEqual(state, .probeNeeded)
    }

    func testProbingDoesNotOverrideUnavailableMicrophoneCapability() {
        let state = stateMachine.state(
            capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: false,
                speechRecognitionAvailable: false,
                textCleanupAvailable: true
            ),
            isProbing: true
        )

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testProbingCanRunBeforeSpeechRecognitionIsAvailable() {
        let state = stateMachine.state(
            capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: true,
                speechRecognitionAvailable: false,
                textCleanupAvailable: true
            ),
            isProbing: true
        )

        XCTAssertEqual(state, .probing)
    }

    func testProbingStateRequiresAvailableCapabilities() {
        let state = stateMachine.state(
            capabilities: availableCapabilities,
            isProbing: true
        )

        XCTAssertEqual(state, .probing)
    }

    func testSuccessfulProbeMakesCaptureReady() {
        let state = stateMachine.state(
            capabilities: availableCapabilities,
            probeResult: AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: -12
            )!
        )

        XCTAssertEqual(state, .ready)
    }

    func testSuccessfulProbeRequiresSpeechRecognitionForReadyState() {
        let state = stateMachine.state(
            capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: true,
                speechRecognitionAvailable: false,
                textCleanupAvailable: true
            ),
            probeResult: AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: -12
            )!
        )

        XCTAssertEqual(state, .unavailable(.speechRecognitionUnavailable))
    }

    func testFailedProbeResultBlocksCapture() {
        let state = stateMachine.state(
            capabilities: availableCapabilities,
            probeResult: AudioCaptureProbeResult(
                microphoneCaptureAvailable: false,
                duration: standardDuration,
                peakPower: nil
            )!
        )

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testProbeErrorBlocksCaptureWhenCapabilitiesAreAvailable() {
        XCTAssertEqual(
            stateMachine.state(
                capabilities: availableCapabilities,
                probeError: .unavailableInCurrentProcess
            ),
            .probeFailed(.unavailableInCurrentProcess)
        )
    }

    func testProbeErrorWinsWhenResultIsAlsoPresent() {
        let state = stateMachine.state(
            capabilities: availableCapabilities,
            probeResult: AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: -12
            )!,
            probeError: .unavailableInCurrentProcess
        )

        XCTAssertEqual(state, .probeFailed(.unavailableInCurrentProcess))
    }

    func testProbeErrorDoesNotOverrideUnavailableMicrophoneCapability() {
        let state = stateMachine.state(
            capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: false,
                speechRecognitionAvailable: false,
                textCleanupAvailable: true
            ),
            probeError: .unavailableInCurrentProcess
        )

        XCTAssertEqual(
            state,
            .unavailable(.microphoneCaptureUnavailable)
        )
    }
}

private let availableCapabilities = RuntimeCapabilities(
    microphoneCaptureAvailable: true,
    speechRecognitionAvailable: true,
    textCleanupAvailable: true
)

private let standardDuration = AudioCaptureProbeDuration(seconds: 1)!
