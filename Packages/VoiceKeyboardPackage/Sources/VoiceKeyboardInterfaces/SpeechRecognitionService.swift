import VoiceKeyboardModels

/// A stream of partial and final speech-recognition updates.
public typealias SpeechRecognitionUpdateStream = AsyncThrowingStream<SpeechRecognitionUpdate, Error>

/// Converts live speech input into recognized text updates.
public protocol SpeechRecognitionService: Sendable {
    /// Starts recognition for the requested locale.
    ///
    /// The returned stream should emit interim updates when available and a
    /// final update before completion. Starting recognition may activate audio
    /// capture depending on the concrete platform adapter. `SpeechRecognitionError`
    /// covers start-time availability failures; the stream may fail with adapter-specific errors.
    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream

    /// Stops any active recognition session and releases related resources.
    func stop() async
}
