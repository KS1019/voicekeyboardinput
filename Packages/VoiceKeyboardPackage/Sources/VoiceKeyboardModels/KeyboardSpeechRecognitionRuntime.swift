public enum KeyboardSpeechRecognitionStrategy: Equatable, Sendable {
    case legacyAudioBuffer
    case speechAnalyzer
}

public enum KeyboardSpeechRecognitionRuntime: Sendable {
    public static func strategy(
        forOperatingSystemMajorVersion majorVersion: Int
    ) -> KeyboardSpeechRecognitionStrategy {
        majorVersion >= 27 ? .speechAnalyzer : .legacyAudioBuffer
    }
}
