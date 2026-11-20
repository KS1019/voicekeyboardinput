public enum KeyboardDictationTapDecision: Equatable, Sendable {
    case ignore
    case finishDirect
    case stopShared
    case start

    public static func evaluate(
        isVisible: Bool,
        directRecognitionIsActive: Bool,
        sharedInteractionIsBlocked: Bool,
        sharedSessionIsActive: Bool
    ) -> Self {
        guard isVisible else { return .ignore }
        if directRecognitionIsActive { return .finishDirect }
        guard !sharedInteractionIsBlocked else { return .ignore }
        return sharedSessionIsActive ? .stopShared : .start
    }
}
