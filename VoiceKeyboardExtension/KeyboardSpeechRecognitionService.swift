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
    private var recognitionTask: Task<Void, Never>?

    init(diagnostics: KeyboardSpeechRecognitionDiagnostics = KeyboardSpeechRecognitionDiagnostics()) {
        self.diagnostics = diagnostics
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        diagnostics.event("start", metadata: ["locale": locale.identifier])
        guard #available(iOS 27, *) else {
            diagnostics.failure("availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        guard AVAudioApplication.shared.recordPermission == .granted else {
            let error: SpeechRecognitionError = AVAudioApplication.shared.recordPermission == .denied
                ? .microphonePermissionDenied
                : .microphonePermissionUndetermined
            diagnostics.failure("permission", error: error)
            throw error
        }

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
        recognitionTask = Task {
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

    func stop() async {
        diagnostics.event("stop")
        recognitionTask?.cancel()
        recognitionTask = nil
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
}
