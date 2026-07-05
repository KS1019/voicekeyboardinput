import VoiceKeyboardModels

/// Refines recognized text before insertion.
public protocol TextCleanupService: Sendable {
    /// Returns text adjusted for the target locale.
    ///
    /// Implementations may normalize punctuation, whitespace, casing, or style,
    /// but should preserve the user's intended content.
    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String
}
