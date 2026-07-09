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

    var status = VoiceInputLaunchStatus.idle

    init(sessionController: any DictationSessionControlling = AppBackgroundDictationSessionController()) {
        self.sessionController = sessionController
    }

    func handleOpenURL(_ url: URL) {
        guard ContainingAppRoute(url: url) == .startDictation else { return }

        Task {
            await startDictation()
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
        sessionStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: UUID().uuidString,
            lastSeenAt: Date(),
            sessionState: .armed
        ))
        startCommandMonitor()
        return .sessionReady
    }

    func startFromContainingApp() async -> VoiceInputLaunchStatus {
        await microphoneActivator.activate()
    }

    func cancelActiveSession() async {
        commandMonitorTask?.cancel()
        commandMonitorTask = nil
        activeStartTask?.cancel()
        activeStartTask = nil
        sessionStoreProvider()?.saveStatus(.cancelled(token: nil))
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

        switch command.kind {
        case .start:
            startDictation(for: command, in: sessionStore)
        case .stop, .cancel:
            activeStartTask?.cancel()
            activeStartTask = nil
            sessionStore.saveStatus(.cancelled(token: command.token))
            sessionStore.saveHeartbeat(SharedDictationAppHeartbeat(
                token: command.token,
                lastSeenAt: Date(),
                sessionState: .armed
            ))
        }
    }

    private func startDictation(
        for command: SharedDictationSessionCommand,
        in sessionStore: SharedDictationSessionStore
    ) {
        activeStartTask?.cancel()

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
        sessionStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: command.token,
            lastSeenAt: startedAt,
            sessionState: .recording
        ))

        activeStartTask = Task { [weak self] in
            guard let self else { return }
            let result = await microphoneActivator.activate()
            guard !Task.isCancelled else { return }
            saveCompletionStatus(for: command.token, result: result, in: sessionStore)
            activeStartTask = nil
        }
    }

    private func saveCompletionStatus(
        for token: String,
        result: VoiceInputLaunchStatus,
        in sessionStore: SharedDictationSessionStore
    ) {
        switch result {
        case .transcriptShared:
            sessionStore.saveStatus(.transcriptReady(token: token))
        case .permissionDenied:
            sessionStore.saveStatus(.failed(
                token: token,
                message: "Microphone permission is denied."
            ))
        case let .failed(message):
            sessionStore.saveStatus(.failed(token: token, message: message))
        case .idle, .sessionReady, .requestingPermission, .microphoneActive:
            sessionStore.saveStatus(.commandAcknowledged(
                token: token,
                acknowledgedAt: Date()
            ))
        }
        sessionStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: token,
            lastSeenAt: Date(),
            sessionState: .armed
        ))
    }
}

struct AppMicrophoneActivator: MicrophoneActivating {
    private let transcriptStoreProvider: () -> SharedDictationTranscriptStore?

    init(
        transcriptStoreProvider: @escaping () -> SharedDictationTranscriptStore? = {
            SharedDictationTranscriptStore.appGroupStore()
        }
    ) {
        self.transcriptStoreProvider = transcriptStoreProvider
    }

    func activate() async -> VoiceInputLaunchStatus {
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
            guard let transcript = SharedDictationTranscript(text: transcriptText) else {
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
