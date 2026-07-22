import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import Foundation
import XCTest

final class KeyboardSpeechCaptureReadinessServiceTests: XCTestCase {
    private let availableCapabilities = RuntimeCapabilities(
        microphoneCaptureAvailable: true,
        speechRecognitionAvailable: true,
        textCleanupAvailable: false
    )
    private let standardDuration = AudioCaptureProbeDuration(seconds: 1)!

    func testCurrentStateNeedsProbeBeforeReportingSpeechUnavailable() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: true,
                speechRecognitionAvailable: false,
                textCleanupAvailable: false
            ))
        )

        let state = await service.currentState()

        XCTAssertEqual(state, .probeNeeded)
    }

    func testCurrentStateReflectsUnavailableMicrophoneCapability() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: false,
                speechRecognitionAvailable: false,
                textCleanupAvailable: false
            ))
        )

        let state = await service.currentState()

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testProbeStateDoesNotProbeWhenCapabilitiesAreUnavailable() async {
        let probe = ProbeSpy(result: .success(AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: standardDuration,
            peakPower: 0.4
        )!))
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: false,
                speechRecognitionAvailable: true,
                textCleanupAvailable: false
            )),
            audioProbe: probe
        )

        let state = await service.probeState(duration: standardDuration)
        let callCount = await probe.callCount()

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
        XCTAssertEqual(callCount, 0)
    }

    func testProbeStateCanProbeBeforeSpeechRecognitionIsAvailable() async {
        let probe = ProbeSpy(result: .success(AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: standardDuration,
            peakPower: 0.4
        )!))
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: RuntimeCapabilities(
                microphoneCaptureAvailable: true,
                speechRecognitionAvailable: false,
                textCleanupAvailable: false
            )),
            audioProbe: probe
        )

        let state = await service.probeState(duration: standardDuration)
        let callCount = await probe.callCount()

        XCTAssertEqual(state, .unavailable(.speechRecognitionUnavailable))
        XCTAssertEqual(callCount, 1)
    }

    func testProbeStateFailsWhenNoProbeIsInjected() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities)
        )

        let state = await service.probeState(duration: standardDuration)

        XCTAssertEqual(state, .probeFailed(.probeUnavailable))
    }

    func testProbeStateReturnsReadyAfterSuccessfulProbe() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: 0.7
            )!))
        )

        let state = await service.probeState(duration: standardDuration)

        XCTAssertEqual(state, .ready)
    }

    func testCurrentStateReflectsLastSuccessfulProbe() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: 0.7
            )!))
        )

        _ = await service.probeState(duration: standardDuration)
        let state = await service.currentState()

        XCTAssertEqual(state, .ready)
    }

    func testProbeStateReturnsUnavailableWhenProbeCannotCaptureMicrophone() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: false,
                duration: standardDuration,
                peakPower: nil
            )!))
        )

        let state = await service.probeState(duration: standardDuration)

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testCurrentStateReflectsFailedProbeResult() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: false,
                duration: standardDuration,
                peakPower: nil
            )!))
        )

        _ = await service.probeState(duration: standardDuration)
        let state = await service.currentState()

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testProbeStateReturnsProbeFailedForProbeError() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .failure(.unavailableInCurrentProcess))
        )

        let state = await service.probeState(duration: standardDuration)

        XCTAssertEqual(state, .probeFailed(.unavailableInCurrentProcess))
    }

    func testProbeStateDoesNotCacheCancellationAsFailure() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .failure(.cancelled))
        )

        let cancelledState = await service.probeState(duration: standardDuration)
        let currentState = await service.currentState()

        XCTAssertEqual(cancelledState, .probeNeeded)
        XCTAssertEqual(currentState, .probeNeeded)
    }

    func testProbeStateDoesNotStartDuplicateProbeWhileProbing() async {
        let duration = standardDuration
        let probe = ReentrantProbe(result: AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: 0.5
        )!)
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: probe
        )
        let firstProbe = Task { [service, duration] in
            await service.probeState(duration: duration)
        }
        await probe.waitForFirstCall()

        let duplicateState = await service.probeState(duration: duration)
        let callCount = await probe.callCount()
        await probe.resumeFirstCall()
        let completedState = await firstProbe.value

        XCTAssertEqual(duplicateState, .probing)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(completedState, .ready)
    }

    func testProbeStateUsesCurrentCapabilitiesAfterSuspendedProbe() async {
        let duration = standardDuration
        let capabilityChecker = MutableCapabilityChecker(capabilities: availableCapabilities)
        let probe = ReentrantProbe(result: AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: 0.5
        )!)
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: capabilityChecker,
            audioProbe: probe
        )
        let probeTask = Task { [service, duration] in
            await service.probeState(duration: duration)
        }
        await probe.waitForFirstCall()

        capabilityChecker.setCapabilities(RuntimeCapabilities(
            microphoneCaptureAvailable: false,
            speechRecognitionAvailable: true,
            textCleanupAvailable: false
        ))
        await probe.resumeFirstCall()
        let state = await probeTask.value

        XCTAssertEqual(state, .unavailable(.microphoneCaptureUnavailable))
    }

    func testProbeStateDoesNotCacheSuccessWhenCapabilitiesBecomeUnavailable() async {
        let duration = standardDuration
        let capabilityChecker = MutableCapabilityChecker(capabilities: availableCapabilities)
        let probe = ReentrantProbe(result: AudioCaptureProbeResult(
            microphoneCaptureAvailable: true,
            duration: duration,
            peakPower: 0.5
        )!)
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: capabilityChecker,
            audioProbe: probe
        )
        let probeTask = Task { [service, duration] in
            await service.probeState(duration: duration)
        }
        await probe.waitForFirstCall()

        capabilityChecker.setCapabilities(RuntimeCapabilities(
            microphoneCaptureAvailable: false,
            speechRecognitionAvailable: true,
            textCleanupAvailable: false
        ))
        await probe.resumeFirstCall()
        _ = await probeTask.value
        capabilityChecker.setCapabilities(availableCapabilities)
        let state = await service.currentState()

        XCTAssertEqual(state, .probeNeeded)
    }

    func testCurrentStateReflectsLastProbeError() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .failure(.unavailableInCurrentProcess))
        )

        _ = await service.probeState(duration: standardDuration)
        let state = await service.currentState()

        XCTAssertEqual(state, .probeFailed(.unavailableInCurrentProcess))
    }

    func testProbeStateRetriesAfterCachedProbeError() async {
        let probe = SequenceProbe(results: [
            .failure(.unavailableInCurrentProcess),
            .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: 0.6
            )!)
        ])
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: probe
        )

        let failedState = await service.probeState(duration: standardDuration)
        let retryState = await service.probeState(duration: standardDuration)
        let callCount = await probe.callCount()

        XCTAssertEqual(failedState, .probeFailed(.unavailableInCurrentProcess))
        XCTAssertEqual(retryState, .ready)
        XCTAssertEqual(callCount, 2)
    }

    func testResetProbeClearsCachedResult() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: 0.7
            )!))
        )

        _ = await service.probeState(duration: standardDuration)
        await service.resetProbe()
        let state = await service.currentState()

        XCTAssertEqual(state, .probeNeeded)
    }

    func testResetProbeClearsCachedError() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .failure(.unavailableInCurrentProcess))
        )

        _ = await service.probeState(duration: standardDuration)
        await service.resetProbe()
        let state = await service.currentState()

        XCTAssertEqual(state, .probeNeeded)
    }

    func testDirectRecognitionReadinessProbesBeforeReportingReady() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: -12
            )!))
        )

        let isReady = await service.directRecognitionIsReady(duration: standardDuration)

        XCTAssertTrue(isReady)
    }

    func testDirectRecognitionReadinessReprobesAfterAPreviouslyReadyRoute() async {
        let probe = SequenceProbe(results: [
            .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: true,
                duration: standardDuration,
                peakPower: -12
            )!),
            .failure(.unavailableInCurrentProcess)
        ])
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: probe
        )

        let firstState = await service.probeState(duration: standardDuration)
        let isReady = await service.directRecognitionIsReady(duration: standardDuration)
        let callCount = await probe.callCount()

        XCTAssertEqual(firstState, .ready)
        XCTAssertFalse(isReady)
        XCTAssertEqual(callCount, 2)
    }

    func testDirectRecognitionReadinessRejectsPermissionOnlyCapabilityWhenProbeFails() async {
        let service = KeyboardSpeechCaptureReadinessService(
            capabilityChecker: CapabilityCheckerSpy(capabilities: availableCapabilities),
            audioProbe: ProbeSpy(result: .success(AudioCaptureProbeResult(
                microphoneCaptureAvailable: false,
                duration: standardDuration,
                peakPower: nil
            )!))
        )

        let isReady = await service.directRecognitionIsReady(duration: standardDuration)

        XCTAssertFalse(isReady)
    }
}

private struct CapabilityCheckerSpy: CapabilityChecking {
    let capabilities: RuntimeCapabilities

    func currentCapabilities() -> RuntimeCapabilities {
        capabilities
    }
}

private final class MutableCapabilityChecker: CapabilityChecking, @unchecked Sendable {
    // NSLock protects mutable test state while satisfying the synchronous CapabilityChecking protocol.
    private let lock = NSLock()
    private var capabilities: RuntimeCapabilities

    init(capabilities: RuntimeCapabilities) {
        self.capabilities = capabilities
    }

    func setCapabilities(_ capabilities: RuntimeCapabilities) {
        lock.withLock {
            self.capabilities = capabilities
        }
    }

    func currentCapabilities() -> RuntimeCapabilities {
        lock.withLock {
            capabilities
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private actor ProbeSpy: AudioCaptureProbing {
    private var calls = 0
    private let result: Result<AudioCaptureProbeResult, AudioCaptureProbeError>

    init(result: Result<AudioCaptureProbeResult, AudioCaptureProbeError>) {
        self.result = result
    }

    func callCount() -> Int {
        calls
    }

    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        calls += 1
        return try result.get()
    }
}

private actor SequenceProbe: AudioCaptureProbing {
    private var calls = 0
    private var results: [Result<AudioCaptureProbeResult, AudioCaptureProbeError>]

    init(results: [Result<AudioCaptureProbeResult, AudioCaptureProbeError>]) {
        self.results = results
    }

    func callCount() -> Int {
        calls
    }

    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        calls += 1
        let result = results.isEmpty ? .failure(.probeUnavailable) : results.removeFirst()
        return try result.get()
    }
}

private actor ReentrantProbe: AudioCaptureProbing {
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallContinuation: CheckedContinuation<AudioCaptureProbeResult, Never>?
    private let result: AudioCaptureProbeResult

    init(result: AudioCaptureProbeResult) {
        self.result = result
    }

    func callCount() -> Int {
        calls
    }

    func waitForFirstCall() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resumeFirstCall() {
        firstCallContinuation?.resume(returning: result)
        firstCallContinuation = nil
    }

    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        calls += 1
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        guard calls == 1 else { return result }
        return await withCheckedContinuation { continuation in
            firstCallContinuation = continuation
        }
    }
}
