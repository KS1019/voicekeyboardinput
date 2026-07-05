public enum KeyboardSpeechCaptureUnavailableReason: Equatable, Sendable {
    case microphoneCaptureUnavailable
    case speechRecognitionUnavailable
}

public enum KeyboardSpeechCaptureState: Equatable, Sendable {
    case containingAppLaunchRequired
    case unavailable(KeyboardSpeechCaptureUnavailableReason)
    case probeNeeded
    case probing
    case ready
    case probeFailed(AudioCaptureProbeError)
}

public struct KeyboardSpeechCaptureStateMachine: Equatable, Sendable {
    public init() {}

    public func state(
        capabilities: RuntimeCapabilities,
        probeResult: AudioCaptureProbeResult? = nil,
        probeError: AudioCaptureProbeError? = nil,
        isProbing: Bool = false
    ) -> KeyboardSpeechCaptureState {
        if !capabilities.microphoneCaptureAvailable {
            return .unavailable(.microphoneCaptureUnavailable)
        }
        if isProbing {
            return .probing
        }
        if let probeError {
            return .probeFailed(probeError)
        }
        if let probeResult {
            guard probeResult.microphoneCaptureAvailable else {
                return .unavailable(.microphoneCaptureUnavailable)
            }
            return capabilities.speechRecognitionAvailable ? .ready : .unavailable(.speechRecognitionUnavailable)
        }
        return .probeNeeded
    }
}
