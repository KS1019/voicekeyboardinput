import Foundation
import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import VoiceKeyboardPresentation

struct KeyboardSpeechCaptureCoordinator {
    // Apple does not guarantee microphone access for custom keyboard
    // extensions, even with full access. Keep the experimental direct path
    // compiled for diagnostics, but make the containing-app handoff the only
    // product path so Bluetooth/HFP capture happens in the supported process.
    private static let directKeyboardCaptureEnabled = false

    private let capabilityChecker: any CapabilityChecking
    private let readinessService: KeyboardSpeechCaptureReadinessService
    private let recognitionSession: KeyboardSpeechRecognitionSession
    private let speechService: any SpeechRecognitionService

    init(
        capabilityChecker: any CapabilityChecking = KeyboardAudioCapabilityChecker(),
        audioProbe: (any AudioCaptureProbing)? = KeyboardAudioInputProbe(),
        speechService: any SpeechRecognitionService = KeyboardSpeechRecognitionService(),
        stateMachine: KeyboardSpeechCaptureStateMachine = KeyboardSpeechCaptureStateMachine()
    ) {
        self.capabilityChecker = capabilityChecker
        readinessService = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: capabilityChecker,
            audioProbe: audioProbe,
            stateMachine: stateMachine
        )
        self.speechService = speechService
        recognitionSession = KeyboardSpeechRecognitionSession(
            speechService: speechService,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: Locale.current.identifier))
        )
    }

    func currentSnapshot() async -> SpeechCapturePresentationSnapshot {
        if shouldOpenContainingAppForDictation() {
            return .keyboardSpeechCapture(.containingAppLaunchRequired)
        }

        let state = await readinessService.currentState()
        return .keyboardSpeechCapture(state)
    }

    func shouldOpenContainingAppForDictation() -> Bool {
        !Self.directKeyboardCaptureEnabled
            || capabilityChecker.currentCapabilities().microphoneCaptureAvailable == false
    }

    func directRecognitionIsReady() async -> Bool {
        guard Self.directKeyboardCaptureEnabled,
              !shouldOpenContainingAppForDictation(),
              let duration = AudioCaptureProbeDuration(seconds: 0.8) else {
            return false
        }
        guard await readinessService.directRecognitionIsReady(duration: duration) else {
            return false
        }
        return await KeyboardAudioSessionOperationCoordinator.shared.waitUntilAvailable(
            timeout: 10
        )
    }

    func probeSnapshot() async -> SpeechCapturePresentationSnapshot {
        if shouldOpenContainingAppForDictation() {
            return .keyboardSpeechCapture(.containingAppLaunchRequired)
        }

        guard let duration = AudioCaptureProbeDuration(seconds: 0.8) else {
            return .keyboardSpeechCapture(.probeFailed(.probeUnavailable))
        }
        let state = await readinessService.probeState(duration: duration)
        return .keyboardSpeechCapture(state)
    }

    func recognitionEvents(
        locale: VoiceKeyboardLocale,
        documentContextBeforeInput: String?
    ) -> AsyncStream<KeyboardSpeechRecognitionEvent> {
        recognitionSession.events(
            locale: locale,
            documentContextBeforeInput: documentContextBeforeInput
        )
    }

    func stopRecognition() async {
        await speechService.stop()
    }
}
