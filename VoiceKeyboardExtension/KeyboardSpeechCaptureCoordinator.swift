import Foundation
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

struct KeyboardSpeechCaptureCoordinator {
    // Apple does not guarantee microphone access for custom keyboard
    // extensions, even with full access. Keep all capture and speech
    // recognition in the containing app, where Bluetooth/HFP routing and
    // AVAudioSession lifecycle are supported. The extension only owns the
    // handoff and text insertion path.
    init() {}

    func currentSnapshot() async -> SpeechCapturePresentationSnapshot {
        .keyboardSpeechCapture(.containingAppLaunchRequired)
    }

    func shouldOpenContainingAppForDictation() -> Bool {
        true
    }

    func directRecognitionIsReady() async -> Bool {
        false
    }

    func probeSnapshot() async -> SpeechCapturePresentationSnapshot {
        .keyboardSpeechCapture(.containingAppLaunchRequired)
    }

    func recognitionEvents(
        locale: VoiceKeyboardLocale,
        documentContextBeforeInput: String?
    ) -> AsyncStream<KeyboardSpeechRecognitionEvent> {
        AsyncStream { continuation in
            continuation.yield(
                KeyboardSpeechRecognitionEvent(
                    state: .recognitionFailed(
                        .unavailableInCurrentProcess
                    )
                )
            )
            continuation.finish()
        }
    }

    func stopRecognition() async {}
}
