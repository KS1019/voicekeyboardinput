public enum VoiceKeyboardTextLimits {
    public static let maximumCharacterCount = 32_768
    public static let maximumUnicodeScalarCount = 65_536
    public static let maximumUTF8ByteCount = 256_000

    public static func isValid(_ value: String) -> Bool {
        value.utf8.prefix(maximumUTF8ByteCount + 1).count <= maximumUTF8ByteCount
            && value.unicodeScalars.prefix(maximumUnicodeScalarCount + 1).count <= maximumUnicodeScalarCount
            && value.prefix(maximumCharacterCount + 1).count <= maximumCharacterCount
    }
}

public struct TextDeletionCount: Equatable, Sendable {
    /// Positive number of backward deletions to perform.
    public let value: Int

    /// Creates a deletion count from a positive integer.
    public init?(_ value: Int) {
        guard value > 0, value <= Self.maximumValue else { return nil }
        self.value = value
    }

    // Shared keyboard delivery expands destructive edits into individual
    // proxy calls and durable progress checkpoints. Keep malformed or
    // unexpectedly large transcripts from monopolizing the extension.
    public static let maximumValue = 256
}

public enum TextOperation: Equatable, Sendable {
    case insertText(String)
    case deleteBackward(count: TextDeletionCount)
    case showUnsupportedCommand(String)
}
