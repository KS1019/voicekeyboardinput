import VoiceKeyboardModels

package struct VoiceCommandParser: Sendable {
    private let commandMap: [String: VoiceCommand]
    private let isJapaneseLocale: Bool
    private let japaneseUnspacedAliases: [(alias: String, command: VoiceCommand)]
    private let maxPhraseLength: Int

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
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var elements: [TranscriptElement] = []
        var index = 0

        while index < words.count {
            var matched: (length: Int, command: VoiceCommand)?

            for length in stride(from: min(maxPhraseLength, words.count - index), through: 1, by: -1) {
                let phrase = words[index..<(index + length)]
                    .joined(separator: " ")
                    .lowercased()

                if let command = commandMap[phrase] {
                    matched = (length, command)
                    break
                }
            }

            if let matched {
                elements.append(.command(matched.command))
                index += matched.length
            } else {
                if isJapaneseLocale {
                    elements.append(contentsOf: parseUnspacedJapaneseSegment(words[index]))
                } else {
                    elements.append(.text(words[index]))
                }
                index += 1
            }
        }

        return ParsedTranscript(elements: elements)
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

    private func parseUnspacedJapaneseSegment(_ segment: String) -> [TranscriptElement] {
        var remaining = segment[...]
        var pendingText = ""
        var elements: [TranscriptElement] = []
        let isCommandSequence = japaneseUnspacedAliases.first(where: {
            segment.hasSuffix($0.alias)
        }).map { terminalMatch in
            let prefix = segment.dropLast(terminalMatch.alias.count)
            return japaneseUnspacedAliases.contains { prefix.contains($0.alias) }
        } ?? false

        while !remaining.isEmpty {
            if let match = japaneseUnspacedAliases.first(where: {
                remaining.hasPrefix($0.alias) &&
                    (isCommandSequence ||
                        hasCommandBoundaries(for: $0.alias, at: remaining.startIndex, in: segment))
            }) {
                if !pendingText.isEmpty {
                    elements.append(.text(pendingText))
                    pendingText = ""
                }
                elements.append(.command(match.command))
                remaining.removeFirst(match.alias.count)
            } else {
                pendingText.append(remaining.removeFirst())
            }
        }

        if !pendingText.isEmpty {
            elements.append(.text(pendingText))
        }

        return elements
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

    private static func makeCommandMap(isJapaneseLocale: Bool) -> [String: VoiceCommand] {
        var commands: [String: VoiceCommand] = [
            "newline": .insertText("\n"),
            "new line": .insertText("\n"),
            "space": .insertText(" "),
            "tab": .insertText("\t"),
            "delete word": .deleteWord,
            "delete sentence": .deleteSentence,
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

private extension Character {
    var isCommandBoundary: Bool {
        !isLetter && !isNumber
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
