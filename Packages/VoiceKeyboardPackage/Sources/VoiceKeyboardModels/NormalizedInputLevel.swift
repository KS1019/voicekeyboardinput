public struct NormalizedInputLevel: Equatable, Sendable {
    /// Clamped display value in the `0...1` range.
    public let value: Double

    /// Creates a normalized level from any finite value, clamping it into `0...1`.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.value = min(max(value, 0), 1)
    }
}

extension Optional where Wrapped == Double {
    var normalizedInputLevel: NormalizedInputLevel? {
        guard let self else { return nil }
        return NormalizedInputLevel(self)
    }
}
