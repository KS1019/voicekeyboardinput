@testable import VoiceKeyboardInput
import XCTest

@MainActor
final class VoiceInputLaunchModelTests: XCTestCase {
    func testStartDictationPublishesInjectedProbeResult() async {
        let activator = MicrophoneActivatorSpy(status: .microphoneActive(peakPower: -18))
        let model = VoiceInputLaunchModel(microphoneActivator: activator)

        await model.startDictation()

        XCTAssertEqual(model.status, .microphoneActive(peakPower: -18))
        let callCount = await activator.recordedCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testStartDictationURLStartsDictation() async throws {
        let activator = MicrophoneActivatorSpy(status: .microphoneActive(peakPower: -12))
        let model = VoiceInputLaunchModel(microphoneActivator: activator)

        model.handleOpenURL(try XCTUnwrap(URL(string: "voicekeyboard://start-dictation")))
        await waitForStatus(.microphoneActive(peakPower: -12), in: model)

        let callCount = await activator.recordedCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testStartDictationIgnoresOverlappingActivation() async {
        let activator = SuspendedMicrophoneActivator()
        let model = VoiceInputLaunchModel(microphoneActivator: activator)

        let firstStart = Task { await model.startDictation() }
        await waitForStatus(.requestingPermission, in: model)

        let secondStart = Task { await model.startDictation() }
        for _ in 0..<10 {
            await Task.yield()
        }

        let callCount = await activator.recordedCallCount()
        XCTAssertEqual(callCount, 1)

        await activator.finish(with: .microphoneActive(peakPower: -9))
        await firstStart.value
        await secondStart.value
    }

    func testUnknownURLDoesNotStartDictation() async throws {
        let activator = MicrophoneActivatorSpy(status: .microphoneActive(peakPower: -12))
        let model = VoiceInputLaunchModel(microphoneActivator: activator)

        model.handleOpenURL(try XCTUnwrap(URL(string: "voicekeyboard://settings")))
        await Task.yield()

        XCTAssertEqual(model.status, .idle)
        let callCount = await activator.recordedCallCount()
        XCTAssertEqual(callCount, 0)
    }

    private func waitForStatus(
        _ status: VoiceInputLaunchStatus,
        in model: VoiceInputLaunchModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10 where model.status != status {
            await Task.yield()
        }
        XCTAssertEqual(model.status, status, file: file, line: line)
    }
}

private actor MicrophoneActivatorSpy: MicrophoneActivating {
    private(set) var callCount = 0
    private let status: VoiceInputLaunchStatus

    init(status: VoiceInputLaunchStatus) {
        self.status = status
    }

    func activate() async -> VoiceInputLaunchStatus {
        callCount += 1
        return status
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

private actor SuspendedMicrophoneActivator: MicrophoneActivating {
    private var continuations: [CheckedContinuation<VoiceInputLaunchStatus, Never>] = []
    private var callCount = 0

    func activate() async -> VoiceInputLaunchStatus {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finish(with status: VoiceInputLaunchStatus) {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume(returning: status) }
    }

    func recordedCallCount() -> Int {
        callCount
    }
}
