import VoiceKeyboardModels

public enum VoiceActivityInputIntensity: Equatable, Sendable {
    case none
    case low
    case medium
    case high

    public init(state: VoiceActivityState) {
        guard state.phase == .listening, let inputLevel = state.inputLevel else {
            self = .none
            return
        }

        self = switch inputLevel.value {
        case ..<0.34:
            .low
        case ..<0.67:
            .medium
        default:
            .high
        }
    }
}
