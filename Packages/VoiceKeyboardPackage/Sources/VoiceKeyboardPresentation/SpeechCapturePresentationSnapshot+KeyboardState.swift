import VoiceKeyboardModels

public extension SpeechCapturePresentationSnapshot {
    static func keyboardSpeechCapture(
        _ state: KeyboardSpeechCaptureState
    ) -> SpeechCapturePresentationSnapshot {
        switch state {
        case .containingAppLaunchRequired:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Open the app for microphone setup.",
                statusText: "Open the app for microphone setup.",
                microphoneTitle: "Open app",
                microphoneTone: .warning,
                activeMicrophoneBars: .checking,
                voiceActivityState: .idle
            )

        case .probeNeeded:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Microphone check needed.",
                statusText: "Microphone check needed.",
                microphoneTitle: "Check mic",
                microphoneTone: .warning,
                activeMicrophoneBars: .checking,
                voiceActivityState: .idle
            )

        case .probing:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Checking microphone...",
                statusText: "Checking microphone...",
                microphoneTitle: "Checking mic",
                microphoneTone: .warning,
                activeMicrophoneBars: .checking,
                voiceActivityState: .processing
            )

        case .ready:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Microphone probe passed.",
                statusText: "Microphone probe passed.",
                microphoneTitle: "Check again",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .idle
            )

        case .probeFailed:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Microphone check failed here.",
                statusText: "Microphone check failed here.",
                microphoneTitle: "Retry check",
                microphoneTone: .critical,
                activeMicrophoneBars: .inactive,
                voiceActivityState: .idle
            )

        case let .unavailable(reason):
            return unavailableKeyboardSpeechCapture(reason)
        }
    }

    private static func unavailableKeyboardSpeechCapture(
        _ reason: KeyboardSpeechCaptureUnavailableReason
    ) -> SpeechCapturePresentationSnapshot {
        let message: String
        let title: String

        switch reason {
        case .microphoneCaptureUnavailable:
            message = "Microphone capture is unavailable in this keyboard."
            title = "Mic unavailable"
        case .speechRecognitionUnavailable:
            message = "Speech recognition is unavailable in this keyboard."
            title = "Speech unavailable"
        }

        return SpeechCapturePresentationSnapshot(
            transcriptText: message,
            statusText: message,
            microphoneTitle: title,
            microphoneTone: .critical,
            activeMicrophoneBars: .inactive,
            voiceActivityState: .unavailable
        )
    }
}
