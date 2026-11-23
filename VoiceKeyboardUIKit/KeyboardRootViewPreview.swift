import SwiftUI
import VoiceKeyboardModels
import VoiceKeyboardPresentation

private struct KeyboardRootPreview: UIViewRepresentable {
    let snapshot: SpeechCapturePresentationSnapshot
    let showsNextKeyboard: Bool

    func makeUIView(context: Context) -> KeyboardRootView {
        let view = KeyboardRootView()
        render(view)
        return view
    }

    func updateUIView(_ view: KeyboardRootView, context: Context) {
        render(view)
    }

    private func render(_ view: KeyboardRootView) {
        view.render(speechCapture: snapshot)
        view.setNextKeyboardVisible(showsNextKeyboard)
    }
}

#Preview("Keyboard Root") {
    KeyboardRootPreview(
        snapshot: .keyboardValidationPending,
        showsNextKeyboard: true
    )
        .frame(height: 260)
}

#Preview("Keyboard Root Without Next") {
    KeyboardRootPreview(
        snapshot: .keyboardValidationPending,
        showsNextKeyboard: false
    )
    .frame(height: 220)
}

#Preview("Keyboard Root Compact") {
    KeyboardRootPreview(
        snapshot: .keyboardValidationPending,
        showsNextKeyboard: true
    )
    .frame(width: 320, height: 180)
}

#Preview("Keyboard Root Listening") {
    KeyboardRootPreview(
        snapshot: .listeningPreview,
        showsNextKeyboard: true
    )
    .frame(height: 260)
}

#Preview("Keyboard Root Unavailable") {
    KeyboardRootPreview(
        snapshot: .keyboardSpeechCapture(.unavailable(.microphoneCaptureUnavailable)),
        showsNextKeyboard: true
    )
    .frame(height: 220)
}

#Preview("Keyboard Root Light") {
    KeyboardRootPreview(
        snapshot: .listeningPreview,
        showsNextKeyboard: true
    )
    .frame(height: 260)
    .background(Color(uiColor: .systemBackground))
    .preferredColorScheme(.light)
}

#Preview("Keyboard Root Dark") {
    KeyboardRootPreview(
        snapshot: .listeningPreview,
        showsNextKeyboard: true
    )
    .frame(height: 260)
    .background(Color(uiColor: .systemBackground))
    .preferredColorScheme(.dark)
}

#Preview("Keyboard Ready Light") {
    KeyboardRootPreview(
        snapshot: .sharedDictationSessionStatus(.idle),
        showsNextKeyboard: true
    )
    .frame(height: 260)
    .background(Color(uiColor: .systemBackground))
    .preferredColorScheme(.light)
}

#Preview("Keyboard Ready Dark") {
    KeyboardRootPreview(
        snapshot: .sharedDictationSessionStatus(.idle),
        showsNextKeyboard: true
    )
    .frame(height: 260)
    .background(Color(uiColor: .systemBackground))
    .preferredColorScheme(.dark)
}

private extension SpeechCapturePresentationSnapshot {
    static let listeningPreview = SpeechCapturePresentationSnapshot(
        transcriptText: "Meeting notes: follow up with the team after lunch.",
        statusText: "Listening. Speak clearly and pause when finished.",
        microphoneTitle: "Mic active",
        microphoneTone: .positive,
        activeMicrophoneBars: .ready,
        voiceActivityState: .listening(level: 0.72)
    )
}
