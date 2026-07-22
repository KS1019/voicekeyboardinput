import VoiceKeyboardInterfaces
import VoiceKeyboardModels

public actor KeyboardSpeechCaptureReadinessService {
    private let capabilityChecker: any CapabilityChecking
    private let audioProbe: (any AudioCaptureProbing)?
    private let stateMachine: KeyboardSpeechCaptureStateMachine
    private var isProbing = false
    private var lastProbeResult: AudioCaptureProbeResult?
    private var lastProbeError: AudioCaptureProbeError?

    public init(
        capabilityChecker: any CapabilityChecking,
        audioProbe: (any AudioCaptureProbing)? = nil,
        stateMachine: KeyboardSpeechCaptureStateMachine = KeyboardSpeechCaptureStateMachine()
    ) {
        self.capabilityChecker = capabilityChecker
        self.audioProbe = audioProbe
        self.stateMachine = stateMachine
    }

    public func currentState() -> KeyboardSpeechCaptureState {
        stateMachine.state(
            capabilities: capabilityChecker.currentCapabilities(),
            probeResult: lastProbeResult,
            probeError: lastProbeError,
            isProbing: isProbing
        )
    }

    public func resetProbe() {
        lastProbeResult = nil
        lastProbeError = nil
    }

    /// Permission is not proof that this process can actually configure an
    /// input route. Before starting recognition, validate the capture path
    /// with the same short probe used by the readiness UI.
    public func directRecognitionIsReady(
        duration: AudioCaptureProbeDuration
    ) async -> Bool {
        let state = currentState()
        switch state {
        case .ready:
            return true
        case .probeNeeded, .probeFailed:
            return await probeState(duration: duration) == .ready
        case .containingAppLaunchRequired,
             .unavailable,
             .probing,
             .listening,
             .transcribing,
             .inserted,
             .unsupportedCommand,
             .recognitionFailed:
            return false
        }
    }

    public func probeState(duration: AudioCaptureProbeDuration) async -> KeyboardSpeechCaptureState {
        let capabilities = capabilityChecker.currentCapabilities()
        let initialState = stateMachine.state(
            capabilities: capabilities,
            probeResult: lastProbeResult,
            probeError: lastProbeError,
            isProbing: isProbing
        )
        guard initialState == .probeNeeded || isRetryableProbeFailure(initialState) else { return initialState }
        guard let audioProbe else {
            lastProbeResult = nil
            lastProbeError = .probeUnavailable
            return .probeFailed(.probeUnavailable)
        }

        isProbing = true
        defer { isProbing = false }

        do {
            let result = try await audioProbe.probe(duration: duration)
            let currentCapabilities = capabilityChecker.currentCapabilities()
            let finalState = stateMachine.state(
                capabilities: currentCapabilities,
                probeResult: result
            )
            if result.microphoneCaptureAvailable, currentCapabilities.microphoneCaptureAvailable {
                lastProbeResult = result
                lastProbeError = nil
            } else if !result.microphoneCaptureAvailable {
                lastProbeResult = result
                lastProbeError = nil
            } else {
                resetProbe()
            }
            return finalState
        } catch {
            guard error != .cancelled else {
                resetProbe()
                return stateMachine.state(capabilities: capabilityChecker.currentCapabilities())
            }
            lastProbeResult = nil
            lastProbeError = error
            return stateMachine.state(
                capabilities: capabilityChecker.currentCapabilities(),
                probeError: error
            )
        }
    }

    private func isRetryableProbeFailure(_ state: KeyboardSpeechCaptureState) -> Bool {
        if case .probeFailed = state {
            return true
        }
        return false
    }
}
