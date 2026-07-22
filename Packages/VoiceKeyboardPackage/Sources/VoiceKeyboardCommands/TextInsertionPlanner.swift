import VoiceKeyboardModels

package struct TextInsertionPlanner: Sendable {
    package init() {}

    package func plan(_ transcript: ParsedTranscript, documentContextBeforeInput: String?) -> [TextOperation] {
        var operations: [TextOperation] = []
        var virtualContext = documentContextBeforeInput ?? ""
        var shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)

        for element in transcript.elements {
            switch element {
            case .text(let value):
                guard !value.isEmpty else { continue }
                let shouldAddSpace = shouldInsertSpaceBeforeText
                    && shouldAddSpaceBetween(previous: virtualContext.last, next: value.first)
                let text = shouldAddSpace ? " \(value)" : value
                operations.append(.insertText(text))
                virtualContext.append(text)
                shouldInsertSpaceBeforeText = true
            case .command(.insertText(let value)):
                let quote = value.count == 1 && (value.first == "\"" || value.first == "'")
                    ? value.first
                    : nil
                let opensQuote = quote.map {
                    isOpeningQuoteContext(virtualContext, quote: $0)
                } ?? false
                let shouldAddSpace = shouldAddSpaceBeforeInsertedCommand(
                    value,
                    in: virtualContext,
                    opensQuote: opensQuote
                )
                let text = shouldAddSpace ? " \(value)" : value
                operations.append(.insertText(text))
                virtualContext.append(text)
                shouldInsertSpaceBeforeText = shouldAddSpaceAfterInsertedCommand(value, opensQuote: opensQuote)
            case .command(.deleteWord):
                let count = deleteWordCount(in: virtualContext)
                if let count = TextDeletionCount(count) {
                    operations.append(.deleteBackward(count: count))
                }
                virtualContext = deletingSuffix(count, from: virtualContext)
                shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)
            case .command(.deleteSentence):
                let count = deleteSentenceCount(in: virtualContext)
                if let count = TextDeletionCount(count) {
                    operations.append(.deleteBackward(count: count))
                }
                virtualContext = deletingSuffix(count, from: virtualContext)
                shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)
            case .command(.unsupportedShortcut(let phrase)):
                operations.append(.showUnsupportedCommand(phrase))
            }
        }

        return operations
    }

    private func shouldAddSpaceBeforeInitialText(in context: String) -> Bool {
        guard let last = context.last else { return false }
        if last == "\"" || last == "'" {
            return !contextEndsWithOpeningDelimiter(context)
        }
        return !last.isWhitespace && !last.isOpeningDelimiter && !last.isJapanesePunctuation
    }

    private func shouldAddSpaceBetween(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        return !previous.isJapaneseText && !next.isJapaneseText
    }

    private func shouldAddSpaceAfterInsertedCommand(_ value: String, opensQuote: Bool) -> Bool {
        if opensQuote { return false }

        return switch value {
        case "", " ", "\n", "\t", "(", "、", "。", "？", "！":
            false
        default:
            true
        }
    }

    private func shouldAddSpaceBeforeInsertedCommand(
        _ value: String,
        in context: String,
        opensQuote: Bool
    ) -> Bool {
        guard value == "(" || opensQuote,
              let previous = context.last else { return false }
        return !previous.isWhitespace
            && shouldAddSpaceBetween(previous: previous, next: value.first)
            && !contextEndsWithOpeningDelimiter(context)
    }

    private func isOpeningQuoteContext(_ context: String, quote: Character = "\"") -> Bool {
        guard quote == "'" else {
            return context.filter { $0 == quote }.count.isMultiple(of: 2)
        }

        var isInsideQuote = false
        for index in context.indices where context[index] == quote {
            let previous = index == context.startIndex
                ? nil
                : context[context.index(before: index)]
            let nextIndex = context.index(after: index)
            let next = nextIndex == context.endIndex ? nil : context[nextIndex]

            if previous?.isWordCharacter == true, next?.isWordCharacter == true {
                continue
            }
            if previous?.isWordCharacter == true, !isInsideQuote {
                continue
            }
            isInsideQuote.toggle()
        }
        return !isInsideQuote
    }

    private func contextEndsWithOpeningDelimiter(_ context: String) -> Bool {
        guard let last = context.last else { return false }
        guard last == "\"" || last == "'" else { return last.isOpeningDelimiter }

        let precedingContext = String(context.dropLast())
        if last == "'",
           precedingContext.last?.isWordCharacter == true,
           isOpeningQuoteContext(precedingContext, quote: last) {
            return false
        }
        return isOpeningQuoteContext(precedingContext, quote: last)
    }

    private func deleteWordCount(in context: String) -> Int {
        let trailingWhitespaceCount = context.reversed().prefix { $0.isWhitespace }.count
        let trimmed = context.dropLast(trailingWhitespaceCount)
        guard !trimmed.isEmpty else { return 0 }

        return trailingWhitespaceCount + trimmed.reversed().prefix { !$0.isWhitespace }.count
    }

    private func deletingSuffix(_ count: Int, from context: String) -> String {
        guard count > 0 else { return context }
        return String(context.dropLast(min(count, context.count)))
    }

    private func deleteSentenceCount(in context: String) -> Int {
        let trailingWhitespaceCount = context.reversed().prefix { $0.isWhitespace }.count
        let trimmed = context.dropLast(trailingWhitespaceCount)
        guard !trimmed.isEmpty else { return 0 }

        let sentenceTerminators: Set<Character> = [".", "?", "!", "\n", "。", "？", "！"]
        var count = 0
        var hasSeenSentenceBody = false

        let trailingClosingDelimiterCount = trimmed.reversed().prefix { $0.isSentenceClosingDelimiter }.count
        count += trailingClosingDelimiterCount

        for character in trimmed.dropLast(trailingClosingDelimiterCount).reversed() {
            if sentenceTerminators.contains(character), hasSeenSentenceBody {
                break
            }
            if !sentenceTerminators.contains(character) {
                hasSeenSentenceBody = true
            }
            count += 1
        }

        return trailingWhitespaceCount + count
    }
}

private extension Character {
    var isWordCharacter: Bool {
        isLetter || isNumber
    }

    var isSentenceClosingDelimiter: Bool {
        [
            "\"", "'", "’", "”", ")", "]", "}", "）", "］", "｝", "】", "〕", "〉", "》", "」", "』", "›", "»"
        ].contains(self)
    }

    var isOpeningDelimiter: Bool {
        self == "("
            || self == "["
            || self == "{"
            || self == "\""
            || self == "'"
            || self == "“"
            || self == "‘"
            || self == "（"
            || self == "［"
            || self == "｛"
            || self == "【"
            || self == "〔"
            || self == "〈"
            || self == "《"
            || self == "「"
            || self == "『"
    }

    var isJapanesePunctuation: Bool {
        self == "、" || self == "。" || self == "？" || self == "！"
    }

    var isJapaneseText: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF:
                true
            default:
                false
            }
        }
    }
}
