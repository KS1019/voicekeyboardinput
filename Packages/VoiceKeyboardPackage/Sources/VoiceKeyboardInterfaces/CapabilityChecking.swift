import VoiceKeyboardModels

/// Reports runtime capabilities required by voice input.
public protocol CapabilityChecking: Sendable {
    /// Returns the latest known capability state.
    ///
    /// This check should describe permissions and platform availability without
    /// starting microphone capture or speech recognition work.
    func currentCapabilities() -> RuntimeCapabilities
}
