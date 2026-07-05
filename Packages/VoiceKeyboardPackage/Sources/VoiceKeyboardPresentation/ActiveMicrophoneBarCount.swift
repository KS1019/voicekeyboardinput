public struct ActiveMicrophoneBarCount: Equatable, Sendable {
    public static let maximumVisibleBars = 3
    public static let inactive = ActiveMicrophoneBarCount(validatedValue: 0)
    public static let checking = ActiveMicrophoneBarCount(validatedValue: 1)
    public static let ready = ActiveMicrophoneBarCount(validatedValue: maximumVisibleBars)

    public let value: Int

    public init?(_ value: Int) {
        guard (0...Self.maximumVisibleBars).contains(value) else { return nil }
        self.value = value
    }

    private init(validatedValue value: Int) {
        self.value = value
    }
}
