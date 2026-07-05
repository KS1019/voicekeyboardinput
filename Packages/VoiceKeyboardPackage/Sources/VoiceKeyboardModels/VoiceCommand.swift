public struct TextDeletionCount: Equatable, Sendable {
    /// Positive number of backward deletions to perform.
    public let value: Int

    /// Creates a deletion count from a positive integer.
    public init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }
}

public enum TextOperation: Equatable, Sendable {
    case insertText(String)
    case deleteBackward(count: TextDeletionCount)
    case showUnsupportedCommand(String)
}
