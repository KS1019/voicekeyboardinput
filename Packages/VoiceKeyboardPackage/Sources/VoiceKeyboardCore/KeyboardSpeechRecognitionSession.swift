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
        AsyncStream { continuation in
            let stopGate = SpeechRecognitionStopGate()
            let task = Task {
                continuation.yield(KeyboardSpeechRecognitionEvent(state: .listening))
                do {
                    let updates = try await speechService.start(locale: locale)
                    var virtualDocumentContext = documentContextBeforeInput ?? ""
                    var pendingFinalTranscript = ""
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
                            continuation.yield(
                                KeyboardSpeechRecognitionEvent(
                                    state: eventState(for: update, actions: actions),
                                    actions: actions
                                )
                            )
                        } else {
                            continuation.yield(KeyboardSpeechRecognitionEvent(state: .transcribing(update)))
                        }
                    }
                    if !Task.isCancelled, !pendingFinalTranscript.isEmpty {
                        let finalUpdate = SpeechRecognitionUpdate(
                            transcript: pendingFinalTranscript,
                            isFinal: true
                        )
                        let actions = actions(
                            transcript: pendingFinalTranscript,
                            documentContextBeforeInput: virtualDocumentContext,
                            locale: locale
                        )
                        virtualDocumentContext = applying(actions, to: virtualDocumentContext)
                        continuation.yield(
                            KeyboardSpeechRecognitionEvent(
                                state: eventState(for: finalUpdate, actions: actions),
                                actions: actions
                            )
                        )
                    }
                    await stopGate.stop(speechService)
                    continuation.finish()
                } catch let error as SpeechRecognitionError {
                    await stopGate.stop(speechService)
                    continuation.yield(KeyboardSpeechRecognitionEvent(state: .recognitionFailed(error)))
                    continuation.finish()
                } catch is CancellationError {
                    await stopGate.stop(speechService)
                    continuation.yield(KeyboardSpeechRecognitionEvent(state: .recognitionFailed(.cancelled)))
                    continuation.finish()
                } catch {
                    await stopGate.stop(speechService)
                    continuation.yield(
                        KeyboardSpeechRecognitionEvent(
                            state: .recognitionFailed(.recognitionFailed(String(describing: error)))
                        )
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
