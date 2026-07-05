import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import VoiceKeyboardPresentation

struct KeyboardSpeechCaptureCoordinator {
    private let capabilityChecker: any CapabilityChecking
    private let readinessService: KeyboardSpeechCaptureReadinessService

    init(
        capabilityChecker: any CapabilityChecking = KeyboardAudioCapabilityChecker(),
        audioProbe: (any AudioCaptureProbing)? = KeyboardAudioInputProbe(),
        stateMachine: KeyboardSpeechCaptureStateMachine = KeyboardSpeechCaptureStateMachine()
    ) {
        self.capabilityChecker = capabilityChecker
        readinessService = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: capabilityChecker,
            audioProbe: audioProbe,
            stateMachine: stateMachine
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
}
