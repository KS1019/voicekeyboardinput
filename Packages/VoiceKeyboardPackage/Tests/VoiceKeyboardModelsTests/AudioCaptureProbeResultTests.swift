import VoiceKeyboardModels
import XCTest

final class AudioCaptureProbeResultTests: XCTestCase {
    func testProbeResultStoresDiagnosticFields() {
        let result = AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: AudioCaptureProbeDuration(seconds: 1.5)!,
            peakPower: -18.0
        )!

        XCTAssertTrue(result.microphoneCaptureAvailable)
        XCTAssertEqual(result.duration, AudioCaptureProbeDuration(seconds: 1.5))
        XCTAssertEqual(result.peakPower, -18.0)
    }

    func testRejectsNonFinitePeakPower() {
        let duration = AudioCaptureProbeDuration(seconds: 1)!

        XCTAssertNil(AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: .nan
        ))
        XCTAssertNil(AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: .infinity
        ))
        XCTAssertNil(AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: -.infinity
        ))
    }

    func testProbeErrorsExposeReadableDiagnostics() {
        XCTAssertEqual(
            AudioCaptureProbeError.cancelled.localizedDescription,
            "Audio input probing was cancelled."
        )
        XCTAssertEqual(
            AudioCaptureProbeError.probeUnavailable.localizedDescription,
            "Audio input probing is unavailable."
        )
        XCTAssertEqual(
            AudioCaptureProbeError.unavailableInCurrentProcess.localizedDescription,
            "Audio input is unavailable in this process."
        )
    }
}
