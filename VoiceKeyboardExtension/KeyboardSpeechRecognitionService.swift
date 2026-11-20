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
            VKPrepareAndStartAudioEngine(engine) ? .succeeded : .failed
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
        private let gate: LegacyAudioTapGate?
        private let engine: AVAudioEngine
        private let request: LegacyRequestHolder
        private let tapInstalled: Bool
        private let teardownLock = NSLock()
        private var teardownTask: Task<Bool, Never>?

        init(
            gate: LegacyAudioTapGate?,
            engine: AVAudioEngine,
            request: LegacyRequestHolder,
            tapInstalled: Bool
        ) {
            self.gate = gate
            self.engine = engine
            self.request = request
            self.tapInstalled = tapInstalled
        }

        func waitForCompletion(timeout: TimeInterval) async -> Bool {
            let task = retainedTeardownTask()
            return await withCheckedContinuation { continuation in
                let completionGate = CleanupCompletionGate()
                Task {
                    let result = await task.value
                    guard completionGate.finish() else { return }
                    continuation.resume(returning: result)
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard completionGate.finish() else { return }
                    continuation.resume(returning: false)
                }
            }
        }

        func quarantine() -> Task<Bool, Never> {
            retainedTeardownTask()
        }

        private func retainedTeardownTask() -> Task<Bool, Never> {
            teardownLock.lock()
            defer { teardownLock.unlock() }
            if let teardownTask { return teardownTask }
            let task = Task.detached { [self] in
                gate?.waitUntilDrained()
                // Signal Speech that no more audio will arrive before
                // stopping the engine. This preserves the normal final
                // callback ordering on the legacy recognition path.
                request.endAudioIfNeeded()
                let didRemoveTap = !tapInstalled || VKRemoveAudioEngineInputTap(engine)
                let didStopEngine = VKStopAudioEngine(engine)
                return didRemoveTap && didStopEngine
            }
            teardownTask = task
            return task
        }
    }

    private final class LegacyRequestHolder: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        private let lock = NSLock()
        private var didEndAudio = false

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }

        func endAudioIfNeeded() {
            lock.lock()
            guard !didEndAudio else {
                lock.unlock()
                return
            }
            didEndAudio = true
            lock.unlock()
            request.endAudio()
        }
    }

    private final class LegacyRecognitionFinalizationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didReceiveFinalResult = false
        private var waiter: CheckedContinuation<Bool, Never>?

        func markFinalResultReceived() {
            lock.lock()
            didReceiveFinalResult = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: true)
        }

        func waitUntilFinalResult(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didReceiveFinalResult {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                waiter = continuation
                lock.unlock()

                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.timeoutWait()
                }
            }
        }

        private func timeoutWait() {
            lock.lock()
            guard !didReceiveFinalResult else {
                lock.unlock()
                return
            }
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: false)
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

    private final class RecognitionTaskRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var isClosed = false

        func register(_ task: Task<Void, Never>) {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func closeAndSnapshot() -> [Task<Void, Never>] {
            lock.lock()
            isClosed = true
            let snapshot = tasks
            tasks.removeAll()
            lock.unlock()
            return snapshot
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

        @discardableResult
        func yield(_ input: AnalyzerInput) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return false }
            if let continuation {
                switch continuation.yield(input) {
                case .enqueued:
                    return true
                case .dropped, .terminated:
                    return false
                @unknown default:
                    return false
                }
            } else {
                if pendingInputs.count >= Self.maximumPendingInputs {
                    return false
                }
                pendingInputs.append(input)
                return true
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

    private protocol AnalyzerInputDeliveryQueueProtocol: AnyObject, Sendable {
        func closeAndFlush() async
    }

    @available(iOS 27, *)
    private final class AnalyzerAudioSample: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: AVAudioTime

        init(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
            self.buffer = buffer
            self.time = time
        }
    }

    @available(iOS 27, *)
    private final class AnalyzerInputDeliveryQueue: @unchecked Sendable, AnalyzerInputDeliveryQueueProtocol {
        private static let maximumPendingBlocks = 8
        private let queue = DispatchQueue(
            label: "com.ks1019.voicekeyboardinput.analyzer-input",
            qos: .userInitiated
        )
        private let stateLock = NSLock()
        private var pendingBlocks = 0
        private var isClosed = false
        private var didFlush = false
        private let converter: AnalyzerInputConverter
        private let sink: @Sendable (AnalyzerInput) -> Bool
        private let onDrop: @Sendable () -> Void

        init(
            converter: AnalyzerInputConverter,
            sink: @escaping @Sendable (AnalyzerInput) -> Bool,
            onDrop: @escaping @Sendable () -> Void
        ) {
            self.converter = converter
            self.sink = sink
            self.onDrop = onDrop
        }

        func closeAndFlush() async {
            guard markClosedForFlush() else { return }

            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    do {
                        let inputs = try self.converter.flush()
                        for input in inputs {
                            guard self.sink(input) else { break }
                        }
                    } catch {
                        self.reportDropIfOpen()
                    }
                    continuation.resume()
                }
            }
        }

        private func markClosedForFlush() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !didFlush else { return false }
            isClosed = true
            didFlush = true
            return true
        }

        private func reportDropIfOpen() {
            stateLock.lock()
            let shouldReport = !isClosed
            stateLock.unlock()
            if shouldReport { onDrop() }
        }

        func reportDrop() {
            reportDropIfOpen()
        }

        func reserveSlot() -> Bool {
            stateLock.lock()
            guard !isClosed, pendingBlocks < Self.maximumPendingBlocks else {
                stateLock.unlock()
                return false
            }
            pendingBlocks += 1
            stateLock.unlock()
            return true
        }

        func releaseReservedSlot() {
            stateLock.lock()
            pendingBlocks = max(0, pendingBlocks - 1)
            stateLock.unlock()
        }

        func enqueue(_ sample: AnalyzerAudioSample) {
            guard reserveSlot() else {
                reportDropIfOpen()
                return
            }
            enqueueReserved(sample)
        }

        func enqueueReserved(_ sample: AnalyzerAudioSample) {
            stateLock.lock()
            let isCurrentlyOpen = !isClosed
            stateLock.unlock()
            guard isCurrentlyOpen else {
                releaseReservedSlot()
                return
            }

            queue.async { [weak self, sink] in
                defer {
                    if let self {
                        self.stateLock.lock()
                        self.pendingBlocks = max(0, self.pendingBlocks - 1)
                        self.stateLock.unlock()
                    }
                }
                do {
                    let inputs = try self?.converter.convert(sample.buffer, at: sample.time) ?? []
                    for input in inputs {
                        guard sink(input) else {
                            self?.reportDropIfOpen()
                            return
                        }
                    }
                } catch {
                    self?.reportDropIfOpen()
                }
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
        private let gate: AnalyzerAudioTapGate?
        private let engine: AVAudioEngine
        private let tapInstalled: Bool
        private let teardownLock = NSLock()
        private var teardownTask: Task<Bool, Never>?

        init(
            gate: AnalyzerAudioTapGate?,
            engine: AVAudioEngine,
            tapInstalled: Bool
        ) {
            self.gate = gate
            self.engine = engine
            self.tapInstalled = tapInstalled
        }

        func waitForCompletion(timeout: TimeInterval) async -> Bool {
            let task = retainedTeardownTask()
            return await withCheckedContinuation { continuation in
                let completionGate = CleanupCompletionGate()
                Task {
                    let result = await task.value
                    guard completionGate.finish() else { return }
                    continuation.resume(returning: result)
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard completionGate.finish() else { return }
                    continuation.resume(returning: false)
                }
            }
        }

        func quarantine() -> Task<Bool, Never> {
            retainedTeardownTask()
        }

        private func retainedTeardownTask() -> Task<Bool, Never> {
            teardownLock.lock()
            defer { teardownLock.unlock() }
            if let teardownTask { return teardownTask }
            let task = Task.detached { [self] in
                gate?.waitUntilDrained()
                let didRemoveTap = !tapInstalled || VKRemoveAudioEngineInputTap(engine)
                let didStopEngine = VKStopAudioEngine(engine)
                return didRemoveTap && didStopEngine
            }
            teardownTask = task
            return task
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
        var recognitionTaskRegistry: RecognitionTaskRegistry?
        var inputBridge: AnalyzerInputBridge?
        var inputDeliveryQueue: (any AnalyzerInputDeliveryQueueProtocol)? = nil
        var outputBridge: RecognitionOutputBridge?
        var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
        var legacyTask: SFSpeechRecognitionTask?
        var legacyFinalizationGate: LegacyRecognitionFinalizationGate?
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
        var acceptingFinalizedAnalyzerResults = false
    }

    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var nextGeneration: UInt64 = 0
    private var activeRun: ActiveRun?
    private var lingeringAnalyzerCleanupTask: Task<Void, Never>?
    private var lingeringAudioTeardownTask: Task<Void, Never>?
    private var lingeringAudioSessionTask: Task<Void, Never>?
    private var audioSessionQuarantineSucceeded = true
    private var lingeringAudioEngineOperation: Task<AudioSessionOperationStatus, Never>?
    private var pendingAudioSessionActivation: DeferredAudioSessionOperation?
    private var audioSessionQuarantineScheduled = false
    private var audioSessionOwnershipToken: UInt64?
    private var terminalAudioQuarantineError: SpeechRecognitionError?
    private var terminalAudioEngine: AVAudioEngine?
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
                    audioSessionQuarantineSucceeded = false
                    lingeringAudioSessionTask = Task { [self] in
                        let status = await cleanup.task.value
                        self.setAudioSessionQuarantineResult(status == .succeeded)
                    }
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
                generation: generation
            )
            throw .audioSessionActivationFailed("Audio session activation timed out")
        }
    }

    private func quarantineAudioSessionOperation(
        _ operation: DeferredAudioSessionOperation,
        generation: UInt64
    ) {
        guard !audioSessionQuarantineScheduled else { return }
        audioSessionQuarantineScheduled = true
        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
        terminalAudioQuarantineError = .recognitionStartFailed(
            "Audio session recovery did not complete; restart the keyboard extension."
        )
        diagnostics.failure("audio-session-quarantine", error: terminalAudioQuarantineError!)
        audioSessionQuarantineSucceeded = false
        // Keep only an activation-settlement waiter here. The cleanup path
        // owns engine teardown and the single matching deactivation; starting
        // deactivation from this waiter would race the engine quarantine.
        lingeringAudioSessionTask = Task { [self] in
            _ = await operation.task.value
            self.noteAudioSessionActivationSettled(generation: generation)
        }
    }

    private func noteAudioSessionActivationSettled(generation: UInt64) {
        guard activeRun?.generation == generation else { return }
        diagnostics.event("audio-session-activation-settled")
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

        guard let inputNode = VKAudioEngineInputNode(engine),
              let naturalFormat = VKAudioEngineInputFormat(engine) else {
            diagnostics.failure("audio-input", error: .audioInputUnavailable)
            throw .audioInputUnavailable
        }
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

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: naturalFormat
        ) else {
            let mapped = SpeechRecognitionError.recognitionStartFailed(
                "Speech analyzer does not expose a compatible audio format"
            )
            diagnostics.failure("audio-format", error: mapped)
            throw mapped
        }

        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("prepare", error: mapped)
            throw mapped
        }

        let inputBridge = AnalyzerInputBridge()
        activeRun?.inputBridge = inputBridge
        let inputStream = AsyncThrowingStream<AnalyzerInput, Error>(
            bufferingPolicy: .bufferingOldest(32)
        ) { continuation in
            inputBridge.attach(continuation)
        }
        let tapGate = AnalyzerAudioTapGate()
        activeRun?.analyzerTapGate = tapGate
        let recognitionTaskRegistry = RecognitionTaskRegistry()
        activeRun?.recognitionTaskRegistry = recognitionTaskRegistry
        let outputBridge = RecognitionOutputBridge()
        activeRun?.outputBridge = outputBridge
        let converter: AnalyzerInputConverter
        do {
            converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("converter", error: mapped)
            throw mapped
        }
        let inputDeliveryQueue = AnalyzerInputDeliveryQueue(
            converter: converter,
            sink: { inputBridge.yield($0) },
            onDrop: { [weak self] in
                Task {
                    await self?.failCurrentRun(
                        .recognitionFailed("Speech analyzer input backpressure dropped audio."),
                        generation: generation
                    )
                }
            }
        )
        activeRun?.inputDeliveryQueue = inputDeliveryQueue
        guard preparationAudioIsStable(session: session, engine: engine, generation: generation) else {
            throw SpeechRecognitionError.audioSessionActivationFailed("Audio input changed during setup")
        }

        guard VKInstallAudioInputTap(inputNode, { buffer, time in
            tapGate.perform {
                guard inputDeliveryQueue.reserveSlot() else {
                    inputDeliveryQueue.reportDrop()
                    return
                }
                guard let copiedBuffer = buffer.copy() as? AVAudioPCMBuffer else {
                    inputDeliveryQueue.releaseReservedSlot()
                    inputDeliveryQueue.reportDrop()
                    return
                }
                inputDeliveryQueue.enqueueReserved(
                    AnalyzerAudioSample(buffer: copiedBuffer, time: time)
                )
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
                        guard self.isCurrentForAnalyzerResult(generation) else { return }
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
            recognitionTaskRegistry.register(resultTask)
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

        guard let inputNode = VKAudioEngineInputNode(engine),
              let format = VKAudioEngineInputFormat(engine) else {
            diagnostics.failure("legacy-audio-input", error: .audioInputUnavailable)
            throw .audioInputUnavailable
        }
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
        let finalizationGate = LegacyRecognitionFinalizationGate()
        activeRun?.legacyFinalizationGate = finalizationGate
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
                        guard self.activeRun?.generation == generation else { return }
                        let update = SpeechRecognitionUpdate(
                            transcript: result.bestTranscription.formattedString,
                            isFinal: result.isFinal,
                            inputLevel: nil
                        )
                        if result.isFinal {
                            self.record(update, generation: generation)
                            outputBridge.yield(update)
                            outputBridge.finish()
                            finalizationGate.markFinalResultReceived()
                        } else if self.isCurrent(generation) {
                            self.record(update, generation: generation)
                            outputBridge.yield(update)
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
        run.acceptingFinalizedAnalyzerResults = run.analyzer != nil
        activeRun = run

        // Invalidate callback gates before waiting for the converter queue.
        // A tap callback can otherwise keep enqueueing work while cleanup is
        // waiting for closeAndFlush(), making the stop path unbounded.
        let analyzerTapGate = run.analyzerTapGate
        let analyzerTapDidDrain = analyzerTapGate?.invalidate() ?? true
        run.analyzerTapGate = nil
        run.timeoutTask?.cancel()
        run.timeoutTask = nil
        let analyzer = run.analyzer
        if let recognitionTaskRegistry = run.recognitionTaskRegistry {
            run.recognitionTasks = recognitionTaskRegistry.closeAndSnapshot()
            run.recognitionTaskRegistry = nil
        }
        if analyzer == nil {
            run.analyzerTask?.cancel()
            run.analyzerTask = nil
            run.recognitionTasks.forEach { $0.cancel() }
            run.recognitionTasks.removeAll()
        }
        let legacyTapGate = run.legacyTapGate
        let legacyTapDidDrain = legacyTapGate?.invalidate() ?? true
        run.legacyTapGate = nil
        let legacyFinalizationGate = run.legacyFinalizationGate
        let legacyRequest = run.legacyRequest
        let legacyRequestHolder = legacyRequest.map(LegacyRequestHolder.init)
        run.legacyRequest = nil
        // End the request while SFSpeechRecognitionTask is still alive. The
        // final callback is asynchronous; canceling the task first can drop
        // the final utterance even though the audio tap was drained.
        if legacyTapDidDrain {
            legacyRequestHolder?.endAudioIfNeeded()
        }
        if let legacyFinalizationGate {
            _ = await legacyFinalizationGate.waitUntilFinalResult(timeout: 0.5)
        }
        run.legacyTask?.cancel()
        run.legacyTask = nil
        run.legacyFinalizationGate = nil
        var inputQueueCleanupTask: Task<Void, Never>?
        if let analyzerTapGate, !analyzerTapDidDrain {
            let drainTask = Task.detached {
                analyzerTapGate.waitUntilDrained()
            }
            _ = await waitForAnalyzerCleanup(drainTask)
        }
        if let inputDeliveryQueue = run.inputDeliveryQueue {
            let flushTask = Task { await inputDeliveryQueue.closeAndFlush() }
            if await waitForAnalyzerCleanup(flushTask) == false {
                inputQueueCleanupTask = flushTask
            }
        }
        run.inputDeliveryQueue = nil
        if inputQueueCleanupTask == nil {
            run.inputBridge?.finish()
            run.inputBridge = nil
        }
        let didFinalizeAnalyzer: Bool
        var deferredAnalyzerResultTasks: [Task<Void, Never>] = []
        var didDeferAnalyzerFinalization = false
        if let analyzer {
            // End-of-input is the normal stop signal for SpeechAnalyzer. It
            // allows a volatile final segment to be emitted before the
            // output bridge is closed.
            if let inputQueueCleanupTask {
                // The converter queue has its own serial worker. If its
                // bounded flush wait expires, finish the input bridge only
                // after the worker has delivered its final converted block;
                // otherwise the tail of the utterance is silently dropped.
                let inputBridge = run.inputBridge
                let outputBridge = run.outputBridge
                let analyzerTask = run.analyzerTask
                let recognitionTasks = run.recognitionTasks
                let deferredFinalization = Task {
                    await inputQueueCleanupTask.value
                    inputBridge?.finish()
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    } catch {
                        // The analyzer is already in terminal cleanup. The
                        // owning recognition task will close the bridge.
                    }
                    if let analyzerTask {
                        await analyzerTask.value
                    }
                    for recognitionTask in recognitionTasks {
                        await recognitionTask.value
                    }
                    outputBridge?.finish()
                }
                lingeringAnalyzerCleanupTask = deferredFinalization
                run.inputBridge = nil
                run.analyzerTask = nil
                run.recognitionTasks.removeAll()
                didDeferAnalyzerFinalization = true
                didFinalizeAnalyzer = await waitForAnalyzerCleanup(deferredFinalization)
                if didFinalizeAnalyzer {
                    lingeringAnalyzerCleanupTask = nil
                }
            } else {
                didFinalizeAnalyzer = await finalizeAnalyzerWithTimeout(analyzer)
                run.analyzerTask?.cancel()
                run.analyzerTask = nil
            }
            if didFinalizeAnalyzer, !didDeferAnalyzerFinalization {
                // SpeechAnalyzer can publish its final value before the
                // AsyncSequence consumer has observed it. Drain the result
                // consumers before cancellation or bridge closure so Stop
                // cannot discard the last utterance.
                for recognitionTask in run.recognitionTasks {
                    if await waitForAnalyzerCleanup(recognitionTask) == false {
                        deferredAnalyzerResultTasks.append(recognitionTask)
                    }
                }
            }
            if deferredAnalyzerResultTasks.isEmpty {
                run.recognitionTasks.forEach { $0.cancel() }
                run.recognitionTasks.removeAll()
            } else {
                let outputBridge = run.outputBridge
                lingeringAnalyzerCleanupTask = Task {
                    for recognitionTask in deferredAnalyzerResultTasks {
                        await recognitionTask.value
                    }
                    outputBridge?.finish()
                }
                run.recognitionTasks.removeAll()
            }
        } else {
            didFinalizeAnalyzer = false
        }
        if deferredAnalyzerResultTasks.isEmpty, !didDeferAnalyzerFinalization {
            run.outputBridge?.finish()
        }
        run.outputBridge = nil
        run.audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        run.audioObservers.removeAll()
        let pendingEngineOperation = lingeringAudioEngineOperation
        let pendingSessionActivation = pendingAudioSessionActivation
        let sessionQuarantineAlreadyScheduled = audioSessionQuarantineScheduled
        var audioQuarantineTask: Task<Void, Never>?
        if pendingSessionActivation != nil || pendingEngineOperation != nil {
            audioSessionQuarantineSucceeded = false
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio startup is still finishing; restart the keyboard extension."
            )
            diagnostics.failure("startup-quarantine", error: terminalAudioQuarantineError!)
        }
        if let pendingSessionActivation {
            audioSessionQuarantineScheduled = true
            audioSessionQuarantineSucceeded = false
            let engine = run.engine
            let tapInstalled = run.tapInstalled
            audioQuarantineTask = Task.detached { [self] in
                let activationSucceeded = await pendingSessionActivation.task.value == .succeeded
                var engineTeardownSucceeded = true
                if let engine {
                    if let analyzerTapGate { analyzerTapGate.waitUntilDrained() }
                    if let legacyTapGate { legacyTapGate.waitUntilDrained() }
                    engineTeardownSucceeded = stopAudioEngineSafely(
                        engine,
                        tapInstalled: tapInstalled
                    )
                    if !engineTeardownSucceeded {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                        await self.recordAudioEngineTeardownFailure(engine)
                    }
                }
                legacyRequestHolder?.endAudioIfNeeded()
                guard engineTeardownSucceeded else {
                    await self.setAudioSessionQuarantineResult(false)
                    return
                }
                if !activationSucceeded {
                    // A failed activation never owns an active audio session;
                    // it does not need a deactivation quarantine. Treat the
                    // cleanup as complete so a transient setup failure does
                    // not permanently poison the extension.
                    await self.setAudioSessionQuarantineResult(true)
                } else if activationSucceeded {
                    let deactivation = DeferredAudioSessionOperation(
                        session: AVAudioSession.sharedInstance(),
                        activate: false
                    )
                    if await deactivation.task.value != .succeeded {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                        await self.setAudioSessionQuarantineResult(false)
                    } else {
                        await self.setAudioSessionQuarantineResult(true)
                    }
                }
            }
        } else if let engine = run.engine, let pendingEngineOperation {
            let tapInstalled = run.tapInstalled
            if let analyzerTapGate {
                audioQuarantineTask = Task.detached { [self] in
                    _ = await pendingEngineOperation.value
                    analyzerTapGate.waitUntilDrained()
                    let didTeardown = stopAudioEngineSafely(
                        engine,
                        tapInstalled: tapInstalled
                    )
                    if !didTeardown {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                        await self.recordAudioEngineTeardownFailure(engine)
                    } else if !sessionQuarantineAlreadyScheduled {
                        await self.setAudioSessionQuarantineResult(true)
                    }
                }
            } else if let legacyTapGate {
                audioQuarantineTask = Task.detached { [self] in
                    _ = await pendingEngineOperation.value
                    legacyTapGate.waitUntilDrained()
                    let didTeardown = stopAudioEngineSafely(
                        engine,
                        tapInstalled: tapInstalled
                    )
                    if !didTeardown {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                        await self.recordAudioEngineTeardownFailure(engine)
                    } else if !sessionQuarantineAlreadyScheduled {
                        await self.setAudioSessionQuarantineResult(true)
                    }
                    legacyRequestHolder?.endAudioIfNeeded()
                }
            } else {
                audioQuarantineTask = Task.detached { [self] in
                    _ = await pendingEngineOperation.value
                    let didTeardown = stopAudioEngineSafely(
                        engine,
                        tapInstalled: tapInstalled
                    )
                    if !didTeardown {
                        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                        await self.recordAudioEngineTeardownFailure(engine)
                    } else if !sessionQuarantineAlreadyScheduled {
                        await self.setAudioSessionQuarantineResult(true)
                    }
                    legacyRequestHolder?.endAudioIfNeeded()
                }
            }
        } else if let engine = run.engine {
            if legacyRequestHolder != nil {
                let cleanup = DeferredLegacyAudioCleanup(
                    gate: legacyTapGate,
                    engine: engine,
                    request: legacyRequestHolder!,
                    tapInstalled: run.tapInstalled
                )
                if await cleanup.waitForCompletion(timeout: 2) == false {
                    KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                    audioQuarantineTask = Task { [self] in
                        let succeeded = await cleanup.quarantine().value
                        if !succeeded {
                            self.recordAudioEngineTeardownFailure(engine)
                        }
                    }
                }
            } else {
                let cleanup = DeferredAnalyzerAudioCleanup(
                    gate: analyzerTapGate,
                    engine: engine,
                    tapInstalled: run.tapInstalled
                )
                if await cleanup.waitForCompletion(timeout: 2) == false {
                    KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
                    audioQuarantineTask = Task { [self] in
                        let succeeded = await cleanup.quarantine().value
                        if !succeeded {
                            self.recordAudioEngineTeardownFailure(engine)
                        }
                    }
                }
            }
        }
        if !audioSessionQuarantineSucceeded,
           audioQuarantineTask == nil,
           lingeringAudioSessionTask == nil {
            activeRun = run
            return
        }
        run.engine = nil
        if let analyzer = run.analyzer, !didFinalizeAnalyzer {
            await cancelAnalyzerWithTimeout(analyzer)
        }
        run.analyzer = nil
        var quarantineTasks: [Task<Void, Never>] = []
        if let inputQueueCleanupTask {
            quarantineTasks.append(inputQueueCleanupTask)
        }
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
            self.lingeringAudioTeardownTask = Task { [self] in
                if await self.waitForAnalyzerCleanup(combinedQuarantineTask) == false {
                    self.markTerminalAudioQuarantine(generation: generation)
                    // Keep the terminal quarantine isolated from stopRecognition().
                    // A blocked engine/tap must not make the extension's stop path
                    // wait forever or race a session deactivation.
                    Task { [self] in
                        await combinedQuarantineTask.value
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
        KeyboardAudioSessionOperationCoordinator.shared.recoverIfIdle()
        activeRun = nil
    }

    private func finishQuarantinedCleanup(
        generation: UInt64,
        sessionActive: Bool
    ) async {
        guard activeRun?.generation == generation else { return }
        guard audioSessionQuarantineSucceeded else {
            // An unknown engine graph must remain quarantined. In particular,
            // do not deactivate or release the shared session after a failed
            // removeTap/stop wrapper call; a late callback may still own it.
            return
        }
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
        audioSessionQuarantineSucceeded = true
        terminalAudioQuarantineError = nil
        KeyboardAudioSessionOperationCoordinator.shared.recoverIfIdle()
    }

    private func deactivateAudioSession(
        _ session: AVAudioSession,
        generation: UInt64
    ) async {
        let coordinator = KeyboardAudioSessionOperationCoordinator.shared
        guard await coordinator.waitForPendingOperations(timeout: 10) else {
            KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio route recovery did not complete; restart the keyboard extension."
            )
            diagnostics.failure("audio-route-quarantine", error: terminalAudioQuarantineError!)
            let deferredCleanup = Task { [self] in
                await coordinator.waitUntilPendingOperationsSettle()
                guard !coordinator.hasPendingOperation else { return }
                let deferredDeactivation = DeferredAudioSessionOperation(
                    session: session,
                    activate: false
                )
                let status = await deferredDeactivation.task.value
                self.finishLingeringAudioSessionCleanup(
                    generation: generation,
                    succeeded: status == .succeeded
                )
            }
            lingeringAudioSessionTask = deferredCleanup
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
            lingeringAudioSessionTask = Task { [self] in
                // A timeout only means the bounded wait expired. If the
                // original deactivation eventually succeeds, no second
                // deactivation is needed (and issuing one can create a new
                // AVAudioSession race on slow HFP teardown).
                switch await operation.task.value {
                case .succeeded:
                    self.finishLingeringAudioSessionCleanup(
                        generation: generation,
                        succeeded: true
                    )
                case .failed, .timedOut:
                    let deferredDeactivation = DeferredAudioSessionOperation(
                        session: session,
                        activate: false
                    )
                    let status = await deferredDeactivation.task.value
                    self.finishLingeringAudioSessionCleanup(
                        generation: generation,
                        succeeded: status == .succeeded
                    )
                }
            }
            guard activeRun?.generation == generation else { return }
        }
    }

    private func finishLingeringAudioSessionCleanup(
        generation: UInt64,
        succeeded: Bool
    ) {
        lingeringAudioSessionTask = nil
        guard succeeded else {
            terminalAudioQuarantineError = .recognitionStartFailed(
                "Audio session deactivation failed; restart the keyboard extension."
            )
            return
        }
        if let ownershipToken = audioSessionOwnershipToken {
            KeyboardAudioSessionOperationCoordinator.shared.releaseOwnership(ownershipToken)
            audioSessionOwnershipToken = nil
        }
        if activeRun?.generation == generation {
            activeRun = nil
        }
        pendingAudioSessionActivation = nil
        lingeringAudioEngineOperation = nil
        audioSessionQuarantineScheduled = false
        audioSessionQuarantineSucceeded = true
        terminalAudioQuarantineError = nil
        KeyboardAudioSessionOperationCoordinator.shared.recoverIfIdle()
    }

    private func setAudioSessionQuarantineResult(_ succeeded: Bool) {
        audioSessionQuarantineSucceeded = succeeded
    }

    private func recordAudioEngineTeardownFailure(_ engine: AVAudioEngine) {
        terminalAudioEngine = engine
        audioSessionQuarantineSucceeded = false
        terminalAudioQuarantineError = .recognitionStartFailed(
            "Audio engine teardown failed; restart the keyboard extension."
        )
        diagnostics.failure("audio-engine-teardown", error: terminalAudioQuarantineError!)
        KeyboardAudioSessionOperationCoordinator.shared.markTerminal()
    }

    private func markTerminalAudioQuarantine(generation: UInt64) {
        guard activeRun?.generation == generation else { return }
        terminalAudioQuarantineError = .recognitionStartFailed(
            "Audio teardown did not complete; restart the keyboard extension."
        )
        diagnostics.failure("audio-quarantine", error: terminalAudioQuarantineError!)
    }

    private func cancelAnalyzerWithTimeout(_ analyzer: SpeechAnalyzer) async {
        // A timed-out finalize is still operating on the same SpeechAnalyzer.
        // Do not start cancelAndFinishNow concurrently or overwrite the only
        // retained task; the actor must observe one terminal operation at a
        // time and keep its ownership until that operation settles.
        if let lingeringAnalyzerCleanupTask {
            if await waitForAnalyzerCleanup(lingeringAnalyzerCleanupTask) {
                self.lingeringAnalyzerCleanupTask = nil
            }
            return
        }
        let cleanupTask = Task {
            await analyzer.cancelAndFinishNow()
        }
        lingeringAnalyzerCleanupTask = cleanupTask
        if await waitForAnalyzerCleanup(cleanupTask) {
            lingeringAnalyzerCleanupTask = nil
        }
    }

    private func finalizeAnalyzerWithTimeout(_ analyzer: SpeechAnalyzer) async -> Bool {
        let operation = Task { () -> Bool in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                // The bounded cancellation fallback below handles an
                // analyzer that cannot finalize after a route interruption.
                return false
            }
        }
        let cleanupTask = Task {
            _ = await operation.value
        }
        lingeringAnalyzerCleanupTask = cleanupTask
        let result: Bool? = await withCheckedContinuation { continuation in
            let gate = CleanupCompletionGate()
            Task {
                let succeeded = await operation.value
                guard gate.finish() else { return }
                continuation.resume(returning: succeeded)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                continuation.resume(returning: nil)
            }
        }
        if result != nil {
            lingeringAnalyzerCleanupTask = nil
        }
        return result == true
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
        guard let format = VKAudioEngineInputFormat(engine) else {
            run.preparationInvalidated = true
            run.preparationFailure = .audioInputUnavailable
            activeRun = run
            return
        }
        run.preparationInvalidated = false
        run.preparationGeneration = run.preparationMonitor.changeCount
        run.preparationInputUID = session.currentRoute.inputs.first?.uid
        run.preparationChannelCount = format.channelCount
        run.preparationSampleRate = format.sampleRate
        activeRun = run
    }

    private func record(_ update: SpeechRecognitionUpdate, generation: UInt64) {
        guard isCurrentForAnalyzerResult(generation) else { return }
        activeRun?.pendingUpdate = update.isFinal ? nil : update
    }

    private func flushPendingUpdate(generation: UInt64) {
        guard var run = activeRun,
              run.generation == generation,
              let pendingUpdate = run.pendingUpdate else { return }
        run.pendingUpdate = nil
        activeRun = run
        // A non-final analyzer result is still revocable. Surface it for UI
        // feedback, but do not promote it to an executable command when the
        // user stops before SpeechAnalyzer confirms the segment.
        let finalUpdate = SpeechRecognitionUpdate(
            transcript: pendingUpdate.transcript,
            isFinal: false,
            inputLevel: pendingUpdate.inputLevel?.value
        )
        run.outputBridge?.yield(finalUpdate)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        activeRun?.generation == generation && activeRun?.stopping == false
    }

    private func isCurrentForAnalyzerResult(_ generation: UInt64) -> Bool {
        guard let run = activeRun, run.generation == generation else { return false }
        return !run.stopping || run.acceptingFinalizedAnalyzerResults
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
        guard let format = VKAudioEngineInputFormat(engine) else {
            return false
        }
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

private func stopAudioEngineSafely(
    _ engine: AVAudioEngine,
    tapInstalled: Bool
) -> Bool {
    let didRemoveTap = !tapInstalled || VKRemoveAudioEngineInputTap(engine)
    let didStopEngine = VKStopAudioEngine(engine)
    return didRemoveTap && didStopEngine
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
