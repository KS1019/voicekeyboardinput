import AVFAudio
import Foundation
import Speech

enum AppSpeechDictationError: LocalizedError {
    case recognizerUnavailable
    case audioInputUnavailable
    case audioEngineStartFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is unavailable for the current locale."
        case .audioInputUnavailable:
            "Audio input is unavailable in the containing app."
        case .audioEngineStartFailed:
            "Could not start the audio engine for speech recognition."
        case .emptyTranscript:
            "Speech recognition finished without a transcript."
        }
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
private final class AppSpeechDictationRun {
    private let locale: Locale
    private let maximumDuration: TimeInterval
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?
    private var latestTranscript = ""
    private var didFinish = false
    private var tapIsInstalled = false

    init(locale: Locale, maximumDuration: TimeInterval) {
        self.locale = locale
        self.maximumDuration = maximumDuration
    }

    func start() async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppSpeechDictationError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AppSpeechDictationError.audioInputUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapIsInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            if tapIsInstalled {
                inputNode.removeTap(onBus: 0)
                tapIsInstalled = false
            }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AppSpeechDictationError.audioEngineStartFailed
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.maximumDuration))
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
            finish(throwing: error)
        }
    }

    private func finishWithLatestTranscript() {
        guard !latestTranscript.isEmpty else {
            finish(throwing: AppSpeechDictationError.emptyTranscript)
            return
        }
        finish(returning: latestTranscript)
    }

    private func finish(returning transcript: String) {
        guard !didFinish else { return }
        didFinish = true
        cleanup()
        continuation?.resume(returning: transcript)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        guard !didFinish else { return }
        didFinish = true
        cleanup()
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        cleanup()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapIsInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
