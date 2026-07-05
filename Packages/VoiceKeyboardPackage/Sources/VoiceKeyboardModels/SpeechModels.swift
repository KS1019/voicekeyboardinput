public struct SpeechRecognitionUpdate: Equatable, Sendable {
    public let transcript: String
    public let isFinal: Bool
    public let inputLevel: NormalizedInputLevel?

    public init(transcript: String, isFinal: Bool, inputLevel: Double? = nil) {
        self.transcript = transcript
        self.isFinal = isFinal
        self.inputLevel = inputLevel.normalizedInputLevel
    }
}

public enum SpeechRecognitionError: Error, Equatable, Sendable {
    case unavailableInCurrentProcess
}
