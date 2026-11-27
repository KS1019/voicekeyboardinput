import AVFAudio
import Foundation
import Speech
import VoiceKeyboardModels

enum AppSpeechDictationError: LocalizedError {
    case recognizerUnavailable
    case alreadyStarted
    case audioInputUnavailable
    case audioEngineStartFailed
    case emptyTranscript
    case audioInterrupted
    case audioRouteLost
    case audioConfigurationChanged
    case audioTapDrainTimedOut
    case transcriptTooLong
    case recognitionBoundaryUnavailable

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
        case .audioTapDrainTimedOut:
            "Audio input did not stop safely. Please try voice input again."
        case .transcriptTooLong:
            "Voice input is too long. Stop and start a new recording."
        case .recognitionBoundaryUnavailable:
            "Speech recognition could not preserve the audio boundary. Please try again."
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

/// Audio notifications may be posted while the audio subsystem holds a lock.
/// Callers hop to MainActor explicitly for UI/session state updates.
enum AppAudioNotifications {
    static func observe(
        _ name: Notification.Name,
        object: Any?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: nil, using: block)
    }
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
        private var routedRequest: SFSpeechAudioBufferRecognitionRequest?
        private var requestGeneration = 0
        private var callbacksByGeneration: [Int: Int] = [:]
        private struct HistoryEntry {
            let start: Int64
            let buffer: AVAudioPCMBuffer
        }
        private var history: [HistoryEntry] = []
        private var pendingReplay: [AVAudioPCMBuffer] = []
        private var totalFrames: Int64 = 0
        private var requestStartFrame: Int64 = 0
        private var sampleRate: Double = 0
        private var routedFrameCount: Int64 = 0
        private var historyIsValid = true
        private let deliver: @Sendable (AVAudioPCMBuffer, SFSpeechAudioBufferRecognitionRequest) -> Void

        init(deliver: @escaping @Sendable (AVAudioPCMBuffer, SFSpeechAudioBufferRecognitionRequest) -> Void = { buffer, request in request.append(buffer) }) {
            self.deliver = deliver
        }

        private static func copy(_ source: AVAudioPCMBuffer, offset: Int = 0, count: Int? = nil) -> AVAudioPCMBuffer? {
            let length = count ?? Int(source.frameLength)
            guard length > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(length)) else { return nil }
            copy.frameLength = AVAudioFrameCount(length)
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in sourceBuffers.indices {
                guard let sourceData = sourceBuffers[index].mData,
                      let destinationData = destinationBuffers[index].mData else { return nil }
                let bytesPerFrame = Int(sourceBuffers[index].mDataByteSize) / Int(source.frameLength)
                memcpy(destinationData, sourceData.advanced(by: offset * bytesPerFrame), length * bytesPerFrame)
            }
            return copy
        }

        func renew(to request: SFSpeechAudioBufferRecognitionRequest, recognizedEndTime: TimeInterval?) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard isActive, historyIsValid else { return false }
            guard totalFrames > requestStartFrame else {
                routeUnlocked(to: request, start: totalFrames, replay: [])
                return true
            }
            let endTime = recognizedEndTime ?? 0
            guard endTime.isFinite, endTime >= 0 else { return false }
            let boundary = requestStartFrame + Int64((endTime * sampleRate).rounded(.up))
            guard boundary <= totalFrames,
                  boundary >= (history.first?.start ?? totalFrames) else { return false }
            var replay: [AVAudioPCMBuffer] = []
            for entry in history {
                let offset = max(0, Int(boundary - entry.start))
                let count = Int(entry.buffer.frameLength) - offset
                if count > 0 {
                    guard let buffer = Self.copy(entry.buffer, offset: offset, count: count) else { return false }
                    replay.append(buffer)
                }
            }
            routeUnlocked(to: request, start: boundary, replay: replay)
            return true
        }

        private func routeUnlocked(to request: SFSpeechAudioBufferRecognitionRequest, start: Int64, replay: [AVAudioPCMBuffer]) {
            requestGeneration += 1
            routedRequest = request
            requestStartFrame = start
            pendingReplay = replay
            routedFrameCount = replay.reduce(0) { $0 + Int64($1.frameLength) }
        }

        func route(to request: SFSpeechAudioBufferRecognitionRequest) -> Int {
            condition.lock()
            defer { condition.unlock() }
            let previous = requestGeneration
            routeUnlocked(to: request, start: totalFrames, replay: [])
            return previous
        }

        func drainRequest(_ generation: Int, timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while callbacksByGeneration[generation, default: 0] > 0 {
                if !condition.wait(until: deadline) { return false }
            }
            return true
        }

        func invalidateAndFrameCount() -> Int64 {
            condition.lock()
            defer { condition.unlock() }
            isActive = false
            return routedFrameCount
        }

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
            let replay = didDrain && !isActive ? pendingReplay : []
            let destination = routedRequest
            if !replay.isEmpty {
                pendingReplay.removeAll()
                inFlightCallbacks += 1
            }
            condition.unlock()
            if let destination, !replay.isEmpty {
                replay.forEach { deliver($0, destination) }
                condition.lock()
                inFlightCallbacks -= 1
                condition.broadcast()
                condition.unlock()
            }
            return didDrain
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            condition.lock()
            guard isActive, let destination = routedRequest else {
                condition.unlock()
                return
            }
            let generation = requestGeneration
            let replay = pendingReplay
            pendingReplay.removeAll()
            if let copied = Self.copy(buffer) {
                sampleRate = buffer.format.sampleRate
                history.append(HistoryEntry(start: totalFrames, buffer: copied))
            } else {
                historyIsValid = false
            }
            totalFrames += Int64(buffer.frameLength)
            routedFrameCount += Int64(buffer.frameLength)
            let oldestFrame = totalFrames - Int64(sampleRate * 5)
            history.removeAll { $0.start + Int64($0.buffer.frameLength) <= oldestFrame }
            inFlightCallbacks += 1
            callbacksByGeneration[generation, default: 0] += 1
            condition.unlock()
            defer {
                condition.lock()
                callbacksByGeneration[generation, default: 0] -= 1
                if callbacksByGeneration[generation] == 0 {
                    callbacksByGeneration.removeValue(forKey: generation)
                    condition.broadcast()
                }
                inFlightCallbacks -= 1
                if inFlightCallbacks == 0 {
                    condition.broadcast()
                }
                condition.unlock()
            }
            replay.forEach { deliver($0, destination) }
            deliver(buffer, destination)
        }
    }

    private final class RecognitionRequestDrain: @unchecked Sendable {
        let gate: AudioTapGate
        let request: SFSpeechAudioBufferRecognitionRequest
        let generation: Int

        init(gate: AudioTapGate, request: SFSpeechAudioBufferRecognitionRequest, generation: Int) {
            self.gate = gate
            self.request = request
            self.generation = generation
        }

        func finish() -> Bool {
            guard gate.drainRequest(generation, timeout: 2) else { return false }
            request.endAudio()
            return true
        }
    }

    private final class DeferredAudioEngineCleanup: @unchecked Sendable {
        private let gate: AudioTapGate?
        private let engine: AVAudioEngine
        private let request: SFSpeechAudioBufferRecognitionRequest?
        private let tapIsInstalled: Bool
        private let engineStartTask: Task<AppAudioEngineOperationStatus, Never>?
        private let teardownLock = NSLock()
        private var teardownTask: Task<Bool, Never>?

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
            let task = retainedTeardownTask()
            return await withCheckedContinuation { continuation in
                let completionGate = AudioSessionCompletionGate()
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
                if let engineStartTask {
                    _ = await engineStartTask.value
                }
                gate?.waitUntilDrained()
                return performTeardown()
            }
            teardownTask = task
            return task
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

        private func performTeardown() -> Bool {
            let didRemoveTap = !tapIsInstalled || VKRemoveAudioEngineInputTap(engine)
            let didStopEngine = VKStopAudioEngine(engine)
            request?.endAudio()
            return didRemoveTap && didStopEngine
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
    private let maximumDuration: TimeInterval?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingError: Error?
    private var latestTranscript = ""
    private var completedTranscript = ""
    private var recognizer: SFSpeechRecognizer?
    private var pendingRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionGeneration = 0
    private var segmentDrainTask: Task<Void, Never>?
    private var didFinish = false
    private var isAwaitingFinalResult = false
    private var stopRequested = false
    private var didStart = false
    private var tapIsInstalled = false
    private var lingeringAudioEngineStartTask: Task<AppAudioEngineOperationStatus, Never>?
    private var lingeringAudioTapCleanupTask: Task<Bool, Never>?
    private var terminalAudioCleanup: DeferredAudioEngineCleanup?
    private var audioEngineQuiesced = false
    private var audioCleanupNeedsLateDeactivation = false
    private var audioSessionQuarantineScheduled = false
    private var drainWatchdogTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var audioTapGate: AudioTapGate?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var mediaServicesResetObserved = false
    private var isPreparingAudio = false
    private var preparationInvalidated = false
    private let preparationMonitor = AudioPreparationMonitor()
    private var preparationGeneration = 0
    private var preparationInputUID: String?
    private var preparationChannelCount: UInt32 = 0
    private var preparationSampleRate: Double = 0
    private var audioSessionOwnershipToken: UInt64?
    private var audioSessionGeneration: UInt64?
    private var ownershipReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(locale: Locale, maximumDuration: TimeInterval? = nil) {
        self.locale = locale
        self.maximumDuration = maximumDuration
    }

    /// Wait until the process-wide audio ownership lease is actually released.
    ///
    /// `cleanup()` can return while a timed-out AVAudioSession operation or a
    /// quarantined engine is still settling. Callers must keep this run alive
    /// until that physical teardown is complete; otherwise a new activation
    /// can race the old graph even though the user-facing task has finished.
    func waitForAudioOwnershipRelease() async {
        guard audioSessionOwnershipToken != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if audioSessionOwnershipToken == nil {
                continuation.resume()
            } else {
                ownershipReleaseWaiters.append(continuation)
            }
        }
    }

    private func signalAudioOwnershipReleased() {
        guard audioSessionOwnershipToken == nil else { return }
        let waiters = ownershipReleaseWaiters
        ownershipReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func start() async throws -> String {
        guard !didStart else {
            throw AppSpeechDictationError.alreadyStarted
        }
        didStart = true
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw AppSpeechDictationError.recognizerUnavailable
        }

        self.recognizer = recognizer
        let session = AVAudioSession.sharedInstance()
        guard let ownershipToken = AppAudioSessionOperationCoordinator.shared.acquireOwnership() else {
            throw AppSpeechDictationError.audioInputUnavailable
        }
        audioSessionOwnershipToken = ownershipToken
        audioSessionGeneration = AppAudioSessionOperationCoordinator.shared.currentGeneration()
        isPreparingAudio = true
        preparationInvalidated = false
        preparationGeneration = preparationMonitor.changeCount
        installAudioSessionObservers()
        do {
            try await setAudioSessionCategory(session)
            guard !stopRequested, !Task.isCancelled else {
                await cleanup()
                throw CancellationError()
            }
            try await activateAudioSession(session)
        } catch {
            await cleanup()
            throw error
        }
        guard !stopRequested else {
            await cleanup()
            throw CancellationError()
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
        guard !stopRequested else {
            await cleanup()
            throw CancellationError()
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

        guard let inputNode = VKAudioEngineInputNode(engine),
              let format = VKAudioEngineInputFormat(engine) else {
            await cleanup()
            throw AppSpeechDictationError.audioInputUnavailable
        }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            await cleanup()
            throw AppSpeechDictationError.audioInputUnavailable
        }
        preparationInputUID = session.currentRoute.inputs.first?.uid
        preparationChannelCount = format.channelCount
        preparationSampleRate = format.sampleRate

        let request = makeRecognitionRequest()
        self.request = request
        let tapGate = AudioTapGate()
        audioTapGate = tapGate
        tapGate.route(to: request)

        guard !stopRequested else {
            await cleanup()
            throw CancellationError()
        }
        guard preparationAudioIsStable(session: session) else {
            await cleanup()
            throw AppSpeechDictationError.audioConfigurationChanged
        }

        guard VKInstallAudioInputTap(inputNode, { buffer, _ in
            tapGate.append(buffer)
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
        guard !stopRequested else {
            await cleanup()
            throw CancellationError()
        }
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
                if stopRequested {
                    self.complete(.failure(CancellationError()))
                    return
                }
                if let pendingError {
                    self.pendingError = nil
                    self.complete(.failure(pendingError))
                    return
                }
                guard !Task.isCancelled else {
                    self.complete(.failure(CancellationError()))
                    return
                }
                startRecognition(request)

            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    private func startRecognition(_ request: SFSpeechAudioBufferRecognitionRequest) {
        recognitionGeneration += 1
        let generation = recognitionGeneration
        latestTranscript = ""
        task = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let recognizedEndTime = result?.bestTranscription.segments.last.map { $0.timestamp + $0.duration }
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration, !self.didFinish else { return }
                self.handle(transcript: transcript, isFinal: isFinal, error: error, recognizedEndTime: recognizedEndTime)
            }
        }
        timeoutTask?.cancel()
        if stopRequested {
            startFinalizationTimeout()
        } else {
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.maximumDuration ?? 45)) }
                catch { return }
                guard !Task.isCancelled, !self.didFinish else { return }
                if self.maximumDuration != nil { self.requestFinalResult() }
                else { self.rotateRecognitionRequest() }
            }
        }
    }

    private func rotateRecognitionRequest() {
        guard !didFinish, !stopRequested, pendingRecognitionRequest == nil,
              let previous = request, let gate = audioTapGate else { return }
        let next = makeRecognitionRequest()
        pendingRecognitionRequest = next
        request = next
        let previousGeneration = gate.route(to: next)
        let drain = RecognitionRequestDrain(gate: gate, request: previous, generation: previousGeneration)
        let generation = recognitionGeneration
        startFinalizationTimeout(after: 5)
        segmentDrainTask = Task { [weak self] in
            let drained = await Task.detached { drain.finish() }.value
            guard let self, !Task.isCancelled, !self.didFinish,
                  generation == self.recognitionGeneration else { return }
            guard drained else {
                self.complete(.failure(AppSpeechDictationError.audioTapDrainTimedOut))
                return
            }
            self.startFinalizationTimeout()
        }
    }

    private func handle(transcript: String?, isFinal: Bool, error: Error?, recognizedEndTime: TimeInterval? = nil) {
        guard !didFinish else { return }
        if isFinal { latestTranscript = transcript ?? "" }
        else if let transcript, !transcript.isEmpty { latestTranscript = transcript }
        if isFinal {
            guard maximumDuration == nil else {
                finishWithLatestTranscript()
                return
            }
            let separator = completedTranscript.isEmpty || latestTranscript.isEmpty ? "" : " "
            let combined = completedTranscript + separator + latestTranscript
            guard combined.isEmpty || VoiceKeyboardTextLimits.isValid(combined) else {
                complete(.failure(AppSpeechDictationError.transcriptTooLong))
                return
            }
            completedTranscript = combined
            latestTranscript = ""
            segmentDrainTask?.cancel()
            segmentDrainTask = nil
            if let next = pendingRecognitionRequest {
                pendingRecognitionRequest = nil
                task = nil
                startRecognition(next)
            } else if stopRequested {
                finishWithLatestTranscript()
            } else {
                let next = makeRecognitionRequest()
                request = next
                guard audioTapGate?.renew(to: next, recognizedEndTime: recognizedEndTime) == true else {
                    complete(.failure(AppSpeechDictationError.recognitionBoundaryUnavailable))
                    return
                }
                task = nil
                startRecognition(next)
            }
            return
        }
        if let error { complete(.failure(error)) }
    }

    private func finishWithLatestTranscript() {
        let separator = completedTranscript.isEmpty || latestTranscript.isEmpty ? "" : " "
        let transcript = completedTranscript + separator + latestTranscript
        guard !transcript.isEmpty else {
            complete(.failure(AppSpeechDictationError.emptyTranscript))
            return
        }
        complete(.success(transcript))
    }

    private func requestFinalResult() {
        guard !didFinish, !isAwaitingFinalResult else { return }
        isAwaitingFinalResult = true
        // `endAudio()` means that no more buffers will arrive. Stop and drain
        // the engine tap first so an in-flight callback cannot append after
        // Speech has started finalizing the request.
        let tapGate = audioTapGate
        tapGate?.invalidate()
        audioTapGate = nil
        let requestToEnd = request
        request = nil
        // AVAudioEngine teardown can block on Bluetooth/HFP route work. Keep
        // it off the main actor even when the tap has already drained, and
        // retain the cleanup holder until both the tap and request are safe.
        let cleanup = DeferredAudioEngineCleanup(
            gate: tapGate,
            engine: engine,
            request: requestToEnd,
            tapIsInstalled: tapIsInstalled,
            engineStartTask: nil
        )
        let coordinator = AppAudioSessionOperationCoordinator.shared
        let generation = audioSessionGeneration ?? coordinator.currentGeneration()
        let cleanupTask = Task.detached { () -> Bool in
            guard await cleanup.waitForCompletion(timeout: 2) else {
                coordinator.markTerminal(forGeneration: generation)
                let didTeardown = await cleanup.quarantine().value
                if !didTeardown { coordinator.markTerminal(forGeneration: generation) }
                return didTeardown
            }
            return true
        }
        lingeringAudioTapCleanupTask = cleanupTask
        // Do not wait indefinitely for a broken route or a stuck Speech
        // append callback before completing User Stop. The normal cleanup
        // path retains the task and keeps the audio coordinator quarantined;
        // it never deactivates the session underneath the callback.
        drainWatchdogTask?.cancel()
        drainWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      !self.didFinish,
                      self.isAwaitingFinalResult,
                      self.lingeringAudioTapCleanupTask != nil else { return }
                self.markAudioTerminal()
                self.complete(.failure(AppSpeechDictationError.audioTapDrainTimedOut))
            }
        }
        Task { [self] in
            let didTeardown = await cleanupTask.value
            await MainActor.run {
                guard self.lingeringAudioTapCleanupTask != nil else { return }
                self.drainWatchdogTask?.cancel()
                self.drainWatchdogTask = nil
                guard didTeardown else {
                    self.terminalAudioCleanup = cleanup
                    self.markAudioTerminal()
                    self.complete(.failure(AppSpeechDictationError.audioTapDrainTimedOut))
                    return
                }
                self.lingeringAudioTapCleanupTask = nil
                self.tapIsInstalled = false
                self.audioEngineQuiesced = true
                if self.didFinish {
                    // `cleanup()` may have timed out while this task was
                    // finishing on another queue. Always schedule a fresh
                    // cleanup pass after the holder is released; otherwise
                    // the timeout path can strand audio ownership.
                    self.audioCleanupNeedsLateDeactivation = false
                    Task { @MainActor [self] in
                        await self.cleanup()
                    }
                }
                guard !self.didFinish else { return }
                self.startFinalizationTimeout()
            }
        }
    }

    private func startFinalizationTimeout(after delay: TimeInterval = 3) {
        guard !didFinish else { return }
        // Speech recognition normally emits a final callback after endAudio.
        // Do not turn the last volatile hypothesis into a command if the
        // recognizer never confirms it; fail safely after a bounded grace
        // period instead.
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !self.didFinish else { return }
                self.complete(.failure(AppSpeechDictationError.emptyTranscript))
            }
        }
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

    func finishForUserStop() {
        guard !didFinish else { return }
        stopRequested = true
        // During permission, route, or engine preparation there is no Speech
        // continuation to finish yet. `start()` observes this flag after each
        // awaited setup phase and performs the normal cleanup path.
        guard continuation != nil, !isAwaitingFinalResult else { return }
        let stoppedFrameCount = audioTapGate?.invalidateAndFrameCount()
        if maximumDuration == nil, stoppedFrameCount == 0 {
            let previousRequestIsFinalizing = pendingRecognitionRequest != nil
            pendingRecognitionRequest = nil
            if !previousRequestIsFinalizing, !completedTranscript.isEmpty, latestTranscript.isEmpty {
                finishWithLatestTranscript()
                return
            }
        }
        // AVAudioEngine.start() runs off-main. Never call removeTap/stop on
        // the same engine until that operation has settled; doing so can
        // trigger an audio graph assertion or deadlock on rapid Stop.
        if let engineStartTask = lingeringAudioEngineStartTask {
            pendingStopTask?.cancel()
            pendingStopTask = Task { [weak self] in
                let didSettle = await self?.waitForAudioEngineStart(
                    engineStartTask,
                    timeout: 2
                ) ?? true
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if didSettle {
                        self.requestFinalResult()
                    } else {
                        self.markAudioTerminal()
                        self.complete(.failure(AppSpeechDictationError.audioEngineStartFailed))
                    }
                }
            }
            return
        }
        requestFinalResult()
    }

    private func waitForAudioEngineStart(
        _ operation: Task<AppAudioEngineOperationStatus, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = AudioSessionCompletionGate()
            Task {
                _ = await operation.value
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

    private func installAudioSessionObservers() {
        let preparationMonitor = self.preparationMonitor
        interruptionObserver = AppAudioNotifications.observe(
            AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        ) { [weak self, preparationMonitor] notification in
            preparationMonitor.markChanged()
            guard let interruptionTypeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue),
                  interruptionType == .began else { return }
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioInterrupted))
            }
        }
        routeChangeObserver = AppAudioNotifications.observe(
            AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                guard let self else { return }
                if self.isPreparingAudio || self.isAwaitingFinalResult || self.didFinish {
                    // Route changes caused by selecting the preferred HFP
                    // input are expected during setup. The stable baseline
                    // is captured after routing settles.
                    return
                }
                // A Bluetooth HFP disconnect may silently fall back to the
                // built-in microphone. Treat any post-setup route/format UID
                // change as a failed run instead of feeding the old tap format
                // into the recognizer.
                guard !self.audioConfigurationMatchesPreparedRoute(
                    session: AVAudioSession.sharedInstance()
                ) else {
                    return
                }
                self.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        engineConfigurationObserver = AppAudioNotifications.observe(
            .AVAudioEngineConfigurationChange,
            object: engine
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                guard let self else { return }
                if self.isPreparingAudio || self.isAwaitingFinalResult || self.didFinish {
                    // AVAudioEngine can report a configuration change while
                    // the selected HFP route is being materialized. The
                    // stable format check below is the setup-time authority.
                    return
                }
                self.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesLostObserver = AppAudioNotifications.observe(
            AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance()
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesResetObserver = AppAudioNotifications.observe(
            AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        ) { [weak self, preparationMonitor] _ in
            preparationMonitor.markChanged()
            Task { @MainActor in
                self?.handleMediaServicesReset()
            }
        }
    }

    private func handleMediaServicesReset() {
        guard !mediaServicesResetObserved else { return }
        mediaServicesResetObserved = true
        preparationInvalidated = true

        // Media services reset invalidates the old AVAudioEngine graph and
        // any in-flight AVAudioSession operation. Do not let a pre-reset
        // callback keep the process-wide audio fence latched for the next
        // run; the old graph is no longer a usable owner.
        let coordinator = AppAudioSessionOperationCoordinator.shared
        coordinator.recoverAfterMediaServicesReset()
        releaseAudioSessionOwnershipAfterMediaServicesReset()

        if !didFinish {
            complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
        }
    }

    private func cleanup() async {
        isPreparingAudio = false
        pendingError = nil
        pendingStopTask?.cancel()
        pendingStopTask = nil
        segmentDrainTask?.cancel()
        segmentDrainTask = nil
        pendingRecognitionRequest = nil
        recognitionGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        drainWatchdogTask?.cancel()
        drainWatchdogTask = nil
        let audioTapGate = self.audioTapGate
        audioTapGate?.invalidate()
        self.audioTapGate = nil
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
        let coordinator = AppAudioSessionOperationCoordinator.shared
        if mediaServicesResetObserved {
            lingeringAudioTapCleanupTask?.cancel()
            lingeringAudioTapCleanupTask = nil
            terminalAudioCleanup = nil
            releaseAudioSessionOwnershipAfterMediaServicesReset()
            removeMediaServicesObservers()
            return
        }
        let session = AVAudioSession.sharedInstance()
        if let lingeringAudioTapCleanupTask {
            let didFinish = await waitForAudioCleanup(lingeringAudioTapCleanupTask, timeout: 2)
            if mediaServicesResetObserved {
                releaseAudioSessionOwnershipAfterMediaServicesReset()
                removeMediaServicesObservers()
                return
            }
            if !didFinish {
                markAudioTerminal()
                audioCleanupNeedsLateDeactivation = true
                // The task retains the engine, tap gate, and request until
                // teardown returns. A hard failure keeps the coordinator
                // terminal and deliberately retains session ownership; a
                // later run must never deactivate an unknown graph.
                return
            }
            self.lingeringAudioTapCleanupTask = nil
            self.tapIsInstalled = false
            self.audioEngineQuiesced = true
        }
        if mediaServicesResetObserved {
            releaseAudioSessionOwnershipAfterMediaServicesReset()
            removeMediaServicesObservers()
            return
        }
        let hasPendingSessionOperation = coordinator.hasPendingSessionOperation
        if hasPendingSessionOperation {
            // A stop racing an in-flight AVAudioSession call must not allow a
            // later run to reuse the shared session before that call settles.
            markAudioTerminal()
        }
        let requestToEnd = self.request
        self.request = nil
        if !audioEngineQuiesced {
            let engineCleanup = DeferredAudioEngineCleanup(
                gate: audioTapGate,
                engine: engine,
                request: requestToEnd,
                tapIsInstalled: tapIsInstalled,
                engineStartTask: lingeringAudioEngineStartTask
            )
            guard await engineCleanup.waitForCompletion(timeout: 2) else {
                markAudioTerminal()
                terminalAudioCleanup = engineCleanup
                let deferredCleanupTask = engineCleanup.quarantine()
                lingeringAudioTapCleanupTask = deferredCleanupTask
                audioCleanupNeedsLateDeactivation = true
                Task { [self] in
                    let didTeardown = await deferredCleanupTask.value
                    await MainActor.run {
                        guard self.lingeringAudioTapCleanupTask != nil else { return }
                        guard didTeardown else {
                            self.markAudioTerminal()
                            return
                        }
                        self.lingeringAudioTapCleanupTask = nil
                        self.tapIsInstalled = false
                        self.audioEngineQuiesced = true
                        self.audioCleanupNeedsLateDeactivation = false
                        Task { @MainActor [self] in
                            await self.cleanup()
                        }
                    }
                }
                // Do not touch AVAudioSession after a failed wrapper call.
                // The retained cleanup holder owns the unknown engine graph
                // and the terminal fence blocks reuse.
                return
            }
            tapIsInstalled = false
            audioEngineQuiesced = true
        }
        if mediaServicesResetObserved {
            releaseAudioSessionOwnershipAfterMediaServicesReset()
            removeMediaServicesObservers()
            return
        }
        if hasPendingSessionOperation {
            // The operation may be a late activation that completes after
            // this bounded cleanup returns. Keep ownership and let the
            // coordinator perform exactly one deactivation after it settles.
            if !audioSessionQuarantineScheduled {
                scheduleDeferredAudioSessionDeactivation(session)
            }
            return
        }
        // Acquire the deactivation token only after engine cleanup succeeds.
        // If cleanup times out, the deferred retry must be able to acquire a
        // fresh token; reserving one before the timeout leaves the coordinator
        // permanently occupied by an operation that never started.
        let deactivationToken = await acquireDeactivationToken(
            expectedGeneration: audioSessionGeneration
        )
        if mediaServicesResetObserved {
            releaseAudioSessionOwnershipAfterMediaServicesReset()
            removeMediaServicesObservers()
            return
        }
        guard let deactivationToken else {
            markAudioTerminal()
            releaseAudioSessionOwnershipAfterTerminal()
            removeMediaServicesObservers()
            return
        }
        if await deactivateAudioSession(session, operationToken: deactivationToken) {
            coordinator.completeDeactivationPending()
            releaseAudioSessionOwnershipIfSafe()
        } else {
            // A failed deactivation has its own coordinator quarantine. Keep
            // ownership until that path proves the session is safe again.
            markAudioTerminal()
            releaseAudioSessionOwnershipAfterTerminal()
        }
        removeMediaServicesObservers()
    }

    private func removeMediaServicesObservers() {
        if let mediaServicesLostObserver {
            NotificationCenter.default.removeObserver(mediaServicesLostObserver)
            self.mediaServicesLostObserver = nil
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
    }

    private func preparationAudioIsStable(session: AVAudioSession) -> Bool {
        guard !isAwaitingFinalResult,
              !didFinish,
              !preparationInvalidated,
              preparationMonitor.changeCount == preparationGeneration,
              let input = session.currentRoute.inputs.first else {
            return false
        }
        guard let format = VKAudioEngineInputFormat(engine) else {
            return false
        }
        return input.uid == preparationInputUID
            && format.channelCount == preparationChannelCount
            && format.sampleRate == preparationSampleRate
    }

    private func audioConfigurationMatchesPreparedRoute(session: AVAudioSession) -> Bool {
        guard let input = session.currentRoute.inputs.first else { return false }
        guard let format = VKAudioEngineInputFormat(engine) else {
            return false
        }
        return input.uid == preparationInputUID
            && format.channelCount == preparationChannelCount
            && format.sampleRate == preparationSampleRate
    }

    private func prepareAndStartAudioEngine() async throws {
        let engine = self.engine
        let operation = Task.detached { () -> AppAudioEngineOperationStatus in
            VKPrepareAndStartAudioEngine(engine) ? .succeeded : .failed
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
            markAudioTerminal()
            throw AppSpeechDictationError.audioEngineStartFailed
        }
    }

    private func setAudioSessionCategory(_ session: AVAudioSession) async throws {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        let operationGeneration = coordinator.beginSessionOperation()
        let operation = Task.detached { () -> AppAudioEngineOperationStatus in
            defer { coordinator.completeSessionOperation(operationGeneration) }
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
            markAudioTerminal()
            throw AudioSessionOperationError.timedOut
        }
    }

    private func scheduleDeferredAudioSessionDeactivation(_ session: AVAudioSession) {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        let generation = audioSessionGeneration ?? coordinator.currentGeneration()
        coordinator.beginDeactivationPending()
        Task { @MainActor [self] in
            guard await coordinator.waitForPendingSessionOperationsUntilSettled(
                generation: generation
            ) else {
                coordinator.markTerminal(forGeneration: generation)
                self.releaseAudioSessionOwnershipAfterTerminal()
                scheduleLateAnonymousAudioSessionDeactivation(
                    session,
                    coordinator: coordinator,
                    generation: generation
                )
                return
            }
            if Task.isCancelled {
                coordinator.markTerminal(forGeneration: generation)
                self.releaseAudioSessionOwnershipAfterTerminal()
                scheduleLateAnonymousAudioSessionDeactivation(
                    session,
                    coordinator: coordinator,
                    generation: generation
                )
                return
            }
            if coordinator.hasPendingSessionOperation(forGeneration: generation) {
                // A late AVAudioSession callback may still activate the
                // session after the user-facing timeout. Keep the terminal
                // fence; the user-facing run lease can be released because
                // the coordinator will reject new activation until the
                // pending operation is resolved.
                coordinator.markTerminal(forGeneration: generation)
                self.releaseAudioSessionOwnershipAfterTerminal()
                scheduleLateAnonymousAudioSessionDeactivation(
                    session,
                    coordinator: coordinator,
                    generation: generation
                )
                return
            }
            for _ in 0..<40 where !Task.isCancelled {
                if coordinator.isTerminal {
                    if let operationToken = coordinator.beginForCleanup(
                        expectedGeneration: generation
                    ) {
                        let didDeactivate = await self.deactivateAudioSession(
                            session,
                            operationToken: operationToken
                        )
                        coordinator.completeDeactivationPending(
                            deactivationSucceeded: didDeactivate
                        )
                        if didDeactivate {
                            self.releaseAudioSessionOwnershipIfSafe()
                        } else {
                            coordinator.markTerminal(forGeneration: generation)
                            self.releaseAudioSessionOwnershipAfterTerminal()
                        }
                    } else {
                        coordinator.completeDeactivationPending(
                            deactivationSucceeded: false
                        )
                        coordinator.markTerminal(forGeneration: generation)
                        self.releaseAudioSessionOwnershipAfterTerminal()
                    }
                    return
                }
                guard let operationToken = await coordinator.beginWhenAvailable(
                    expectedGeneration: generation
                ) else {
                    continue
                }
                let didDeactivate = await self.deactivateAudioSession(
                    session,
                    operationToken: operationToken
                )
                coordinator.completeDeactivationPending(
                    deactivationSucceeded: didDeactivate
                )
                if didDeactivate {
                    self.releaseAudioSessionOwnershipIfSafe()
                } else {
                    coordinator.markTerminal(forGeneration: generation)
                    self.releaseAudioSessionOwnershipAfterTerminal()
                }
                return
            }
            coordinator.markTerminal(forGeneration: generation)
            coordinator.completeDeactivationPending(deactivationSucceeded: false)
            self.releaseAudioSessionOwnershipAfterTerminal()
        }
    }

    /// The user-facing run must not be retained while an AVAudioSession
    /// callback is stalled. Keep only a coordinator-owned cleanup observer;
    /// once the original operation settles, deactivate the session exactly
    /// once and close the anonymous deactivation barrier.
    private func scheduleLateAnonymousAudioSessionDeactivation(
        _ session: AVAudioSession,
        coordinator: AppAudioSessionOperationCoordinator,
        generation: UInt64
    ) {
        Task.detached {
            while coordinator.hasPendingSessionOperation(forGeneration: generation) {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  coordinator.isCurrentGeneration(generation),
                  let operationToken = coordinator.beginForCleanup(
                    expectedGeneration: generation
                  ) else {
                coordinator.markTerminal(forGeneration: generation)
                coordinator.completeDeactivationPending(
                    deactivationSucceeded: false
                )
                return
            }
            let operation = Task.detached { () -> AppAudioEngineOperationStatus in
                let operationGeneration = coordinator.beginSessionOperation()
                defer { coordinator.completeSessionOperation(operationGeneration) }
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    return .succeeded
                } catch {
                    return .failed
                }
            }
            let status = await operation.value
            coordinator.finish(operationToken)
            switch status {
            case .succeeded:
                coordinator.completeDeactivationPending(
                    deactivationSucceeded: true
                )
            case .failed, .timedOut:
                coordinator.markTerminal(forGeneration: generation)
                coordinator.completeDeactivationPending(
                    deactivationSucceeded: false
                )
            }
        }
    }

    private func releaseAudioSessionOwnershipAfterTerminal() {
        guard let ownershipToken = audioSessionOwnershipToken else { return }
        AppAudioSessionOperationCoordinator.shared.releaseOwnershipAfterTerminal(ownershipToken)
        audioSessionOwnershipToken = nil
        audioSessionGeneration = nil
        signalAudioOwnershipReleased()
    }

    private func releaseAudioSessionOwnershipAfterMediaServicesReset() {
        guard audioSessionOwnershipToken != nil else { return }
        AppAudioSessionOperationCoordinator.shared.releaseOwnershipAfterMediaServicesReset()
        audioSessionOwnershipToken = nil
        audioSessionGeneration = nil
        signalAudioOwnershipReleased()
    }

    private func acquireDeactivationToken(expectedGeneration: UInt64? = nil) async -> UInt64? {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        if let token = await coordinator.beginWhenAvailable(
            expectedGeneration: expectedGeneration
        ) {
            return token
        }
        return coordinator.isTerminal
            ? coordinator.beginForCleanup(expectedGeneration: expectedGeneration)
            : nil
    }

    private func releaseAudioSessionOwnershipIfSafe() {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let ownershipToken = audioSessionOwnershipToken else { return }
        let didRelease = coordinator.releaseOwnershipWhenIdle(ownershipToken)
        guard didRelease else {
            Task { @MainActor [self] in
                await coordinator.waitForOwnershipRelease(ownershipToken)
                guard self.audioSessionOwnershipToken == ownershipToken else { return }
                self.audioSessionOwnershipToken = nil
                self.audioSessionGeneration = nil
                self.signalAudioOwnershipReleased()
            }
            return
        }
        audioSessionOwnershipToken = nil
        audioSessionGeneration = nil
        signalAudioOwnershipReleased()
    }

    private func markAudioTerminal() {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let generation = audioSessionGeneration else { return }
        coordinator.markTerminal(forGeneration: generation)
    }

    private func scheduleActivationAudioSessionQuarantine(
        _ session: AVAudioSession,
        coordinator: AppAudioSessionOperationCoordinator,
        operationToken: UInt64
    ) {
        audioSessionQuarantineScheduled = true
        scheduleAudioSessionQuarantine(
            session,
            coordinator: coordinator,
            operationToken: operationToken
        ) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                self?.completeActivationAudioSessionQuarantine(succeeded: succeeded)
            }
        }
    }

    private func completeActivationAudioSessionQuarantine(succeeded: Bool) {
        guard audioSessionQuarantineScheduled else { return }
        audioSessionQuarantineScheduled = false
        if succeeded {
            releaseAudioSessionOwnershipIfSafe()
        } else {
            markAudioTerminal()
            releaseAudioSessionOwnershipAfterTerminal()
        }
    }

    private func waitForAudioCleanup(
        _ cleanupTask: Task<Bool, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = AudioSessionCompletionGate()
            Task {
                let succeeded = await cleanupTask.value
                guard gate.finish() else { return }
                continuation.resume(returning: succeeded)
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
                let operationGeneration = coordinator.beginSessionOperation()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.markTerminal(forGeneration: operationGeneration)
                    coordinator.invalidateAndHold(operationToken)
                    scheduleActivationAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume(throwing: AudioSessionOperationError.timedOut)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    session.activate(options: []) { activated, error in
                        coordinator.completeSessionOperation(operationGeneration)
                        let isCurrent = coordinator.isCurrent(operationToken)
                        let wonCompletion = gate.finish()
                        guard isCurrent && wonCompletion else {
                            if coordinator.recordActivationCallbackDuringFallback(
                                operationToken,
                                activated: activated && error == nil
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
            let operationGeneration = coordinator.beginSessionOperation()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.markTerminal(forGeneration: operationGeneration)
                coordinator.invalidateAndHold(operationToken)
                scheduleActivationAudioSessionQuarantine(
                    session,
                    coordinator: coordinator,
                    operationToken: operationToken
                )
                continuation.resume(throwing: AudioSessionOperationError.timedOut)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.completeSessionOperation(operationGeneration)
                    if coordinator.recordActivationCallbackDuringFallback(operationToken, activated: false) {
                        return
                    }
                    coordinator.finish(operationToken)
                    return
                }
                do {
                    try session.setActive(true)
                    coordinator.completeSessionOperation(operationGeneration)
                    let isCurrent = coordinator.isCurrent(operationToken)
                    let wonCompletion = gate.finish()
                    guard isCurrent && wonCompletion else {
                        if coordinator.recordActivationCallbackDuringFallback(operationToken, activated: true) {
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
                    coordinator.completeSessionOperation(operationGeneration)
                    guard coordinator.isCurrent(operationToken), gate.finish() else {
                        if coordinator.recordActivationCallbackDuringFallback(operationToken, activated: false) {
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
    ) async -> Bool {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        if #available(iOS 27.0, *) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let gate = AudioSessionCompletionGate()
                let operationGeneration = coordinator.beginSessionOperation()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.markTerminal(forGeneration: operationGeneration)
                    coordinator.invalidateAndHold(operationToken)
                    scheduleAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume(returning: false)
                }
                DispatchQueue.global(qos: .utility).async {
                    session.deactivate(options: .notifyOthersOnDeactivation) { success, error in
                        coordinator.completeSessionOperation(operationGeneration)
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
                            coordinator.markTerminal(forGeneration: operationGeneration)
                            coordinator.invalidateAndHold(operationToken)
                            scheduleAudioSessionQuarantine(
                                session,
                                coordinator: coordinator,
                                operationToken: operationToken
                            )
                            continuation.resume(returning: false)
                            return
                        }
                        coordinator.finish(operationToken)
                        continuation.resume(returning: true)
                    }
                }
            }
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = AudioSessionCompletionGate()
            let operationGeneration = coordinator.beginSessionOperation()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.markTerminal(forGeneration: operationGeneration)
                coordinator.invalidateAndHold(operationToken)
                scheduleAudioSessionQuarantine(
                    session,
                    coordinator: coordinator,
                    operationToken: operationToken
                )
                continuation.resume(returning: false)
            }
            DispatchQueue.global(qos: .utility).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.completeSessionOperation(operationGeneration)
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
                coordinator.completeSessionOperation(operationGeneration)
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
                    coordinator.markTerminal(forGeneration: operationGeneration)
                    coordinator.invalidateAndHold(operationToken)
                    scheduleAudioSessionQuarantine(
                        session,
                        coordinator: coordinator,
                        operationToken: operationToken
                    )
                    continuation.resume(returning: false)
                    return
                }
                coordinator.finish(operationToken)
                continuation.resume(returning: true)
            }
        }
    }

#if DEBUG
    private var testCompletionReadinessContinuation: CheckedContinuation<Void, Never>?

    static func testRun(maximumDuration: TimeInterval) -> AppSpeechDictationRun {
        AppSpeechDictationRun(locale: Locale(identifier: "en_US"), maximumDuration: maximumDuration)
    }

    private final class AudioReplayTestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [ObjectIdentifier: [Float]] = [:]

        func append(_ buffer: AVAudioPCMBuffer, to request: SFSpeechAudioBufferRecognitionRequest) {
            lock.lock()
            defer { lock.unlock() }
            let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            samples[ObjectIdentifier(request), default: []].append(contentsOf: values)
        }

        func values(for request: SFSpeechAudioBufferRecognitionRequest) -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples[ObjectIdentifier(request), default: []]
        }
    }

    private final class AudioReplayTestBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    static func testAtomicStopAgainstAudioCallback() -> Bool {
        for _ in 0..<40 {
            let recorder = AudioReplayTestRecorder()
            let gate = AudioTapGate { recorder.append($0, to: $1) }
            let request = SFSpeechAudioBufferRecognitionRequest()
            let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            buffer.frameLength = 1
            buffer.floatChannelData![0][0] = 0.0001
            let box = AudioReplayTestBuffer(buffer)
            let done = DispatchSemaphore(value: 0)
            gate.route(to: request)
            Thread {
                gate.append(box.buffer)
                done.signal()
            }.start()
            let frames = gate.invalidateAndFrameCount()
            guard done.wait(timeout: .now() + 1) == .success else { return false }
            gate.waitUntilDrained()
            if Int64(recorder.values(for: request).count) != frames { return false }
        }
        return true
    }

    static func testReplayedAudio(input: [Float], recognizedEndTime: TimeInterval?, tail: [Float]) -> [Float]? {
        let recorder = AudioReplayTestRecorder()
        let gate = AudioTapGate { recorder.append($0, to: $1) }
        let first = SFSpeechAudioBufferRecognitionRequest()
        let second = SFSpeechAudioBufferRecognitionRequest()
        let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
        func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
            return buffer
        }
        gate.route(to: first)
        gate.append(buffer(input))
        guard gate.renew(to: second, recognizedEndTime: recognizedEndTime) else { return nil }
        if !tail.isEmpty { gate.append(buffer(tail)) }
        gate.invalidate()
        gate.waitUntilDrained()
        return recorder.values(for: second)
    }

    static func testContinuousRun() -> AppSpeechDictationRun {
        let run = AppSpeechDictationRun(locale: Locale(identifier: "en_US"))
        let request = run.makeRecognitionRequest()
        run.request = request
        let gate = AudioTapGate()
        gate.route(to: request)
        run.audioTapGate = gate
        run.startRecognition(request)
        return run
    }

    var testRecognitionGeneration: Int { recognitionGeneration }
    var testDidFinish: Bool { didFinish }
    var testHasPendingRecognition: Bool { pendingRecognitionRequest != nil }

    func testReceiveRecognition(_ transcript: String, isFinal: Bool, generation: Int? = nil) {
        guard generation == nil || generation == recognitionGeneration else { return }
        handle(transcript: transcript, isFinal: isFinal, error: nil)
    }

    func testRotateRecognition() { rotateRecognitionRequest() }

    func testAppendSilentAudio() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        buffer.frameLength = 10
        for index in 0..<10 { buffer.floatChannelData![0][index] = 0 }
        audioTapGate?.append(buffer)
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

private final class AudioQuarantineCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

private func scheduleAudioSessionQuarantine(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64,
    onFinished: @escaping @Sendable (Bool) -> Void = { _ in }
) {
    let generation = coordinator.currentGeneration()
    let completionGate = AudioQuarantineCompletionGate()
    let finish: @Sendable (Bool) -> Bool = { succeeded in
        guard completionGate.finish() else { return false }
        onFinished(succeeded)
        return true
    }
    guard coordinator.beginDeactivationPending(for: operationToken) else {
        _ = finish(false)
        return
    }
    Task {
        try? await Task.sleep(for: .seconds(2))
        guard await coordinator.waitForPendingSessionOperationsUntilSettled(generation: generation) else {
            coordinator.markTerminal(forGeneration: generation)
            // The user-facing run may finish now, but the AVAudioSession
            // operation can still settle later. Keep a coordinator-only
            // observer so a late callback can perform the matching cleanup
            // instead of leaving the quarantine token latched forever.
            scheduleLateAudioSessionQuarantineSettlement(
                session,
                coordinator: coordinator,
                operationToken: operationToken,
                generation: generation,
                finish: finish
            )
            return
        }
        startAudioSessionQuarantineFallback(
            session,
            coordinator: coordinator,
            operationToken: operationToken,
            generation: generation,
            finish: finish
        )
    }
}

private func scheduleLateAudioSessionQuarantineSettlement(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64,
    generation: UInt64,
    finish: @escaping @Sendable (Bool) -> Bool
) {
    Task.detached {
        while coordinator.hasPendingSessionOperation(forGeneration: generation) {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              coordinator.isCurrentGeneration(generation) else { return }
        if coordinator.completeDeactivationPendingIfOperationFinished(operationToken) {
            _ = finish(true)
            return
        }
        guard coordinator.beginFallbackDeactivation(operationToken) else {
            // A late callback may have settled the token between the pending
            // counter reaching zero and this claim. Resolve that race as
            // success when the coordinator records a finished operation.
            _ = finish(coordinator.completeDeactivationPendingIfOperationFinished(operationToken))
            return
        }
        runAudioSessionQuarantineFallback(
            session,
            coordinator: coordinator,
            operationToken: operationToken,
            generation: generation,
            finish: finish
        )
    }
}

private func startAudioSessionQuarantineFallback(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64,
    generation: UInt64,
    finish: @escaping @Sendable (Bool) -> Bool
) {
    guard coordinator.beginFallbackDeactivation(operationToken) else {
        _ = finish(coordinator.completeDeactivationPendingIfOperationFinished(operationToken))
        return
    }
    runAudioSessionQuarantineFallback(
        session,
        coordinator: coordinator,
        operationToken: operationToken,
        generation: generation,
        finish: finish
    )
}

private func runAudioSessionQuarantineFallback(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64,
    generation: UInt64,
    finish: @escaping @Sendable (Bool) -> Bool
) {
    Task {
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        // This is only a user-facing timeout. Keep the fallback token alive so
        // a much later AVAudioSession completion can still close the pending
        // quarantine and clear the terminal fence.
        guard finish(false) else { return }
        coordinator.markTerminal(forGeneration: generation)
    }
    let operationGeneration = coordinator.beginSessionOperation()
    DispatchQueue.global(qos: .utility).async {
        let succeeded: Bool
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            succeeded = true
        } catch {
            succeeded = false
        }
        coordinator.completeSessionOperation(operationGeneration)
        let result = coordinator.completeFallbackDeactivation(
            operationToken,
            succeeded: succeeded
        )
        switch result {
        case .succeeded:
            coordinator.completeDeactivationPending(for: operationToken)
            _ = finish(true)
        case .failed:
            coordinator.completeDeactivationPending(
                for: operationToken,
                deactivationSucceeded: false
            )
            _ = finish(false)
        case .ignored:
            _ = coordinator.completeDeactivationPendingIfOperationFinished(operationToken)
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
        let operationGeneration = coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            session.deactivate(options: .notifyOthersOnDeactivation) { success, error in
                coordinator.completeSessionOperation(operationGeneration)
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
        let operationGeneration = coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                coordinator.completeSessionOperation(operationGeneration)
                if coordinator.recordCallbackDuringLateFallback(
                    operationToken,
                    succeeded: true
                ) {
                    return
                }
                coordinator.finish(operationToken)
            } catch {
                coordinator.completeSessionOperation(operationGeneration)
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

enum AppAudioDeactivationResult {
    case ignored
    case succeeded
    case failed
}

private func scheduleLateDeactivationWatchdog(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) {
    Task {
        try? await Task.sleep(for: .seconds(2))
        guard await coordinator.waitForPendingSessionOperationsUntilSettled() else {
            coordinator.markTerminalIfCurrent(operationToken)
            scheduleLateDeactivationFallbackAfterPending(
                session,
                coordinator: coordinator,
                operationToken: operationToken
            )
            return
        }
        startLateDeactivationFallback(
            session,
            coordinator: coordinator,
            operationToken: operationToken
        )
    }
}

private func scheduleLateDeactivationFallbackAfterPending(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) {
    Task.detached {
        while coordinator.hasPendingSessionOperation {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        startLateDeactivationFallback(
            session,
            coordinator: coordinator,
            operationToken: operationToken
        )
    }
}

private func startLateDeactivationFallback(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) {
        guard coordinator.beginLateDeactivationFallback(operationToken) else {
            // The original late callback may have completed in the small
            // window between the operation wait and this watchdog. It already
            // called finish(), so release the quarantine token here as well;
            // otherwise deactivationPending remains latched forever.
            coordinator.completeDeactivationPendingIfOperationFinished(operationToken)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            // Keep the late-fallback token alive after the user-facing
            // timeout. A delayed AVAudioSession callback must still be able
            // to close the pending quarantine and clear the terminal fence.
            coordinator.markTerminalIfCurrent(operationToken)
        }
        let operationGeneration = coordinator.beginSessionOperation()
        DispatchQueue.global(qos: .utility).async {
            let succeeded: Bool
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                succeeded = true
            } catch {
                succeeded = false
            }
            coordinator.completeSessionOperation(operationGeneration)
            switch coordinator.completeLateDeactivationFallback(
                operationToken,
                succeeded: succeeded
            ) {
            case .succeeded:
                coordinator.completeDeactivationPending(for: operationToken)
            case .failed:
                coordinator.completeDeactivationPending(
                    for: operationToken,
                    deactivationSucceeded: false
                )
            case .ignored:
                break
            }
        }
}

final class AppAudioSessionOperationCoordinator: @unchecked Sendable {
    static let shared = AppAudioSessionOperationCoordinator()

    private let lock = NSLock()
    private var audioGeneration: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var currentToken: UInt64?
    private var tokenGenerations: [UInt64: UInt64] = [:]
    private var invalidatedTokens: Set<UInt64> = []
    private var lateDeactivationTokens: Set<UInt64> = []
    private var fallbackDeactivationTokens: Set<UInt64> = []
    private var callbackObservedDuringFallback: Set<UInt64> = []
    private var activationCallbackObservedDuringFallback: Set<UInt64> = []
    private var lateFallbackDeactivationTokens: Set<UInt64> = []
    private var callbackObservedDuringLateFallback: Set<UInt64> = []
    private var retiredTokens: Set<UInt64> = []
    private var terminalTokens: Set<UInt64> = []
    private var finishedTokens: Set<UInt64> = []
    private var isTerminalState = false
    private var pendingSessionOperations: [UInt64: Int] = [:]
    private var deactivationPending = false
    private var anonymousDeactivationPendingCount = 0
    private var nextOwnerToken: UInt64 = 0
    private var ownerToken: UInt64?
    private var deferredOwnerReleaseToken: UInt64?
    private var scheduledQuarantineTokens: Set<UInt64> = []

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminalState,
              currentToken == nil,
              pendingSessionOperations[audioGeneration, default: 0] == 0,
              !deactivationPending else { return nil }
        nextToken &+= 1
        currentToken = nextToken
        tokenGenerations[nextToken] = audioGeneration
        return nextToken
    }

    func beginForCleanup(expectedGeneration: UInt64? = nil) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == nil,
              expectedGeneration == nil || expectedGeneration == audioGeneration else {
            return nil
        }
        nextToken &+= 1
        currentToken = nextToken
        tokenGenerations[nextToken] = audioGeneration
        return nextToken
    }

    func beginWhenAvailable(expectedGeneration: UInt64? = nil) async -> UInt64? {
        for _ in 0..<40 {
            if let expectedGeneration,
               expectedGeneration != currentGeneration() {
                return nil
            }
            if isTerminal {
                return nil
            }
            if let token = begin(expectedGeneration: expectedGeneration) {
                return token
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func begin(expectedGeneration: UInt64? = nil) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard expectedGeneration == nil || expectedGeneration == audioGeneration,
              !isTerminalState,
              currentToken == nil,
              pendingSessionOperations[audioGeneration, default: 0] == 0,
              !deactivationPending else { return nil }
        nextToken &+= 1
        currentToken = nextToken
        tokenGenerations[nextToken] = audioGeneration
        return nextToken
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return audioGeneration
    }

    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioGeneration == generation
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTerminalState
    }

    var hasPendingSessionOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSessionOperations[audioGeneration, default: 0] > 0
    }

    func hasPendingSessionOperation(forGeneration generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSessionOperations[generation, default: 0] > 0
    }

    @discardableResult
    func beginSessionOperation() -> UInt64 {
        lock.lock()
        let generation = audioGeneration
        pendingSessionOperations[generation, default: 0] += 1
        lock.unlock()
        return generation
    }

    func completeSessionOperation(_ generation: UInt64? = nil) {
        lock.lock()
        let generation = generation ?? audioGeneration
        if let count = pendingSessionOperations[generation] {
            if count <= 1 {
                pendingSessionOperations.removeValue(forKey: generation)
            } else {
                pendingSessionOperations[generation] = count - 1
            }
        }
        lock.unlock()
    }

    func waitForPendingSessionOperations(
        timeout: TimeInterval,
        generation: UInt64? = nil
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while generation.map({ hasPendingSessionOperation(forGeneration: $0) })
            ?? hasPendingSessionOperation {
            guard ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    func waitForPendingSessionOperationsUntilSettled(
        timeout: TimeInterval = 10,
        generation: UInt64? = nil
    ) async -> Bool {
        await waitForPendingSessionOperations(timeout: timeout, generation: generation)
    }

    func acquireOwnership() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminalState,
              ownerToken == nil,
              currentToken == nil,
              pendingSessionOperations[audioGeneration, default: 0] == 0,
              !deactivationPending else { return nil }
        nextOwnerToken &+= 1
        ownerToken = nextOwnerToken
        return nextOwnerToken
    }

    func releaseOwnership(_ token: UInt64) {
        lock.lock()
        if ownerToken == token {
            ownerToken = nil
        }
        if deferredOwnerReleaseToken == token {
            deferredOwnerReleaseToken = nil
        }
        recoverIfIdleLocked()
        lock.unlock()
    }

    @discardableResult
    func releaseOwnershipWhenIdle(_ token: UInt64) -> Bool {
        lock.lock()
        guard ownerToken == token else {
            lock.unlock()
            return true
        }
        let didRelease: Bool
        if currentToken == nil,
           pendingSessionOperations[audioGeneration, default: 0] == 0,
           !deactivationPending {
            ownerToken = nil
            deferredOwnerReleaseToken = nil
            didRelease = true
        } else {
            deferredOwnerReleaseToken = token
            didRelease = false
        }
        recoverIfIdleLocked()
        lock.unlock()
        return didRelease
    }

    func waitForOwnershipRelease(_ token: UInt64) async {
        while isOwnershipHeld(token) {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    private func isOwnershipHeld(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownerToken == token
    }

    /// Releases the process owner without clearing the terminal quarantine.
    /// A failed deactivation must keep future starts fenced, but it must not
    /// retain an ownership token that can never become usable again.
    func releaseOwnershipAfterTerminal(_ token: UInt64) {
        lock.lock()
        if ownerToken == token {
            ownerToken = nil
        }
        if deferredOwnerReleaseToken == token {
            deferredOwnerReleaseToken = nil
        }
        lock.unlock()
    }

    /// Media services reset invalidates every audio graph and callback that
    /// existed before the reset. Drop the old generation atomically so a
    /// subsequent run can acquire ownership while late callbacks from the
    /// discarded generation become harmless no-ops.
    func recoverAfterMediaServicesReset() {
        lock.lock()
        audioGeneration &+= 1
        currentToken = nil
        tokenGenerations.removeAll()
        invalidatedTokens.removeAll()
        lateDeactivationTokens.removeAll()
        fallbackDeactivationTokens.removeAll()
        callbackObservedDuringFallback.removeAll()
        activationCallbackObservedDuringFallback.removeAll()
        lateFallbackDeactivationTokens.removeAll()
        callbackObservedDuringLateFallback.removeAll()
        retiredTokens.removeAll()
        terminalTokens.removeAll()
        finishedTokens.removeAll()
        scheduledQuarantineTokens.removeAll()
        isTerminalState = false
        pendingSessionOperations.removeAll()
        deactivationPending = false
        anonymousDeactivationPendingCount = 0
        ownerToken = nil
        deferredOwnerReleaseToken = nil
        lock.unlock()
    }

    /// Releases ownership after a media-services reset that has already
    /// advanced the coordinator generation. This intentionally does not
    /// advance the generation again: a late cleanup pass from the reset
    /// generation must not invalidate a new recording that has started since.
    func releaseOwnershipAfterMediaServicesReset() {
        lock.lock()
        ownerToken = nil
        deferredOwnerReleaseToken = nil
        lock.unlock()
    }

    func markTerminal(forGeneration generation: UInt64) {
        lock.lock()
        guard audioGeneration == generation else {
            lock.unlock()
            return
        }
        isTerminalState = true
        if let ownerToken {
            deferredOwnerReleaseToken = ownerToken
        }
        lock.unlock()
    }

    func markTerminal() {
        lock.lock()
        isTerminalState = true
        if let ownerToken {
            deferredOwnerReleaseToken = ownerToken
        }
        lock.unlock()
    }

    @discardableResult
    func markTerminalIfCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        guard currentToken == token else {
            lock.unlock()
            return false
        }
        isTerminalState = true
        if let ownerToken {
            deferredOwnerReleaseToken = ownerToken
        }
        lock.unlock()
        return true
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
        finishedTokens.insert(token)
        if currentToken == token {
            currentToken = nil
        }
        tokenGenerations.removeValue(forKey: token)
        invalidatedTokens.remove(token)
        lateDeactivationTokens.remove(token)
        fallbackDeactivationTokens.remove(token)
        callbackObservedDuringFallback.remove(token)
        activationCallbackObservedDuringFallback.remove(token)
        lateFallbackDeactivationTokens.remove(token)
        callbackObservedDuringLateFallback.remove(token)
        retiredTokens.remove(token)
        terminalTokens.remove(token)
        recoverIfIdleLocked()
        lock.unlock()
    }

    func recoverIfIdle() {
        lock.lock()
        recoverIfIdleLocked()
        lock.unlock()
    }

    private func recoverIfIdleLocked(clearTerminalState: Bool = true) {
        if currentToken == nil,
           pendingSessionOperations[audioGeneration, default: 0] == 0,
           !deactivationPending,
           deferredOwnerReleaseToken == ownerToken {
            ownerToken = nil
            deferredOwnerReleaseToken = nil
        }
        guard currentToken == nil,
              pendingSessionOperations[audioGeneration, default: 0] == 0,
              !deactivationPending,
              ownerToken == nil else { return }
        guard clearTerminalState else { return }
        isTerminalState = false
        invalidatedTokens.removeAll()
        lateDeactivationTokens.removeAll()
        fallbackDeactivationTokens.removeAll()
        callbackObservedDuringFallback.removeAll()
        activationCallbackObservedDuringFallback.removeAll()
        lateFallbackDeactivationTokens.removeAll()
        callbackObservedDuringLateFallback.removeAll()
        retiredTokens.removeAll()
        terminalTokens.removeAll()
        finishedTokens.removeAll()
    }

    func beginDeactivationPending() {
        lock.lock()
        anonymousDeactivationPendingCount += 1
        deactivationPending = true
        lock.unlock()
    }

    @discardableResult
    func beginDeactivationPending(for token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard tokenGenerations[token] == audioGeneration,
              scheduledQuarantineTokens.insert(token).inserted else { return false }
        deactivationPending = true
        return true
    }

    private func refreshDeactivationPendingLocked() {
        deactivationPending = anonymousDeactivationPendingCount > 0
            || !scheduledQuarantineTokens.isEmpty
    }

    func completeDeactivationPending(
        for token: UInt64? = nil,
        deactivationSucceeded: Bool = true
    ) {
        lock.lock()
        if let token {
            guard scheduledQuarantineTokens.remove(token) != nil else {
                lock.unlock()
                return
            }
        } else {
            guard anonymousDeactivationPendingCount > 0 else {
                lock.unlock()
                return
            }
            anonymousDeactivationPendingCount -= 1
        }
        refreshDeactivationPendingLocked()
        recoverIfIdleLocked(clearTerminalState: deactivationSucceeded)
        lock.unlock()
    }

    @discardableResult
    func completeDeactivationPendingIfOperationFinished(_ token: UInt64) -> Bool {
        lock.lock()
        let tokenHasSettled = terminalTokens.contains(token)
            || finishedTokens.contains(token)
        guard tokenHasSettled,
              currentToken == token || currentToken == nil else {
            lock.unlock()
            return false
        }
        scheduledQuarantineTokens.remove(token)
        refreshDeactivationPendingLocked()
        let didFinishWithoutActiveSession = finishedTokens.remove(token) != nil
        recoverIfIdleLocked(clearTerminalState: didFinishWithoutActiveSession)
        lock.unlock()
        return didFinishWithoutActiveSession
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

    @discardableResult
    func completeFallbackDeactivation(
        _ token: UInt64,
        succeeded: Bool
    ) -> AppAudioDeactivationResult {
        lock.lock()
        guard currentToken == token,
              fallbackDeactivationTokens.remove(token) != nil else {
            lock.unlock()
            return .ignored
        }
        let result: AppAudioDeactivationResult
        let callbackObserved = callbackObservedDuringFallback.remove(token) != nil
        let activationCallbackObserved = activationCallbackObservedDuringFallback.remove(token) != nil
        if succeeded {
            // A successful fallback deactivation is the authoritative final
            // state. The original callback may have arrived concurrently, but
            // the session is now inactive and must not remain quarantined.
            currentToken = nil
            finishedTokens.insert(token)
            result = .succeeded
        } else if callbackObserved {
            // The original deactivation already succeeded. A compensating
            // fallback can fail during route/media-service churn without
            // making that established inactive state unsafe.
            currentToken = nil
            finishedTokens.insert(token)
            result = .succeeded
        } else if activationCallbackObserved {
            // This token was originally an activation. A late activation
            // callback proves that the session may have become active; it is
            // not evidence that the compensating deactivation succeeded.
            // Keep the terminal fence when that deactivation failed.
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
            result = .failed
        } else {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
            result = .failed
        }
        lock.unlock()
        return result
    }

    func recordCallbackDuringFallback(_ token: UInt64, succeeded: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              fallbackDeactivationTokens.contains(token) else { return false }
        if succeeded {
            callbackObservedDuringFallback.insert(token)
        }
        // Keep the compensating fallback as the exactly-once owner even when
        // the original callback reports failure. It still has to settle the
        // quarantine and release the pending token.
        recoverIfIdleLocked(clearTerminalState: false)
        return true
    }

    func recordActivationCallbackDuringFallback(_ token: UInt64, activated: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              fallbackDeactivationTokens.contains(token) else { return false }
        if activated {
            activationCallbackObservedDuringFallback.insert(token)
        }
        // Activation completion is tracked separately from a deactivation
        // completion. It must never make a failed fallback look successful.
        recoverIfIdleLocked(clearTerminalState: false)
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
        recoverIfIdleLocked(clearTerminalState: false)
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
        recoverIfIdleLocked(clearTerminalState: false)
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

    func completeLateDeactivationFallback(
        _ token: UInt64,
        succeeded: Bool
    ) -> AppAudioDeactivationResult {
        lock.lock()
        guard currentToken == token,
              lateFallbackDeactivationTokens.remove(token) != nil else {
            lock.unlock()
            return .ignored
        }
        let result: AppAudioDeactivationResult
        let callbackObserved = callbackObservedDuringLateFallback.remove(token) != nil
        if succeeded {
            // The fallback itself established the safe inactive state. A late
            // original callback is no longer grounds for permanent quarantine.
            currentToken = nil
            finishedTokens.insert(token)
            result = .succeeded
        } else if callbackObserved {
            // The late original callback already confirmed deactivation. Do
            // not turn a redundant fallback failure into a permanent process
            // quarantine.
            currentToken = nil
            finishedTokens.insert(token)
            result = .succeeded
        } else {
            currentToken = nil
            terminalTokens.insert(token)
            isTerminalState = true
            result = .failed
        }
        recoverIfIdleLocked(clearTerminalState: false)
        lock.unlock()
        return result
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
        recoverIfIdleLocked(clearTerminalState: false)
    }

    func recordCallbackDuringLateFallback(_ token: UInt64, succeeded: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token,
              lateFallbackDeactivationTokens.contains(token) else { return false }
        if succeeded {
            callbackObservedDuringLateFallback.insert(token)
        }
        // A failed original callback must not retire the late fallback before
        // its compensating deactivation has completed.
        recoverIfIdleLocked(clearTerminalState: false)
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
