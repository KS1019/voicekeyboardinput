import AVFAudio
import Foundation
import Speech

enum AppSpeechDictationError: LocalizedError {
    case recognizerUnavailable
    case alreadyStarted
    case audioInputUnavailable
    case audioEngineStartFailed
    case emptyTranscript
    case audioInterrupted
    case audioRouteLost
    case audioConfigurationChanged

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is unavailable for the current locale."
        case .alreadyStarted:
            "This speech recognition run has already started."
        case .audioInputUnavailable:
            "Audio input is unavailable in the containing app."
        case .audioEngineStartFailed:
            "Could not start the audio engine for speech recognition."
        case .emptyTranscript:
            "Speech recognition finished without a transcript."
        case .audioInterrupted:
            "Audio input was interrupted."
        case .audioRouteLost:
            "Audio input is no longer available."
        case .audioConfigurationChanged:
            "Audio input changed while recording. Please try again."
        }
    }
}

private final class AudioPreparationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func markChanged() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

enum AppAudioEngineOperationStatus: Sendable {
    case succeeded
    case failed
    case timedOut
}

@MainActor
final class AppSpeechDictationService {
    func transcribe(
        locale: Locale,
        maximumDuration: TimeInterval
    ) async throws -> String {
        let run = AppSpeechDictationRun(locale: locale, maximumDuration: maximumDuration)
        return try await run.start()
    }
}

@MainActor
final class AppSpeechDictationRun {
    private final class AudioTapGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isActive = true
        private var inFlightCallbacks = 0

        @discardableResult
        func invalidate() -> Bool {
            condition.lock()
            isActive = false
            let didDrain = inFlightCallbacks == 0
            condition.unlock()
            return didDrain
        }

        func waitUntilDrained() {
            _ = waitUntilDrained(timeout: nil)
        }

        @discardableResult
        func waitUntilDrained(timeout: TimeInterval?) -> Bool {
            condition.lock()
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while inFlightCallbacks > 0 {
                if let deadline {
                    guard condition.wait(until: deadline) else { break }
                } else {
                    condition.wait()
                }
            }
            let didDrain = inFlightCallbacks == 0
            condition.unlock()
            return didDrain
        }

        func append(
            _ buffer: AVAudioPCMBuffer,
            to request: SFSpeechAudioBufferRecognitionRequest
        ) {
            condition.lock()
            guard isActive else {
                condition.unlock()
                return
            }
            inFlightCallbacks += 1
            condition.unlock()
            defer {
                condition.lock()
                inFlightCallbacks -= 1
                if inFlightCallbacks == 0 {
                    condition.broadcast()
                }
                condition.unlock()
            }
            request.append(buffer)
        }
    }

    private final class DeferredAudioEngineCleanup: @unchecked Sendable {
        private let gate: AudioTapGate?
        private let engine: AVAudioEngine
        private let request: SFSpeechAudioBufferRecognitionRequest?
        private let tapIsInstalled: Bool
        private let engineStartTask: Task<AppAudioEngineOperationStatus, Never>?

        init(
            gate: AudioTapGate?,
            engine: AVAudioEngine,
            request: SFSpeechAudioBufferRecognitionRequest?,
            tapIsInstalled: Bool,
            engineStartTask: Task<AppAudioEngineOperationStatus, Never>?
        ) {
            self.gate = gate
            self.request = request
            self.engine = engine
            self.tapIsInstalled = tapIsInstalled
            self.engineStartTask = engineStartTask
        }

        func waitForCompletion(timeout: TimeInterval) async -> Bool {
            if let engineStartTask,
               await waitForTask(engineStartTask, timeout: timeout) == false {
                return false
            }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    guard gate?.waitUntilDrained(timeout: timeout) ?? true else {
                        continuation.resume(returning: false)
                        return
                    }
                    performTeardown()
                    continuation.resume(returning: true)
                }
            }
        }

        func quarantine() -> Task<Void, Never> {
            Task.detached { [self] in
                if let engineStartTask {
                    _ = await engineStartTask.value
                }
                gate?.waitUntilDrained()
                performTeardown()
            }
        }

        private func waitForTask(
            _ task: Task<AppAudioEngineOperationStatus, Never>,
            timeout: TimeInterval
        ) async -> Bool {
            await withCheckedContinuation { continuation in
                let gate = AudioSessionCompletionGate()
                Task {
                    _ = await task.value
                    guard gate.finish() else { return }
                    continuation.resume(returning: true)
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard gate.finish() else { return }
                    continuation.resume(returning: false)
                }
            }
        }

        private func performTeardown() {
            if tapIsInstalled {
                _ = VKRemoveAudioInputTap(engine.inputNode)
            }
            engine.stop()
            request?.endAudio()
        }
    }

    private final class AudioSessionCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isFinished = false

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }

    private enum AudioSessionOperationError: LocalizedError {
        case timedOut
        case busy
        case terminal

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "Audio session operation timed out."
            case .busy:
                "Audio session is busy with another operation."
            case .terminal:
                "Audio session recovery requires relaunching the containing app."
            }
        }
    }

    private let locale: Locale
    private let maximumDuration: TimeInterval
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingError: Error?
    private var latestTranscript = ""
    private var didFinish = false
    private var didStart = false
    private var tapIsInstalled = false
    private var lingeringAudioEngineStartTask: Task<AppAudioEngineOperationStatus, Never>?
    private var audioTapGate: AudioTapGate?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var isPreparingAudio = false
    private var preparationInvalidated = false
    private let preparationMonitor = AudioPreparationMonitor()
    private var preparationGeneration = 0
    private var preparationInputUID: String?
    private var preparationChannelCount: UInt32 = 0
    private var preparationSampleRate: Double = 0
    private var audioSessionOwnershipToken: UInt64?

    init(locale: Locale, maximumDuration: TimeInterval) {
        self.locale = locale
        self.maximumDuration = maximumDuration
    }

    func start() async throws -> String {
        guard !didStart else {
            throw AppSpeechDictationError.alreadyStarted
        }
        didStart = true
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppSpeechDictationError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        guard let ownershipToken = AppAudioSessionOperationCoordinator.shared.acquireOwnership() else {
            throw AppSpeechDictationError.audioInputUnavailable
        }
        audioSessionOwnershipToken = ownershipToken
        isPreparingAudio = true
        preparationInvalidated = false
        preparationGeneration = preparationMonitor.changeCount
        installAudioSessionObservers()
        do {
            try await setAudioSessionCategory(session)
            try await activateAudioSession(session)
        } catch {
            await cleanup()
            throw error
        }
        guard !Task.isCancelled else {
            await cleanup()
            throw CancellationError()
        }
        do {
            try await AppAudioSessionRouting.selectPreferredInputIfAvailable(session)
            try await AppAudioSessionRouting.waitForStableInput(
                session: session,
                engine: engine
            )
        } catch {
            await cleanup()
            throw AppSpeechDictationError.audioConfigurationChanged
        }

        // Selecting Bluetooth HFP intentionally emits route/engine
        // configuration notifications. Establish the run's baseline only
        // after that transition has settled; otherwise the setup itself is
        // mistaken for a broken input route.
        preparationInvalidated = false
        preparationGeneration = preparationMonitor.changeCount

        if let pendingError {
            await cleanup()
            throw pendingError
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            await cleanup()
            throw AppSpeechDictationError.audioInputUnavailable
        }
        preparationInputUID = session.currentRoute.inputs.first?.uid
        preparationChannelCount = format.channelCount
        preparationSampleRate = format.sampleRate

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let tapGate = AudioTapGate()
        audioTapGate = tapGate

        guard preparationAudioIsStable(session: session) else {
            await cleanup()
            throw AppSpeechDictationError.audioConfigurationChanged
        }

        guard VKInstallAudioInputTap(inputNode, { buffer, _ in
            tapGate.append(buffer, to: request)
        }) else {
            await cleanup()
            throw AppSpeechDictationError.audioConfigurationChanged
        }
        tapIsInstalled = true

        let preparationIsStable: Bool
        do {
            try await prepareAndStartAudioEngine()
            preparationIsStable = preparationAudioIsStable(session: session)
        } catch {
            isPreparingAudio = false
            await cleanup()
            throw AppSpeechDictationError.audioEngineStartFailed
        }

        isPreparingAudio = false
        guard preparationIsStable else {
            await cleanup()
            throw AppSpeechDictationError.audioConfigurationChanged
        }

        if let pendingError {
            await cleanup()
            throw pendingError
        }

        guard !Task.isCancelled else {
            await cleanup()
            throw CancellationError()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if let pendingError {
                    self.pendingError = nil
                    self.complete(.failure(pendingError))
                    return
                }
                guard !Task.isCancelled else {
                    self.complete(.failure(CancellationError()))
                    return
                }
                timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: .seconds(self.maximumDuration))
                    } catch {
                        return
                    }
                    await MainActor.run {
                        self.finishWithLatestTranscript()
                    }
                }
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        self?.handle(result: result, error: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let transcript = result?.bestTranscription.formattedString, !transcript.isEmpty {
            latestTranscript = transcript
        }

        if result?.isFinal == true {
            finishWithLatestTranscript()
            return
        }

        if let error {
            complete(.failure(error))
        }
    }

    private func finishWithLatestTranscript() {
        guard !latestTranscript.isEmpty else {
            complete(.failure(AppSpeechDictationError.emptyTranscript))
            return
        }
        complete(.success(latestTranscript))
    }

    private func complete(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        guard continuation != nil else {
            if case let .failure(error) = result {
                pendingError = error
            }
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        Task { @MainActor in
            await cleanup()
            switch result {
            case let .success(transcript):
                continuation?.resume(returning: transcript)
            case let .failure(error):
                continuation?.resume(throwing: error)
            }
        }
    }

    private func cancel() {
        complete(.failure(CancellationError()))
    }

    private func installAudioSessionObservers() {
        let notificationCenter = NotificationCenter.default
        let preparationMonitor = self.preparationMonitor
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self, preparationMonitor] notification in
            preparationMonitor.markChanged()
            guard let interruptionTypeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue),
                  interruptionType == .began else { return }
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioInterrupted))
            }
        }
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                guard let self else { return }
                if self.isPreparingAudio {
                    // Route changes caused by selecting the preferred HFP
                    // input are expected during setup. The stable baseline
                    // is captured after routing settles.
                    return
                }
                // A Bluetooth HFP disconnect may silently fall back to the
                // built-in microphone. Treat any post-setup route/format UID
                // change as a failed run instead of feeding the old tap format
                // into the recognizer.
                guard !self.preparationAudioIsStable(session: AVAudioSession.sharedInstance()) else {
                    return
                }
                self.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        engineConfigurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                guard let self else { return }
                if self.isPreparingAudio {
                    // AVAudioEngine can report a configuration change while
                    // the selected HFP route is being materialized. The
                    // stable format check below is the setup-time authority.
                    return
                }
                self.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesLostObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
    }

    private func cleanup() async {
        isPreparingAudio = false
        pendingError = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        if let mediaServicesLostObserver {
            NotificationCenter.default.removeObserver(mediaServicesLostObserver)
            self.mediaServicesLostObserver = nil
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
        let session = AVAudioSession.sharedInstance()
        let coordinator = AppAudioSessionOperationCoordinator.shared
        let hasPendingSessionOperation = coordinator.hasPendingSessionOperation
        if hasPendingSessionOperation {
            // A stop racing an in-flight AVAudioSession call must not allow a
            // later run to reuse the shared session before that call settles.
            coordinator.markTerminal()
        }
        let deactivationToken = hasPendingSessionOperation
            ? nil
            : await acquireDeactivationToken()
        let audioTapGate = self.audioTapGate
        audioTapGate?.invalidate()
        self.audioTapGate = nil
        let requestToEnd = self.request
        self.request = nil
        let engineCleanup = DeferredAudioEngineCleanup(
            gate: audioTapGate,
            engine: engine,
            request: requestToEnd,
            tapIsInstalled: tapIsInstalled,
            engineStartTask: lingeringAudioEngineStartTask
        )
        let didCompleteEngineCleanup = await engineCleanup.waitForCompletion(timeout: 2)
        tapIsInstalled = false
        if didCompleteEngineCleanup {
            if coordinator.hasPendingSessionOperation {
                scheduleDeferredAudioSessionDeactivation(session)
                return
            }
            guard let deactivationToken else {
                scheduleDeferredAudioSessionDeactivation(session)
                return
            }
            await deactivateAudioSession(session, operationToken: deactivationToken)
            releaseAudioSessionOwnershipIfSafe()
        } else {
            let quarantineTask = engineCleanup.quarantine()
            Task { @MainActor [self] in
                let didFinishQuarantine = await waitForAudioCleanup(quarantineTask, timeout: 2)
                if !didFinishQuarantine {
                    AppAudioSessionOperationCoordinator.shared.markTerminal()
                    // Do not touch AVAudioSession while AVAudioEngine.start() or a tap
                    // callback is still in flight. The terminal state prevents a new
                    // run from starting; a detached continuation performs cleanup only
                    // after the engine operation has actually quiesced.
                    Task { @MainActor [weak self] in
                        await quarantineTask.value
                        guard let self else { return }
                        if let deactivationToken {
                            await self.deactivateAudioSession(
                                session,
                                operationToken: deactivationToken
                            )
                            self.releaseAudioSessionOwnershipIfSafe()
                        } else {
                            self.scheduleDeferredAudioSessionDeactivation(session)
                        }
                    }
                    return
                }
                if let deactivationToken {
                    await deactivateAudioSession(session, operationToken: deactivationToken)
                    releaseAudioSessionOwnershipIfSafe()
                } else {
                    scheduleDeferredAudioSessionDeactivation(session)
                }
            }
        }
    }

    private func preparationAudioIsStable(session: AVAudioSession) -> Bool {
        guard !preparationInvalidated,
              preparationMonitor.changeCount == preparationGeneration,
              let input = session.currentRoute.inputs.first else {
            return false
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        return input.uid == preparationInputUID
            && format.channelCount == preparationChannelCount
            && format.sampleRate == preparationSampleRate
    }

    private func prepareAndStartAudioEngine() async throws {
        let engine = self.engine
        let operation = Task.detached { () -> AppAudioEngineOperationStatus in
            do {
                engine.prepare()
                try engine.start()
                return .succeeded
            } catch {
                return .failed
            }
        }
        lingeringAudioEngineStartTask = operation
        let status = await withCheckedContinuation { continuation in
            let gate = AudioSessionCompletionGate()
            Task {
                let status = await operation.value
                guard gate.finish() else { return }
                continuation.resume(returning: status)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
        switch status {
        case .succeeded:
            lingeringAudioEngineStartTask = nil
            return
        case .failed:
            lingeringAudioEngineStartTask = nil
            throw AppSpeechDictationError.audioEngineStartFailed
        case .timedOut:
            AppAudioSessionOperationCoordinator.shared.markTerminal()
            throw AppSpeechDictationError.audioEngineStartFailed
        }
    }

    private func setAudioSessionCategory(_ session: AVAudioSession) async throws {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        coordinator.beginSessionOperation()
        let operation = Task.detached { () -> AppAudioEngineOperationStatus in
            defer { coordinator.completeSessionOperation() }
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .measurement,
                    options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
                )
                return .succeeded
            } catch {
                return .failed
            }
        }
        let status = await withCheckedContinuation { continuation in
            let gate = AudioSessionCompletionGate()
            Task {
                let status = await operation.value
                guard gate.finish() else { return }
                continuation.resume(returning: status)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
        switch status {
        case .succeeded:
            return
        case .failed:
            throw AppSpeechDictationError.audioInputUnavailable
        case .timedOut:
            coordinator.markTerminal()
            throw AudioSessionOperationError.timedOut
        }
    }

    private func scheduleDeferredAudioSessionDeactivation(_ session: AVAudioSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await AppAudioSessionOperationCoordinator.shared.waitForPendingSessionOperations(
                timeout: 10
            ) else {
                AppAudioSessionOperationCoordinator.shared.markTerminal()
                return
            }
            for _ in 0..<40 where !Task.isCancelled {
                if AppAudioSessionOperationCoordinator.shared.isTerminal {
                    if let operationToken = AppAudioSessionOperationCoordinator.shared.beginForCleanup() {
                        await self.deactivateAudioSession(session, operationToken: operationToken)
                        self.releaseAudioSessionOwnershipIfSafe()
                    }
                    return
                }
                guard let operationToken = await AppAudioSessionOperationCoordinator.shared.beginWhenAvailable() else {
                    continue
                }
                await self.deactivateAudioSession(session, operationToken: operationToken)
                self.releaseAudioSessionOwnershipIfSafe()
                return
            }
            AppAudioSessionOperationCoordinator.shared.markTerminal()
        }
    }

    private func acquireDeactivationToken() async -> UInt64? {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        if let token = await coordinator.beginWhenAvailable() {
            return token
        }
        return coordinator.isTerminal ? coordinator.beginForCleanup() : nil
    }

    private func releaseAudioSessionOwnershipIfSafe() {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard !coordinator.isTerminal, !coordinator.hasPendingSessionOperation,
              let ownershipToken = audioSessionOwnershipToken else { return }
        coordinator.releaseOwnership(ownershipToken)
        audioSessionOwnershipToken = nil
    }

    private func waitForAudioCleanup(
        _ cleanupTask: Task<Void, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = AudioSessionCompletionGate()
            Task {
                await cleanupTask.value
                guard gate.finish() else { return }
                continuation.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard gate.finish() else { return }
                continuation.resume(returning: false)
            }
        }
    }

    private func activateAudioSession(_ session: AVAudioSession) async throws {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard !coordinator.isTerminal else {
            throw AudioSessionOperationError.terminal
        }
        guard let operationToken = coordinator.begin() else {
            throw AudioSessionOperationError.busy
        }
        if #available(iOS 27.0, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = AudioSessionCompletionGate()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.markTerminal()
                    coordinator.invalidateAndHold(operationToken)
                    scheduleAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume(throwing: AudioSessionOperationError.timedOut)
                }
                coordinator.beginSessionOperation()
                DispatchQueue.global(qos: .userInitiated).async {
                    session.activate(options: []) { activated, error in
                        coordinator.completeSessionOperation()
                        let isCurrent = coordinator.isCurrent(operationToken)
                        let wonCompletion = gate.finish()
                        guard isCurrent && wonCompletion else {
                            if coordinator.recordCallbackDuringFallback(
                                operationToken,
                                succeeded: activated && error == nil
                            ) {
                                return
                            }
                            if activated {
                                if deactivateLateAudioSession(
                                    session,
                                    coordinator: coordinator,
                                    operationToken: operationToken
                                ) { return }
                            }
                            coordinator.finish(operationToken)
                            return
                        }
                        coordinator.finish(operationToken)
                        if let error {
                            continuation.resume(throwing: error)
                        } else if activated {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: AppSpeechDictationError.audioInputUnavailable)
                        }
                    }
                }
            }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = AudioSessionCompletionGate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.markTerminal()
                coordinator.invalidateAndHold(operationToken)
                scheduleAudioSessionQuarantine(
                    session,
                    coordinator: coordinator,
                    operationToken: operationToken
                )
                continuation.resume(throwing: AudioSessionOperationError.timedOut)
            }
            coordinator.beginSessionOperation()
            DispatchQueue.global(qos: .userInitiated).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.completeSessionOperation()
                    if coordinator.recordCallbackDuringFallback(operationToken, succeeded: false) {
                        return
                    }
                    coordinator.finish(operationToken)
                    return
                }
                do {
                    try session.setActive(true)
                    coordinator.completeSessionOperation()
                    let isCurrent = coordinator.isCurrent(operationToken)
                    let wonCompletion = gate.finish()
                    guard isCurrent && wonCompletion else {
                        if coordinator.recordCallbackDuringFallback(operationToken, succeeded: true) {
                            return
                        }
                        if deactivateLateAudioSession(
                            session,
                            coordinator: coordinator,
                            operationToken: operationToken
                        ) { return }
                        coordinator.finish(operationToken)
                        return
                    }
                    coordinator.finish(operationToken)
                    continuation.resume()
                } catch {
                    coordinator.completeSessionOperation()
                    guard coordinator.isCurrent(operationToken), gate.finish() else {
                        if coordinator.recordCallbackDuringFallback(operationToken, succeeded: false) {
                            return
                        }
                        coordinator.finish(operationToken)
                        return
                    }
                    coordinator.finish(operationToken)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func deactivateAudioSession(
        _ session: AVAudioSession,
        operationToken: UInt64
    ) async {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        if #available(iOS 27.0, *) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let gate = AudioSessionCompletionGate()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.markTerminal()
                    coordinator.invalidateAndHold(operationToken)
                    scheduleAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume()
                }
                coordinator.beginSessionOperation()
                DispatchQueue.global(qos: .utility).async {
                    session.deactivate(options: .notifyOthersOnDeactivation) { success, error in
                        coordinator.completeSessionOperation()
                        guard gate.finish() else {
                            if coordinator.recordCallbackDuringFallback(
                                operationToken,
                                succeeded: success && error == nil
                            ) {
                                return
                            }
                            if success && error == nil {
                                coordinator.finish(operationToken)
                            } else {
                                coordinator.invalidateAndHold(operationToken)
                                scheduleAudioSessionQuarantine(
                                    session,
                                    coordinator: coordinator,
                                    operationToken: operationToken
                                )
                            }
                            return
                        }
                        guard success && error == nil else {
                            coordinator.markTerminal()
                            coordinator.invalidateAndHold(operationToken)
                            scheduleAudioSessionQuarantine(
                                session,
                                coordinator: coordinator,
                                operationToken: operationToken
                            )
                            continuation.resume()
                            return
                        }
                        coordinator.finish(operationToken)
                        continuation.resume()
                    }
                }
            }
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = AudioSessionCompletionGate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.markTerminal()
                coordinator.invalidateAndHold(operationToken)
                scheduleAudioSessionQuarantine(
                    session,
                    coordinator: coordinator,
                    operationToken: operationToken
                )
                continuation.resume()
            }
            coordinator.beginSessionOperation()
            DispatchQueue.global(qos: .utility).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.completeSessionOperation()
                    if coordinator.recordCallbackDuringFallback(operationToken, succeeded: false) {
                        return
                    }
                    coordinator.finish(operationToken)
                    return
                }
                var didDeactivate = false
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    didDeactivate = true
                } catch {
                }
                coordinator.completeSessionOperation()
                guard coordinator.isCurrent(operationToken), gate.finish() else {
                    if coordinator.recordCallbackDuringFallback(
                        operationToken,
                        succeeded: didDeactivate
                    ) {
                        return
                    }
                    if didDeactivate {
                        coordinator.finish(operationToken)
                    } else {
                        coordinator.invalidateAndHold(operationToken)
                        scheduleAudioSessionQuarantine(
                            session,
                            coordinator: coordinator,
                            operationToken: operationToken
                        )
                    }
                    return
                }
                guard didDeactivate else {
                    coordinator.markTerminal()
                    coordinator.invalidateAndHold(operationToken)
                    scheduleAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume()
                    return
                }
                coordinator.finish(operationToken)
                continuation.resume()
            }
        }
    }

#if DEBUG
    private var testCompletionReadinessContinuation: CheckedContinuation<Void, Never>?

    static func testRun(maximumDuration: TimeInterval) -> AppSpeechDictationRun {
        AppSpeechDictationRun(locale: Locale(identifier: "en_US"), maximumDuration: maximumDuration)
    }

    func testWaitForCompletion() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let readinessContinuation = testCompletionReadinessContinuation
            testCompletionReadinessContinuation = nil
            readinessContinuation?.resume()
        }
    }

    func testWaitUntilCompletionReady() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { readinessContinuation in
            if continuation != nil {
                readinessContinuation.resume()
            } else {
                testCompletionReadinessContinuation = readinessContinuation
            }
        }
    }

    func testStartTimeout() {
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            await MainActor.run {
                self.finishWithLatestTranscript()
            }
        }
    }

    func testCancelTimeout() {
        timeoutTask?.cancel()
    }

    func testComplete(_ result: Result<String, Error>) {
        complete(result)
    }

    func testCancel() {
        cancel()
    }
#endif
}

private func scheduleAudioSessionQuarantine(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) {
    Task {
        try? await Task.sleep(for: .seconds(2))
        guard await coordinator.waitForPendingSessionOperations(timeout: 10) else {
            coordinator.markTerminalAndRelease(operationToken)
            return
        }
        guard coordinator.beginFallbackDeactivation(operationToken) else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            coordinator.terminateFallbackIfNeeded(operationToken)
        }
        coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            let succeeded: Bool
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                succeeded = true
            } catch {
                succeeded = false
            }
            coordinator.completeSessionOperation()
            coordinator.completeFallbackDeactivation(
                operationToken,
                succeeded: succeeded
            )
            if succeeded {
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    coordinator.terminateIfNeeded(operationToken)
                }
            }
        }
    }
}

@discardableResult
private func deactivateLateAudioSession(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) -> Bool {
    guard coordinator.claimLateDeactivation(operationToken) else { return false }
    if #available(iOS 27.0, *) {
        coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            session.deactivate(options: .notifyOthersOnDeactivation) { success, error in
                coordinator.completeSessionOperation()
                guard success && error == nil else { return }
                if coordinator.recordCallbackDuringLateFallback(
                    operationToken,
                    succeeded: true
                ) {
                    return
                }
                coordinator.finish(operationToken)
            }
        }
    } else {
        coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                coordinator.completeSessionOperation()
                if coordinator.recordCallbackDuringLateFallback(
                    operationToken,
                    succeeded: true
                ) {
                    return
                }
                coordinator.finish(operationToken)
            } catch {
                coordinator.completeSessionOperation()
                // The late-deactivation watchdog owns the remaining recovery.
            }
        }
    }
    scheduleLateDeactivationWatchdog(
        session,
        coordinator: coordinator,
        operationToken: operationToken
    )
    return true
}

private func scheduleLateDeactivationWatchdog(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) {
    Task {
        try? await Task.sleep(for: .seconds(2))
        guard await coordinator.waitForPendingSessionOperations(timeout: 10) else {
            coordinator.terminateOperationIfNeeded(operationToken)
            return
        }
        guard coordinator.beginLateDeactivationFallback(operationToken) else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            coordinator.terminateLateFallbackIfNeeded(operationToken)
        }
        coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            let succeeded: Bool
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                succeeded = true
            } catch {
                succeeded = false
            }
            coordinator.completeSessionOperation()
            coordinator.completeLateDeactivationFallback(operationToken, succeeded: succeeded)
            if succeeded {
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    coordinator.terminateIfNeeded(operationToken)
                }
            }
        }
    }
}

final class AppAudioSessionOperationCoordinator: @unchecked Sendable {
    static let shared = AppAudioSessionOperationCoordinator()

    private let lock = NSLock()
    private var nextToken: UInt64 = 0
    private var currentToken: UInt64?
    private var invalidatedTokens: Set<UInt64> = []
    private var lateDeactivationTokens: Set<UInt64> = []
    private var fallbackDeactivationTokens: Set<UInt64> = []
    private var callbackObservedDuringFallback: Set<UInt64> = []
    private var lateFallbackDeactivationTokens: Set<UInt64> = []
    private var callbackObservedDuringLateFallback: Set<UInt64> = []
    private var retiredTokens: Set<UInt64> = []
    private var terminalTokens: Set<UInt64> = []
    private var isTerminalState = false
    private var pendingSessionOperations = 0
    private var nextOwnerToken: UInt64 = 0
    private var ownerToken: UInt64?

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminalState, currentToken == nil else { return nil }
        nextToken &+= 1
        currentToken = nextToken
        return nextToken
    }

    func beginForCleanup() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == nil else { return nil }
        nextToken &+= 1
        currentToken = nextToken
        return nextToken
    }

    func beginWhenAvailable() async -> UInt64? {
        for _ in 0..<40 {
            if isTerminal {
                return nil
            }
            if let token = begin() {
                return token
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTerminalState
    }

    var hasPendingSessionOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSessionOperations > 0
    }

    func beginSessionOperation() {
        lock.lock()
        pendingSessionOperations += 1
        lock.unlock()
    }

    func completeSessionOperation() {
        lock.lock()
        pendingSessionOperations = max(0, pendingSessionOperations - 1)
        lock.unlock()
    }

    func waitForPendingSessionOperations(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while hasPendingSessionOperation {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func acquireOwnership() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminalState, ownerToken == nil else { return nil }
        nextOwnerToken &+= 1
        ownerToken = nextOwnerToken
        return nextOwnerToken
    }

    func releaseOwnership(_ token: UInt64) {
        lock.lock()
        if ownerToken == token {
            ownerToken = nil
        }
        lock.unlock()
    }

    func markTerminal() {
        lock.lock()
        isTerminalState = true
        lock.unlock()
    }

    func markTerminalAndRelease(_ token: UInt64) {
        lock.lock()
        guard currentToken == token else {
            lock.unlock()
            return
        }
        currentToken = nil
        terminalTokens.insert(token)
        isTerminalState = true
        lock.unlock()
    }

    func terminateOperationIfNeeded(_ token: UInt64) {
        markTerminalAndRelease(token)
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken == token
            && !invalidatedTokens.contains(token)
            && !lateDeactivationTokens.contains(token)
            && !fallbackDeactivationTokens.contains(token)
            && !retiredTokens.contains(token)
    }

    func isHeld(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken == token
            && invalidatedTokens.contains(token)
            && !lateDeactivationTokens.contains(token)
            && !fallbackDeactivationTokens.contains(token)
            && !retiredTokens.contains(token)
    }

    func finish(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            currentToken = nil
        }
        invalidatedTokens.remove(token)
        lateDeactivationTokens.remove(token)
        fallbackDeactivationTokens.remove(token)
        callbackObservedDuringFallback.remove(token)
        lateFallbackDeactivationTokens.remove(token)
        callbackObservedDuringLateFallback.remove(token)
        retiredTokens.remove(token)
        terminalTokens.remove(token)
        lock.unlock()
    }

    func invalidate(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            invalidatedTokens.insert(token)
            lateDeactivationTokens.remove(token)
            fallbackDeactivationTokens.remove(token)
        }
        lock.unlock()
    }

    func invalidateAndHold(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            invalidatedTokens.insert(token)
        }
        lock.unlock()
    }

    func beginFallbackDeactivation(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              invalidatedTokens.contains(token),
              !lateDeactivationTokens.contains(token) else { return false }
        invalidatedTokens.remove(token)
        fallbackDeactivationTokens.insert(token)
        return true
    }

    func completeFallbackDeactivation(_ token: UInt64, succeeded: Bool) {
        lock.lock()
        guard currentToken == token,
              fallbackDeactivationTokens.remove(token) != nil else {
            lock.unlock()
            return
        }
        if callbackObservedDuringFallback.remove(token) != nil {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        } else if succeeded {
            retiredTokens.insert(token)
        } else {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        }
        lock.unlock()
    }

    func recordCallbackDuringFallback(_ token: UInt64, succeeded: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              fallbackDeactivationTokens.contains(token) else { return false }
        if succeeded {
            callbackObservedDuringFallback.insert(token)
        } else {
            fallbackDeactivationTokens.remove(token)
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        }
        return true
    }

    func terminateIfNeeded(_ token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              retiredTokens.contains(token) else { return }
        currentToken = nil
        retiredTokens.remove(token)
        terminalTokens.insert(token)
        isTerminalState = true
    }

    func terminateFallbackIfNeeded(_ token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              fallbackDeactivationTokens.remove(token) != nil else { return }
        callbackObservedDuringFallback.remove(token)
        currentToken = nil
        terminalTokens.insert(token)
        isTerminalState = true
    }

    func beginLateDeactivationFallback(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              lateDeactivationTokens.contains(token) else { return false }
        lateDeactivationTokens.remove(token)
        lateFallbackDeactivationTokens.insert(token)
        return true
    }

    func completeLateDeactivationFallback(_ token: UInt64, succeeded: Bool) {
        lock.lock()
        guard currentToken == token,
              lateFallbackDeactivationTokens.remove(token) != nil else {
            lock.unlock()
            return
        }
        if callbackObservedDuringLateFallback.remove(token) != nil {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        } else if succeeded {
            retiredTokens.insert(token)
        } else {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        }
        lock.unlock()
    }

    func terminateLateFallbackIfNeeded(_ token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              lateFallbackDeactivationTokens.remove(token) != nil else { return }
        callbackObservedDuringLateFallback.remove(token)
        currentToken = nil
        terminalTokens.insert(token)
        isTerminalState = true
    }

    func recordCallbackDuringLateFallback(_ token: UInt64, succeeded: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              lateFallbackDeactivationTokens.contains(token) else { return false }
        if succeeded {
            callbackObservedDuringLateFallback.insert(token)
        } else {
            lateFallbackDeactivationTokens.remove(token)
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
        }
        return true
    }

    func retire(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            invalidatedTokens.remove(token)
            lateDeactivationTokens.remove(token)
            retiredTokens.insert(token)
        }
        lock.unlock()
    }

    func claimLateDeactivation(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (invalidatedTokens.contains(token) || retiredTokens.contains(token) || terminalTokens.contains(token)),
              !lateDeactivationTokens.contains(token),
              !fallbackDeactivationTokens.contains(token),
              !lateFallbackDeactivationTokens.contains(token),
              currentToken == token || terminalTokens.contains(token) else { return false }
        invalidatedTokens.remove(token)
        retiredTokens.remove(token)
        terminalTokens.remove(token)
        lateDeactivationTokens.insert(token)
        currentToken = token
        return true
    }
}
