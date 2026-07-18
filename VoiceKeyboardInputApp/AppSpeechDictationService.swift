import AVFAudio
import Foundation
import Speech

enum AppSpeechDictationError: LocalizedError {
    case recognizerUnavailable
    case audioInputUnavailable
    case audioEngineStartFailed
    case emptyTranscript
    case audioInterrupted
    case audioRouteLost

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
        case .audioInterrupted:
            "Audio input was interrupted."
        case .audioRouteLost:
            "Audio input is no longer available."
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
final class AppSpeechDictationRun {
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
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

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
        try await activateAudioSession(session)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            await deactivateAudioSession(session)
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
            await deactivateAudioSession(session)
            throw AppSpeechDictationError.audioEngineStartFailed
        }

        installAudioSessionObservers()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
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
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
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
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                  reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory,
                  AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty else { return }
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioRouteLost))
            }
        }
    }

    private func cleanup() async {
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
        request?.endAudio()
        request = nil
        if tapIsInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
        engine.stop()
        await deactivateAudioSession(AVAudioSession.sharedInstance())
    }

    private func activateAudioSession(_ session: AVAudioSession) async throws {
        if #available(iOS 27.0, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { activated, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if activated {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: AppSpeechDictationError.audioInputUnavailable)
                    }
                }
            }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func deactivateAudioSession(_ session: AVAudioSession) async {
        if #available(iOS 27.0, *) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in
                    continuation.resume()
                }
            }
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
