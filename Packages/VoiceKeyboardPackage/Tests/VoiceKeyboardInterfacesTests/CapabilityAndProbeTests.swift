import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import XCTest

final class CapabilityAndProbeTests: XCTestCase {
    func testAudioCaptureProbeProtocolAcceptsConcreteImplementation() async throws {
        let duration = AudioCaptureProbeDuration(seconds: 1)!
        let probe = ProbeSpy(result: AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: 0.5
        )!)

        let result = try await runProbe(probe, duration: duration)

        XCTAssertTrue(result.microphoneCaptureAvailable)
        XCTAssertEqual(result.duration, duration)
        XCTAssertEqual(result.peakPower, 0.5)
    }

    func testCapabilityCheckerProtocolAcceptsConcreteImplementation() {
        let checker = CapabilityCheckerSpy(capabilities: RuntimeCapabilities(
            microphoneCaptureAvailable: true,
            speechRecognitionAvailable: true,
            textCleanupAvailable: false
        ))

        let capabilities = currentCapabilities(from: checker)

        XCTAssertTrue(capabilities.microphoneCaptureAvailable)
        XCTAssertTrue(capabilities.speechRecognitionAvailable)
        XCTAssertFalse(capabilities.textCleanupAvailable)
    }

    func testSpeechRecognitionServiceProtocolAcceptsConcreteImplementation() async throws {
        let service = SpeechRecognitionServiceSpy(update: SpeechRecognitionUpdate(
            transcript: "hello",
            isFinal: true,
            inputLevel: 0.25
        ))

        let stream = try await start(service, locale: VoiceKeyboardLocale(identifier: "en-US"))
        var iterator = stream.makeAsyncIterator()
        let update = try await iterator.next()

        XCTAssertEqual(update?.transcript, "hello")
        XCTAssertEqual(update?.isFinal, true)
        XCTAssertEqual(update?.inputLevel, NormalizedInputLevel(0.25))
    }
}

private func runProbe(
    _ probe: any AudioCaptureProbing,
    duration: AudioCaptureProbeDuration
) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
    try await probe.probe(duration: duration)
}

private func currentCapabilities(
    from checker: any CapabilityChecking
) -> RuntimeCapabilities {
    checker.currentCapabilities()
}

private func start(
    _ service: any SpeechRecognitionService,
    locale: VoiceKeyboardLocale
) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
    try await service.start(locale: locale)
}

private struct CapabilityCheckerSpy: CapabilityChecking {
    let capabilities: RuntimeCapabilities

    func currentCapabilities() -> RuntimeCapabilities {
        capabilities
    }
}

private struct ProbeSpy: AudioCaptureProbing {
    let result: AudioCaptureProbeResult

    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        result
    }
}

private actor SpeechRecognitionServiceSpy: SpeechRecognitionService {
    let update: SpeechRecognitionUpdate

    init(update: SpeechRecognitionUpdate) {
        self.update = update
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        let update = update
        return AsyncThrowingStream { continuation in
            continuation.yield(update)
            continuation.finish()
        }
    }

    func stop() async {}
}
