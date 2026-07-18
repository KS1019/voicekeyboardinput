import Foundation
import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import VoiceKeyboardPresentation

struct KeyboardSpeechCaptureCoordinator {
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
        capabilityChecker.currentCapabilities().microphoneCaptureAvailable == false
    }

    func probeSnapshot() async -> SpeechCapturePresentationSnapshot {
        if shouldOpenContainingAppForDictation() {
            return .keyboardSpeechCapture(.containingAppLaunchRequired)
        }

        guard let duration = AudioCaptureProbeDuration(seconds: 0.8) else {
            preconditionFailure("Invalid audio input probe duration")
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
