import VoiceKeyboardCommands
import VoiceKeyboardModels

public enum LiteralTranscriptCommand: Equatable, Sendable {
    case insertText(String)
    case deleteWord
    case deleteSentence
    case unsupportedShortcut(String)
}

public enum LiteralTranscriptElement: Equatable, Sendable {
    case text(String)
    case command(LiteralTranscriptCommand)
}

public struct LiteralTranscriptPreview: Equatable, Sendable {
    public let elements: [LiteralTranscriptElement]
    public let operations: [TextOperation]

    public init(
        elements: [LiteralTranscriptElement],
        operations: [TextOperation]
    ) {
        self.elements = elements
        self.operations = operations
    }
}

public struct LiteralTranscriptCommandPipeline: Sendable {
    public static let maximumInputCharacterCount = VoiceKeyboardTextLimits.maximumCharacterCount
    public static let maximumInputUTF8ByteCount = VoiceKeyboardTextLimits.maximumUTF8ByteCount
    public static let maximumOperationCount = 64

    private let parser: VoiceCommandParser
    private let planner: TextInsertionPlanner

    public init(locale: VoiceKeyboardLocale) {
        parser = VoiceCommandParser(locale: locale)
        planner = TextInsertionPlanner()
    }

    public func preview(
        for transcript: String,
        documentContextBeforeInput: String?
    ) -> LiteralTranscriptPreview {
        guard Self.isBounded(transcript),
              documentContextBeforeInput.map(Self.isBounded) ?? true else {
            return LiteralTranscriptPreview(
                elements: [.text("Transcript is too large to preview safely.")],
                operations: []
            )
        }
        let parsed = parser.parse(transcript)
        guard !parsed.didOverflow else {
            return LiteralTranscriptPreview(
                elements: [.text("Transcript contains too many command elements to preview safely.")],
                operations: []
            )
        }
        guard let operations = planner.plan(
            parsed,
            documentContextBeforeInput: documentContextBeforeInput,
            maximumOperationCount: Self.maximumOperationCount
        ), operations.allSatisfy(Self.isBounded) else {
            return LiteralTranscriptPreview(
                elements: [.text("Transcript is too large to preview safely.")],
                operations: []
            )
        }
        return LiteralTranscriptPreview(
            elements: parsed.elements.map(Self.mapElement),
            operations: operations
        )
    }

    public func boundedPreview(
        for transcript: String,
        documentContextBeforeInput: String?,
        maximumOperationCount: Int,
        omittingLiteralPrefix: String = "",
        interpretCommands: Bool = true
    ) -> LiteralTranscriptPreview? {
        guard Self.isBounded(transcript),
              documentContextBeforeInput.map(Self.isBounded) ?? true else {
            return nil
        }
        let parsed = interpretCommands ? parser.parse(transcript) : ParsedTranscript(elements: [.text(transcript)])
        guard !parsed.didOverflow else { return nil }
        var elements = parsed.elements
        if !omittingLiteralPrefix.isEmpty {
            guard let first = elements.first, case .text(let text) = first,
                  text.hasPrefix(omittingLiteralPrefix) else { return nil }
            elements[0] = .text(String(text.dropFirst(omittingLiteralPrefix.count)))
        }
        let remainder = ParsedTranscript(elements: elements)
        guard let operations = planner.plan(
                  remainder,
                  documentContextBeforeInput: documentContextBeforeInput,
                  maximumOperationCount: maximumOperationCount
              ) else { return nil }
        guard operations.allSatisfy(Self.isBounded) else { return nil }
        return LiteralTranscriptPreview(
            elements: remainder.elements.map(Self.mapElement),
            operations: operations
        )
    }

    public func mayContainStreamingCommand(_ transcript: String) -> Bool {
        parser.mayContainStreamingCommand(transcript)
    }

    public func hasIncompleteCommandPrefix(for transcript: String) -> Bool {
        guard Self.isBounded(transcript) else { return false }
        return parser.hasIncompleteCommandPrefix(transcript)
    }

    private static func isBounded(_ value: String) -> Bool {
        VoiceKeyboardTextLimits.isValid(value)
    }

    private static func isBounded(_ operation: TextOperation) -> Bool {
        switch operation {
        case .insertText(let value), .showUnsupportedCommand(let value):
            return isBounded(value)
        case .deleteBackward:
            return true
        }
    }

    private static func mapElement(
        _ element: TranscriptElement
    ) -> LiteralTranscriptElement {
        switch element {
        case .text(let value):
            .text(value)
        case .command(let command):
            .command(mapCommand(command))
        }
    }

    private static func mapCommand(
        _ command: VoiceCommand
    ) -> LiteralTranscriptCommand {
        switch command {
        case .insertText(let value):
            .insertText(value)
        case .deleteWord:
            .deleteWord
        case .deleteSentence:
            .deleteSentence
        case .unsupportedShortcut(let phrase):
            .unsupportedShortcut(phrase)
        }
    }
}
