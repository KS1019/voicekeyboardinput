import VoiceKeyboardModels

public struct CommandPreviewPresentationSnapshot: Equatable, Sendable {
    public static let empty = CommandPreviewPresentationSnapshot(operations: [])

    public let displayText: String

    public init(operations: [TextOperation]) {
        let lines = operations.map(Self.line(for:))
        self.displayText = lines.isEmpty
            ? "Command operations appear here."
            : lines.joined(separator: "\n")
    }

    private static func line(for operation: TextOperation) -> String {
        switch operation {
        case .insertText(let text):
            "insert \(String(reflecting: text))"
        case .deleteBackward(let count):
            "delete \(count.value)"
        case .showUnsupportedCommand(let phrase):
            "unsupported \(String(reflecting: phrase))"
        }
    }
}
