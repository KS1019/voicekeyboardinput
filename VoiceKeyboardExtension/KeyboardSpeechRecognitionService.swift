import AVFAudio
import Foundation
import Speech
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

actor KeyboardSpeechRecognitionService: SpeechRecognitionService {
    private final class LegacyAudioTapGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isActive = true
        private var inFlightCallbacks = 0

        func invalidate() {
            condition.lock()
            isActive = false
            while inFlightCallbacks > 0 {
                condition.wait()
            }
            condition.unlock()
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

    private final class AnalyzerAudioTapGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isActive = true
        private var inFlightCallbacks = 0

        func invalidate() {
            condition.lock()
            isActive = false
            while inFlightCallbacks > 0 {
                condition.wait()
            }
            condition.unlock()
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

    private struct ActiveRun {
        let generation: UInt64
        var engine: AVAudioEngine?
        var tapInstalled = false
        var sessionActive = false
        var analyzer: SpeechAnalyzer?
        var analyzerTask: Task<Void, Never>?
        var analyzerTapGate: AnalyzerAudioTapGate?
        var recognitionTasks: [Task<Void, Never>] = []
        var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
        var outputContinuations: [SpeechRecognitionUpdateStream.Continuation] = []
        var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
        var legacyTask: SFSpeechRecognitionTask?
        var legacyTapGate: LegacyAudioTapGate?
        var audioObservers: [NSObjectProtocol] = []
        var stopping = false
    }

    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var nextGeneration: UInt64 = 0
    private var activeRun: ActiveRun?
    private var cleanupTasks: [UInt64: Task<Void, Never>] = [:]
    private var pendingInputFailures: [UInt64: SpeechRecognitionError] = [:]
    private var pendingOutputFailures: [UInt64: SpeechRecognitionError] = [:]
    private var pendingFailureExpiryTasks: [UInt64: Task<Void, Never>] = [:]
    private var activePermissionCancellation: (() -> Void)?
    private var activePermissionCancellationToken: AnyObject?

    init(diagnostics: KeyboardSpeechRecognitionDiagnostics = KeyboardSpeechRecognitionDiagnostics()) {
        self.diagnostics = diagnostics
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        guard activeRun == nil else {
            throw .recognitionStartFailed("Speech recognition is already active")
        }
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
                return try await startSpeechAnalyzerRecognition(locale: locale, generation: generation)
            }
        } catch {
            await requestCleanup(generation: generation)
            throw error
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

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            activeRun?.sessionActive = true
            try await KeyboardAudioSessionRouting.selectPreferredInputIfAvailable(session)
            diagnostics.event("audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("audio-session", error: mapped)
            throw mapped
        }

        let engine = AVAudioEngine()
        activeRun?.engine = engine
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

        do {
            try await analyzer.prepareToAnalyze(in: naturalFormat)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("prepare", error: mapped)
            throw mapped
        }

        let inputStream = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
            Task { self.setInputContinuation(continuation, generation: generation) }
        }
        let tapGate = AnalyzerAudioTapGate()
        activeRun?.analyzerTapGate = tapGate
        let converter: AnalyzerInputConverter
        do {
            converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
            guard isCurrent(generation) else { throw SpeechRecognitionError.cancelled }
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("converter", error: mapped)
            throw mapped
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { [weak self] buffer, time in
            guard let self else { return }
            do {
                guard let inputs = try tapGate.perform({
                    try converter.convert(buffer, at: time)
                }) else {
                    return
                }
                Task {
                    for input in inputs {
                        await self.yield(input, generation: generation)
                    }
                }
            } catch {
                let description = String(describing: error)
                Task {
                    await self.finishInput(throwing: SpeechRecognitionError.recognitionFailed(description), generation: generation)
                }
            }
        }
        activeRun?.tapInstalled = true

        guard isCurrent(generation) else { throw .cancelled }
        installAudioObservers(session: session, engine: engine, generation: generation)

        do {
            engine.prepare()
            try engine.start()
            diagnostics.event("audio-engine-started")
        } catch {
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("audio-engine", error: mapped)
            throw mapped
        }
        activeRun?.analyzerTask = Task {
            do {
                try await analyzer.start(inputSequence: inputStream)
                await self.requestCleanup(generation: generation)
            } catch {
                self.failCurrentRun(
                    .recognitionFailed(String(describing: error)),
                    generation: generation
                )
            }
        }

        return SpeechRecognitionUpdateStream { continuation in
            Task { await self.addOutputContinuation(continuation, generation: generation) }
            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        guard self.isCurrent(generation) else { return }
                        let transcript = String(result.text.characters)
                        continuation.yield(
                            SpeechRecognitionUpdate(
                                transcript: transcript,
                                isFinal: result.isFinal,
                                inputLevel: nil
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    guard self.isCurrent(generation) else { return }
                    continuation.finish(throwing: SpeechRecognitionError.recognitionFailed(String(describing: error)))
                }
            }
            Task { await self.addRecognitionTask(resultTask, generation: generation) }
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

        let session = AVAudioSession.sharedInstance()
        guard isCurrent(generation) else { throw .cancelled }
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            activeRun?.sessionActive = true
            try await KeyboardAudioSessionRouting.selectPreferredInputIfAvailable(session)
            diagnostics.event("legacy-audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("legacy-audio-session", error: mapped)
            throw mapped
        }

        let engine = AVAudioEngine()
        activeRun?.engine = engine
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        activeRun?.legacyRequest = request
        let tapGate = LegacyAudioTapGate()
        activeRun?.legacyTapGate = tapGate
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            tapGate.append(buffer, to: request)
        }
        activeRun?.tapInstalled = true

        installAudioObservers(session: session, engine: engine, generation: generation)

        do {
            engine.prepare()
            try engine.start()
            diagnostics.event("legacy-audio-engine-started")
        } catch {
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("legacy-audio-engine", error: mapped)
            throw mapped
        }
        return SpeechRecognitionUpdateStream { continuation in
            Task { await self.addOutputContinuation(continuation, generation: generation) }
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    Task {
                        guard self.isCurrent(generation) else { return }
                        continuation.yield(
                            SpeechRecognitionUpdate(
                                transcript: result.bestTranscription.formattedString,
                                isFinal: result.isFinal,
                                inputLevel: nil
                            )
                        )
                        if result.isFinal, self.isCurrent(generation) {
                            continuation.finish()
                        }
                    }
                }

                if let error {
                    Task {
                        guard self.isCurrent(generation) else { return }
                        continuation.finish(
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
        run.inputContinuation?.finish()
        run.inputContinuation = nil
        run.outputContinuations.forEach { $0.finish() }
        run.outputContinuations.removeAll()
        run.analyzerTask?.cancel()
        run.analyzerTask = nil
        run.recognitionTasks.forEach { $0.cancel() }
        run.recognitionTasks.removeAll()
        run.analyzerTapGate?.invalidate()
        run.analyzerTapGate = nil
        run.legacyTask?.cancel()
        run.legacyTask = nil
        run.legacyTapGate?.invalidate()
        run.legacyTapGate = nil
        run.legacyRequest?.endAudio()
        run.legacyRequest = nil
        run.audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        run.audioObservers.removeAll()
        if run.tapInstalled {
            run.engine?.inputNode.removeTap(onBus: 0)
        }
        run.engine?.stop()
        run.engine = nil
        if let analyzer = run.analyzer {
            await cancelAnalyzerWithTimeout(analyzer)
        }
        run.analyzer = nil
        if run.sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        activeRun = nil
    }

    private func cancelAnalyzerWithTimeout(_ analyzer: SpeechAnalyzer) async {
        await withCheckedContinuation { continuation in
            let gate = CleanupCompletionGate()
            let cleanupTask = Task {
                await analyzer.cancelAndFinishNow()
                guard gate.finish() else { return }
                continuation.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                cleanupTask.cancel()
                continuation.resume()
            }
        }
    }

    private func installAudioObservers(
        session: AVAudioSession,
        engine: AVAudioEngine,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        let notificationCenter = NotificationCenter.default
        let interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let interruptionTypeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue),
                  interruptionType == .began else { return }
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio input was interrupted."),
                    generation: generation
                )
            }
        }
        let routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                  reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory,
                  session.currentRoute.inputs.isEmpty else { return }
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio input route is no longer available."),
                    generation: generation
                )
            }
        }
        let engineConfigurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
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
        ) { [weak self] _ in
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio media services were lost."),
                    generation: generation
                )
            }
        }
        let mediaServicesResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.failCurrentRun(
                    .recognitionFailed("Audio media services were reset."),
                    generation: generation
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

    private func failCurrentRun(
        _ error: SpeechRecognitionError,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        cachePendingFailure(error, generation: generation)
        activeRun?.inputContinuation?.finish(throwing: error)
        activeRun?.outputContinuations.forEach { $0.finish(throwing: error) }
        Task { await requestCleanup(generation: generation) }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        activeRun?.generation == generation && activeRun?.stopping == false
    }

    private func setInputContinuation(
        _ continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
        generation: UInt64
    ) {
        if let pendingFailure = pendingInputFailures.removeValue(forKey: generation) {
            continuation.finish(throwing: pendingFailure)
            clearPendingFailureExpiryIfUnused(generation: generation)
            return
        }
        guard isCurrent(generation) else {
            continuation.finish()
            return
        }
        activeRun?.inputContinuation = continuation
    }

    private func addOutputContinuation(
        _ continuation: SpeechRecognitionUpdateStream.Continuation,
        generation: UInt64
    ) {
        if let pendingFailure = pendingOutputFailures.removeValue(forKey: generation) {
            continuation.finish(throwing: pendingFailure)
            clearPendingFailureExpiryIfUnused(generation: generation)
            return
        }
        guard isCurrent(generation) else {
            continuation.finish()
            return
        }
        activeRun?.outputContinuations.append(continuation)
    }

    private func yield(_ input: AnalyzerInput, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.inputContinuation?.yield(input)
    }

    private func finishInput(throwing error: Error, generation: UInt64) {
        guard isCurrent(generation) else { return }
        if let inputContinuation = activeRun?.inputContinuation {
            inputContinuation.finish(throwing: error)
        } else {
            cachePendingFailure(
                .recognitionFailed(String(describing: error)),
                generation: generation
            )
        }
    }

    private func cachePendingFailure(
        _ error: SpeechRecognitionError,
        generation: UInt64
    ) {
        pendingInputFailures[generation] = error
        pendingOutputFailures[generation] = error
        pendingFailureExpiryTasks[generation]?.cancel()
        pendingFailureExpiryTasks[generation] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            await self?.expirePendingFailure(generation: generation)
        }
    }

    private func clearPendingFailureExpiryIfUnused(generation: UInt64) {
        guard pendingInputFailures[generation] == nil,
              pendingOutputFailures[generation] == nil else { return }
        pendingFailureExpiryTasks[generation]?.cancel()
        pendingFailureExpiryTasks[generation] = nil
    }

    private func expirePendingFailure(generation: UInt64) {
        pendingInputFailures[generation] = nil
        pendingOutputFailures[generation] = nil
        pendingFailureExpiryTasks[generation] = nil
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
