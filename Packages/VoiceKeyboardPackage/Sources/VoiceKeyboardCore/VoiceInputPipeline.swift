import VoiceKeyboardCommandPipeline
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

public struct VoiceInputPipeline: Sendable {
    private let commandPipeline: LiteralTranscriptCommandPipeline
    private let cleanupService: (any TextCleanupService)?
    private let locale: VoiceKeyboardLocale

    public init(
        locale: VoiceKeyboardLocale,
        cleanupService: (any TextCleanupService)? = nil
    ) {
        self.locale = locale
        self.commandPipeline = LiteralTranscriptCommandPipeline(locale: locale)
        self.cleanupService = cleanupService
    }

    public func operations(
        for transcript: String,
        documentContextBeforeInput: String?,
        locale: VoiceKeyboardLocale? = nil
    ) -> [TextOperation] {
        let commandPipeline = locale.map(LiteralTranscriptCommandPipeline.init(locale:)) ?? self.commandPipeline
        return commandPipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContextBeforeInput
        ).operations
    }

    public func hasIncompleteCommandPrefix(
        for transcript: String,
        locale: VoiceKeyboardLocale? = nil
    ) -> Bool {
        let commandPipeline = locale.map { LiteralTranscriptCommandPipeline(locale: $0) } ?? self.commandPipeline
        return commandPipeline.hasIncompleteCommandPrefix(for: transcript)
    }

    /// Prepares insertable text for a transcript that contains only insertion operations.
    ///
    /// Transcripts that include delete or unsupported-command operations return `.editingOperations`
    /// so the caller can apply them directly. Pure insertion transcripts require a cleanup service;
    /// otherwise this throws `VoiceInputPipelineError.textCleanupServiceRequired`.
    public func prepareInsertedText(
        for transcript: String,
        documentContextBeforeInput: String?
    ) async throws -> InsertedTextPreparationResult {
        let operations = operations(
            for: transcript,
            documentContextBeforeInput: documentContextBeforeInput
        )

        var insertedText = ""
        for operation in operations {
            switch operation {
            case .insertText(let value):
                insertedText.append(value)
            case .deleteBackward, .showUnsupportedCommand:
                return .editingOperations(operations)
            }
        }

        guard let cleanupService else { throw VoiceInputPipelineError.textCleanupServiceRequired }

        let cleanedText = try await cleanupService.cleanedText(from: insertedText, locale: locale)
        return .insertableText(
            restoreBoundaryWhitespace(from: insertedText, to: cleanedText),
            cleanupApplied: true
        )
    }

    private func restoreBoundaryWhitespace(from original: String, to cleaned: String) -> String {
        guard !cleaned.isEmpty else {
            return original.allSatisfy(\.isWhitespace) ? original : cleaned
        }

        let leadingWhitespace = original.prefix { $0.isWhitespace }
        let trailingWhitespace = original.reversed().prefix { $0.isWhitespace }.reversed()
        let cleanedCore = cleaned.trimmingWhitespace()
        guard !cleanedCore.isEmpty else { return cleanedCore }

        return String(leadingWhitespace) + cleanedCore + String(trailingWhitespace)
    }
}

public enum VoiceInputPipelineError: Error, Equatable, Sendable {
    case textCleanupServiceRequired
}

private extension String {
    func trimmingWhitespace() -> String {
        let withoutLeading = drop(while: \.isWhitespace)
        let withoutTrailing = withoutLeading.reversed().drop(while: \.isWhitespace).reversed()
        return String(withoutTrailing)
    }
}
