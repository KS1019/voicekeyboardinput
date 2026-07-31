import VoiceKeyboardModels

package struct VoiceCommandParser: Sendable {
    private let commandMap: [String: VoiceCommand]
    private let isJapaneseLocale: Bool
    private let japaneseUnspacedAliases: [(alias: String, command: VoiceCommand)]
    private let maxPhraseLength: Int

    private struct TranscriptToken {
        let value: String
        let range: Range<String.Index>
    }

    private struct CommandOnlyBoundaries {
        let prefix: [Bool]
        let suffix: [Bool]
    }

    package init(locale: VoiceKeyboardLocale) {
        let isJapaneseLocale = locale.usesJapaneseCommandAliases
        let commandMap = Self.makeCommandMap(isJapaneseLocale: isJapaneseLocale)

        self.commandMap = commandMap
        self.isJapaneseLocale = isJapaneseLocale
        self.japaneseUnspacedAliases = commandMap
            .filter { key, _ in
                !key.contains(where: \.isWhitespace) && key.containsJapaneseCharacter
            }
            .map { (alias: $0.key, command: $0.value) }
            .sorted { lhs, rhs in lhs.alias.count > rhs.alias.count }
        self.maxPhraseLength = commandMap.keys.map { $0.split(separator: " ").count }.max() ?? 1
    }

    package func parse(_ transcript: String) -> ParsedTranscript {
        let tokens = transcript.split(whereSeparator: { $0.isWhitespace }).map {
            TranscriptToken(value: String($0), range: $0.startIndex..<$0.endIndex)
        }
        let words = tokens.map(\.value)

        guard !transcript.isEmpty else { return ParsedTranscript(elements: []) }
        guard !words.isEmpty else { return ParsedTranscript(elements: [.text(transcript)]) }
        let commandOnlyBoundaries = makeCommandOnlyBoundaries(for: words)
        if containsUnsafeDestructiveCommand(in: words, boundaries: commandOnlyBoundaries) {
            return ParsedTranscript(elements: [.text(transcript)])
        }
        if containsNaturalLanguageSensitiveCommand(in: words, boundaries: commandOnlyBoundaries) {
            return ParsedTranscript(elements: [.text(transcript)])
        }

        var elements: [TranscriptElement] = []
        var index = 0

        while index < words.count {
            if elements.count >= Self.maximumElementCount {
                return ParsedTranscript(elements: [.text(transcript)])
            }
            var matched: (length: Int, command: VoiceCommand)?

            for length in stride(from: min(maxPhraseLength, words.count - index), through: 1, by: -1) {
                let phrase = words[index..<(index + length)]
                    .joined(separator: " ")
                    .lowercased()

                if let command = commandMap[phrase] {
                    if (!command.isDestructive && isSafeNonDestructiveMatch(
                        command,
                        at: index,
                        length: length,
                        in: words,
                        boundaries: commandOnlyBoundaries
                    )) || (command.isDestructive && isSafeDestructiveMatch(
                        command,
                        at: index,
                        length: length,
                        phrase: phrase,
                        in: words,
                        boundaries: commandOnlyBoundaries
                    )) {
                        matched = (length, command)
                        break
                    }
                }
            }

            if let matched {
                appendNonCanonicalSeparator(
                    beforeTokenAt: index,
                    tokens: tokens,
                    transcript: transcript,
                    to: &elements
                )
                elements.append(.command(matched.command))
                index += matched.length
            } else {
                if isJapaneseLocale {
                    guard let parsed = parseUnspacedJapaneseSegment(
                        words[index],
                        maximumElementCount: Self.maximumElementCount - elements.count
                    ) else {
                        return ParsedTranscript(elements: [.text(transcript)])
                    }
                    appendLiteralElements(
                        parsed,
                        token: tokens[index],
                        tokenIndex: index,
                        tokens: tokens,
                        transcript: transcript,
                        to: &elements
                    )
                } else {
                    appendLiteralText(
                        words[index],
                        token: tokens[index],
                        tokenIndex: index,
                        tokens: tokens,
                        transcript: transcript,
                        to: &elements
                    )
                }
                index += 1
            }
        }

        guard let lastToken = tokens.last else { return ParsedTranscript(elements: elements) }
        let trailing = String(transcript[lastToken.range.upperBound...])
        if !trailing.isEmpty, elements.contains(where: { element in
            if case .command = element { return true }
            return false
        }) {
            appendLiteralText(trailing, to: &elements)
        }

        // When the recognizer produced no executable command, the transcript
        // is literal speech. Keep its exact whitespace as one text element;
        // rebuilding it from `split` words would silently turn tabs, repeated
        // spaces, and newlines into single ASCII spaces.
        if !elements.contains(where: { element in
            if case .command = element { return true }
            return false
        }) {
            return ParsedTranscript(elements: transcript.isEmpty ? [] : [.text(transcript)])
        }

        return ParsedTranscript(elements: elements)
    }

    private func appendLiteralElements(
        _ parsed: [TranscriptElement],
        token: TranscriptToken,
        tokenIndex: Int,
        tokens: [TranscriptToken],
        transcript: String,
        to elements: inout [TranscriptElement]
    ) {
        guard parsed.count == 1, case let .text(value) = parsed[0] else {
            appendNonCanonicalSeparator(
                beforeTokenAt: tokenIndex,
                tokens: tokens,
                transcript: transcript,
                to: &elements
            )
            elements.append(contentsOf: parsed)
            return
        }
        appendLiteralText(
            value,
            token: token,
            tokenIndex: tokenIndex,
            tokens: tokens,
            transcript: transcript,
            to: &elements
        )
    }

    private func appendLiteralText(
        _ value: String,
        token: TranscriptToken,
        tokenIndex: Int,
        tokens: [TranscriptToken],
        transcript: String,
        to elements: inout [TranscriptElement]
    ) {
        let separatorStart = tokenIndex == 0
            ? transcript.startIndex
            : tokens[tokenIndex - 1].range.upperBound
        let separator = String(transcript[separatorStart..<token.range.lowerBound])
        guard separator != " " else {
            elements.append(.text(value))
            return
        }
        if case let .text(previous)? = elements.last, previous.count < 1_024 {
            elements[elements.index(before: elements.endIndex)] = .text(previous + separator + value)
        } else {
            elements.append(.text(separator + value))
        }
    }

    private func appendLiteralText(_ value: String, to elements: inout [TranscriptElement]) {
        guard !value.isEmpty else { return }
        if case let .text(previous)? = elements.last, previous.count < 1_024 {
            elements[elements.index(before: elements.endIndex)] = .text(previous + value)
        } else {
            elements.append(.text(value))
        }
    }

    private func appendNonCanonicalSeparator(
        beforeTokenAt index: Int,
        tokens: [TranscriptToken],
        transcript: String,
        to elements: inout [TranscriptElement]
    ) {
        let separatorStart = index == 0
            ? transcript.startIndex
            : tokens[index - 1].range.upperBound
        let separator = String(transcript[separatorStart..<tokens[index].range.lowerBound])
        guard !separator.isEmpty, separator != " " else { return }
        appendLiteralText(separator, to: &elements)
    }

    private func containsUnsafeDestructiveCommand(
        in words: [String],
        boundaries: CommandOnlyBoundaries
    ) -> Bool {
        for index in words.indices {
            for length in stride(
                from: min(maxPhraseLength, words.count - index),
                through: 1,
                by: -1
            ) {
                let phrase = words[index..<(index + length)].joined(separator: " ").lowercased()
                guard let command = commandMap[phrase], command.isDestructive else { continue }
                // A command-only phrase is not confirmation that recognition
                // was correct. Destructive edits require an explicit prefix.
                if phrase.hasPrefix("command ") {
                    if !boundaries.prefix[index] || !boundaries.suffix[index + length] {
                        return true
                    }
                    continue
                }
                // The command map also contains the destructive suffix (for
                // example "delete word") so it can be parsed independently.
                // When that suffix is inside an already-prefixed phrase, it
                // is not a second unsafe command occurrence.
                if index > words.startIndex,
                   words[index - 1].lowercased() == "command" {
                    continue
                }
                return true
            }
        }
        return false
    }

    private func containsNaturalLanguageSensitiveCommand(
        in words: [String],
        boundaries: CommandOnlyBoundaries
    ) -> Bool {
        for index in words.indices {
            for length in stride(
                from: min(maxPhraseLength, words.count - index),
                through: 1,
                by: -1
            ) {
                let phrase = words[index..<(index + length)].joined(separator: " ").lowercased()
                guard let command = commandMap[phrase], command.isNaturalLanguageSensitiveAlias else { continue }
                let prefix = words[..<index]
                let suffix = words[(index + length)...]
                if !isJapaneseLocale {
                    let isExplicitUnsupportedShortcut = command.isUnsupportedShortcut
                        && index == words.startIndex
                        && phrase.hasPrefix("command ")
                    if command.isUnsupportedShortcut && !isExplicitUnsupportedShortcut {
                        return true
                    }
                    let precedingWord = prefix.last?.lowercased()
                    let followingWord = suffix.first?.lowercased()
                    let precedingCue = Self.naturalLanguageCueWords.contains(precedingWord ?? "")
                    let followingCue = Self.naturalLanguageCueWords.contains(followingWord ?? "")
                    if (precedingCue && !boundaries.prefix[index])
                        || (followingCue && !boundaries.suffix[index + length]) {
                        return true
                    }
                } else {
                    // Japanese punctuation aliases are especially easy to
                    // utter as ordinary prose (for example, "読点 多すぎ").
                    // They are executable only when every other token is a
                    // recognized command; otherwise preserve the utterance
                    // literally instead of silently editing the document.
                    if !boundaries.prefix[index]
                        || !boundaries.suffix[index + length] {
                        return true
                    }
                    if prefix.contains(where: Self.containsJapaneseNaturalLanguageCue)
                        || suffix.contains(where: Self.containsJapaneseLeadingNaturalLanguageCue) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func containsJapaneseNaturalLanguageCue(_ word: String) -> Bool {
        let normalizedWord = word.lowercased()
        return japaneseNaturalLanguageCueWords.contains { cue in
            normalizedWord == cue || (cue.count > 1 && normalizedWord.contains(cue))
        }
    }

    private static func containsJapaneseLeadingNaturalLanguageCue(_ word: String) -> Bool {
        let normalizedWord = word.lowercased()
        return japaneseNaturalLanguageCueWords.contains { cue in
            cue.count == 1
                ? normalizedWord.hasPrefix(cue)
                : normalizedWord.contains(cue)
        }
    }

    package func hasIncompleteCommandPrefix(_ transcript: String) -> Bool {
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let maximumSuffixLength = min(maxPhraseLength - 1, words.count)
        if maximumSuffixLength > 0 {
            for length in 1...maximumSuffixLength {
                let suffix = words.suffix(length).joined(separator: " ").lowercased()
                if commandMap.keys.contains(where: { phrase in
                    phrase.hasPrefix(suffix + " ")
                }) {
                    return true
                }
            }
        }
        return hasIncompleteJapaneseAliasSuffix(in: transcript)
    }

    private func hasIncompleteJapaneseAliasSuffix(in transcript: String) -> Bool {
        guard isJapaneseLocale,
              let segment = transcript.split(whereSeparator: { $0.isWhitespace }).last else {
            return false
        }

        for match in japaneseUnspacedAliases {
            let maximumSuffixLength = min(segment.count, match.alias.count - 1)
            guard maximumSuffixLength > 0 else { continue }

            for length in 1...maximumSuffixLength {
                let suffix = segment.suffix(length)
                guard match.alias.hasPrefix(suffix) else { continue }

                let suffixStart = suffix.startIndex
                if suffixStart == segment.startIndex ||
                    segment[segment.index(before: suffixStart)].isCommandBoundary {
                    return true
                }
            }
        }
        return false
    }

    private func parseUnspacedJapaneseSegment(
        _ segment: String,
        maximumElementCount: Int
    ) -> [TranscriptElement]? {
        guard maximumElementCount > 0 else { return nil }
        var remaining = segment[...]
        var pendingText = ""
        var elements: [TranscriptElement] = []
        let allowsImplicitSequence = canImplicitlyParseJapaneseSegment(segment)

        while !remaining.isEmpty {
            if let match = japaneseUnspacedAliases.first(where: {
                remaining.hasPrefix($0.alias) &&
                    ((hasCommandBoundaries(for: $0.alias, at: remaining.startIndex, in: segment) &&
                        isSafeUnspacedJapaneseMatch($0, at: remaining.startIndex, in: segment)) ||
                        (allowsImplicitSequence && $0.command.isSafeUnspacedJapaneseCommand))
            }) {
                if !pendingText.isEmpty {
                    guard elements.count < maximumElementCount else { return nil }
                    elements.append(.text(pendingText))
                    pendingText = ""
                }
                guard elements.count < maximumElementCount else { return nil }
                elements.append(.command(match.command))
                remaining.removeFirst(match.alias.count)
            } else {
                pendingText.append(remaining.removeFirst())
            }
        }

        if !pendingText.isEmpty {
            guard elements.count < maximumElementCount else { return nil }
            elements.append(.text(pendingText))
        }

        return elements
    }

    private func canImplicitlyParseJapaneseSegment(_ segment: String) -> Bool {
        var remaining = segment[...]
        var matchCount = 0
        var endsWithCommand = false
        var hasSeenCommand = false
        var literalSinceCommand = ""

        while !remaining.isEmpty {
            if let match = japaneseUnspacedAliases.first(where: {
                remaining.hasPrefix($0.alias) && $0.command.isSafeUnspacedJapaneseCommand
            }) {
                if hasSeenCommand,
                   (Self.containsJapaneseNaturalLanguageCue(literalSinceCommand)
                    || Self.containsJapaneseLeadingNaturalLanguageCue(literalSinceCommand)) {
                    return false
                }
                hasSeenCommand = true
                literalSinceCommand = ""
                matchCount += 1
                endsWithCommand = remaining.count == match.alias.count
                remaining.removeFirst(match.alias.count)
            } else {
                endsWithCommand = false
                literalSinceCommand.append(remaining.removeFirst())
            }
        }
        return matchCount >= 2
            && endsWithCommand
            && !Self.containsJapaneseNaturalLanguageCue(literalSinceCommand)
            && !Self.containsJapaneseLeadingNaturalLanguageCue(literalSinceCommand)
    }

    private func isSafeDestructiveMatch(
        _ command: VoiceCommand,
        at index: Int,
        length: Int,
        phrase: String,
        in words: [String],
        boundaries: CommandOnlyBoundaries
    ) -> Bool {
        guard command.isDestructive else { return true }
        guard phrase.hasPrefix("command ") else { return false }
        // A destructive alias is executable only when the complete spoken
        // segment is made of commands. This keeps phrases such as
        // "do not delete sentence" literal.
        let prefix = words[..<index]
        let end = index + length
        let suffix = words[end...]
        return (prefix.isEmpty || boundaries.prefix[index])
            && (suffix.isEmpty || boundaries.suffix[index + length])
    }

    private func isSafeNonDestructiveMatch(
        _ command: VoiceCommand,
        at index: Int,
        length: Int,
        in words: [String],
        boundaries: CommandOnlyBoundaries
    ) -> Bool {
        // "period" is a common noun. When surrounded by ordinary prose,
        // preserving the literal word is safer than silently inserting '.'.
        let prefix = words[..<index]
        let suffix = words[(index + length)...]
        guard command.isNaturalLanguageSensitiveAlias else { return true }
        let precedingWord = prefix.last?.lowercased()
        let followingWord = suffix.first?.lowercased()
        let precedingCue = Self.naturalLanguageCueWords.contains(precedingWord ?? "")
        let followingCue = Self.naturalLanguageCueWords.contains(followingWord ?? "")
        if (precedingCue && !boundaries.prefix[index])
            || (followingCue && !boundaries.suffix[index + length])
            || (isJapaneseLocale && (
                Self.japaneseNaturalLanguageCueWords.contains(precedingWord ?? "")
                    || Self.japaneseNaturalLanguageCueWords.contains(followingWord ?? "")
                    || suffix.contains { Self.japaneseNaturalLanguageCueWords.contains($0.lowercased()) }
            )) {
            return false
        }
        guard command.isAmbiguousNaturalLanguageAlias else { return true }
        guard !prefix.isEmpty, !suffix.isEmpty else { return true }
        return boundaries.prefix[index] || boundaries.suffix[index + length]
    }

    private static let naturalLanguageCueWords: Set<String> = [
        "a", "an", "the", "some", "this", "that", "is", "was", "need", "needs", "add", "insert", "put",
        "explore", "travel", "separated", "values", "start", "of", "business", "use", "missing", "here",
        "new", "line", "text", "code", "means", "meaning", "character", "parenthesis", "parentheses",
        "there", "no", "left", "me", "splice", "were", "are", "isn't", "isnt",
        "oxford", "debate", "exploration", "word", "words", "said", "say", "says", "mentioned", "mention",
        "called", "call", "phrase", "phrases", "literal", "literally", "type", "typed", "typing", "write",
        "wrote", "written", "use", "using"
    ]

    private static let japaneseNaturalLanguageCueWords: Set<String> = [
        "この", "その", "あの", "これ", "それ", "は", "を", "が", "に", "の", "について", "必要", "文字", "コード",
        "使い方", "多すぎ", "不要", "入れる", "いる"
    ]

    private func makeCommandOnlyBoundaries(for words: [String]) -> CommandOnlyBoundaries {
        var nextMatch = Array(repeating: 0, count: words.count)
        for index in words.indices {
            for length in stride(
                from: min(maxPhraseLength, words.count - index),
                through: 1,
                by: -1
            ) {
                let phrase = words[index..<(index + length)]
                    .joined(separator: " ")
                    .lowercased()
                if commandMap[phrase] != nil {
                    nextMatch[index] = length
                    break
                }
            }
        }

        var suffix = Array(repeating: false, count: words.count + 1)
        suffix[words.count] = true
        for index in words.indices.reversed() {
            let length = nextMatch[index]
            suffix[index] = length > 0 && suffix[index + length]
        }

        var prefix = Array(repeating: false, count: words.count + 1)
        prefix[0] = true
        var index = 0
        while index < words.count, nextMatch[index] > 0 {
            index += nextMatch[index]
            prefix[index] = true
        }
        return CommandOnlyBoundaries(prefix: prefix, suffix: suffix)
    }

    private func hasCommandBoundaries(
        for alias: String,
        at startIndex: String.Index,
        in segment: String
    ) -> Bool {
        let hasLeadingBoundary = startIndex == segment.startIndex ||
            segment[segment.index(before: startIndex)].isCommandBoundary
        let endIndex = segment.index(startIndex, offsetBy: alias.count)
        let hasTrailingBoundary = endIndex == segment.endIndex ||
            segment[endIndex].isCommandBoundary
        return hasLeadingBoundary && hasTrailingBoundary
    }

    private func isSafeUnspacedJapaneseMatch(
        _ match: (alias: String, command: VoiceCommand),
        at startIndex: String.Index,
        in segment: String
    ) -> Bool {
        guard match.command.isSafeUnspacedJapaneseCommand else { return false }
        let endIndex = segment.index(startIndex, offsetBy: match.alias.count)
        let leadingIsExplicit = startIndex != segment.startIndex
            && segment[segment.index(before: startIndex)].isExplicitJapaneseCommandBoundary
        let trailingIsExplicit = endIndex != segment.endIndex
            && segment[endIndex].isExplicitJapaneseCommandBoundary
        return (startIndex == segment.startIndex || leadingIsExplicit)
            && (endIndex == segment.endIndex || trailingIsExplicit)
    }

    private static let maximumElementCount = 512

    private static func makeCommandMap(isJapaneseLocale: Bool) -> [String: VoiceCommand] {
        var commands: [String: VoiceCommand] = [
            "newline": .insertText("\n"),
            "new line": .insertText("\n"),
            "space": .insertText(" "),
            "tab": .insertText("\t"),
            "delete word": .deleteWord,
            "delete sentence": .deleteSentence,
            "command delete word": .deleteWord,
            "command delete sentence": .deleteSentence,
            "comma": .insertText(","),
            "period": .insertText("."),
            "question mark": .insertText("?"),
            "exclamation mark": .insertText("!"),
            "quote": .insertText("\""),
            "open parenthesis": .insertText("("),
            "close parenthesis": .insertText(")"),
            "command copy": .unsupportedShortcut("command copy"),
            "command paste": .unsupportedShortcut("command paste"),
            "command select all": .unsupportedShortcut("command select all")
        ]

        if isJapaneseLocale {
            commands["改行"] = .insertText("\n")
            commands["空白"] = .insertText(" ")
            commands["タブ"] = .insertText("\t")
            commands["読点"] = .insertText("、")
            commands["句点"] = .insertText("。")
            commands["疑問符"] = .insertText("？")
            commands["感嘆符"] = .insertText("！")
        }

        return commands
    }
}

private extension VoiceCommand {
    var isDestructive: Bool {
        switch self {
        case .deleteWord, .deleteSentence:
            true
        case .insertText, .unsupportedShortcut:
            false
        }
    }

    var isAmbiguousNaturalLanguageAlias: Bool {
        if case .insertText(".") = self { return true }
        return false
    }

    var isNaturalLanguageSensitiveAlias: Bool {
        switch self {
        case .insertText("."),
             .insertText(" "),
             .insertText("\t"),
             .insertText("\n"),
             .insertText(","),
             .insertText("?"),
             .insertText("!"),
             .insertText("\""),
             .insertText("("),
             .insertText(")"),
             .insertText("、"),
             .insertText("。"),
             .insertText("？"),
             .insertText("！"),
             .unsupportedShortcut:
            return true
        default:
            return false
        }
    }

    var isSafeUnspacedJapaneseCommand: Bool {
        guard case let .insertText(value) = self else { return false }
        return value.allSatisfy { $0 == "、" || $0 == "。" || $0 == "？" || $0 == "！" || $0 == "\n" }
    }

    var isUnsupportedShortcut: Bool {
        if case .unsupportedShortcut = self { return true }
        return false
    }
}

private extension Character {
    var isCommandBoundary: Bool {
        !isLetter && !isNumber && !unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return false
            }
        })
    }

    var isExplicitJapaneseCommandBoundary: Bool {
        self == "/" || self == "／" || self == "|" || self == "｜"
    }
}

private extension String {
    var containsJapaneseCharacter: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}

private extension VoiceKeyboardLocale {
    var usesJapaneseCommandAliases: Bool {
        languageSubtag == "ja"
    }

    var languageSubtag: String {
        let separator = identifier.firstIndex { $0 == "-" || $0 == "_" || $0 == "@" } ?? identifier.endIndex
        return identifier[..<separator].lowercased()
    }
}
