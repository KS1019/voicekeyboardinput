public enum VoiceKeyboardTextLimits {
    public static let maximumCharacterCount = 32_768
    public static let maximumUnicodeScalarCount = 65_536
    public static let maximumUTF8ByteCount = 256_000

    public static func isValid(_ value: String) -> Bool {
        value.utf8.prefix(maximumUTF8ByteCount + 1).count <= maximumUTF8ByteCount
            && value.unicodeScalars.prefix(maximumUnicodeScalarCount + 1).count <= maximumUnicodeScalarCount
            && value.prefix(maximumCharacterCount + 1).count <= maximumCharacterCount
    }

    /// Bounds pasted or restored text before `Character` iteration. This is
    /// deliberately scalar-first so a malformed grapheme containing a huge
    /// number of combining marks cannot make a main-actor text field scan the
    /// entire value before applying the limit.
    public static func bounded(_ value: String) -> String {
        let scalarBoundedValue = String(
            value.unicodeScalars.prefix(maximumUnicodeScalarCount)
        )
        var bounded = String()
        var characterCount = 0
        var scalarCount = 0
        var utf8ByteCount = 0

        for character in scalarBoundedValue {
            let nextScalarCount = scalarCount + character.unicodeScalars.count
            let nextUTF8ByteCount = utf8ByteCount + character.utf8.count
            guard characterCount < maximumCharacterCount,
                  nextScalarCount <= maximumUnicodeScalarCount,
                  nextUTF8ByteCount <= maximumUTF8ByteCount else {
                return bounded
            }
            bounded.append(character)
            characterCount += 1
            scalarCount = nextScalarCount
            utf8ByteCount = nextUTF8ByteCount
        }

        return bounded
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
