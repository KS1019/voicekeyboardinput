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
        func invalidate(timeout: TimeInterval = 1) -> Bool {
            condition.lock()
            isActive = false
            let deadline = Date().addingTimeInterval(timeout)
            while inFlightCallbacks > 0 {
                guard condition.wait(until: deadline) else { break }
            }
            let didDrain = inFlightCallbacks == 0
            condition.unlock()
            return didDrain
        }

        func waitUntilDrained() {
            condition.lock()
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

    private final class DeferredAudioRequestCleanup: @unchecked Sendable {
        private let gate: AudioTapGate
        private let request: SFSpeechAudioBufferRecognitionRequest

        init(gate: AudioTapGate, request: SFSpeechAudioBufferRecognitionRequest) {
            self.gate = gate
            self.request = request
        }

        func schedule() {
            DispatchQueue.global(qos: .utility).async { [self] in
                gate.waitUntilDrained()
                request.endAudio()
            }
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

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "Audio session operation timed out."
            case .busy:
                "Audio session is busy with another operation."
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
    private var audioTapGate: AudioTapGate?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var isPreparingAudio = false

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
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
        )
        do {
            try await activateAudioSession(session)
        } catch {
            await deactivateAudioSession(session)
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

        isPreparingAudio = true
        installAudioSessionObservers()
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let tapGate = AudioTapGate()
        audioTapGate = tapGate

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            tapGate.append(buffer, to: request)
        }
        tapIsInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            await cleanup()
            throw AppSpeechDictationError.audioEngineStartFailed
        }

        isPreparingAudio = false
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
            let routeIsUnavailable = AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
            let isPreparingAudio = self?.isPreparingAudio == true
            let reasonRequiresFailure: Bool
            if let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
                reasonRequiresFailure = reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory
            } else {
                reasonRequiresFailure = false
            }
            guard isPreparingAudio || (reasonRequiresFailure && routeIsUnavailable) else { return }
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        engineConfigurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesLostObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.complete(.failure(AppSpeechDictationError.audioConfigurationChanged))
            }
        }
        mediaServicesResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
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
        if let audioTapGate {
            let didDrain = audioTapGate.invalidate()
            self.audioTapGate = nil
            if let request {
                if didDrain {
                    request.endAudio()
                } else {
                    DeferredAudioRequestCleanup(
                        gate: audioTapGate,
                        request: request
                    ).schedule()
                }
            }
        } else {
            request?.endAudio()
        }
        request = nil
        if tapIsInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
        engine.stop()
        await deactivateAudioSession(AVAudioSession.sharedInstance())
    }

    private func activateAudioSession(_ session: AVAudioSession) async throws {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let operationToken = coordinator.begin() else {
            throw AudioSessionOperationError.busy
        }
        if #available(iOS 27.0, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = AudioSessionCompletionGate()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.invalidate(operationToken)
                    continuation.resume(throwing: AudioSessionOperationError.timedOut)
                }
                session.activate(options: []) { activated, error in
                    let isCurrent = coordinator.isCurrent(operationToken)
                    let wonCompletion = gate.finish()
                    guard isCurrent && wonCompletion else {
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
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = AudioSessionCompletionGate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.invalidate(operationToken)
                continuation.resume(throwing: AudioSessionOperationError.timedOut)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.finish(operationToken)
                    return
                }
                do {
                    try session.setActive(true)
                    let isCurrent = coordinator.isCurrent(operationToken)
                    let wonCompletion = gate.finish()
                    guard isCurrent && wonCompletion else {
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
                    guard coordinator.isCurrent(operationToken), gate.finish() else {
                        coordinator.finish(operationToken)
                        return
                    }
                    coordinator.finish(operationToken)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func deactivateAudioSession(_ session: AVAudioSession) async {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let operationToken = await coordinator.beginWhenAvailable() else { return }
        if #available(iOS 27.0, *) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let gate = AudioSessionCompletionGate()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard gate.finish() else { return }
                    coordinator.invalidate(operationToken)
                    continuation.resume()
                }
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in
                    guard gate.finish() else {
                        coordinator.finish(operationToken)
                        return
                    }
                    coordinator.finish(operationToken)
                    continuation.resume()
                }
            }
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = AudioSessionCompletionGate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                coordinator.invalidate(operationToken)
                continuation.resume()
            }
            DispatchQueue.global(qos: .utility).async {
                guard coordinator.isCurrent(operationToken) else {
                    coordinator.finish(operationToken)
                    return
                }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                guard coordinator.isCurrent(operationToken), gate.finish() else {
                    coordinator.finish(operationToken)
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

@discardableResult
private func deactivateLateAudioSession(
    _ session: AVAudioSession,
    coordinator: AppAudioSessionOperationCoordinator,
    operationToken: UInt64
) -> Bool {
    guard coordinator.claimLateDeactivation(operationToken) else { return false }
    if #available(iOS 27.0, *) {
        session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in
            coordinator.finish(operationToken)
        }
    } else {
        DispatchQueue.global(qos: .utility).async {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            coordinator.finish(operationToken)
        }
    }
    return true
}

final class AppAudioSessionOperationCoordinator: @unchecked Sendable {
    static let shared = AppAudioSessionOperationCoordinator()

    private let lock = NSLock()
    private var nextToken: UInt64 = 0
    private var currentToken: UInt64?
    private var invalidatedTokens: Set<UInt64> = []

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == nil else { return nil }
        nextToken &+= 1
        currentToken = nextToken
        return nextToken
    }

    func beginWhenAvailable() async -> UInt64? {
        for _ in 0..<40 {
            if let token = begin() {
                return token
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken == token && !invalidatedTokens.contains(token)
    }

    func finish(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            currentToken = nil
        }
        invalidatedTokens.remove(token)
        lock.unlock()
    }

    func invalidate(_ token: UInt64) {
        lock.lock()
        if currentToken == token {
            currentToken = nil
            invalidatedTokens.insert(token)
        }
        lock.unlock()
    }

    func claimLateDeactivation(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard invalidatedTokens.contains(token), currentToken == nil else { return false }
        currentToken = token
        return true
    }
}
