public enum KeyboardDictationStartDecision: Equatable, Sendable {
    case startDirectKeyboardRecognition
    case writeSharedStartCommand
    case openContainingApp
    case showSharedStorageUnavailable

    public static func evaluate(
        directKeyboardRecognitionReady: Bool,
        hasSessionStore: Bool,
        appHeartbeatIsFresh: Bool
    ) -> KeyboardDictationStartDecision {
        if directKeyboardRecognitionReady {
            return .startDirectKeyboardRecognition
        }
        guard hasSessionStore else {
            return .showSharedStorageUnavailable
        }
        guard appHeartbeatIsFresh else {
            return .openContainingApp
        }
        return .writeSharedStartCommand
    }
}
