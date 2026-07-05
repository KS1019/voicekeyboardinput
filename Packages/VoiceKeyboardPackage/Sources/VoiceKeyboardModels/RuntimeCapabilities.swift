public struct RuntimeCapabilities: Equatable, Sendable {
    public let microphoneCaptureAvailable: Bool
    public let speechRecognitionAvailable: Bool
    public let textCleanupAvailable: Bool

    public init(
        microphoneCaptureAvailable: Bool,
        speechRecognitionAvailable: Bool,
        textCleanupAvailable: Bool
    ) {
        self.microphoneCaptureAvailable = microphoneCaptureAvailable
        self.speechRecognitionAvailable = speechRecognitionAvailable
        self.textCleanupAvailable = textCleanupAvailable
    }
}
