import VoiceKeyboardModels

/// Measures whether the current process can capture microphone input.
public protocol AudioCaptureProbing: Sendable {
    /// Runs a short audio-capture probe and returns microphone availability plus probe metadata.
    ///
    /// Implementations should keep the probe brief because keyboard extensions
    /// have tighter memory and lifetime constraints than containing apps.
    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult
}
