import Foundation

public struct AudioCaptureProbeDuration: Equatable, Sendable {
    /// Probe duration in seconds.
    public let seconds: Double

    /// Creates a duration from a positive finite number of seconds.
    public init?(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return nil }
        self.seconds = seconds
    }
}

public struct AudioCaptureProbeResult: Equatable, Sendable {
    /// Whether the process observed a usable microphone capture path.
    public let microphoneCaptureAvailable: Bool
    /// Duration requested for the probe.
    public let duration: AudioCaptureProbeDuration
    /// Highest observed input power in decibels, when a signal was measured.
    public let peakPower: Float?

    /// Creates a probe result, rejecting non-finite peak-power values.
    public init?(
        microphoneCaptureAvailable: Bool,
        duration: AudioCaptureProbeDuration,
        peakPower: Float?
    ) {
        guard peakPower?.isFinite != false else { return nil }

        self.microphoneCaptureAvailable = microphoneCaptureAvailable
        self.duration = duration
        self.peakPower = peakPower
    }
}

public enum AudioCaptureProbeError: LocalizedError, Equatable, Sendable {
    case cancelled
    case probeUnavailable
    case unavailableInCurrentProcess

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Audio input probing was cancelled."
        case .probeUnavailable:
            "Audio input probing is unavailable."
        case .unavailableInCurrentProcess:
            "Audio input is unavailable in this process."
        }
    }
}
