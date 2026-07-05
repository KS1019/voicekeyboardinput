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
