package enum VoiceCommand: Equatable, Sendable {
    case insertText(String)
    case deleteWord
    case deleteSentence
    case unsupportedShortcut(String)
}

package enum TranscriptElement: Equatable, Sendable {
    case text(String)
    case command(VoiceCommand)
}

package struct ParsedTranscript: Equatable, Sendable {
    package let elements: [TranscriptElement]

    package init(elements: [TranscriptElement]) {
        self.elements = elements
    }
}
