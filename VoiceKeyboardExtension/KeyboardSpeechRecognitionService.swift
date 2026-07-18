import AVFAudio
import Foundation
import Speech
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

actor KeyboardSpeechRecognitionService: SpeechRecognitionService {
    private final class LegacyAudioTapGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isActive = true

        func invalidate() {
            lock.lock()
            isActive = false
            lock.unlock()
        }

        func append(
            _ buffer: AVAudioPCMBuffer,
            to request: SFSpeechAudioBufferRecognitionRequest
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            request.append(buffer)
        }
    }

    private struct ActiveRun {
        let generation: UInt64
        var engine: AVAudioEngine?
        var tapInstalled = false
        var sessionActive = false
        var analyzer: SpeechAnalyzer?
        var analyzerTask: Task<Void, Never>?
        var recognitionTasks: [Task<Void, Never>] = []
        var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
        var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
        var legacyTask: SFSpeechRecognitionTask?
        var legacyTapGate: LegacyAudioTapGate?
        var stopping = false
    }

    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var nextGeneration: UInt64 = 0
    private var activeRun: ActiveRun?
    private var cleanupTasks: [UInt64: Task<Void, Never>] = [:]

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
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            activeRun?.sessionActive = true
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
                let inputs = try converter.convert(buffer, at: time)
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
            } catch {
                self.finishInput(throwing: error, generation: generation)
            }
        }

        return SpeechRecognitionUpdateStream { continuation in
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
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            activeRun?.sessionActive = true
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
        run.analyzerTask?.cancel()
        run.analyzerTask = nil
        run.recognitionTasks.forEach { $0.cancel() }
        run.recognitionTasks.removeAll()
        run.legacyTask?.cancel()
        run.legacyTask = nil
        run.legacyTapGate?.invalidate()
        run.legacyTapGate = nil
        run.legacyRequest?.endAudio()
        run.legacyRequest = nil
        if run.tapInstalled {
            run.engine?.inputNode.removeTap(onBus: 0)
        }
        run.engine?.stop()
        run.engine = nil
        await run.analyzer?.cancelAndFinishNow()
        run.analyzer = nil
        if run.sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        activeRun = nil
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        activeRun?.generation == generation && activeRun?.stopping == false
    }

    private func setInputContinuation(
        _ continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
        generation: UInt64
    ) {
        guard isCurrent(generation) else {
            continuation.finish()
            return
        }
        activeRun?.inputContinuation = continuation
    }

    private func yield(_ input: AnalyzerInput, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.inputContinuation?.yield(input)
    }

    private func finishInput(throwing error: Error, generation: UInt64) {
        guard isCurrent(generation) else { return }
        activeRun?.inputContinuation?.finish(throwing: error)
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
            let isGranted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
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
            let requestedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
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
