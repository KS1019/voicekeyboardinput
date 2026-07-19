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

        case .listening:
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Listening...",
                statusText: "Listening...",
                microphoneTitle: "Stop",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .listening(level: nil)
            )

        case let .transcribing(update):
            return SpeechCapturePresentationSnapshot(
                transcriptText: update.transcript.isEmpty ? "Listening..." : update.transcript,
                statusText: "Transcribing...",
                microphoneTitle: "Stop",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .listening(level: update.inputLevel)
            )

        case let .inserted(text):
            return SpeechCapturePresentationSnapshot(
                transcriptText: text,
                statusText: "Inserted.",
                microphoneTitle: "Speak",
                microphoneTone: .positive,
                activeMicrophoneBars: .ready,
                voiceActivityState: .idle
            )

        case let .unsupportedCommand(phrase):
            return SpeechCapturePresentationSnapshot(
                transcriptText: "Unsupported command: \(phrase)",
                statusText: "Unsupported command.",
                microphoneTitle: "Speak",
                microphoneTone: .warning,
                activeMicrophoneBars: .ready,
                voiceActivityState: .idle
            )

        case let .recognitionFailed(error):
            return failedKeyboardSpeechCapture(error)

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

    private static func failedKeyboardSpeechCapture(
        _ error: SpeechRecognitionError
    ) -> SpeechCapturePresentationSnapshot {
        let message: String
        let title: String
        let isUnavailable: Bool

        switch error {
        case .microphonePermissionDenied:
            message = "Microphone permission is denied for this keyboard."
            title = "Mic denied"
            isUnavailable = true
        case .microphonePermissionUndetermined:
            message = "Microphone permission is not decided for this keyboard."
            title = "Mic setup"
            isUnavailable = true
        case .audioInputUnavailable:
            message = "Microphone input is unavailable in this keyboard."
            title = "Mic unavailable"
            isUnavailable = true
        case .speechRecognizerUnavailable:
            message = "Speech recognition is unavailable in this keyboard."
            title = "Speech unavailable"
            isUnavailable = true
        case .speechAuthorizationDenied:
            message = "Speech recognition permission is denied."
            title = "Speech denied"
            isUnavailable = true
        case .cancelled:
            message = "Voice input stopped."
            title = "Speak"
            isUnavailable = false
        case .unavailableInCurrentProcess,
             .audioSessionActivationFailed,
             .audioEngineStartFailed,
             .recognitionStartFailed,
             .recognitionFailed:
            message = "Voice input failed in this keyboard."
            title = "Retry"
            isUnavailable = false
        }

        return SpeechCapturePresentationSnapshot(
            transcriptText: message,
            statusText: message,
            microphoneTitle: title,
            microphoneTone: .critical,
            activeMicrophoneBars: .inactive,
            voiceActivityState: isUnavailable ? .unavailable : .idle
        )
    }
}
