import VoiceKeyboardModels

package struct TextInsertionPlanner: Sendable {
    package init() {}

    package func plan(_ transcript: ParsedTranscript, documentContextBeforeInput: String?) -> [TextOperation] {
        plan(
            transcript,
            documentContextBeforeInput: documentContextBeforeInput,
            maximumOperationCount: .max
        ) ?? []
    }

    package func plan(
        _ transcript: ParsedTranscript,
        documentContextBeforeInput: String?,
        maximumOperationCount: Int
    ) -> [TextOperation]? {
        guard maximumOperationCount > 0 else { return nil }
        var operations: [TextOperation] = []
        var virtualContext = documentContextBeforeInput ?? ""
        var shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)

        for element in transcript.elements {
            switch element {
            case .text(let value):
                guard !value.isEmpty else { continue }
                let shouldAddSpace = shouldInsertSpaceBeforeText
                    && value.first?.isWhitespace != true
                    && shouldAddSpaceBetween(previous: virtualContext.last, next: value.first)
                let text = shouldAddSpace ? " \(value)" : value
                operations.append(.insertText(text))
                guard operations.count <= maximumOperationCount else { return nil }
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
                guard operations.count <= maximumOperationCount else { return nil }
                virtualContext.append(text)
                shouldInsertSpaceBeforeText = shouldAddSpaceAfterInsertedCommand(value, opensQuote: opensQuote)
            case .command(.deleteWord):
                let count = deleteWordCount(in: virtualContext)
                guard appendDeletionOperations(
                    count,
                    to: &operations,
                    maximumOperationCount: maximumOperationCount
                ) else { return nil }
                if count > 0 {
                    virtualContext = deletingSuffix(count, from: virtualContext)
                    shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)
                }
            case .command(.deleteSentence):
                let count = deleteSentenceCount(in: virtualContext)
                guard appendDeletionOperations(
                    count,
                    to: &operations,
                    maximumOperationCount: maximumOperationCount
                ) else { return nil }
                if count > 0 {
                    virtualContext = deletingSuffix(count, from: virtualContext)
                    shouldInsertSpaceBeforeText = shouldAddSpaceBeforeInitialText(in: virtualContext)
                }
            case .command(.unsupportedShortcut(let phrase)):
                operations.append(.showUnsupportedCommand(phrase))
                guard operations.count <= maximumOperationCount else { return nil }
            }
        }

        return operations
    }

    private func appendDeletionOperations(
        _ count: Int,
        to operations: inout [TextOperation],
        maximumOperationCount: Int
    ) -> Bool {
        guard count > 0 else { return true }
        var remaining = count
        while remaining > 0 {
            guard operations.count < maximumOperationCount else { return false }
            let chunk = min(remaining, TextDeletionCount.maximumValue)
            guard let deletion = TextDeletionCount(chunk) else { return false }
            operations.append(.deleteBackward(count: deletion))
            remaining -= chunk
        }
        return true
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

        let characters = Array(trimmed)
        var tokenStart = 0
        for index in stride(from: characters.count - 1, through: 0, by: -1) {
            let character = characters[index]
            guard character.isWhitespace else {
                continue
            }
            let isNumericGroupingSeparator = (character == "\u{2007}" || character == "\u{2009}")
                && index > 0
                && index + 1 < characters.count
                && characters[index - 1].isNumber
                && characters[index + 1].isNumber
            let isNonBreakingNumericGroupingSeparator = (character == "\u{00A0}" || character == "\u{202F}")
                && index > 0
                && index + 1 < characters.count
                && characters[index - 1].isNumber
                && characters[index + 1].isNumber
            if !isNumericGroupingSeparator && !isNonBreakingNumericGroupingSeparator {
                tokenStart = index + 1
                break
            }
        }
        let trailingToken = String(characters[tokenStart...])
        let trailingPunctuation = Set<Character>([
            ".", ",", ";", ":", "!", "?", ")", "]", "}",
            "）", "］", "｝", "】", "〕", "〉", "》", "」", "』", "”", "’", "»", "›"
        ])
        let trailingPunctuationCount = trailingToken.reversed().prefix {
            trailingPunctuation.contains($0)
        }.count
        let structuredToken = String(trailingToken.dropLast(trailingPunctuationCount))
        let leadingWrappers = Set<Character>([
            "(", "[", "{", "（", "［", "｛", "【", "〔", "〈", "《", "「", "『",
            "\"", "'", "“", "‘"
        ])
        let leadingWrapperCount = structuredToken.prefix {
            leadingWrappers.contains($0)
        }.count
        let structuredCore = String(structuredToken.dropFirst(leadingWrapperCount))
        let decimalSeparators: Set<Character> = [
            ".", "．", "｡", "﹒", "․", ",", "，", "٫", "٬", "\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}"
        ]
        let trailingCharacters = Array(structuredCore)
        let hasNumericSeparator = trailingCharacters.indices.contains { index in
            guard decimalSeparators.contains(trailingCharacters[index]),
                  index > trailingCharacters.startIndex,
                  index + 1 < trailingCharacters.endIndex else { return false }
            return trailingCharacters[index - 1].isNumber
                && trailingCharacters[index + 1].isNumber
        }
        if structuredCore.contains("@")
            || structuredCore.contains("://")
            || isSchemeLessHostToken(structuredCore)
            || hasNumericSeparator {
            // Treat URLs, e-mail addresses, and decimal-like tokens as one
            // word while keeping sentence punctuation consistent with normal
            // word deletion. Removing only `com` or `14` leaves a malformed
            // token, but the surrounding comma or period is a separate edit.
            return trailingWhitespaceCount
                + (trailingPunctuationCount == 0
                    ? max(structuredToken.count - leadingWrapperCount, 1)
                    : 1)
        }

        if trimmed.last?.isJapaneseText == true {
            return trailingWhitespaceCount + 1
        }
        var count = 0
        let wordCharacters = characters
        for (index, character) in wordCharacters.enumerated().reversed() {
            let isInternalApostrophe = (character == "'" || character == "’")
                && index > 0
                && index + 1 < wordCharacters.count
                && wordCharacters[index - 1].isWordCharacter
                && wordCharacters[index + 1].isWordCharacter
            guard (character.isLetter || character.isNumber || character == "_" || isInternalApostrophe),
                  !character.isJapaneseText else { break }
            count += 1
        }
        return trailingWhitespaceCount + max(count, 1)
    }

    private func isSchemeLessHostToken(_ token: String) -> Bool {
        let authority = token
            .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" })
            .first
            .map(String.init) ?? token
        let host: String
        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
            host = String(authority[..<colon])
        } else {
            host = authority
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && label.first?.isWordCharacter == true
                      && label.last?.isWordCharacter == true
                      && label.allSatisfy { $0.isWordCharacter || $0 == "-" }
              }) else {
            return false
        }
        let topLevelLabel = labels[labels.index(before: labels.endIndex)]
        return topLevelLabel.count >= 2 && topLevelLabel.allSatisfy(\.isLetter)
    }

    private func deletingSuffix(_ count: Int, from context: String) -> String {
        guard count > 0 else { return context }
        return String(context.dropLast(min(count, context.count)))
    }

    private func deleteSentenceCount(in context: String) -> Int {
        let trailingWhitespaceCount = context.reversed().prefix { $0.isWhitespace }.count
        let trimmed = context.dropLast(trailingWhitespaceCount)
        guard !trimmed.isEmpty else { return 0 }

        // Swift exposes CRLF as one Character cluster. Include both the
        // cluster and standalone Unicode line separators so sentence
        // deletion never crosses a Windows-style line boundary.
        let sentenceTerminators: Set<Character> = [
            ".", "?", "!", "\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}",
            "。", "？", "！", "…", "．", "｡", "﹒", "․", "۔", "։", "।", "॥", "؟", "።", "᙮", "᠃", "᠉"
        ]
        var count = 0
        var hasSeenSentenceBody = false
        var pendingClosingDelimiterCount = 0
        var stoppedAtSentenceBoundary = false

        let trailingClosingDelimiterCount = trimmed.reversed().prefix { $0.isSentenceClosingDelimiter }.count
        count += trailingClosingDelimiterCount

        let sentenceBody = trimmed.dropLast(trailingClosingDelimiterCount)
        for index in sentenceBody.indices.reversed() {
            let character = sentenceBody[index]
            if character.isSentenceClosingDelimiter {
                // Keep a closing quote/parenthesis pending until we know
                // whether its terminator belongs to the sentence being
                // deleted. With a following sentence, it closes the prior
                // sentence and must remain untouched.
                pendingClosingDelimiterCount += 1
                continue
            }
            let previousIndex = index == sentenceBody.startIndex
                ? nil
                : sentenceBody.index(before: index)
            let nextIndex = sentenceBody.index(after: index)
            let isDecimalPoint = [".", "．", "｡", "﹒", "․", ",", "，", "٫", "٬"].contains(character)
                && previousIndex.map { sentenceBody[$0].isNumber } == true
                && nextIndex < sentenceBody.endIndex
                && sentenceBody[nextIndex].isNumber
            let isSentenceBoundary = sentenceTerminators.contains(character)
                && !isDecimalPoint
                && isSentenceBoundaryCandidate(character, at: index, in: sentenceBody)
            if isSentenceBoundary, hasSeenSentenceBody {
                stoppedAtSentenceBoundary = true
                break
            }
            count += pendingClosingDelimiterCount
            pendingClosingDelimiterCount = 0
            if !isSentenceBoundary {
                hasSeenSentenceBody = true
            }
            count += 1
        }

        if !stoppedAtSentenceBoundary {
            count += pendingClosingDelimiterCount
        }
        return trailingWhitespaceCount + count
    }

    private func isSentenceBoundaryCandidate(
        _ character: Character,
        at index: String.Index,
        in text: Substring
    ) -> Bool {
        guard character == "." || character == "?" || character == "!" else {
            return true
        }
        var nextIndex = text.index(after: index)
        while nextIndex < text.endIndex,
              text[nextIndex].isSentenceClosingDelimiter {
            nextIndex = text.index(after: nextIndex)
        }
        guard nextIndex == text.endIndex || text[nextIndex].isWhitespace else {
            return false
        }
        guard character == "." else { return true }

        // Sentence deletion is destructive. A period followed by whitespace
        // is therefore treated as a boundary even for initials/abbreviations;
        // crossing that ambiguity can delete an entire preceding sentence.
        return true
    }
}

private extension Character {
    var isWordCharacter: Bool {
        isLetter || isNumber
    }

    var isSentenceClosingDelimiter: Bool {
        if unicodeScalars.allSatisfy({ scalar in
            switch scalar.properties.generalCategory {
            case .closePunctuation, .finalPunctuation:
                true
            default:
                false
            }
        }) {
            return true
        }
        return [
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
            case 0x3040...0x30FF,
                 0x3400...0x9FFF,
                 0xF900...0xFAFF,
                 0xFF61...0xFF9F,
                 0x1AFF0...0x1B16F:
                true
            case 0x20000...0x2FA1F,
                 0x30000...0x3347F:
                true
            default:
                false
            }
        }
    }

}
