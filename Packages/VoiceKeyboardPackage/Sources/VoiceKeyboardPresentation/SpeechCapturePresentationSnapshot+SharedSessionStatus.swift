import VoiceKeyboardModels

public extension SpeechCapturePresentationSnapshot {
    static func sharedDictationSessionStatus(
        _ status: SharedDictationSessionStatus
    ) -> SpeechCapturePresentationSnapshot {
        switch status {
        case .idle:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Ready for voice input.",
                statusText: "Ready for voice input.",
                microphoneTitle: "Speak",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .idle
            )
        case .commandPending, .commandAcknowledged:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Listening request sent.",
                statusText: "Voice Keyboard Input is starting dictation.",
                microphoneTitle: "Starting",
                microphoneTone: .warning,
                activeMicrophoneBars: .checking,
                voiceActivityState: .processing
            )
        case .recording:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Listening...",
                statusText: "Listening from Voice Keyboard Input.",
                microphoneTitle: "Stop",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .listening
            )
        case .transcribing:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Transcribing...",
                statusText: "Transcribing...",
                microphoneTitle: "Stop",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .processing
            )
        case .transcriptReady:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Transcript ready.",
                statusText: "Inserting transcript...",
                microphoneTitle: "Speak",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .processing
            )
        case let .failed(_, message):
            return SpeechCapturePresentationSnapshot(
                transcriptText: message,
                statusText: message,
                microphoneTitle: "Retry",
                microphoneTone: .critical,
                activeMicrophoneBars: .inactive,
                voiceActivityState: .idle
            )
        case .cancelled:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Voice input stopped.",
                statusText: "Voice input stopped.",
                microphoneTitle: "Speak",
                microphoneTone: .warning,
                activeMicrophoneBars: .inactive,
                voiceActivityState: .idle
            )
        }
    }
}
