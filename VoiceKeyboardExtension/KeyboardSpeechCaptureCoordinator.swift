import AVFAudio
import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
final class KeyboardSpeechCaptureCoordinator {
    enum Event: Sendable {
        case presentation(SpeechCapturePresentationSnapshot)
        case final(SpeechCapturePresentationSnapshot, [KeyboardTextInsertionAction])
        case startupFailed
    }

    private let capture = WebKitDictationCapture()
    private let speech = KeyboardFileSpeechRecognition()
    private var continuation: AsyncStream<Event>.Continuation?
    private var sessionID: UUID?

    func preload(in view: UIView) {
        capture.preload(in: view)
    }

    func currentSnapshot(hasFullAccess: Bool) -> SpeechCapturePresentationSnapshot {
        guard directRecognitionIsReady(hasFullAccess: hasFullAccess) else {
            return .keyboardSpeechCapture(.containingAppLaunchRequired)
        }
        return SpeechCapturePresentationSnapshot(
            transcriptText: "",
            statusText: "Ready for voice input.",
            microphoneTitle: "Speak",
            microphoneTone: .positive,
            activeMicrophoneBars: .ready,
            voiceActivityState: .idle
        )
    }

    func directRecognitionIsReady(hasFullAccess: Bool) -> Bool {
        microphoneIsAllowed(hasFullAccess: hasFullAccess) && KeyboardFileSpeechRecognition.isAuthorized
    }

    private func microphoneIsAllowed(hasFullAccess: Bool) -> Bool {
        hasFullAccess && AVAudioApplication.shared.recordPermission == .granted
    }

    func recognitionEvents(
        locale: VoiceKeyboardLocale,
        documentContextBeforeInput: String?,
        hasFullAccess: @escaping () -> Bool
    ) -> AsyncStream<Event> {
        let (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(2))
        guard sessionID == nil else {
            continuation.finish()
            return events
        }

        let id = UUID()
        sessionID = id
        self.continuation = continuation
        continuation.yield(.presentation(Self.starting))
        capture.start(permitsMicrophone: { [weak self] in
            self?.microphoneIsAllowed(hasFullAccess: hasFullAccess()) == true
        }, handle: { [weak self] event in
            guard let self, self.sessionID == id else { return }
            switch event {
            case .started:
                continuation.yield(.presentation(.keyboardSpeechCapture(.listening)))
            case .stopping:
                continuation.yield(.presentation(Self.processing))
            case .finished(let pcm):
                self.speech.start(pcm, locale: locale) { [weak self] result in
                    guard let self, self.sessionID == id else { return }
                    switch result {
                    case .success(let transcript):
                        self.end(Self.finalEvent(transcript, context: documentContextBeforeInput, locale: locale))
                    case .failure(let error):
                        self.end(Self.errorEvent(error))
                    }
                }
            case .startupFailed:
                self.end(.startupFailed)
            case .failed:
                self.end(Self.errorEvent(.recognitionFailed("Microphone capture stopped.")))
            }
        })
        return events
    }

    func finishRecognition() {
        capture.finish()
    }

    func cancelRecognition() {
        capture.cancel()
        speech.cancel()
        end()
    }

    private func end(_ event: Event? = nil) {
        if let event {
            continuation?.yield(event)
        }
        continuation?.finish()
        continuation = nil
        sessionID = nil
    }

    private static func finalEvent(_ transcript: String, context: String?, locale: VoiceKeyboardLocale) -> Event {
        guard VoiceKeyboardTextLimits.isValid(transcript),
              let operations = VoiceInputPipeline(locale: locale).boundedOperations(
                  for: transcript,
                  documentContextBeforeInput: context,
                  maximumOperationCount: VoiceInputPipeline.maximumOperationCount
              ) else {
            return errorEvent(.recognitionFailed("Voice input produced too many editing operations."))
        }
        guard !operations.isEmpty else {
            return .final(.keyboardSpeechCapture(.unsupportedCommand("Nothing to delete")), [])
        }
        let actions = operations.map { operation -> KeyboardTextInsertionAction in
            switch operation {
            case .insertText(let text):
                return .insertText(text)
            case .deleteBackward(let count):
                return .deleteBackward(count: count)
            case .showUnsupportedCommand(let phrase):
                return .showUnsupportedCommand(phrase)
            }
        }
        let state: KeyboardSpeechCaptureState
        if let phrase = actions.compactMap({ action -> String? in
            if case .showUnsupportedCommand(let phrase) = action { return phrase }
            return nil
        }).first {
            state = .unsupportedCommand(phrase)
        } else {
            let inserted = actions.reduce(into: "") { text, action in
                if case .insertText(let value) = action { text.append(value) }
            }
            state = .inserted(inserted.isEmpty ? "Text edited" : inserted)
        }
        return .final(.keyboardSpeechCapture(state), actions)
    }

    private static func errorEvent(_ error: SpeechRecognitionError) -> Event {
        .presentation(.keyboardSpeechCapture(.recognitionFailed(error)))
    }

    private static let starting = SpeechCapturePresentationSnapshot(
        transcriptText: "",
        statusText: "Starting microphone…",
        microphoneTitle: "Stop",
        microphoneTone: .warning,
        activeMicrophoneBars: .checking,
        voiceActivityState: .processing
    )

    private static let processing = SpeechCapturePresentationSnapshot(
        transcriptText: "",
        statusText: "Transcribing…",
        microphoneTitle: "Processing",
        microphoneTone: .warning,
        activeMicrophoneBars: .checking,
        voiceActivityState: .processing
    )
}
