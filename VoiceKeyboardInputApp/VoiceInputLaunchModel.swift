import AVFAudio
import Observation
import Speech
import VoiceKeyboardModels

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
        guard ContainingAppRoute(url: url) == .startDictation else { return }
        guard routeStartTask == nil else { return }

        routeStartTask = Task { [weak self] in
            await self?.startDictation()
            self?.routeStartTask = nil
        }
    }

    func startDictation() async {
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        status = await sessionController.startFromContainingApp()
    }

    func prepareSession() async {
        guard status == .idle else { return }
        status = await sessionController.prepareSession()
    }
}

@MainActor
protocol DictationSessionControlling {
    func prepareSession() async -> VoiceInputLaunchStatus
    func startFromContainingApp() async -> VoiceInputLaunchStatus
    func cancelActiveSession() async
}

@MainActor
protocol MicrophoneActivating {
    func activate() async -> VoiceInputLaunchStatus
}

@MainActor
final class AppBackgroundDictationSessionController: DictationSessionControlling {
    private let microphoneActivator: any MicrophoneActivating
    private let sessionStoreProvider: () -> SharedDictationSessionStore?
    private var commandMonitorTask: Task<Void, Never>?
    private var activeStartTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatToken: String?
    private var heartbeatState: SharedDictationAppHeartbeat.SessionState = .armed
    private var activeSessionID: String?
    private var activeCommandToken: String?
    private var isMicrophoneActivationActive = false
    private var lastClaimedCommandToken: String?

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
        heartbeatState = .armed
        lastClaimedCommandToken = nil
        writeHeartbeat(in: sessionStore)
        startHeartbeatTask()
        startCommandMonitor()
        return .sessionReady
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
        defer {
            isMicrophoneActivationActive = false
        }
        let result = await activateMicrophone(
            sessionID: command.sessionID,
            commandToken: command.token
        )
        guard !Task.isCancelled,
              activeSessionID == command.sessionID,
              activeCommandToken == command.token else {
            return result
        }
        saveCompletionStatus(for: command, result: result, in: sessionStore)
        return result
    }

    func cancelActiveSession() async {
        commandMonitorTask?.cancel()
        commandMonitorTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeStartTask?.cancel()
        activeStartTask = nil
        if let activeCommandToken {
            sessionStoreProvider()?.saveStatus(.cancelled(token: activeCommandToken))
        }
        activeSessionID = nil
        activeCommandToken = nil
        heartbeatState = .unavailable
        writeHeartbeat()
    }

    private func startCommandMonitor() {
        guard commandMonitorTask == nil else { return }
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
        case .stop, .cancel:
            guard activeSessionID == command.sessionID else { return }
            activeStartTask?.cancel()
            activeStartTask = nil
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            sessionStore.saveStatus(.cancelled(token: command.token))
            heartbeatState = .armed
            writeHeartbeat(in: sessionStore)
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
            heartbeatState = .armed
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
            guard let self else { return }
            defer {
                isMicrophoneActivationActive = false
                activeStartTask = nil
            }
            let result = await activateMicrophone(
                sessionID: command.sessionID,
                commandToken: command.token
            )
            guard !Task.isCancelled else { return }
            guard activeSessionID == command.sessionID,
                  activeCommandToken == command.token else { return }
            saveCompletionStatus(for: command, result: result, in: sessionStore)
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
        activeSessionID = nil
        activeCommandToken = nil
        heartbeatState = .armed
        writeHeartbeat(in: sessionStore)
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
                self?.writeHeartbeat()
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
        case let .commandAcknowledged(token, _):
            sessionStore.saveStatus(.cancelled(token: token))
        case let .recording(token, _, _):
            sessionStore.saveStatus(.cancelled(token: token))
        case let .transcribing(token):
            sessionStore.saveStatus(.cancelled(token: token))
        case .idle,
             .commandPending,
             .transcriptReady,
             .failed,
             .cancelled:
            break
        }
    }
}

@MainActor
protocol SessionAwareMicrophoneActivating {
    func activate(sessionID: String, commandToken: String) async -> VoiceInputLaunchStatus
}

struct AppMicrophoneActivator: MicrophoneActivating, SessionAwareMicrophoneActivating {
    private let transcriptStoreProvider: () -> SharedDictationTranscriptStore?

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

        do {
            let transcriptText = try await AppSpeechDictationService().transcribe(
                locale: Locale.current,
                maximumDuration: 8
            )
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

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }

    private func requestSpeechRecognitionAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
