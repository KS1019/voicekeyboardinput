import AVFAudio
import Foundation
import Speech
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

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

enum AudioSessionOperationStatus: Sendable {
    case succeeded
    case failed
    case timedOut
}

final class DeferredAudioSessionOperation: @unchecked Sendable {
    let task: Task<AudioSessionOperationStatus, Never>

    init(session: AVAudioSession, activate: Bool) {
        let coordinator = KeyboardAudioSessionOperationCoordinator.shared
        coordinator.beginOperation()
        task = Task.detached {
            defer { coordinator.completeOperation() }
            do {
                if activate {
                    try session.setCategory(
                        .record,
                        mode: .measurement,
                        options: [.allowBluetoothHFP]
                    )
                    try session.setActive(true)
                } else {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
                return .succeeded
            } catch {
                return .failed
            }
        }
    }
}

final class DeferredAudioEngineOperation: @unchecked Sendable {
    let task: Task<AudioSessionOperationStatus, Never>

    init(engine: AVAudioEngine) {
        task = Task.detached {
            do {
                engine.prepare()
                try engine.start()
                return .succeeded
            } catch {
                return .failed
            }
        }
    }
}

actor KeyboardSpeechRecognitionService: SpeechRecognitionService {
    private final class LegacyAudioTapGate: @unchecked Sendable {
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

    private final class DeferredLegacyAudioCleanup: @unchecked Sendable {
        private let gate: LegacyAudioTapGate
        private let engine: AVAudioEngine
        private let request: SFSpeechAudioBufferRecognitionRequest

        init(
            gate: LegacyAudioTapGate,
            engine: AVAudioEngine,
            request: SFSpeechAudioBufferRecognitionRequest
        ) {
            self.gate = gate
            self.engine = engine
            self.request = request
        }

        func waitForCompletion(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    guard gate.waitUntilDrained(timeout: timeout) else {
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
                gate.waitUntilDrained()
                performTeardown()
            }
        }

        private func performTeardown() {
            _ = VKRemoveAudioInputTap(engine.inputNode)
            engine.stop()
            request.endAudio()
        }
    }

    private final class LegacyRequestHolder: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }
    }

    private final class CleanupCompletionGate: @unchecked Sendable {
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

    private final class RecognitionOutputBridge: @unchecked Sendable {
        private static let maximumPendingUpdates = 64
        private let lock = NSLock()
        private var continuation: SpeechRecognitionUpdateStream.Continuation?
        private var pendingUpdates: [SpeechRecognitionUpdate] = []
        private var isFinished = false
        private var terminalError: Error?

        func attach(_ continuation: SpeechRecognitionUpdateStream.Continuation) {
            lock.lock()
            if isFinished {
                let pendingUpdates = self.pendingUpdates
                self.pendingUpdates.removeAll()
                let terminalError = self.terminalError
                lock.unlock()
                pendingUpdates.forEach { continuation.yield($0) }
                continuation.finish(throwing: terminalError)
                return
            }
            self.continuation = continuation
            let pendingUpdates = self.pendingUpdates
            self.pendingUpdates.removeAll()
            pendingUpdates.forEach { continuation.yield($0) }
            lock.unlock()
        }

        func yield(_ update: SpeechRecognitionUpdate) {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return }
            if let continuation {
                continuation.yield(update)
            } else {
                if pendingUpdates.count >= Self.maximumPendingUpdates {
                    pendingUpdates.removeFirst()
                }
                pendingUpdates.append(update)
            }
        }

        func finish(throwing error: Error? = nil) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            terminalError = error
            let continuation = self.continuation
            if continuation != nil {
                pendingUpdates.removeAll()
            }
            lock.unlock()
            continuation?.finish(throwing: error)
        }
    }

    private final class AnalyzerInputBridge: @unchecked Sendable {
        private static let maximumPendingInputs = 32
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
        private var pendingInputs: [AnalyzerInput] = []
        private var isFinished = false
        private var terminalError: Error?

        func attach(_ continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation) {
            lock.lock()
            if isFinished {
                let pendingInputs = self.pendingInputs
                self.pendingInputs.removeAll()
                let terminalError = self.terminalError
                lock.unlock()
                pendingInputs.forEach { continuation.yield($0) }
                continuation.finish(throwing: terminalError)
                return
            }
            self.continuation = continuation
            let pendingInputs = self.pendingInputs
            self.pendingInputs.removeAll()
            pendingInputs.forEach { continuation.yield($0) }
            lock.unlock()
        }

        func yield(_ input: AnalyzerInput) {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return }
            if let continuation {
                continuation.yield(input)
            } else {
                if pendingInputs.count >= Self.maximumPendingInputs {
                    pendingInputs.removeFirst()
                }
                pendingInputs.append(input)
            }
        }

        func finish(throwing error: Error? = nil) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            terminalError = error
            let continuation = self.continuation
            if continuation != nil {
                pendingInputs.removeAll()
            }
            lock.unlock()
            continuation?.finish(throwing: error)
        }
    }

    private final class AnalyzerInputDeliveryQueue: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "com.ks1019.voicekeyboardinput.analyzer-input",
            qos: .userInitiated
        )
        private let sink: @Sendable (AnalyzerInput) -> Void

        init(sink: @escaping @Sendable (AnalyzerInput) -> Void) {
            self.sink = sink
        }

        func enqueue(_ inputs: [AnalyzerInput]) {
            queue.async { [sink] in
                inputs.forEach(sink)
            }
        }
    }

    private final class AnalyzerAudioTapGate: @unchecked Sendable {
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

        func perform<T>(_ operation: () throws -> T) rethrows -> T? {
            condition.lock()
            guard isActive else {
                condition.unlock()
                return nil
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
            return try operation()
        }
    }

    private final class DeferredAnalyzerAudioCleanup: @unchecked Sendable {
        private let gate: AnalyzerAudioTapGate
        private let engine: AVAudioEngine

        init(gate: AnalyzerAudioTapGate, engine: AVAudioEngine) {
            self.gate = gate
            self.engine = engine
        }

        func waitForCompletion(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    guard gate.waitUntilDrained(timeout: timeout) else {
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
                gate.waitUntilDrained()
                performTeardown()
            }
        }

        private func performTeardown() {
            _ = VKRemoveAudioInputTap(engine.inputNode)
            engine.stop()
        }
    }

    private struct ActiveRun {
        let generation: UInt64
        var engine: AVAudioEngine?
        var tapInstalled = false
        var sessionActive = false
        var analyzer: SpeechAnalyzer?
        var analyzerTask: Task<Void, Never>?
        var analyzerTapGate: AnalyzerAudioTapGate?
        var timeoutTask: Task<Void, Never>?
        var pendingUpdate: SpeechRecognitionUpdate?
        var recognitionTasks: [Task<Void, Never>] = []
        var inputBridge: AnalyzerInputBridge?
        var outputBridge: RecognitionOutputBridge?
        var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
        var legacyTask: SFSpeechRecognitionTask?
        var legacyTapGate: LegacyAudioTapGate?
        var audioObservers: [NSObjectProtocol] = []
        var isPreparingAudio = true
        var preparationInvalidated = false
        var preparationFailure: SpeechRecognitionError?
        var preparationMonitor = AudioPreparationMonitor()
        var preparationGeneration = 0
        var preparationInputUID: String?
        var preparationChannelCount: UInt32 = 0
        var preparationSampleRate: Double = 0
        var stopping = false
    }

    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var nextGeneration: UInt64 = 0
    private var activeRun: ActiveRun?
    private var lingeringAnalyzerCleanupTask: Task<Void, Never>?
    private var lingeringAudioTeardownTask: Task<Void, Never>?
    private var lingeringAudioSessionTask: Task<Void, Never>?
    private var lingeringAudioEngineOperation: Task<AudioSessionOperationStatus, Never>?
    private var pendingAudioSessionActivation: DeferredAudioSessionOperation?
    private var audioSessionQuarantineScheduled = false
    private var audioSessionOwnershipToken: UInt64?
    private var terminalAudioQuarantineError: SpeechRecognitionError?
    private var cleanupTasks: [UInt64: Task<Void, Never>] = [:]
    private var activePermissionCancellation: (() -> Void)?
    private var activePermissionCancellationToken: AnyObject?

    init(diagnostics: KeyboardSpeechRecognitionDiagnostics = KeyboardSpeechRecognitionDiagnostics()) {
        self.diagnostics = diagnostics
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        if let terminalAudioQuarantineError {
            throw terminalAudioQuarantineError
        }
        if KeyboardAudioSessionOperationCoordinator.shared.isTerminal {
            throw .recognitionStartFailed(
                "Audio session recovery did not complete; restart the keyboard extension."
            )
        }
        if let lingeringAudioTeardownTask {
            guard await waitForAnalyzerCleanup(lingeringAudioTeardownTask) else {
                throw .recognitionStartFailed("A previous audio teardown is still finishing")
            }
            self.lingeringAudioTeardownTask = nil
        }
        if let lingeringAnalyzerCleanupTask {
            guard await waitForAnalyzerCleanup(lingeringAnalyzerCleanupTask) else {
                throw .recognitionStartFailed("A previous speech analyzer is still finishing")
            }
            self.lingeringAnalyzerCleanupTask = nil
        }
        guard activeRun == nil else {
            throw .recognitionStartFailed("Speech recognition is already active")
        }
        guard let ownershipToken = KeyboardAudioSessionOperationCoordinator.shared.acquireOwnership() else {
            throw .recognitionStartFailed("Audio input is already in use")
        }
        audioSessionOwnershipToken = ownershipToken
        nextGeneration &+= 1
        let generation = nextGeneration
        activeRun = ActiveRun(generation: generation)
        diagnostics.event("start", metadata: ["locale": locale.identifier])
        let strategy = KeyboardSpeechRecognitionRuntime.strategy(
            forOperatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        diagnostics.event("strategy", metadata: ["value": "\(strategy)"])
        do {
            switch strategy {
            case .legacyAudioBuffer:
                return try await startLegacyAudioBufferRecognition(locale: locale, generation: generation)
            case .speechAnalyzer:
                do {
                    return try await startSpeechAnalyzerRecognition(locale: locale, generation: generation)
                } catch let error {
                    guard error == .speechRecognizerUnavailable else {
                        throw error
                    }

                    // SpeechAnalyzer availability and locale support are
                    // runtime capabilities, not OS-version guarantees.
                    // Recreate the audio run before trying the legacy path.
                    await requestCleanup(generation: generation)
                    guard terminalAudioQuarantineError == nil,
                          !KeyboardAudioSessionOperationCoordinator.shared.isTerminal,
                          let ownershipToken = KeyboardAudioSessionOperationCoordinator.shared.acquireOwnership()
                    else {
                        throw SpeechRecognitionError.speechRecognizerUnavailable
                    }
                    audioSessionOwnershipToken = ownershipToken
                    nextGeneration &+= 1
                    let fallbackGeneration = nextGeneration
                    activeRun = ActiveRun(generation: fallbackGeneration)
                    diagnostics.event("strategy-fallback", metadata: [
                        "value": "legacyAudioBuffer"
                    ])
                    return try await startLegacyAudioBufferRecognition(
                        locale: locale,
                        generation: fallbackGeneration
                    )
                }
            }
        } catch {
            await requestCleanup(generation: activeRun?.generation ?? generation)
            if let error = error as? SpeechRecognitionError {
                throw error
            }
            throw SpeechRecognitionError.recognitionStartFailed(String(describing: error))
        }
    }

    private func activateAudioSession(
        _ session: AVAudioSession,
        generation: UInt64
    ) async throws(SpeechRecognitionError) {
        let operation = DeferredAudioSessionOperation(session: session, activate: true)
        pendingAudioSessionActivation = operation
        switch await waitForAudioSessionOperation(operation, timeout: 2) {
        case .succeeded:
            pendingAudioSessionActivation = nil
            guard activeRun?.generation == generation,
                  activeRun?.stopping == false else {
                guard !audioSessionQuarantineScheduled else {
                    throw .cancelled
                }
                let cleanup = DeferredAudioSessionOperation(session: session, activate: false)
                switch await waitForAudioSessionOperation(cleanup, timeout: 2) {
                case .succeeded:
                    break
                case .failed, .timedOut:
                    KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                    terminalAudioQuarantineError = .recognitionStartFailed(
                        "A stale audio session activation could not be reversed; restart the keyboard extension."
                    )
                    diagnostics.failure("stale-audio-session-activation", error: terminalAudioQuarantineError!)
                    lingeringAudioSessionTask = Task { _ = await cleanup.task.value }
                }
                throw .cancelled
            }
            activeRun?.sessionActive = true
        case .failed:
            pendingAudioSessionActivation = nil
            throw .audioSessionActivationFailed("Could not activate the audio session")
        case .timedOut:
            quarantineAudioSessionOperation(
                operation,
                session: session,
                generation: generation
            )
            throw .audioSessionActivationFailed("Audio session activation timed out")
        }
    }

    private func quarantineAudioSessionOperation(
        _ operation: DeferredAudioSessionOperation,
        session: AVAudioSession,
        generation: UInt64
    ) {
        guard !audioSessionQuarantineScheduled else { return }
        audioSessionQuarantineScheduled = true
        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
        terminalAudioQuarantineError = .recognitionStartFailed(
            "Audio session recovery did not complete; restart the keyboard extension."
        )
        diagnostics.failure("audio-session-quarantine", error: terminalAudioQuarantineError!)
        let finalizer = Task.detached {
            if await operation.task.value == .succeeded {
                _ = await DeferredAudioSessionOperation(session: session, activate: false).task.value
            }
        }
        lingeringAudioSessionTask = Task { await finalizer.value }
    }

    private func waitForAudioSessionOperation(
        _ operation: DeferredAudioSessionOperation,
        timeout: TimeInterval
    ) async -> AudioSessionOperationStatus {
        await withCheckedContinuation { continuation in
            let gate = CleanupCompletionGate()
            Task {
                let status = await operation.task.value
                guard gate.finish() else { return }
                continuation.resume(returning: status)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard gate.finish() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
    }

    private func prepareAndStartAudioEngine(
        _ engine: AVAudioEngine,
        generation: UInt64
    ) async throws(SpeechRecognitionError) {
        let operation = DeferredAudioEngineOperation(engine: engine)
        lingeringAudioEngineOperation = operation.task
        switch await waitForAudioEngineOperation(operation, timeout: 2) {
        case .succeeded:
            lingeringAudioEngineOperation = nil
            guard activeRun?.generation == generation,
                  activeRun?.stopping == false else {
                throw .cancelled
            }
            return
        case .failed:
            lingeringAudioEngineOperation = nil
            throw .audioEngineStartFailed("Could not start the audio engine")
        case .timedOut:
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio engine startup did not complete; restart the keyboard extension."
            )
            diagnostics.failure("audio-engine-quarantine", error: terminalAudioQuarantineError!)
            guard activeRun?.generation == generation else { return }
            throw .audioEngineStartFailed("Audio engine startup timed out")
        }
    }

    private func waitForAudioEngineOperation(
        _ operation: DeferredAudioEngineOperation,
        timeout: TimeInterval
    ) async -> AudioSessionOperationStatus {
        await withCheckedContinuation { continuation in
            let gate = CleanupCompletionGate()
            Task {
                let status = await operation.task.value
                guard gate.finish() else { return }
                continuation.resume(returning: status)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard gate.finish() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
    }

    private func startSpeechAnalyzerRecognition(
        locale: VoiceKeyboardLocale,
        generation: UInt64
    ) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        guard #available(iOS 27, *) else {
            diagnostics.failure("availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        try await ensureMicrophonePermission()
        guard isCurrent(generation) else { throw .cancelled }

        guard SpeechTranscriber.isAvailable else {
            diagnostics.failure("availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: locale.identifier)
        ) else {
            diagnostics.failure("locale", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        guard isCurrent(generation) else { throw .cancelled }
        activeRun?.analyzer = analyzer

        let engine = AVAudioEngine()
        activeRun?.engine = engine
        let session = AVAudioSession.sharedInstance()
        installAudioObservers(session: session, engine: engine, generation: generation)
        do {
            try await activateAudioSession(session, generation: generation)
            try await KeyboardAudioSessionRouting.selectPreferredInputIfAvailable(session)
            try await KeyboardAudioSessionRouting.waitForStableInput(
                session: session,
                engine: engine
            )
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
            establishPreparationBaseline(
                session: session,
                engine: engine,
                generation: generation
            )
            if let preparationFailure = activeRun?.preparationFailure {
                throw preparationFailure
            }
            diagnostics.event("audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("audio-session", error: mapped)
            throw mapped
        }

        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            diagnostics.failure("audio-input", error: .audioInputUnavailable)
            throw .audioInputUnavailable
        }

        diagnostics.event("audio-format", metadata: [
            "channels": "\(naturalFormat.channelCount)",
            "sampleRate": "\(naturalFormat.sampleRate)"
        ])
        activeRun?.preparationInputUID = session.currentRoute.inputs.first?.uid
        activeRun?.preparationChannelCount = naturalFormat.channelCount
        activeRun?.preparationSampleRate = naturalFormat.sampleRate

        do {
            try await analyzer.prepareToAnalyze(in: naturalFormat)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("prepare", error: mapped)
            throw mapped
        }

        let inputBridge = AnalyzerInputBridge()
        activeRun?.inputBridge = inputBridge
        let inputDeliveryQueue = AnalyzerInputDeliveryQueue(sink: inputBridge.yield)
        let inputStream = AsyncThrowingStream<AnalyzerInput, Error>(
            bufferingPolicy: .bufferingNewest(32)
        ) { continuation in
            inputBridge.attach(continuation)
        }
        let tapGate = AnalyzerAudioTapGate()
        activeRun?.analyzerTapGate = tapGate
        let outputBridge = RecognitionOutputBridge()
        activeRun?.outputBridge = outputBridge
        let converter: AnalyzerInputConverter
        do {
            converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("converter", error: mapped)
            throw mapped
        }
        guard preparationAudioIsStable(session: session, engine: engine, generation: generation) else {
            throw SpeechRecognitionError.audioSessionActivationFailed("Audio input changed during setup")
        }

        guard VKInstallAudioInputTap(inputNode, { [weak self] buffer, time in
            guard let self else { return }
            do {
                guard let inputs = try tapGate.perform({
                    try converter.convert(buffer, at: time)
                }) else {
                    return
                }
                inputDeliveryQueue.enqueue(inputs)
            } catch {
                let description = String(describing: error)
                Task {
                    await self.finishInput(throwing: SpeechRecognitionError.recognitionFailed(description), generation: generation)
                }
            }
        }) else {
            throw SpeechRecognitionError.audioSessionActivationFailed("Audio input tap could not be installed")
        }
        activeRun?.tapInstalled = true

        guard isCurrent(generation) else { throw .cancelled }
        do {
            try await prepareAndStartAudioEngine(engine, generation: generation)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
            let preparationIsStable = preparationAudioIsStable(
                session: session,
                engine: engine,
                generation: generation
            )
            activeRun?.isPreparingAudio = false
            guard preparationIsStable else {
                throw SpeechRecognitionError.audioSessionActivationFailed("Audio input changed during setup")
            }
            diagnostics.event("audio-engine-started")
        } catch {
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("audio-engine", error: mapped)
            throw mapped
        }
        activeRun?.analyzerTask = Task {
            do {
                // SpeechAnalyzer.start begins analysis and returns before the
                // input sequence is exhausted. The result stream owns the
                // lifetime of this run; cleanup is driven by stop(), an
                // output-stream failure, or an audio observer failure.
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                self.failCurrentRun(
                    .recognitionFailed(String(describing: error)),
                    generation: generation
                )
            }
        }

        activeRun?.timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.failCurrentRun(
                .recognitionFailed("Keyboard speech recognition reached its safety timeout."),
                generation: generation
            )
        }

        return SpeechRecognitionUpdateStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.requestCleanup(generation: generation) }
            }
            outputBridge.attach(continuation)
            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        guard self.isCurrent(generation) else { return }
                        let transcript = String(result.text.characters)
                        let update = SpeechRecognitionUpdate(
                            transcript: transcript,
                            isFinal: result.isFinal,
                            inputLevel: nil
                        )
                        self.record(update, generation: generation)
                        outputBridge.yield(update)
                    }
                    self.flushPendingUpdate(generation: generation)
                    outputBridge.finish()
                } catch {
                    guard self.isCurrent(generation) else { return }
                    outputBridge.finish(
                        throwing: SpeechRecognitionError.recognitionFailed(String(describing: error))
                    )
                }
            }
            Task { self.addRecognitionTask(resultTask, generation: generation) }
        }
    }

    private func startLegacyAudioBufferRecognition(
        locale: VoiceKeyboardLocale,
        generation: UInt64
    ) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        try await ensureMicrophonePermission()
        guard isCurrent(generation) else { throw .cancelled }
        try await ensureSpeechRecognitionAuthorization()
        guard isCurrent(generation) else { throw .cancelled }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.identifier)) else {
            diagnostics.failure("legacy-recognizer", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        guard recognizer.isAvailable else {
            diagnostics.failure("legacy-availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        let engine = AVAudioEngine()
        activeRun?.engine = engine
        let session = AVAudioSession.sharedInstance()
        guard isCurrent(generation) else { throw .cancelled }
        installAudioObservers(session: session, engine: engine, generation: generation)
        do {
            try await activateAudioSession(session, generation: generation)
            try await KeyboardAudioSessionRouting.selectPreferredInputIfAvailable(session)
            try await KeyboardAudioSessionRouting.waitForStableInput(
                session: session,
                engine: engine
            )
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
            establishPreparationBaseline(
                session: session,
                engine: engine,
                generation: generation
            )
            if let preparationFailure = activeRun?.preparationFailure {
                throw preparationFailure
            }
            diagnostics.event("legacy-audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("legacy-audio-session", error: mapped)
            throw mapped
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            diagnostics.failure("legacy-audio-input", error: .audioInputUnavailable)
            throw .audioInputUnavailable
        }

        diagnostics.event("legacy-audio-format", metadata: [
            "channels": "\(format.channelCount)",
            "sampleRate": "\(format.sampleRate)",
            "onDevice": "\(recognizer.supportsOnDeviceRecognition)"
        ])
        activeRun?.preparationInputUID = session.currentRoute.inputs.first?.uid
        activeRun?.preparationChannelCount = format.channelCount
        activeRun?.preparationSampleRate = format.sampleRate

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        activeRun?.legacyRequest = request
        let tapGate = LegacyAudioTapGate()
        activeRun?.legacyTapGate = tapGate
        let outputBridge = RecognitionOutputBridge()
        activeRun?.outputBridge = outputBridge
        guard preparationAudioIsStable(session: session, engine: engine, generation: generation) else {
            throw SpeechRecognitionError.audioSessionActivationFailed("Audio input changed during setup")
        }
        guard VKInstallAudioInputTap(inputNode, { buffer, _ in
            tapGate.append(buffer, to: request)
        }) else {
            throw SpeechRecognitionError.audioSessionActivationFailed("Audio input tap could not be installed")
        }
        activeRun?.tapInstalled = true

        do {
            try await prepareAndStartAudioEngine(engine, generation: generation)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
            let preparationIsStable = preparationAudioIsStable(
                session: session,
                engine: engine,
                generation: generation
            )
            activeRun?.isPreparingAudio = false
            guard preparationIsStable else {
                throw SpeechRecognitionError.audioSessionActivationFailed("Audio input changed during setup")
            }
            diagnostics.event("legacy-audio-engine-started")
        } catch {
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("legacy-audio-engine", error: mapped)
            throw mapped
        }
        return SpeechRecognitionUpdateStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.requestCleanup(generation: generation) }
            }
            outputBridge.attach(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    Task {
                        guard self.isCurrent(generation) else { return }
                        let update = SpeechRecognitionUpdate(
                            transcript: result.bestTranscription.formattedString,
                            isFinal: result.isFinal,
                            inputLevel: nil
                        )
                        self.record(update, generation: generation)
                        outputBridge.yield(update)
                        if result.isFinal, self.isCurrent(generation) {
                            outputBridge.finish()
                        }
                    }
                }

                if let error {
                    Task {
                        guard self.isCurrent(generation) else { return }
                        outputBridge.finish(
                            throwing: SpeechRecognitionError.recognitionFailed(String(describing: error))
                        )
                    }
                }
            }

            Task {
                self.setLegacyTask(task, generation: generation)
            }
        }
    }

    func stop() async {
        diagnostics.event("stop")
        activePermissionCancellation?()
        activePermissionCancellation = nil
        activePermissionCancellationToken = nil
        guard let generation = activeRun?.generation else { return }
        flushPendingUpdate(generation: generation)
        await requestCleanup(generation: generation)
    }

    private func requestCleanup(generation: UInt64) async {
        if let cleanupTask = cleanupTasks[generation] {
            await cleanupTask.value
            return
        }

        let cleanupTask = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.cleanup(generation: generation)
        }
        cleanupTasks[generation] = cleanupTask
        await cleanupTask.value
        cleanupTasks[generation] = nil
    }

    private func cleanup(generation: UInt64) async {
        guard var run = activeRun, run.generation == generation, !run.stopping else { return }
        run.stopping = true
        activeRun = run

        // Invalidate callbacks before releasing any resource.
        run.inputBridge?.finish()
        run.inputBridge = nil
        run.outputBridge?.finish()
        run.outputBridge = nil
        run.analyzerTask?.cancel()
        run.analyzerTask = nil
        run.timeoutTask?.cancel()
        run.timeoutTask = nil
        run.recognitionTasks.forEach { $0.cancel() }
        run.recognitionTasks.removeAll()
        let analyzerTapGate = run.analyzerTapGate
        let analyzerTapDidDrain = analyzerTapGate?.invalidate() ?? true
        run.analyzerTapGate = nil
        run.legacyTask?.cancel()
        run.legacyTask = nil
        let legacyTapGate = run.legacyTapGate
        let legacyTapDidDrain = legacyTapGate?.invalidate() ?? true
        run.legacyTapGate = nil
        let legacyRequest = run.legacyRequest
        run.legacyRequest = nil
        run.audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        run.audioObservers.removeAll()
        let pendingEngineOperation = lingeringAudioEngineOperation
        let pendingSessionActivation = pendingAudioSessionActivation
        let sessionQuarantineAlreadyScheduled = audioSessionQuarantineScheduled
        var audioQuarantineTask: Task<Void, Never>?
        if pendingSessionActivation != nil || pendingEngineOperation != nil {
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio startup is still finishing; restart the keyboard extension."
            )
            diagnostics.failure("startup-quarantine", error: terminalAudioQuarantineError!)
        }
        if let pendingSessionActivation {
            audioSessionQuarantineScheduled = true
            let engine = run.engine
            let tapInstalled = run.tapInstalled
            let legacyRequestHolder = legacyRequest.map(LegacyRequestHolder.init)
            audioQuarantineTask = Task.detached {
                let activationSucceeded = await pendingSessionActivation.task.value == .succeeded
                if let engine {
                    if let analyzerTapGate { analyzerTapGate.waitUntilDrained() }
                    if let legacyTapGate { legacyTapGate.waitUntilDrained() }
                    if tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                }
                legacyRequestHolder?.request.endAudio()
                if activationSucceeded && !sessionQuarantineAlreadyScheduled {
                    let deactivation = DeferredAudioSessionOperation(
                        session: AVAudioSession.sharedInstance(),
                        activate: false
                    )
                    if await deactivation.task.value != .succeeded {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                    }
                }
            }
        } else if let engine = run.engine, let pendingEngineOperation {
            let tapInstalled = run.tapInstalled
            let legacyRequestHolder = legacyRequest.map(LegacyRequestHolder.init)
            if let analyzerTapGate {
                audioQuarantineTask = Task.detached {
                    _ = await pendingEngineOperation.value
                    analyzerTapGate.waitUntilDrained()
                    if tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                }
            } else if let legacyTapGate {
                audioQuarantineTask = Task.detached {
                    _ = await pendingEngineOperation.value
                    legacyTapGate.waitUntilDrained()
                    if tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                    legacyRequestHolder?.request.endAudio()
                }
            } else {
                audioQuarantineTask = Task.detached {
                    _ = await pendingEngineOperation.value
                if tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                    legacyRequestHolder?.request.endAudio()
                }
            }
        } else if let engine = run.engine {
            if let analyzerTapGate {
                if analyzerTapDidDrain {
                    if run.tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                } else {
                    let cleanup = DeferredAnalyzerAudioCleanup(gate: analyzerTapGate, engine: engine)
                    if await cleanup.waitForCompletion(timeout: 2) == false {
                        audioQuarantineTask = cleanup.quarantine()
                    }
                }
            } else if let legacyTapGate {
                if legacyTapDidDrain {
                    if run.tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                    engine.stop()
                } else if let legacyRequest {
                    let cleanup = DeferredLegacyAudioCleanup(
                        gate: legacyTapGate,
                        engine: engine,
                        request: legacyRequest
                    )
                    if await cleanup.waitForCompletion(timeout: 2) == false {
                        audioQuarantineTask = cleanup.quarantine()
                    }
                }
            } else {
                if run.tapInstalled { _ = VKRemoveAudioInputTap(engine.inputNode) }
                engine.stop()
            }
        }
        if pendingEngineOperation == nil && pendingSessionActivation == nil
            && (legacyTapGate == nil || legacyTapDidDrain) {
            legacyRequest?.endAudio()
        }
        run.engine = nil
        if let analyzer = run.analyzer {
            await cancelAnalyzerWithTimeout(analyzer)
        }
        run.analyzer = nil
        var quarantineTasks: [Task<Void, Never>] = []
        if let audioQuarantineTask {
            quarantineTasks.append(audioQuarantineTask)
        }
        if let analyzerCleanupTask = lingeringAnalyzerCleanupTask {
            quarantineTasks.append(analyzerCleanupTask)
        }
        if let audioSessionCleanupTask = lingeringAudioSessionTask {
            quarantineTasks.append(audioSessionCleanupTask)
        }
        if !quarantineTasks.isEmpty {
            let generation = run.generation
            let sessionActive = run.sessionActive
            let combinedQuarantineTask = Task {
                for task in quarantineTasks {
                    await task.value
                }
            }
            self.lingeringAudioTeardownTask = Task { [weak self] in
                guard let self else {
                    await combinedQuarantineTask.value
                    return
                }
                if await self.waitForAnalyzerCleanup(combinedQuarantineTask) == false {
                    await self.markTerminalAudioQuarantine(generation: generation)
                    // Keep the terminal quarantine isolated from stopRecognition().
                    // A blocked engine/tap must not make the extension's stop path
                    // wait forever or race a session deactivation.
                    Task { [weak self] in
                        await combinedQuarantineTask.value
                        guard let self else { return }
                        await self.finishQuarantinedCleanup(
                            generation: generation,
                            sessionActive: sessionActive
                        )
                    }
                    return
                }
                await self.finishQuarantinedCleanup(
                    generation: generation,
                    sessionActive: sessionActive
                )
            }
            activeRun = run
            return
        }
        if run.sessionActive {
            await deactivateAudioSession(AVAudioSession.sharedInstance(), generation: run.generation)
        }
        if lingeringAudioSessionTask != nil {
            return
        }
        if let ownershipToken = audioSessionOwnershipToken {
            KeyboardAudioSessionOperationCoordinator.shared.releaseOwnership(ownershipToken)
            audioSessionOwnershipToken = nil
        }
        activeRun = nil
    }

    private func finishQuarantinedCleanup(
        generation: UInt64,
        sessionActive: Bool
    ) async {
        guard activeRun?.generation == generation else { return }
        let hadLingeringAudioSessionTask = lingeringAudioSessionTask != nil
        if sessionActive {
            await deactivateAudioSession(AVAudioSession.sharedInstance(), generation: generation)
        }
        if !hadLingeringAudioSessionTask, lingeringAudioSessionTask != nil {
            return
        }
        lingeringAudioSessionTask = nil
        if let ownershipToken = audioSessionOwnershipToken {
            KeyboardAudioSessionOperationCoordinator.shared.releaseOwnership(ownershipToken)
            audioSessionOwnershipToken = nil
        }
        activeRun = nil
        lingeringAudioTeardownTask = nil
        lingeringAudioEngineOperation = nil
        pendingAudioSessionActivation = nil
        audioSessionQuarantineScheduled = false
    }

    private func deactivateAudioSession(
        _ session: AVAudioSession,
        generation: UInt64
    ) async {
        guard await KeyboardAudioSessionOperationCoordinator.shared.waitForPendingOperations(
            timeout: 10
        ) else {
            KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio route recovery did not complete; restart the keyboard extension."
            )
            diagnostics.failure("audio-route-quarantine", error: terminalAudioQuarantineError!)
            return
        }
        let operation = DeferredAudioSessionOperation(session: session, activate: false)
        switch await waitForAudioSessionOperation(operation, timeout: 2) {
        case .succeeded:
            return
        case .failed, .timedOut:
            KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio session deactivation did not complete; restart the keyboard extension."
            )
            diagnostics.failure("audio-session-deactivation", error: terminalAudioQuarantineError!)
            let lingeringTask = Task { _ = await operation.task.value }
            lingeringAudioSessionTask = lingeringTask
            Task { [weak self] in
                await lingeringTask.value
                await self?.finishLingeringAudioSessionCleanup(generation: generation)
            }
            guard activeRun?.generation == generation else { return }
        }
    }

    private func finishLingeringAudioSessionCleanup(generation: UInt64) {
        lingeringAudioSessionTask = nil
        if let ownershipToken = audioSessionOwnershipToken {
            KeyboardAudioSessionOperationCoordinator.shared.releaseOwnership(ownershipToken)
            audioSessionOwnershipToken = nil
        }
        if activeRun?.generation == generation {
            activeRun = nil
        }
    }

    private func markTerminalAudioQuarantine(generation: UInt64) {
        guard activeRun?.generation == generation else { return }
        terminalAudioQuarantineError = .recognitionStartFailed(
            "Audio teardown did not complete; restart the keyboard extension."
        )
        diagnostics.failure("audio-quarantine", error: terminalAudioQuarantineError!)
    }

    private func cancelAnalyzerWithTimeout(_ analyzer: SpeechAnalyzer) async {
        let cleanupTask = Task {
            await analyzer.cancelAndFinishNow()
        }
        lingeringAnalyzerCleanupTask = cleanupTask
        if await waitForAnalyzerCleanup(cleanupTask) {
            lingeringAnalyzerCleanupTask = nil
        }
    }

    private func waitForAnalyzerCleanup(_ cleanupTask: Task<Void, Never>) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = CleanupCompletionGate()
            Task {
                await cleanupTask.value
                guard gate.finish() else { return }
                continuation.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                continuation.resume(returning: false)
            }
        }
    }

    private func installAudioObservers(
        session: AVAudioSession,
        engine: AVAudioEngine,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        let preparationMonitor = activeRun?.preparationMonitor
        let notificationCenter = NotificationCenter.default
        let interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self, preparationMonitor] notification in
            preparationMonitor?.markChanged()
            guard let interruptionTypeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue),
                  interruptionType == .began else { return }
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio input was interrupted."),
                    generation: generation,
                    latchDuringPreparation: true
                )
            }
        }
        let routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor?.markChanged()
            Task {
                guard let self,
                      await self.routeChangeInvalidatesRun(
                          session: session,
                          engine: engine,
                          generation: generation
                      ) else { return }
                await self.failCurrentRun(
                    .recognitionFailed("Audio input route changed during recognition."),
                    generation: generation
                )
            }
        }
        let engineConfigurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor?.markChanged()
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio engine configuration changed."),
                    generation: generation
                )
            }
        }
        let mediaServicesLostObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: session,
            queue: nil
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor?.markChanged()
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio media services were lost."),
                    generation: generation,
                    latchDuringPreparation: true
                )
            }
        }
        let mediaServicesResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor?.markChanged()
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio media services were reset."),
                    generation: generation,
                    latchDuringPreparation: true
                )
            }
        }
        activeRun?.audioObservers = [
            interruptionObserver,
            routeChangeObserver,
            engineConfigurationObserver,
            mediaServicesLostObserver,
            mediaServicesResetObserver
        ]
    }

    private func routeChangeInvalidatesRun(
        session: AVAudioSession,
        engine: AVAudioEngine,
        generation: UInt64
    ) -> Bool {
        guard isCurrent(generation), activeRun?.isPreparingAudio == false else { return false }
        return !preparationAudioIsStable(
            session: session,
            engine: engine,
            generation: generation
        )
    }

    private func failCurrentRun(
        _ error: SpeechRecognitionError,
        generation: UInt64,
        latchDuringPreparation: Bool = false
    ) {
        guard isCurrent(generation) else { return }
        guard activeRun?.isPreparingAudio == false else {
            guard latchDuringPreparation else { return }
            activeRun?.preparationInvalidated = true
            activeRun?.preparationFailure = error
            return
        }
        activeRun?.inputBridge?.finish(throwing: error)
        activeRun?.outputBridge?.finish(throwing: error)
        Task { await requestCleanup(generation: generation) }
    }

    private func establishPreparationBaseline(
        session: AVAudioSession,
        engine: AVAudioEngine,
        generation: UInt64
    ) {
        guard isCurrent(generation), var run = activeRun,
              run.generation == generation else { return }
        guard run.preparationFailure == nil else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        run.preparationInvalidated = false
        run.preparationGeneration = run.preparationMonitor.changeCount
        run.preparationInputUID = session.currentRoute.inputs.first?.uid
        run.preparationChannelCount = format.channelCount
        run.preparationSampleRate = format.sampleRate
        activeRun = run
    }

    private func record(_ update: SpeechRecognitionUpdate, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.pendingUpdate = update.isFinal ? nil : update
    }

    private func flushPendingUpdate(generation: UInt64) {
        guard var run = activeRun,
              run.generation == generation,
              let pendingUpdate = run.pendingUpdate else { return }
        run.pendingUpdate = nil
        activeRun = run
        let finalUpdate = SpeechRecognitionUpdate(
            transcript: pendingUpdate.transcript,
            isFinal: true,
            inputLevel: pendingUpdate.inputLevel?.value
        )
        run.outputBridge?.yield(finalUpdate)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        activeRun?.generation == generation && activeRun?.stopping == false
    }

    private func preparationAudioIsStable(
        session: AVAudioSession,
        engine: AVAudioEngine,
        generation: UInt64
    ) -> Bool {
        guard let run = activeRun,
              run.generation == generation,
              !run.preparationInvalidated,
              run.preparationFailure == nil,
              run.preparationMonitor.changeCount == run.preparationGeneration,
              let input = session.currentRoute.inputs.first else {
            return false
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        return input.uid == run.preparationInputUID
            && format.channelCount == run.preparationChannelCount
            && format.sampleRate == run.preparationSampleRate
    }

    private func yield(_ input: AnalyzerInput, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.inputBridge?.yield(input)
    }

    private func finishInput(throwing error: Error, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.inputBridge?.finish(
            throwing: SpeechRecognitionError.recognitionFailed(String(describing: error))
        )
    }

    private func setLegacyTask(_ task: SFSpeechRecognitionTask, generation: UInt64) {
        guard isCurrent(generation) else {
            task.cancel()
            return
        }
        activeRun?.legacyTask = task
    }

    private func addRecognitionTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard isCurrent(generation) else {
            task.cancel()
            return
        }
        activeRun?.recognitionTasks.append(task)
    }

    private func ensureMicrophonePermission() async throws(SpeechRecognitionError) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            diagnostics.event("microphone-permission", metadata: ["value": "granted"])
        case .denied:
            diagnostics.failure("microphone-permission", error: .microphonePermissionDenied)
            throw .microphonePermissionDenied
        case .undetermined:
            diagnostics.event("microphone-permission", metadata: ["value": "requesting"])
            guard !Task.isCancelled else { throw .cancelled }
            let gate = KeyboardPermissionRequestGate(cancelledValue: false)
            activePermissionCancellationToken = gate
            activePermissionCancellation = { gate.cancel() }
            defer {
                if activePermissionCancellationToken === gate {
                    activePermissionCancellation = nil
                    activePermissionCancellationToken = nil
                }
            }
            let isGranted = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    gate.install(continuation)
                    guard !Task.isCancelled else {
                        gate.cancel()
                        return
                    }
                    AVAudioApplication.requestRecordPermission { isGranted in
                        gate.finish(isGranted)
                    }
                }
            }, onCancel: {
                gate.cancel()
            })
            guard !Task.isCancelled else { throw .cancelled }
            guard isGranted else {
                diagnostics.failure("microphone-permission", error: .microphonePermissionDenied)
                throw .microphonePermissionDenied
            }
            diagnostics.event("microphone-permission", metadata: ["value": "granted-after-request"])
        @unknown default:
            diagnostics.failure("microphone-permission", error: .microphonePermissionUndetermined)
            throw .microphonePermissionUndetermined
        }
    }

    private func ensureSpeechRecognitionAuthorization() async throws(SpeechRecognitionError) {
        let status = SFSpeechRecognizer.authorizationStatus()
        diagnostics.event("speech-authorization", metadata: ["value": "\(status.rawValue)"])
        switch status {
        case .authorized:
            return
        case .notDetermined:
            guard !Task.isCancelled else { throw .cancelled }
            let gate = KeyboardPermissionRequestGate(cancelledValue: SFSpeechRecognizerAuthorizationStatus.denied)
            activePermissionCancellationToken = gate
            activePermissionCancellation = { gate.cancel() }
            defer {
                if activePermissionCancellationToken === gate {
                    activePermissionCancellation = nil
                    activePermissionCancellationToken = nil
                }
            }
            let requestedStatus = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                    gate.install(continuation)
                    guard !Task.isCancelled else {
                        gate.cancel()
                        return
                    }
                    SFSpeechRecognizer.requestAuthorization { status in
                        gate.finish(status)
                    }
                }
            }, onCancel: {
                gate.cancel()
            })
            guard !Task.isCancelled else { throw .cancelled }
            guard requestedStatus == .authorized else {
                diagnostics.failure("speech-authorization", error: .speechAuthorizationDenied)
                throw .speechAuthorizationDenied
            }
        case .denied, .restricted:
            diagnostics.failure("speech-authorization", error: .speechAuthorizationDenied)
            throw .speechAuthorizationDenied
        @unknown default:
            diagnostics.failure("speech-authorization", error: .speechAuthorizationDenied)
            throw .speechAuthorizationDenied
        }
    }
}

private final class KeyboardPermissionRequestGate<Value: Sendable>: @unchecked Sendable {
    private let cancelledValue: Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var isFinished = false
    private var finishedValue: Value?

    init(cancelledValue: Value) {
        self.cancelledValue = cancelledValue
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        var immediateValue: Value?
        lock.lock()
        if isFinished {
            immediateValue = finishedValue ?? cancelledValue
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if let immediateValue {
            continuation.resume(returning: immediateValue)
        }
    }

    func finish(_ value: Value) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        finishedValue = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancel() {
        finish(cancelledValue)
    }
}
