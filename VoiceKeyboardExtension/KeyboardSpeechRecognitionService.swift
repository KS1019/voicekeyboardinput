import AVFAudio
import Foundation
import Speech
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

actor KeyboardSpeechRecognitionService: SpeechRecognitionService {
    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?

    init(diagnostics: KeyboardSpeechRecognitionDiagnostics = KeyboardSpeechRecognitionDiagnostics()) {
        self.diagnostics = diagnostics
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        diagnostics.event("start", metadata: ["locale": locale.identifier])
        let strategy = KeyboardSpeechRecognitionRuntime.strategy(
            forOperatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        diagnostics.event("strategy", metadata: ["value": "\(strategy)"])
        switch strategy {
        case .legacyAudioBuffer:
            return try await startLegacyAudioBufferRecognition(locale: locale)
        case .speechAnalyzer:
            return try await startSpeechAnalyzerRecognition(locale: locale)
        }
    }

    private func startSpeechAnalyzerRecognition(
        locale: VoiceKeyboardLocale
    ) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        guard #available(iOS 27, *) else {
            diagnostics.failure("availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        try await ensureMicrophonePermission()

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
        self.analyzer = analyzer

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            diagnostics.event("audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("audio-session", error: mapped)
            throw mapped
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            diagnostics.failure("audio-input", error: .audioInputUnavailable)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw .audioInputUnavailable
        }

        diagnostics.event("audio-format", metadata: [
            "channels": "\(naturalFormat.channelCount)",
            "sampleRate": "\(naturalFormat.sampleRate)"
        ])

        do {
            try await analyzer.prepareToAnalyze(in: naturalFormat)
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("prepare", error: mapped)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw mapped
        }

        let inputStream = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
            self.inputContinuation = continuation
        }
        let converter: AnalyzerInputConverter
        do {
            converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("converter", error: mapped)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw mapped
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { [weak self] buffer, time in
            guard let self else { return }
            do {
                let inputs = try converter.convert(buffer, at: time)
                Task {
                    for input in inputs {
                        await self.yield(input)
                    }
                }
            } catch {
                let description = String(describing: error)
                Task {
                    await self.finishInput(throwing: SpeechRecognitionError.recognitionFailed(description))
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            diagnostics.event("audio-engine-started")
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("audio-engine", error: mapped)
            throw mapped
        }

        self.engine = engine
        analyzerTask = Task {
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                await self.finishInput(throwing: error)
            }
        }

        return SpeechRecognitionUpdateStream { continuation in
            Task {
                do {
                    for try await result in transcriber.results {
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
                    continuation.finish(throwing: SpeechRecognitionError.recognitionFailed(String(describing: error)))
                }
            }
        }
    }

    private func startLegacyAudioBufferRecognition(
        locale: VoiceKeyboardLocale
    ) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        try await ensureMicrophonePermission()
        try await ensureSpeechRecognitionAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.identifier)) else {
            diagnostics.failure("legacy-recognizer", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        guard recognizer.isAvailable else {
            diagnostics.failure("legacy-availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            diagnostics.event("legacy-audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("legacy-audio-session", error: mapped)
            throw mapped
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            diagnostics.failure("legacy-audio-input", error: .audioInputUnavailable)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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

        legacyRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            diagnostics.event("legacy-audio-engine-started")
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("legacy-audio-engine", error: mapped)
            throw mapped
        }

        self.engine = engine
        return SpeechRecognitionUpdateStream { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(
                        SpeechRecognitionUpdate(
                            transcript: result.bestTranscription.formattedString,
                            isFinal: result.isFinal,
                            inputLevel: nil
                        )
                    )
                    if result.isFinal {
                        continuation.finish()
                    }
                }

                if let error {
                    continuation.finish(
                        throwing: SpeechRecognitionError.recognitionFailed(String(describing: error))
                    )
                }
            }

            Task {
                await self.setLegacyTask(task)
            }
        }
    }

    func stop() async {
        diagnostics.event("stop")
        analyzerTask?.cancel()
        analyzerTask = nil
        legacyTask?.cancel()
        legacyTask = nil
        legacyRequest?.endAudio()
        legacyRequest = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        inputContinuation?.finish()
        inputContinuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func yield(_ input: AnalyzerInput) {
        inputContinuation?.yield(input)
    }

    private func finishInput(throwing error: Error) {
        inputContinuation?.finish(throwing: error)
    }

    private func setLegacyTask(_ task: SFSpeechRecognitionTask) {
        legacyTask = task
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
