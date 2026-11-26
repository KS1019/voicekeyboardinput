import AVFAudio
import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
final class KeyboardSpeechCaptureCoordinator {
    enum Event: Sendable {
        case presentation(SpeechCapturePresentationSnapshot)
        case failure(SpeechCapturePresentationSnapshot)
        case transcript(String)
        case stopping
        case recognitionGap
        case finished
        case startupFailed
    }

    private let capture: any KeyboardAudioCapturing
    private let speech: any KeyboardSegmentRecognizing
    private var continuation: AsyncStream<Event>.Continuation?
    private var sessionID: UUID?
    private var pendingSegments: [DictationPCM] = []
    private var isRecognizing = false
    private var captureFinished = false

    init(capture: any KeyboardAudioCapturing = WebKitDictationCapture(),
         speech: any KeyboardSegmentRecognizing = KeyboardFileSpeechRecognition()) {
        self.capture = capture
        self.speech = speech
    }

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
        hasFullAccess: @escaping () -> Bool
    ) -> AsyncStream<Event> {
        let (events, continuation) = AsyncStream<Event>.makeStream()
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
                continuation.yield(.stopping)
            case .segment(let pcm):
                self.enqueue(pcm, locale: locale, id: id)
            case .finished(let pcm):
                self.captureFinished = true
                self.enqueue(pcm, locale: locale, id: id)
            case .startupFailed:
                self.end(.startupFailed)
            case .failed:
                self.end(Self.errorEvent(.recognitionFailed("Microphone capture stopped.")))
            }
        })
        return events
    }

    private func enqueue(_ pcm: DictationPCM, locale: VoiceKeyboardLocale, id: UUID) {
        if pcm.sampleCount > 0 {
            // Capture is bounded to 60 seconds. Bound backlog as well when
            // recognition is slower than speech; never silently drop a segment.
            guard pendingSegments.count < 60 else {
                capture.cancel()
                speech.cancel()
                end(Self.errorEvent(.recognitionFailed("Speech recognition could not keep up. Please try again.")))
                return
            }
            pendingSegments.append(pcm)
        }
        recognizeNext(locale: locale, id: id)
    }

    private func recognizeNext(locale: VoiceKeyboardLocale, id: UUID) {
        guard sessionID == id, !isRecognizing else { return }
        guard !pendingSegments.isEmpty else {
            if captureFinished { end(.finished) }
            return
        }
        isRecognizing = true
        let pcm = pendingSegments.removeFirst()
        speech.start(pcm, locale: locale) { [weak self] result in
            guard let self, self.sessionID == id else { return }
            self.isRecognizing = false
            switch result {
            case .success(let transcript):
                self.continuation?.yield(.transcript(transcript))
                self.recognizeNext(locale: locale, id: id)
            case .failure(.recognitionFailed):
                self.continuation?.yield(.recognitionGap)
                self.recognizeNext(locale: locale, id: id)
            case .failure(let error):
                self.end(Self.errorEvent(error))
            }
        }
    }

    func finishRecognition() {
        capture.finish()
    }

    func cancelRecognition() {
        end()
    }

    private func end(_ event: Event? = nil) {
        capture.cancel()
        speech.cancel()
        if let event {
            continuation?.yield(event)
        }
        continuation?.finish()
        continuation = nil
        sessionID = nil
        pendingSegments.removeAll()
        isRecognizing = false
        captureFinished = false
    }

    static func insertionResult(_ transcript: String, context: String?, locale: VoiceKeyboardLocale,
                                omittingLiteralPrefix: String = "", interpretCommands: Bool = true) -> (SpeechCapturePresentationSnapshot, [KeyboardTextInsertionAction]) {
        guard VoiceKeyboardTextLimits.isValid(transcript),
              let operations = VoiceInputPipeline(locale: locale).boundedOperations(
                  for: transcript,
                  documentContextBeforeInput: context,
                  maximumOperationCount: VoiceInputPipeline.maximumOperationCount,
                  omittingLiteralPrefix: omittingLiteralPrefix, interpretCommands: interpretCommands
              ) else {
            return (.keyboardSpeechCapture(.recognitionFailed(.recognitionFailed("Voice input produced too many editing operations."))), [])
        }
        guard !operations.isEmpty else {
            return (.keyboardSpeechCapture(.unsupportedCommand("Nothing to delete")), [])
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
        return (.keyboardSpeechCapture(state), actions)
    }

    private static func errorEvent(_ error: SpeechRecognitionError) -> Event {
        .failure(.keyboardSpeechCapture(.recognitionFailed(error)))
    }

    private static let starting = SpeechCapturePresentationSnapshot(
        transcriptText: "",
        statusText: "Starting microphone…",
        microphoneTitle: "Stop",
        microphoneTone: .warning,
        activeMicrophoneBars: .checking,
        voiceActivityState: .processing
    )

}
