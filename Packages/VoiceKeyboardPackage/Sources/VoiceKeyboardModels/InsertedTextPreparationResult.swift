public enum InsertedTextPreparationResult: Equatable, Sendable {
    case insertableText(String, cleanupApplied: Bool)
    case editingOperations([TextOperation])
}
