public struct VoiceActivityMeterBarCount: Equatable, Sendable {
    public static let standardVisibleBars = VoiceActivityMeterBarCount(validatedValue: 7)

    public let value: Int

    public init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }

    private init(validatedValue value: Int) {
        self.value = value
    }
}
