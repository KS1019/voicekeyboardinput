public struct VoiceActivityState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case unavailable
        case idle
        case listening
        case processing
    }

    public let phase: Phase
    public let inputLevel: NormalizedInputLevel?

    private init(phase: Phase, inputLevel: Double? = nil) {
        self.phase = phase
        self.inputLevel = phase == .listening ? inputLevel.normalizedInputLevel : nil
    }

    private init(phase: Phase, normalizedInputLevel: NormalizedInputLevel?) {
        self.phase = phase
        self.inputLevel = phase == .listening ? normalizedInputLevel : nil
    }

    public static let unavailable = VoiceActivityState(phase: .unavailable)
    public static let idle = VoiceActivityState(phase: .idle)
    public static let listening = VoiceActivityState(phase: .listening)
    public static let processing = VoiceActivityState(phase: .processing)

    public static func listening(level: Double) -> VoiceActivityState {
        VoiceActivityState(phase: .listening, inputLevel: level)
    }

    public static func listening(level: NormalizedInputLevel?) -> VoiceActivityState {
        VoiceActivityState(phase: .listening, normalizedInputLevel: level)
    }
}
