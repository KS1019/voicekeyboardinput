@testable import VoiceKeyboardInput
import VoiceKeyboardModels
import VoiceKeyboardSharedStorage
import XCTest

typealias SharedDictationSessionStore = VoiceKeyboardInput.SharedDictationSessionStoreForTesting

@MainActor
final class VoiceInputLaunchModelTests: XCTestCase {
    func testTimedOutAudioOperationRetainsOwnershipUntilLateDeactivation() {
        let coordinator = AppAudioSessionOperationCoordinator()
        guard let token = coordinator.begin() else {
            return XCTFail("Expected the coordinator to grant the first token")
        }

        coordinator.invalidateAndHold(token)

        XCTAssertNil(coordinator.begin())
        XCTAssertTrue(coordinator.claimLateDeactivation(token))
        coordinator.finish(token)
        let nextToken = coordinator.begin()
        XCTAssertNotNil(nextToken)
        if let nextToken {
            coordinator.finish(nextToken)
        }
    }

    func testRetiredAudioOperationStillBlocksNewActivationUntilLateCallback() {
        let coordinator = AppAudioSessionOperationCoordinator()
        guard let token = coordinator.begin() else {
            return XCTFail("Expected the coordinator to grant the first token")
        }

        coordinator.invalidateAndHold(token)
        coordinator.retire(token)

        XCTAssertNil(coordinator.begin())
        XCTAssertTrue(coordinator.claimLateDeactivation(token))
        coordinator.finish(token)
        let nextToken = coordinator.begin()
        XCTAssertNotNil(nextToken)
        if let nextToken {
            coordinator.finish(nextToken)
        }
    }

    func testLateSessionOperationCompletionDoesNotClearTerminalQuarantine() {
        let coordinator = AppAudioSessionOperationCoordinator()
        guard let token = coordinator.begin() else {
            return XCTFail("Expected the coordinator to grant the first token")
        }

        coordinator.beginSessionOperation()
        coordinator.markTerminal()
        coordinator.completeSessionOperation()

        XCTAssertTrue(coordinator.isTerminal)
        XCTAssertNil(coordinator.begin())

        coordinator.finish(token)
        XCTAssertFalse(coordinator.isTerminal)
    }

    func testFinishedAudioOperationCanReleaseAWatchdogQuarantine() {
        let coordinator = AppAudioSessionOperationCoordinator()
        guard let token = coordinator.begin() else {
            return XCTFail("Expected the coordinator to grant the first token")
        }

        XCTAssertTrue(coordinator.beginDeactivationPending(for: token))
        coordinator.finish(token)
        coordinator.completeDeactivationPendingIfOperationFinished(token)

        let nextToken = coordinator.begin()
        XCTAssertNotNil(nextToken)
        if let nextToken {
            coordinator.finish(nextToken)
        }
    }

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

    func testKeyboardSessionURLUsesTheExistingSessionHandoff() async throws {
        let controller = DictationSessionControllerSpy(startStatus: .transcriptShared("hello"))
        let model = VoiceInputLaunchModel(sessionController: controller)

        model.handleOpenURL(try XCTUnwrap(URL(string: "voicekeyboard://start-dictation?sessionID=keyboard-1")))
        await waitForStatus(.transcriptShared("hello"), in: model)

        XCTAssertEqual(controller.recordedKeyboardSessionStartCallCount(), 1)
        XCTAssertEqual(controller.recordedStartCallCount(), 0)
    }

    func testPrepareSessionPublishesSessionReady() async {
        let controller = DictationSessionControllerSpy(prepareStatus: .sessionReady)
        let model = VoiceInputLaunchModel(sessionController: controller)

        await model.prepareSession()

        XCTAssertEqual(model.status, .sessionReady)
        XCTAssertEqual(controller.recordedPrepareCallCount(), 1)
    }

    func testConcurrentPreparationDoesNotOverwriteStartStatus() async {
        let controller = SuspendedPreparationDictationSessionController()
        let model = VoiceInputLaunchModel(sessionController: controller)

        let prepareTask = Task { await model.prepareSession() }
        for _ in 0..<20 where controller.recordedPrepareCallCount() == 0 {
            await Task.yield()
        }
        let startTask = Task { await model.startDictation() }
        controller.finishPreparation()

        _ = await prepareTask.value
        await startTask.value

        XCTAssertEqual(model.status, .microphoneActive(peakPower: -10))
        XCTAssertEqual(controller.recordedPrepareCallCount(), 1)
        XCTAssertEqual(controller.recordedStartCallCount(), 1)
    }

    func testPreparedAppSessionConsumesSharedStartCommand() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = MicrophoneActivatorSpy(status: .transcriptShared("hello"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        let prepareStatus = await controller.prepareSession()
        let startCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(startCommand)

        await waitForStartCall(in: activator)

        XCTAssertEqual(prepareStatus, .sessionReady)
        XCTAssertEqual(activator.recordedCallCount(), 1)
        if case .transcriptReady = store.status() {
        } else {
            XCTFail("Expected transcriptReady status, got \(store.status())")
        }
    }

    func testColdKeyboardSessionStartClaimsTheExactExistingCommand() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = MicrophoneActivatorSpy(status: .transcriptShared("cold hello"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )
        let command = SharedDictationSessionCommand.start(source: .keyboard)
        store.saveCommand(command)

        let result = await controller.startFromKeyboardSession(sessionID: command.sessionID)

        XCTAssertEqual(result, .transcriptShared("cold hello"))
        XCTAssertEqual(activator.recordedCallCount(), 1)
        XCTAssertEqual(store.status(), .transcriptReady(token: command.token))
    }

    func testPreparedAppSessionPublishesRecordingStatusWhileStartCommandRuns() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = SuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(startCommand)

        await waitForSessionStatus(in: store) { status in
            if case .recording = status { return true }
            return false
        }

        XCTAssertEqual(activator.recordedCallCount(), 1)
        activator.finish(with: .transcriptShared("hello"))
    }

    func testPrepareSessionCancelsPendingCommandFromPreviousProcess() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = MicrophoneActivatorSpy(status: .transcriptShared("unexpected"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )
        let staleCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date().addingTimeInterval(-20)
        )
        store.saveCommand(staleCommand)

        let result = await controller.prepareSession()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(result, .sessionReady)
        XCTAssertEqual(activator.recordedCallCount(), 0)
        XCTAssertEqual(store.status(), .cancelled(token: staleCommand.token))
    }

    func testPrepareSessionFailsClosedWhenTranscriptStoreIsUnavailable() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let staleCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date().addingTimeInterval(-20)
        )
        store.saveCommand(staleCommand)
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: MicrophoneActivatorSpy(status: .transcriptShared("unexpected")),
            sessionStoreProvider: { store },
            transcriptStoreProvider: { nil }
        )

        let result = await controller.prepareSession()

        XCTAssertEqual(result, .failed("Shared App Group storage is unavailable."))
        XCTAssertEqual(store.status(), .idle)
    }

    func testPrepareSessionRecoversFreshCommandWhenStatusWriteWasInterrupted() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = MicrophoneActivatorSpy(status: .transcriptShared("recovered"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )
        let command = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(command)
        store.saveStatus(.idle)

        _ = await controller.prepareSession()
        await waitForStartCall(in: activator)

        XCTAssertEqual(activator.recordedCallCount(), 1)
        XCTAssertEqual(store.status(), .transcriptReady(token: command.token))
    }

    func testPrepareSessionPromotesPersistedTranscriptWhenStatusWriteWasInterrupted() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = SharedDictationTranscriptStore(defaults: defaults)
        let command = SharedDictationSessionCommand.start(source: .keyboard)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: command.sessionID,
            commandToken: command.token,
            text: "persisted before status",
            createdAt: Date()
        ))
        store.saveCommand(command)
        store.saveStatus(.recording(
            token: command.token,
            startedAt: Date(),
            timeoutSeconds: 8
        ))
        transcriptStore.save(transcript)

        let activator = MicrophoneActivatorSpy(status: .transcriptShared("must not restart"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(activator.recordedCallCount(), 0)
        XCTAssertEqual(store.status(), .transcriptReady(token: command.token))
    }

    func testStopCommandCancelsPendingStartBeforeAppClaimsIt() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = MicrophoneActivatorSpy(status: .transcriptShared("unexpected"))
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startCommand = SharedDictationSessionCommand.start(source: .keyboard)
        store.saveCommand(startCommand)
        let stopCommand = SharedDictationSessionCommand.stop(
            sessionID: startCommand.sessionID,
            source: .keyboard
        )
        store.saveCommand(stopCommand)

        await waitForSessionStatus(in: store) { status in
            status == .cancelled(token: stopCommand.token)
        }

        XCTAssertEqual(activator.recordedCallCount(), 0)
    }

    func testPrepareSessionClaimsStopCommandAfterRestart() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let oldStart = SharedDictationSessionCommand.start(source: .keyboard)
        let stop = SharedDictationSessionCommand.stop(
            sessionID: oldStart.sessionID,
            source: .keyboard
        )
        store.saveStatus(.recording(
            token: oldStart.token,
            startedAt: Date().addingTimeInterval(-1),
            timeoutSeconds: 8
        ))
        store.saveCommand(stop)

        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: MicrophoneActivatorSpy(status: .transcriptShared("unexpected")),
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        await waitForSessionStatus(in: store) { status in
            status == .cancelled(token: stop.token)
        }
    }

    func testContainingAppStartIsNotReprocessedByKeyboardCommandMonitor() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = SuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startTask = Task { await controller.startFromContainingApp() }
        await waitForStartCall(in: activator)
        try await Task.sleep(for: .milliseconds(350))

        if case .recording = store.status() {
        } else {
            XCTFail("Containing-app recording was overwritten by command monitoring: \(store.status())")
        }

        activator.finish(with: .transcriptShared("hello"))
        let result = await startTask.value
        XCTAssertEqual(result, .transcriptShared("hello"))
    }

    func testPreparedAppSessionCancelsActiveStartWhenStopCommandArrives() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = CancellableSuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(startCommand)
        await waitForSessionStatus(in: store) { status in
            if case .recording = status { return true }
            return false
        }

        store.saveCommand(SharedDictationSessionCommand.stop(
            sessionID: startCommand.sessionID,
            source: .keyboard,
            requestedAt: Date()
        ))

        await waitForSessionStatus(in: store) { status in
            if case .cancelled = status { return true }
            return false
        }

        await waitForCancellation(in: activator)
        XCTAssertEqual(activator.recordedCancellationCount(), 1)
    }

    func testActiveStopPromotesTranscriptFinalizedByStoppableActivator() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = StoppableTranscriptMicrophoneActivator(transcriptStore: transcriptStore)
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(startCommand)
        await waitForSessionStatus(in: store) { status in
            if case .recording(token: startCommand.token, _, _) = status { return true }
            return false
        }

        let stopCommand = SharedDictationSessionCommand.stop(
            sessionID: startCommand.sessionID,
            source: .keyboard,
            requestedAt: Date(),
            replacingCommandToken: startCommand.token
        )
        XCTAssertTrue(store.saveCommand(stopCommand))

        await waitForSessionStatus(in: store) { status in
            status == .cancelled(token: stopCommand.token)
        }

        XCTAssertEqual(
            store.status(forCommandToken: startCommand.token),
            .transcriptReady(token: startCommand.token)
        )
        let transcript = try XCTUnwrap(
            transcriptStore.latestTranscript(forSessionID: startCommand.sessionID)
        )
        XCTAssertEqual(transcript.commandToken, startCommand.token)
        XCTAssertEqual(transcript.text, "final words")
        XCTAssertFalse(transcript.isConsumed)
    }

    func testContainingAppStartIsCancelledBySessionCancellation() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = CancellableSuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let startTask = Task { await controller.startFromContainingApp() }
        await waitForStartCall(in: activator)

        await controller.cancelActiveSession()
        await waitForCancellation(in: activator)

        let result = await startTask.value
        XCTAssertEqual(result, .failed("Cancelled"))
    }

    func testCancelledStartCannotClearNewerStartState() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = NonCooperativeSuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        let firstCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(firstCommand)
        await waitForStartCall(in: activator, expectedCount: 1)

        store.saveCommand(SharedDictationSessionCommand.stop(
            sessionID: firstCommand.sessionID,
            source: .keyboard,
            requestedAt: Date()
        ))
        await waitForSessionStatus(in: store) { status in
            if case .cancelled = status { return true }
            return false
        }
        activator.finish(at: 0, with: .failed("Cancelled"))

        let secondCommand = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        store.saveCommand(secondCommand)
        await waitForStartCall(in: activator, expectedCount: 2)

        activator.finish(at: 1, with: .transcriptShared("newer"))

        await waitForSessionStatus(in: store) { status in
            if case .transcriptReady(token: secondCommand.token) = status { return true }
            return false
        }
    }

    func testManualStartDoesNotOverlapActiveSharedStartCommand() async throws {
        let suiteName = "VoiceInputLaunchModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SharedDictationSessionStore(defaults: defaults)
        let transcriptStore = try makeTranscriptStore()
        let activator = SuspendedMicrophoneActivator()
        let controller = AppBackgroundDictationSessionController(
            microphoneActivator: activator,
            sessionStoreProvider: { store },
            transcriptStoreProvider: { transcriptStore }
        )

        _ = await controller.prepareSession()
        store.saveCommand(SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        ))
        await waitForStartCall(in: activator)

        let manualStart = Task { await controller.startFromContainingApp() }
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(activator.recordedCallCount(), 1)

        activator.finish(with: .transcriptShared("hello"))
        let manualResult = await manualStart.value
        XCTAssertEqual(manualResult, .failed("Voice input is already in progress."))
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

    func testDictationRunCancellingTimeoutDoesNotCompleteLater() async throws {
        let run = AppSpeechDictationRun.testRun(maximumDuration: 0.02)
        let waitingTask = Task { try await run.testWaitForCompletion() }

        await run.testWaitUntilCompletionReady()
        run.testStartTimeout()
        run.testCancelTimeout()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(waitingTask.isCancelled)
        run.testComplete(.success("late-safe"))
        let result = try await waitingTask.value
        XCTAssertEqual(result, "late-safe")
    }

    func testDictationRunLateFinalCallbackAfterCancellationCompletesAtMostOnce() async throws {
        let run = AppSpeechDictationRun.testRun(maximumDuration: 1)
        let waitingTask = Task { try await run.testWaitForCompletion() }

        await run.testWaitUntilCompletionReady()
        run.testCancel()
        run.testComplete(.success("late-final"))

        do {
            _ = try await waitingTask.value
            XCTFail("Cancellation should win over the late final callback")
        } catch is CancellationError {
            // Expected.
        }
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

    private func waitForStartCall(
        in activator: MicrophoneActivatorSpy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where activator.recordedCallCount() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activator.recordedCallCount(), 1, file: file, line: line)
    }

    private func waitForStartCall(
        in activator: SuspendedMicrophoneActivator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where activator.recordedCallCount() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activator.recordedCallCount(), 1, file: file, line: line)
    }

    private func waitForStartCall(
        in activator: CancellableSuspendedMicrophoneActivator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where activator.recordedCallCount() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activator.recordedCallCount(), 1, file: file, line: line)
    }

    private func waitForStartCall(
        in activator: NonCooperativeSuspendedMicrophoneActivator,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where activator.recordedCallCount() < expectedCount {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activator.recordedCallCount(), expectedCount, file: file, line: line)
    }

    private func waitForSessionStatus(
        in store: SharedDictationSessionStore,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (SharedDictationSessionStatus?) -> Bool
    ) async {
        for _ in 0..<20 where !matches(store.status()) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(matches(store.status()), "Unexpected status: \(String(describing: store.status()))", file: file, line: line)
    }

    private func waitForCancellation(
        in activator: CancellableSuspendedMicrophoneActivator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where activator.recordedCancellationCount() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activator.recordedCancellationCount(), 1, file: file, line: line)
    }

    private func makeTranscriptStore() throws -> SharedDictationTranscriptStore {
        let suiteName = "VoiceInputLaunchModelTests.TranscriptStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return SharedDictationTranscriptStore(defaults: defaults)
    }
}

@MainActor
private final class MicrophoneActivatorSpy: MicrophoneActivating {
    private var callCount = 0
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

@MainActor
private final class SuspendedMicrophoneActivator: MicrophoneActivating {
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

@MainActor
private final class CancellableSuspendedMicrophoneActivator: MicrophoneActivating {
    private var continuations: [CheckedContinuation<VoiceInputLaunchStatus, Never>] = []
    private var callCount = 0
    private var cancellationCount = 0

    func activate() async -> VoiceInputLaunchStatus {
        callCount += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancellationCount += 1
                self.finish(with: .failed("Cancelled"))
            }
        }
    }

    func finish(with status: VoiceInputLaunchStatus) {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume(returning: status) }
    }

    func recordedCancellationCount() -> Int {
        cancellationCount
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

@MainActor
private final class StoppableTranscriptMicrophoneActivator: MicrophoneActivating, StoppableSessionAwareMicrophoneActivating {
    private let transcriptStore: SharedDictationTranscriptStore
    private var continuation: CheckedContinuation<VoiceInputLaunchStatus, Never>?

    init(transcriptStore: SharedDictationTranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func activate() async -> VoiceInputLaunchStatus {
        await activate(
            sessionID: UUID().uuidString,
            commandToken: UUID().uuidString,
            ownerToken: ""
        )
    }

    func activate(
        sessionID: String,
        commandToken: String,
        ownerToken: String
    ) async -> VoiceInputLaunchStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop(sessionID: String, commandToken: String) async {
        guard let transcript = SharedDictationTranscript(
            sessionID: sessionID,
            commandToken: commandToken,
            text: "final words"
        ) else {
            continuation?.resume(returning: .failed("Could not create transcript"))
            continuation = nil
            return
        }
        XCTAssertTrue(transcriptStore.save(transcript))
        continuation?.resume(returning: .transcriptShared(transcript.text))
        continuation = nil
    }
}

@MainActor
private final class NonCooperativeSuspendedMicrophoneActivator: MicrophoneActivating {
    private var continuations: [CheckedContinuation<VoiceInputLaunchStatus, Never>?] = []
    private var callCount = 0

    func activate() async -> VoiceInputLaunchStatus {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finish(at index: Int, with status: VoiceInputLaunchStatus) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: status)
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

@MainActor
private final class DictationSessionControllerSpy: DictationSessionControlling {
    private var prepareCallCount = 0
    private var startCallCount = 0
    private var keyboardSessionStartCallCount = 0
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

    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus {
        keyboardSessionStartCallCount += 1
        return startStatus
    }

    func setAppAvailable(_ isAvailable: Bool) {}

    func cancelActiveSession() async {}

    func recordedPrepareCallCount() -> Int {
        prepareCallCount
    }

    func recordedStartCallCount() -> Int {
        startCallCount
    }

    func recordedKeyboardSessionStartCallCount() -> Int {
        keyboardSessionStartCallCount
    }
}

@MainActor
private final class SuspendedPreparationDictationSessionController: DictationSessionControlling {
    private var preparationContinuation: CheckedContinuation<VoiceInputLaunchStatus, Never>?
    private var prepareCallCount = 0
    private var startCallCount = 0

    func prepareSession() async -> VoiceInputLaunchStatus {
        prepareCallCount += 1
        return await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func startFromContainingApp() async -> VoiceInputLaunchStatus {
        startCallCount += 1
        return .microphoneActive(peakPower: -10)
    }

    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus {
        startCallCount += 1
        return .microphoneActive(peakPower: -10)
    }

    func setAppAvailable(_ isAvailable: Bool) {}

    func cancelActiveSession() async {}

    func finishPreparation() {
        preparationContinuation?.resume(returning: .sessionReady)
        preparationContinuation = nil
    }

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

    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus {
        startCallCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func setAppAvailable(_ isAvailable: Bool) {}

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
