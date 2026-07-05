import VoiceKeyboardModels

public struct VoiceActivityPresentationSnapshot: Equatable, Sendable {
    public let title: String
    public let accessibilityValue: String
    public let meterSnapshot: VoiceActivityMeterSnapshot
    public let tone: PresentationTone

    public init(
        title: String,
        accessibilityValue: String,
        meterSnapshot: VoiceActivityMeterSnapshot,
        tone: PresentationTone
    ) {
        self.title = title
        self.accessibilityValue = accessibilityValue
        self.meterSnapshot = meterSnapshot
        self.tone = tone
    }

    public init(state: VoiceActivityState, meterBarCount: VoiceActivityMeterBarCount) {
        let title: String
        let tone: PresentationTone

        switch state.phase {
        case .unavailable:
            title = "Off"
            tone = .critical
        case .idle:
            title = "Idle"
            tone = .muted
        case .listening:
            title = "Listening"
            tone = .positive
        case .processing:
            title = "Processing"
            tone = .warning
        }

        self.init(
            title: title,
            accessibilityValue: Self.accessibilityValue(
                title: title,
                intensity: VoiceActivityInputIntensity(state: state)
            ),
            meterSnapshot: VoiceActivityMeterSnapshot(state: state, barCount: meterBarCount),
            tone: tone
        )
    }

    private static func accessibilityValue(
        title: String,
        intensity: VoiceActivityInputIntensity
    ) -> String {
        switch intensity {
        case .none:
            title
        case .low:
            "\(title), low input"
        case .medium:
            "\(title), medium input"
        case .high:
            "\(title), high input"
        }
    }
}
