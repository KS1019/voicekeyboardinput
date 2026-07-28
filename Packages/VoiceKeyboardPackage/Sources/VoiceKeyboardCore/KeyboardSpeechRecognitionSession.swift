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
    private enum SessionError: Error {
        case transcriptTooLong
    }

    private static let maximumTranscriptCharacterCount = 32_768

    private struct TranscriptAccumulator {
        private(set) var value = ""
        private var characterCount = 0
        private var scalarCount = 0
        private var utf8ByteCount = 0

        mutating func append(_ segment: String) throws {
            guard !segment.isEmpty else { return }
            let separator: String
            if value.isEmpty {
                separator = ""
            } else if let last = value.last, let first = segment.first {
                if last.isWhitespace || first.isWhitespace
                    || first.isCombiningMark
                    || first.isGraphemeContinuation
                    || (last.isGraphemeContinuation && first.isEmojiLike)
                    || (last.isRegionalIndicator && first.isRegionalIndicator)
                    || first.isPunctuationLike
                    || last.isOpeningPunctuation
                    || last.isJapaneseTextLike
                    || first.isJapaneseTextLike {
                    separator = ""
                } else {
                    separator = " "
                }
            } else {
                separator = ""
            }

            let nextCharacterCount = characterCount + separator.count + segment.count
            let nextScalarCount = scalarCount
                + separator.unicodeScalars.count
                + segment.unicodeScalars.count
            let nextUTF8ByteCount = utf8ByteCount
                + separator.utf8.count
                + segment.utf8.count
            guard nextCharacterCount <= KeyboardSpeechRecognitionSession.maximumTranscriptCharacterCount,
                  nextScalarCount <= KeyboardSpeechRecognitionSession.maximumTranscriptScalarCount,
                  nextUTF8ByteCount <= KeyboardSpeechRecognitionSession.maximumTranscriptUTF8ByteCount else {
                throw SessionError.transcriptTooLong
            }
            value.append(contentsOf: separator)
            value.append(contentsOf: segment)
            characterCount = nextCharacterCount
            scalarCount = nextScalarCount
            utf8ByteCount = nextUTF8ByteCount
        }
    }

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
        // Keep the newest partial update and one terminal event. A slow
        // keyboard consumer must never cause the final insertion/error event
        // to be rejected behind an already-buffered listening/partial event.
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let stopGate = SpeechRecognitionStopGate()
            let task = Task {
                guard await yieldRequired(
                    KeyboardSpeechRecognitionEvent(state: .listening),
                    to: continuation
                ) else { return }

                let virtualDocumentContext = documentContextBeforeInput ?? ""
                var pendingFinalTranscript = TranscriptAccumulator()
                do {
                    let updates = try await speechService.start(locale: locale)
                    for try await update in updates {
                        guard !Task.isCancelled else { break }
                        guard VoiceKeyboardTextLimits.isValid(update.transcript) else {
                            throw SessionError.transcriptTooLong
                        }
                        if update.isFinal {
                            try pendingFinalTranscript.append(update.transcript)
                            let transcript = pendingFinalTranscript.value
                            if pipeline.hasIncompleteCommandPrefix(
                                for: transcript,
                                locale: locale
                            ) {
                                continuation.yield(
                                    KeyboardSpeechRecognitionEvent(
                                        state: .transcribing(
                                            SpeechRecognitionUpdate(
                                                transcript: transcript,
                                                isFinal: false,
                                                inputLevel: update.inputLevel?.value
                                            )
                                        )
                                    )
                                )
                                continue
                            }
                            // Finalized SpeechAnalyzer segments are not
                            // guaranteed to be utterance boundaries. Keep
                            // the complete final transcript until the stream
                            // closes so a later segment can disambiguate
                            // natural text such as "hello delete word".
                            // This intentionally delays document mutation;
                            // it prevents an early destructive prefix from
                            // being applied before the sentence is known.
                            _ = update
                        } else {
                            continuation.yield(KeyboardSpeechRecognitionEvent(state: .transcribing(update)))
                        }
                    }
                    if !Task.isCancelled, !pendingFinalTranscript.value.isEmpty {
                        let event = finalEvent(
                            transcript: pendingFinalTranscript.value,
                            documentContextBeforeInput: virtualDocumentContext,
                            locale: locale
                        )
                        _ = await yieldRequired(event, to: continuation)
                    }
                    await stopGate.stop(speechService)
                    continuation.finish()
                } catch {
                    let pendingTranscript = pendingFinalTranscript.value
                    let pendingActions = actions(
                        transcript: pendingTranscript,
                        documentContextBeforeInput: virtualDocumentContext,
                        locale: locale
                    )
                    if let pendingActions,
                       !(error is SessionError),
                       !pendingTranscript.isEmpty,
                       !pendingActions.contains(where: isDestructiveAction),
                       !(error is CancellationError) {
                        let event = finalEvent(
                            transcript: pendingTranscript,
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
        guard let actions = actions(
            transcript: transcript,
            documentContextBeforeInput: documentContextBeforeInput,
            locale: locale
        ) else {
            return KeyboardSpeechRecognitionEvent(
                state: .recognitionFailed(
                    .recognitionFailed("Voice input produced too many editing operations.")
                )
            )
        }
        return KeyboardSpeechRecognitionEvent(
            state: eventState(for: update, actions: actions),
            actions: actions
        )
    }

    private func yieldRequired(
        _ event: KeyboardSpeechRecognitionEvent,
        to continuation: AsyncStream<KeyboardSpeechRecognitionEvent>.Continuation
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled {
            guard ContinuousClock.now < deadline else { return false }
            switch continuation.yield(event) {
            case .enqueued:
                return true
            case .dropped:
                // bufferingNewest keeps the newly yielded event and evicts
                // an older buffered event. Retrying here would enqueue the
                // same terminal insertion/deletion twice.
                return true
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
    ) -> [KeyboardTextInsertionAction]? {
        guard let operations = pipeline.boundedOperations(
            for: transcript,
            documentContextBeforeInput: documentContextBeforeInput,
            maximumOperationCount: VoiceInputPipeline.maximumOperationCount,
            locale: locale
        ) else { return nil }
        let mappedActions = operations.map { operation -> KeyboardTextInsertionAction in
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

    private func isDestructiveAction(_ action: KeyboardTextInsertionAction) -> Bool {
        if case .deleteBackward = action { return true }
        return false
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

    private static let maximumTranscriptScalarCount = 65_536
    private static let maximumTranscriptUTF8ByteCount = 256_000

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
    var isCombiningMark: Bool {
        unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                true
            default:
                false
            }
        }
    }

    var isGraphemeContinuation: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x200D, 0xFE00...0xFE0F, 0xE0100...0xE01EF,
                 0x1F3FB...0x1F3FF:
                true
            default:
                false
            }
        }
    }

    var isEmojiLike: Bool {
        unicodeScalars.contains { $0.properties.isEmoji }
    }

    var isRegionalIndicator: Bool {
        unicodeScalars.count == 1
            && unicodeScalars.first.map { 0x1F1E6...0x1F1FF ~= $0.value } == true
    }

    var isPunctuationLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation,
                 .dashPunctuation,
                 .openPunctuation,
                 .closePunctuation,
                 .initialPunctuation,
                 .finalPunctuation,
                 .otherPunctuation:
                true
            default:
                false
            }
        }
    }

    var isOpeningPunctuation: Bool {
        "([{「『（［｛【〔〈《".contains(self)
    }

    var isJapaneseTextLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF01...0xFF65:
                return true
            case 0x20000...0x2FA1F:
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
