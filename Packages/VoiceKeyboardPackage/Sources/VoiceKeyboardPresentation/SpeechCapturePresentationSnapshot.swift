import VoiceKeyboardModels

public struct SpeechCapturePresentationSnapshot: Equatable, Sendable {
    public let transcriptText: String
    public let statusText: String
    public let microphoneTitle: String
    public let microphoneTone: PresentationTone
    public let activeMicrophoneBars: ActiveMicrophoneBarCount
    public let voiceActivityState: VoiceActivityState

    public init(
        transcriptText: String,
        statusText: String,
        microphoneTitle: String,
        microphoneTone: PresentationTone,
        activeMicrophoneBars: ActiveMicrophoneBarCount,
        voiceActivityState: VoiceActivityState
    ) {
        self.transcriptText = transcriptText
        self.statusText = statusText
        self.microphoneTitle = microphoneTitle
        self.microphoneTone = microphoneTone
        self.activeMicrophoneBars = activeMicrophoneBars
        self.voiceActivityState = voiceActivityState
    }

    public static let keyboardValidationPending = SpeechCapturePresentationSnapshot(
        transcriptText: "Speech capture is disabled here. Test commands in the containing app.",
        statusText: "Speech capture is disabled here. Test commands in the containing app.",
        microphoneTitle: "Mic unavailable",
        microphoneTone: .critical,
        activeMicrophoneBars: .inactive,
        voiceActivityState: .unavailable
    )
}
