import AVFAudio
import Observation
import Speech
import VoiceKeyboardModels
import VoiceKeyboardSharedStorage

enum VoiceInputLaunchStatus: Equatable {
    case idle
    case sessionReady
    case requestingPermission
    case microphoneActive(peakPower: Float?)
    case transcriptShared(String)
    case permissionDenied
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .sessionReady:
            "Voice Session Ready"
        case .requestingPermission:
            "Requesting Microphone"
        case .microphoneActive:
            "Microphone Active"
        case .transcriptShared:
            "Transcript Ready"
        case .permissionDenied:
            "Microphone Permission Denied"
        case .failed:
            "Microphone Activation Failed"
        }
    }

    var message: String {
        switch self {
        case .idle:
            "Preparing a voice session lets the keyboard start dictation without reopening this app while the session is alive."
        case .sessionReady:
            "Voice Keyboard can start dictation from the keyboard while this app session is alive."
        case .requestingPermission:
            "Waiting for the iOS microphone permission prompt."
        case let .microphoneActive(peakPower):
            if let peakPower {
                "Audio input probe passed. Peak input: \(peakPower.formatted(.number.precision(.fractionLength(1)))) dB."
            } else {
                "Audio input probe passed. No non-silent input was detected during the short probe."
            }
        case let .transcriptShared(transcript):
            "Transcript saved for the keyboard: \(transcript)"
        case .permissionDenied:
            "Enable microphone access in Settings to use keyboard voice input."
        case let .failed(message):
            message
        }
    }
}

@MainActor
@Observable
final class VoiceInputLaunchModel {
    private let sessionController: any DictationSessionControlling
    private var routeStartTask: Task<Void, Never>?

    var status = VoiceInputLaunchStatus.idle

    init(sessionController: any DictationSessionControlling = AppBackgroundDictationSessionController()) {
        self.sessionController = sessionController
    }

    func handleOpenURL(_ url: URL) {
        guard let route = ContainingAppRoute(url: url) else { return }
        guard routeStartTask == nil else { return }

        routeStartTask = Task { [weak self] in
            guard let self else { return }
            switch route {
            case .startDictation:
                await self.startDictation()
            case let .startDictationForKeyboardSession(sessionID):
                await self.startDictation(forKeyboardSessionID: sessionID)
            }
            self.routeStartTask = nil
        }
    }

    func startDictation() async {
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        status = await sessionController.startFromContainingApp()
    }

    private func startDictation(forKeyboardSessionID sessionID: String) async {
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        status = await sessionController.startFromKeyboardSession(sessionID: sessionID)
    }

    func prepareSession() async {
        guard status == .idle else { return }
        status = await sessionController.prepareSession()
    }

    func setAppAvailable(_ isAvailable: Bool) {
        sessionController.setAppAvailable(isAvailable)
    }
}

@MainActor
protocol DictationSessionControlling {
    func prepareSession() async -> VoiceInputLaunchStatus
    func startFromContainingApp() async -> VoiceInputLaunchStatus
    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus
    func setAppAvailable(_ isAvailable: Bool)
    func cancelActiveSession() async
}

// UIKit tests use the host application's package instance instead of linking
// a second copy of the shared-storage classes into the test bundle.
typealias SharedDictationSessionStoreForTesting = SharedDictationSessionStore

@MainActor
protocol MicrophoneActivating {
    func activate() async -> VoiceInputLaunchStatus
}

@MainActor
final class AppBackgroundDictationSessionController: DictationSessionControlling {
    private let microphoneActivator: any MicrophoneActivating
    private let sessionStoreProvider: () -> SharedDictationSessionStore?
    private var commandMonitorTask: Task<Void, Never>?
    private var activeStartTask: Task<VoiceInputLaunchStatus, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatToken: String?
    private var heartbeatState: SharedDictationAppHeartbeat.SessionState = .armed
    private var activeSessionID: String?
    private var activeCommandToken: String?
    private var isMicrophoneActivationActive = false
    private var lastClaimedCommandToken: String?
    private var isAppAvailable = true

    init(
        microphoneActivator: any MicrophoneActivating = AppMicrophoneActivator(),
        sessionStoreProvider: @escaping () -> SharedDictationSessionStore? = {
            SharedDictationSessionStore.appGroupStore()
        }
    ) {
        self.microphoneActivator = microphoneActivator
        self.sessionStoreProvider = sessionStoreProvider
    }

    func prepareSession() async -> VoiceInputLaunchStatus {
        guard let sessionStore = sessionStoreProvider() else {
            return .failed("Shared App Group storage is unavailable.")
        }
        recoverStaleSession(in: sessionStore)
        heartbeatToken = UUID().uuidString
        heartbeatState = isAppAvailable ? .armed : .unavailable
        // A fresh pending command may have been written just before this app
        // launched. Older acknowledged/recording commands are one-shot and
        // must not be replayed by the new process.
        let currentStatus = sessionStore.status()
        if case let .commandPending(token, _) = currentStatus,
           let pendingCommand = sessionStore.latestCommand(),
           pendingCommand.token == token,
           !pendingCommand.isExpired() {
            lastClaimedCommandToken = nil
        } else if let latestCommand = sessionStore.latestCommand(),
                  latestCommand.kind == .start,
                  latestCommand.source == .keyboard,
                  !latestCommand.isExpired(),
                  currentStatus.commandToken != latestCommand.token {
            // Command and status are separate App Group records. If the
            // extension or app is terminated between those writes, recover a
            // fresh keyboard command instead of suppressing it as already
            // claimed.
            lastClaimedCommandToken = nil
        } else if let latestCommand = sessionStore.latestCommand(),
                  (latestCommand.kind == .stop || latestCommand.kind == .cancel),
                  latestCommand.source == .keyboard,
                  !latestCommand.isExpired() {
            // A stop may have been written while the app was terminated.
            // Claim it after stale-session recovery so the keyboard sees a
            // terminal status for the stop token instead of timing out.
            lastClaimedCommandToken = nil
        } else {
            lastClaimedCommandToken = sessionStore.latestCommand()?.token
        }
        writeHeartbeat(in: sessionStore)
        guard isAppAvailable else { return .sessionReady }
        startHeartbeatTask()
        startCommandMonitor()
        return .sessionReady
    }

    func setAppAvailable(_ isAvailable: Bool) {
        isAppAvailable = isAvailable
        if !isAvailable {
            heartbeatState = .unavailable
            writeHeartbeat()
            commandMonitorTask?.cancel()
            commandMonitorTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }

        heartbeatState = isMicrophoneActivationActive ? .recording : .armed
        writeHeartbeat()
        startHeartbeatTask()
        startCommandMonitor()
    }

    func startFromContainingApp() async -> VoiceInputLaunchStatus {
        guard !isMicrophoneActivationActive else {
            return .failed("Voice input is already in progress.")
        }
        guard let sessionStore = sessionStoreProvider() else {
            return .failed("Shared App Group storage is unavailable.")
        }

        let command = SharedDictationSessionCommand.start(source: .containingApp)
        isMicrophoneActivationActive = true
        activeSessionID = command.sessionID
        activeCommandToken = command.token
        let startedAt = Date()
        sessionStore.saveCommand(command)
        sessionStore.saveStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
        ))
        sessionStore.saveStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        ))
        heartbeatState = .recording
        writeHeartbeat(in: sessionStore)

        let activationTask = Task { [weak self] () -> VoiceInputLaunchStatus in
            guard let self else { return .failed("Voice input controller was released.") }
            defer { self.clearActivationIfOwned(by: command) }
            guard !Task.isCancelled else { return .failed("Cancelled") }
            let result = await self.activateMicrophone(
                sessionID: command.sessionID,
                commandToken: command.token
            )
            guard !Task.isCancelled,
                  self.activeSessionID == command.sessionID,
                  self.activeCommandToken == command.token else {
                return result
            }
            self.saveCompletionStatus(for: command, result: result, in: sessionStore)
            return result
        }
        activeStartTask = activationTask
        return await withTaskCancellationHandler {
            await activationTask.value
        } onCancel: {
            activationTask.cancel()
        }
    }

    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus {
        guard let sessionStore = sessionStoreProvider() else {
            return .failed("Shared App Group storage is unavailable.")
        }
        // A cold URL launch can arrive before SwiftUI's root .task has
        // prepared the heartbeat and command monitor. Prepare synchronously
        // here, then claim the exact keyboard-owned command from the URL.
        if commandMonitorTask == nil {
            _ = await prepareSession()
        }
        guard let command = sessionStore.latestCommand(),
              command.kind == .start,
              command.source == .keyboard,
              command.sessionID == sessionID,
              !command.isExpired() else {
            return .failed("The keyboard dictation request is no longer available.")
        }
        if isMicrophoneActivationActive {
            guard activeSessionID == command.sessionID,
                  let activationTask = activeStartTask else {
                return .failed("Voice input is already in progress.")
            }
            return await activationTask.value
        }

        // Claim the exact command before starting. The monitor will therefore
        // ignore it and cannot create a second microphone activation.
        lastClaimedCommandToken = command.token
        startDictation(for: command, in: sessionStore)
        guard let activationTask = activeStartTask else {
            return .failed("Voice input could not be started.")
        }
        return await activationTask.value
    }

    func cancelActiveSession() async {
        commandMonitorTask?.cancel()
        commandMonitorTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let activationTask = activeStartTask
        activeStartTask = nil
        activationTask?.cancel()
        if let activeCommandToken {
            sessionStoreProvider()?.saveStatus(.cancelled(token: activeCommandToken))
        }
        activeSessionID = nil
        activeCommandToken = nil
        isMicrophoneActivationActive = false
        heartbeatState = isAppAvailable ? .armed : .unavailable
        writeHeartbeat()
        if let activationTask {
            _ = await activationTask.value
        }
    }

    private func startCommandMonitor() {
        guard isAppAvailable, commandMonitorTask == nil else { return }
        commandMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.consumeCommandIfNeeded()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func consumeCommandIfNeeded() async {
        guard let sessionStore = sessionStoreProvider() else { return }
        guard let command = sessionStore.claimCommand(
            afterLastClaimedToken: lastClaimedCommandToken
        ) else {
            return
        }
        lastClaimedCommandToken = command.token
        guard command.source == .keyboard else { return }

        switch command.kind {
        case .start:
            startDictation(for: command, in: sessionStore)
        case .stop:
            guard activeSessionID == command.sessionID else {
                guard activeSessionID == nil else { return }
                // A stop can arrive while the containing app has not yet
                // claimed the pending start. Complete the mailbox state so
                // the keyboard's stop monitor does not wait on the replaced
                // start token until its deadline.
                sessionStore.saveStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                writeHeartbeat(in: sessionStore)
                return
            }
            guard sessionStore.status(forCommandToken: activeCommandToken ?? "").acceptsKeyboardStopCommand else {
                return
            }
            let activationTask = activeStartTask
            sessionStore.saveStatus(.commandAcknowledged(
                token: command.token,
                acknowledgedAt: Date()
            ))
            if let stoppableActivator = microphoneActivator as? any StoppableSessionAwareMicrophoneActivating {
                await stoppableActivator.stop(
                    sessionID: command.sessionID,
                    commandToken: activeCommandToken ?? ""
                )
                if let activationTask {
                    _ = await activationTask.value
                }
                sessionStore.saveStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                writeHeartbeat(in: sessionStore)
            } else {
                activeStartTask = nil
                activationTask?.cancel()
                isMicrophoneActivationActive = false
                activeSessionID = nil
                activeCommandToken = nil
                sessionStore.saveStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                writeHeartbeat(in: sessionStore)
                if let activationTask {
                    _ = await activationTask.value
                }
            }
        case .cancel:
            guard activeSessionID == command.sessionID else { return }
            let activationTask = activeStartTask
            activeStartTask = nil
            activationTask?.cancel()
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            sessionStore.saveStatus(.cancelled(token: command.token))
            heartbeatState = isAppAvailable ? .armed : .unavailable
            writeHeartbeat(in: sessionStore)
            if let activationTask { _ = await activationTask.value }
        }
    }

    private func startDictation(
        for command: SharedDictationSessionCommand,
        in sessionStore: SharedDictationSessionStore
    ) {
        guard !isMicrophoneActivationActive else {
            sessionStore.saveStatus(.failed(
                token: command.token,
                message: "Voice input is already in progress."
            ))
            heartbeatState = isAppAvailable ? .armed : .unavailable
            writeHeartbeat(in: sessionStore)
            return
        }

        activeSessionID = command.sessionID
        activeCommandToken = command.token

        let startedAt = Date()
        sessionStore.saveStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
        ))
        sessionStore.saveStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        ))
        heartbeatState = .recording
        writeHeartbeat(in: sessionStore)

        isMicrophoneActivationActive = true
        activeStartTask = Task { [weak self] in
            guard let self else { return .failed("Voice input controller was released.") }
            defer { self.clearActivationIfOwned(by: command) }
            guard !Task.isCancelled else { return .failed("Cancelled") }
            let result = await self.activateMicrophone(
                sessionID: command.sessionID,
                commandToken: command.token
            )
            guard !Task.isCancelled else { return result }
            guard self.activeSessionID == command.sessionID,
                  self.activeCommandToken == command.token else { return result }
            self.saveCompletionStatus(for: command, result: result, in: sessionStore)
            return result
        }
    }

    private func saveCompletionStatus(
        for command: SharedDictationSessionCommand,
        result: VoiceInputLaunchStatus,
        in sessionStore: SharedDictationSessionStore
    ) {
        switch result {
        case .transcriptShared:
            sessionStore.saveStatus(.transcriptReady(token: command.token))
        case .permissionDenied:
            sessionStore.saveStatus(.failed(
                token: command.token,
                message: "Microphone permission is denied."
            ))
        case let .failed(message):
            sessionStore.saveStatus(.failed(token: command.token, message: message))
        case .idle, .sessionReady, .requestingPermission, .microphoneActive:
            sessionStore.saveStatus(.commandAcknowledged(
                token: command.token,
                acknowledgedAt: Date()
            ))
        }
        if activeCommandToken == command.token {
            activeStartTask = nil
        }
        activeSessionID = nil
        activeCommandToken = nil
        isMicrophoneActivationActive = false
        heartbeatState = isAppAvailable ? .armed : .unavailable
        writeHeartbeat(in: sessionStore)
    }

    private func clearActivationIfOwned(by command: SharedDictationSessionCommand) {
        guard activeCommandToken == command.token else { return }
        isMicrophoneActivationActive = false
        activeStartTask = nil
    }

    private func activateMicrophone(
        sessionID: String,
        commandToken: String
    ) async -> VoiceInputLaunchStatus {
        if let sessionAwareActivator = microphoneActivator as? any SessionAwareMicrophoneActivating {
            return await sessionAwareActivator.activate(
                sessionID: sessionID,
                commandToken: commandToken
            )
        }
        return await microphoneActivator.activate()
    }

    private func startHeartbeatTask() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self, self.isAppAvailable else { return }
                self.writeHeartbeat()
            }
        }
    }

    private func writeHeartbeat(
        in sessionStore: SharedDictationSessionStore? = nil
    ) {
        guard let heartbeatToken,
              let store = sessionStore ?? sessionStoreProvider() else { return }
        store.saveHeartbeat(SharedDictationAppHeartbeat(
            token: heartbeatToken,
            lastSeenAt: Date(),
            sessionState: heartbeatState
        ))
    }

    private func recoverStaleSession(in sessionStore: SharedDictationSessionStore) {
        switch sessionStore.status() {
        case .idle:
            guard let command = sessionStore.latestCommand(),
                  command.source == .keyboard,
                  command.isExpired() else {
                return
            }
            sessionStore.saveStatus(.cancelled(token: command.token))
        case let .commandAcknowledged(token, _):
            sessionStore.saveStatus(.cancelled(token: token))
        case let .recording(token, _, _):
            sessionStore.saveStatus(.cancelled(token: token))
        case let .transcribing(token):
            sessionStore.saveStatus(.cancelled(token: token))
        case .transcriptReady,
             .failed,
             .cancelled:
            break
        case let .commandPending(token, _):
            guard let command = sessionStore.latestCommand(),
                  command.token == token,
                  !command.isExpired() else {
                sessionStore.saveStatus(.cancelled(token: token))
                return
            }
        }
    }
}

@MainActor
protocol SessionAwareMicrophoneActivating {
    func activate(sessionID: String, commandToken: String) async -> VoiceInputLaunchStatus
}

@MainActor
protocol StoppableSessionAwareMicrophoneActivating: SessionAwareMicrophoneActivating {
    func stop(sessionID: String, commandToken: String) async
}

@MainActor
final class AppMicrophoneActivator: MicrophoneActivating, StoppableSessionAwareMicrophoneActivating {
    private let transcriptStoreProvider: () -> SharedDictationTranscriptStore?
    private var activeRun: AppSpeechDictationRun?

    init(
        transcriptStoreProvider: @escaping () -> SharedDictationTranscriptStore? = {
            SharedDictationTranscriptStore.appGroupStore()
        }
    ) {
        self.transcriptStoreProvider = transcriptStoreProvider
    }

    func activate() async -> VoiceInputLaunchStatus {
        await activate(
            sessionID: UUID().uuidString,
            commandToken: UUID().uuidString
        )
    }

    func activate(
        sessionID: String,
        commandToken: String
    ) async -> VoiceInputLaunchStatus {
        guard await requestRecordPermission() else {
            return .permissionDenied
        }

        guard await requestSpeechRecognitionAuthorization() else {
            return .failed("Enable speech recognition access in Settings to use keyboard voice input.")
        }

        let run = AppSpeechDictationRun(locale: Locale.current, maximumDuration: 8)
        activeRun = run
        defer { if activeRun === run { activeRun = nil } }

        do {
            let transcriptText = try await run.start()
            guard let transcript = SharedDictationTranscript(
                sessionID: sessionID,
                commandToken: commandToken,
                text: transcriptText
            ) else {
                return .failed("Speech recognition returned an empty transcript.")
            }

            guard let transcriptStore = transcriptStoreProvider() else {
                return .failed("Shared App Group storage is unavailable.")
            }

            transcriptStore.save(transcript)
            return .transcriptShared(transcript.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func stop(sessionID: String, commandToken: String) async {
        activeRun?.finishForUserStop()
    }

    private func requestRecordPermission() async -> Bool {
        guard !Task.isCancelled else { return false }
        let gate = AppPermissionRequestGate(cancelledValue: false)
        return await withTaskCancellationHandler(operation: {
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
    }

    private func requestSpeechRecognitionAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            guard !Task.isCancelled else { return false }
            let gate = AppPermissionRequestGate(cancelledValue: false)
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    gate.install(continuation)
                    guard !Task.isCancelled else {
                        gate.cancel()
                        return
                    }
                    SFSpeechRecognizer.requestAuthorization { status in
                        gate.finish(status == .authorized)
                    }
                }
            }, onCancel: {
                gate.cancel()
            })
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private final class AppPermissionRequestGate<Value: Sendable>: @unchecked Sendable {
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

private extension SharedDictationSessionStatus {
    var commandToken: String? {
        switch self {
        case .idle:
            nil
        case let .commandPending(token, _),
             let .commandAcknowledged(token, _),
             let .recording(token, _, _),
             let .transcribing(token),
             let .transcriptReady(token):
            token
        case let .failed(token, _),
             let .cancelled(token):
            token
        }
    }
}
