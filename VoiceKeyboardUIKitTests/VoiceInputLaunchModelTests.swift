@testable import VoiceKeyboardInput
import XCTest

@MainActor
final class VoiceInputLaunchModelTests: XCTestCase {
    func testStartDictationPublishesInjectedProbeResult() async {
        let controller = DictationSessionControllerSpy(startStatus: .microphoneActive(peakPower: -18))
        let model = VoiceInputLaunchModel(sessionController: controller)

        await model.startDictation()

        XCTAssertEqual(model.status, .microphoneActive(peakPower: -18))
        XCTAssertEqual(controller.recordedStartCallCount(), 1)
    }

    func testStartDictationURLStartsDictation() async throws {
        let controller = DictationSessionControllerSpy(startStatus: .microphoneActive(peakPower: -12))
        let model = VoiceInputLaunchModel(sessionController: controller)

        model.handleOpenURL(try XCTUnwrap(URL(string: "voicekeyboard://start-dictation")))
        await waitForStatus(.microphoneActive(peakPower: -12), in: model)

        XCTAssertEqual(controller.recordedStartCallCount(), 1)
    }

    func testPrepareSessionPublishesSessionReady() async {
        let controller = DictationSessionControllerSpy(prepareStatus: .sessionReady)
        let model = VoiceInputLaunchModel(sessionController: controller)

        await model.prepareSession()

        XCTAssertEqual(model.status, .sessionReady)
        XCTAssertEqual(controller.recordedPrepareCallCount(), 1)
    }

    func testStartDictationIgnoresOverlappingActivation() async {
        let controller = SuspendedDictationSessionController()
        let model = VoiceInputLaunchModel(sessionController: controller)

        let firstStart = Task { await model.startDictation() }
        await waitForStatus(.requestingPermission, in: model)

        let secondStart = Task { await model.startDictation() }
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(controller.recordedStartCallCount(), 1)

        controller.finish(with: .microphoneActive(peakPower: -9))
        await firstStart.value
        await secondStart.value
    }

    func testUnknownURLDoesNotStartDictation() async throws {
        let controller = DictationSessionControllerSpy(startStatus: .microphoneActive(peakPower: -12))
        let model = VoiceInputLaunchModel(sessionController: controller)

        model.handleOpenURL(try XCTUnwrap(URL(string: "voicekeyboard://settings")))
        await Task.yield()

        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(controller.recordedStartCallCount(), 0)
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

@MainActor
private final class DictationSessionControllerSpy: DictationSessionControlling {
    private var prepareCallCount = 0
    private var startCallCount = 0
    private let prepareStatus: VoiceInputLaunchStatus
    private let startStatus: VoiceInputLaunchStatus

    init(
        prepareStatus: VoiceInputLaunchStatus = .sessionReady,
        startStatus: VoiceInputLaunchStatus = .microphoneActive(peakPower: nil)
    ) {
        self.prepareStatus = prepareStatus
        self.startStatus = startStatus
    }

    func prepareSession() async -> VoiceInputLaunchStatus {
        prepareCallCount += 1
        return prepareStatus
    }

    func startFromContainingApp() async -> VoiceInputLaunchStatus {
        startCallCount += 1
        return startStatus
    }

    func cancelActiveSession() async {}

    func recordedPrepareCallCount() -> Int {
        prepareCallCount
    }

    func recordedStartCallCount() -> Int {
        startCallCount
    }
}

@MainActor
private final class SuspendedDictationSessionController: DictationSessionControlling {
    private var continuations: [CheckedContinuation<VoiceInputLaunchStatus, Never>] = []
    private var startCallCount = 0

    func prepareSession() async -> VoiceInputLaunchStatus {
        .sessionReady
    }

    func startFromContainingApp() async -> VoiceInputLaunchStatus {
        startCallCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func cancelActiveSession() async {}

    func finish(with status: VoiceInputLaunchStatus) {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume(returning: status) }
    }

    func recordedStartCallCount() -> Int {
        startCallCount
    }
}
