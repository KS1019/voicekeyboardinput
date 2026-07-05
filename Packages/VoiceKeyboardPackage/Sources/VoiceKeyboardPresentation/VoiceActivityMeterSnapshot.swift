import VoiceKeyboardModels

public struct VoiceActivityMeterSnapshot: Equatable, Sendable {
    public let barLevels: [Double]

    public init(state: VoiceActivityState, barCount: VoiceActivityMeterBarCount) {
        guard
            state.phase == .listening,
            let inputLevel = state.inputLevel
        else {
            self.barLevels = Array(repeating: 0, count: barCount.value)
            return
        }

        self.barLevels = (0..<barCount.value).map { index in
            let center = Double(barCount.value - 1) / 2
            let distanceFromCenter = abs(Double(index) - center)
            let shape = 1 - (distanceFromCenter / Double(barCount.value))
            return min(max(inputLevel.value * shape, 0), 1)
        }
    }
}
