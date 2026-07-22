import VoiceKeyboardInterfaces
import VoiceKeyboardModels

public struct KeyboardSpeechRecognitionEvent: Equatable, Sendable {
    public let state: KeyboardSpeechCaptureState
    public let actions: [KeyboardTextInsertionAction]

    public init(
        state: KeyboardSpeechCaptureState,
        actions: [KeyboardTextInsertionAction] = []
    ) {
        self.state = state
        self.actions = actions
    }
}

public enum KeyboardTextInsertionAction: Equatable, Sendable {
    case insertText(String)
    case deleteBackward(count: TextDeletionCount)
    case showUnsupportedCommand(String)
}

public struct KeyboardSpeechRecognitionSession: Sendable {
    private let speechService: any SpeechRecognitionService
    private let pipeline: VoiceInputPipeline

    public init(
        speechService: any SpeechRecognitionService,
        pipeline: VoiceInputPipeline
    ) {
        self.speechService = speechService
        self.pipeline = pipeline
    }

    public func events(
        locale: VoiceKeyboardLocale,
        documentContextBeforeInput: String?
    ) -> AsyncStream<KeyboardSpeechRecognitionEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let stopGate = SpeechRecognitionStopGate()
            let task = Task {
                guard await yieldRequired(
                    KeyboardSpeechRecognitionEvent(state: .listening),
                    to: continuation
                ) else { return }

                var virtualDocumentContext = documentContextBeforeInput ?? ""
                var pendingFinalTranscript = ""
                do {
                    let updates = try await speechService.start(locale: locale)
                    for try await update in updates {
                        guard !Task.isCancelled else { break }
                        if update.isFinal {
                            pendingFinalTranscript = appendingTranscriptSegment(
                                update.transcript,
                                to: pendingFinalTranscript
                            )
                            if pipeline.hasIncompleteCommandPrefix(
                                for: pendingFinalTranscript,
                                locale: locale
                            ) {
                                continuation.yield(
                                    KeyboardSpeechRecognitionEvent(
                                        state: .transcribing(
                                            SpeechRecognitionUpdate(
                                                transcript: pendingFinalTranscript,
                                                isFinal: false,
                                                inputLevel: update.inputLevel?.value
                                            )
                                        )
                                    )
                                )
                                continue
                            }
                            let actions = actions(
                                transcript: pendingFinalTranscript,
                                documentContextBeforeInput: virtualDocumentContext,
                                locale: locale
                            )
                            pendingFinalTranscript = ""
                            virtualDocumentContext = applying(actions, to: virtualDocumentContext)
                            guard await yieldRequired(
                                KeyboardSpeechRecognitionEvent(
                                    state: eventState(for: update, actions: actions),
                                    actions: actions
                                ),
                                to: continuation
                            ) else { break }
                        } else {
                            continuation.yield(KeyboardSpeechRecognitionEvent(state: .transcribing(update)))
                        }
                    }
                    if !Task.isCancelled, !pendingFinalTranscript.isEmpty {
                        let event = finalEvent(
                            transcript: pendingFinalTranscript,
                            documentContextBeforeInput: virtualDocumentContext,
                            locale: locale
                        )
                        _ = await yieldRequired(event, to: continuation)
                    }
                    await stopGate.stop(speechService)
                    continuation.finish()
                } catch {
                    if !pendingFinalTranscript.isEmpty {
                        let event = finalEvent(
                            transcript: pendingFinalTranscript,
                            documentContextBeforeInput: virtualDocumentContext,
                            locale: locale
                        )
                        _ = await yieldRequired(event, to: continuation)
                    }
                    await stopGate.stop(speechService)
                    let recognitionError: SpeechRecognitionError
                    if let error = error as? SpeechRecognitionError {
                        recognitionError = error
                    } else if error is CancellationError {
                        recognitionError = .cancelled
                    } else {
                        recognitionError = .recognitionFailed(String(describing: error))
                    }
                    _ = await yieldRequired(
                        KeyboardSpeechRecognitionEvent(state: .recognitionFailed(recognitionError)),
                        to: continuation
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await stopGate.stop(speechService)
                }
            }
        }
    }

    private func finalEvent(
        transcript: String,
        documentContextBeforeInput: String,
        locale: VoiceKeyboardLocale
    ) -> KeyboardSpeechRecognitionEvent {
        let update = SpeechRecognitionUpdate(transcript: transcript, isFinal: true)
        let actions = actions(
            transcript: transcript,
            documentContextBeforeInput: documentContextBeforeInput,
            locale: locale
        )
        return KeyboardSpeechRecognitionEvent(
            state: eventState(for: update, actions: actions),
            actions: actions
        )
    }

    private func yieldRequired(
        _ event: KeyboardSpeechRecognitionEvent,
        to continuation: AsyncStream<KeyboardSpeechRecognitionEvent>.Continuation
    ) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(event) {
            case .enqueued:
                return true
            case .dropped:
                try? await Task.sleep(nanoseconds: 1_000_000)
            case .terminated:
                return false
            @unknown default:
                return false
            }
        }
        return false
    }

    private func actions(
        transcript: String,
        documentContextBeforeInput: String?,
        locale: VoiceKeyboardLocale
    ) -> [KeyboardTextInsertionAction] {
        let mappedActions = pipeline.operations(
            for: transcript,
            documentContextBeforeInput: documentContextBeforeInput,
            locale: locale
        ).map { operation -> KeyboardTextInsertionAction in
            switch operation {
            case .insertText(let value):
                return .insertText(value)
            case .deleteBackward(let count):
                return .deleteBackward(count: count)
            case .showUnsupportedCommand(let phrase):
                return .showUnsupportedCommand(phrase)
            }
        }
        return coalescedInsertActions(from: mappedActions)
    }

    private func applying(
        _ actions: [KeyboardTextInsertionAction],
        to context: String
    ) -> String {
        actions.reduce(into: context) { context, action in
            switch action {
            case .insertText(let value):
                context.append(value)
            case .deleteBackward(let count):
                context = String(context.dropLast(min(count.value, context.count)))
            case .showUnsupportedCommand:
                break
            }
        }
    }

    private func appendingTranscriptSegment(
        _ segment: String,
        to transcript: String
    ) -> String {
        guard !segment.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return segment }
        guard let last = transcript.last, let first = segment.first else {
            return transcript + segment
        }
        if last.isWhitespace || first.isWhitespace {
            return transcript + segment
        }
        if last.isJapaneseTextLike && first.isJapaneseTextLike {
            return transcript + segment
        }
        return transcript + " " + segment
    }

    private func eventState(
        for update: SpeechRecognitionUpdate,
        actions: [KeyboardTextInsertionAction]
    ) -> KeyboardSpeechCaptureState {
        if let phrase = actions.compactMap(unsupportedCommand(from:)).first {
            return .unsupportedCommand(phrase)
        }
        guard let insertedText = insertedText(from: actions) else {
            return .transcribing(update)
        }
        return .inserted(insertedText)
    }

    private func unsupportedCommand(
        from action: KeyboardTextInsertionAction
    ) -> String? {
        guard case let .showUnsupportedCommand(phrase) = action else { return nil }
        return phrase
    }

    private func insertedText(
        from actions: [KeyboardTextInsertionAction]
    ) -> String? {
        let text = actions.reduce(into: "") { result, action in
            if case .insertText(let value) = action {
                result.append(value)
            }
        }
        return text.isEmpty ? nil : text
    }

    private func coalescedInsertActions(
        from actions: [KeyboardTextInsertionAction]
    ) -> [KeyboardTextInsertionAction] {
        var result: [KeyboardTextInsertionAction] = []
        var pendingText = ""

        func flushPendingText() {
            guard !pendingText.isEmpty else { return }
            result.append(.insertText(pendingText))
            pendingText = ""
        }

        for action in actions {
            switch action {
            case .insertText(let value):
                pendingText.append(value)
            case .deleteBackward:
                flushPendingText()
                result.append(action)
            case .showUnsupportedCommand:
                flushPendingText()
                result.append(action)
            }
        }

        flushPendingText()
        return result
    }
}

private extension Character {
    var isJapaneseTextLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF01...0xFF65:
                return true
            default:
                return false
            }
        }
    }
}

private actor SpeechRecognitionStopGate {
    private var stopTask: Task<Void, Never>?

    func stop(_ speechService: any SpeechRecognitionService) async {
        if let stopTask {
            await stopTask.value
            return
        }

        let stopTask = Task.detached {
            await speechService.stop()
        }
        self.stopTask = stopTask
        await stopTask.value
    }
}
