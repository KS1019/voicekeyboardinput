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
        let preparationStatus = await sessionController.prepareSession()
        guard case .sessionReady = preparationStatus else {
            status = preparationStatus
            return
        }
        status = .requestingPermission
        status = await sessionController.startFromContainingApp()
    }

    private func startDictation(forKeyboardSessionID sessionID: String) async {
        guard status != .requestingPermission else { return }
        let preparationStatus = await sessionController.prepareSession()
        guard case .sessionReady = preparationStatus else {
            status = preparationStatus
            return
        }
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
    private let sessionStoreProvider: @Sendable () -> SharedDictationSessionStore?
    private let transcriptStoreProvider: @Sendable () -> SharedDictationTranscriptStore?
    private var commandMonitorTask: Task<Void, Never>?
    private var commandMonitorGeneration: UInt64 = 0
    private var activeStartTask: Task<VoiceInputLaunchStatus, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatToken: String?
    private var heartbeatState: SharedDictationAppHeartbeat.SessionState = .armed
    private var activeSessionID: String?
    private var activeCommandToken: String?
    private var activationGeneration: UInt64 = 0
    private var isMicrophoneActivationActive = false
    private var startReservationToken: String?
    private var startIntentInFlight = false
    private var lastClaimedCommandToken: String?
    private var isAppAvailable = true

    init(
        microphoneActivator: any MicrophoneActivating = AppMicrophoneActivator(),
        sessionStoreProvider: @escaping @Sendable () -> SharedDictationSessionStore? = {
            SharedDictationSessionStore.appGroupStore()
        },
        transcriptStoreProvider: @escaping @Sendable () -> SharedDictationTranscriptStore? = {
            SharedDictationTranscriptStore.appGroupStore()
        }
    ) {
        self.microphoneActivator = microphoneActivator
        self.sessionStoreProvider = sessionStoreProvider
        self.transcriptStoreProvider = transcriptStoreProvider
    }

    deinit {
        commandMonitorTask?.cancel()
        activeStartTask?.cancel()
        heartbeatTask?.cancel()
    }

    private func sessionStoreCall<Result: Sendable>(
        _ operation: @escaping @Sendable (SharedDictationSessionStore) -> Result
    ) async -> Result? {
        let provider = sessionStoreProvider
        return await Task.detached {
            guard let store = provider() else { return nil }
            return operation(store)
        }.value
    }

    private func transcriptStoreCall<Result: Sendable>(
        _ operation: @escaping @Sendable (SharedDictationTranscriptStore) -> Result
    ) async -> Result? {
        let provider = transcriptStoreProvider
        return await Task.detached {
            guard let store = provider() else { return nil }
            return operation(store)
        }.value
    }

    func prepareSession() async -> VoiceInputLaunchStatus {
        if heartbeatToken != nil {
            writeHeartbeat()
            if heartbeatTask == nil, isAppAvailable || isMicrophoneActivationActive {
                startHeartbeatTask()
            }
            if commandMonitorTask == nil, isAppAvailable || isMicrophoneActivationActive {
                startCommandMonitor()
            }
            return .sessionReady
        }
        guard await sessionStoreCall({ $0.storageHealth() }) == true else {
            return .failed("Shared App Group storage is unavailable.")
        }
        guard await recoverStaleSession() else {
            return .failed("Shared App Group storage is unavailable.")
        }
        heartbeatToken = UUID().uuidString
        heartbeatState = isAppAvailable ? .armed : .unavailable
        // A fresh pending command may have been written just before this app
        // launched. Older acknowledged/recording commands are one-shot and
        // must not be replayed by the new process.
        let currentStatus = await sessionStoreCall { $0.status() } ?? .idle
        let latestCommand = await sessionStoreCall { $0.latestCommand() } ?? nil
        if case let .commandPending(token, _) = currentStatus,
           let pendingCommand = latestCommand,
           pendingCommand.token == token,
           !pendingCommand.isExpired() {
            lastClaimedCommandToken = nil
        } else if let latestCommand,
                  latestCommand.kind == .start,
                  latestCommand.source == .keyboard,
                  !latestCommand.isExpired(),
                  currentStatus.commandToken != latestCommand.token {
            // Command and status are separate App Group records. If the
            // extension or app is terminated between those writes, recover a
            // fresh keyboard command instead of suppressing it as already
            // claimed.
            lastClaimedCommandToken = nil
        } else if let latestCommand,
                  (latestCommand.kind == .stop || latestCommand.kind == .cancel),
                  latestCommand.source == .keyboard,
                  !latestCommand.isExpired() {
            // A stop may have been written while the app was terminated.
            // Claim it after stale-session recovery so the keyboard sees a
            // terminal status for the stop token instead of timing out.
            lastClaimedCommandToken = nil
        } else {
            lastClaimedCommandToken = latestCommand?.token
        }
        await persistHeartbeat()
        guard isAppAvailable else { return .sessionReady }
        startHeartbeatTask()
        startCommandMonitor()
        return .sessionReady
    }

    func setAppAvailable(_ isAvailable: Bool) {
        isAppAvailable = isAvailable
        if !isAvailable {
            heartbeatState = isMicrophoneActivationActive ? .recording : .unavailable
            writeHeartbeat()
            if isMicrophoneActivationActive {
                // The containing app can become inactive while the keyboard
                // is visible. Keep consuming the keyboard's Stop command so
                // an active audio run is not left alive until its timeout.
                startCommandMonitor()
            } else {
                commandMonitorGeneration &+= 1
                commandMonitorTask?.cancel()
                commandMonitorTask = nil
            }
            if !isMicrophoneActivationActive {
                heartbeatTask?.cancel()
                heartbeatTask = nil
            } else {
                startHeartbeatTask()
            }
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
        guard heartbeatToken != nil else {
            return .failed("Voice input session is still preparing. Please try again.")
        }
        guard !startIntentInFlight else {
            return .failed("Voice input is already being prepared.")
        }
        startIntentInFlight = true
        defer { startIntentInFlight = false }
        let command: SharedDictationSessionCommand
        let shouldPublishCommand: Bool
        if let pendingKeyboardCommand = await firstUnclaimedKeyboardCommand() {
            // If the user opened the app manually after the keyboard wrote a
            // handoff command, keep the keyboard's session identity. This
            // preserves delivery even when the extension cannot open the app
            // directly on a given iOS release.
            command = pendingKeyboardCommand
            shouldPublishCommand = false
        } else {
            command = SharedDictationSessionCommand.start(source: .containingApp)
            shouldPublishCommand = true
        }
        if shouldPublishCommand {
            guard await sessionStoreCall({ $0.saveCommand(command) }) == true else {
                return .failed("Shared App Group storage is busy. Please try again.")
            }
        }
        let ownerToken = heartbeatToken
        guard let ownerToken,
              !Task.isCancelled else {
            return .failed("Another app scene is already handling this voice input.")
        }
        startReservationToken = command.token
        activationGeneration &+= 1
        isMicrophoneActivationActive = true
        activeSessionID = command.sessionID
        activeCommandToken = command.token
        guard await sessionStoreCall({
                  $0.claimCommand(token: command.token, ownerToken: ownerToken)
              }) == true else {
            startReservationToken = nil
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            return .failed("Another app scene is already handling this voice input.")
        }
        if command.source == .keyboard {
            // The containing app adopted a keyboard-owned command. Claim it
            // before the monitor can observe the same mailbox entry.
            lastClaimedCommandToken = command.token
        }
        startReservationToken = nil
        let startedAt = Date()
        guard await saveOwnedStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
        )),
        await saveOwnedStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        )) else {
            _ = await saveOwnedStatus(.failed(
                token: command.token,
                message: "Shared App Group storage could not persist the recording state."
            ))
            // The activation flags are set before the two status writes so a
            // concurrent command cannot start a second run. If persistence
            // fails, release those flags as well; otherwise a transient App
            // Group write failure strands this scene in a permanently active
            // state without ever starting the microphone.
            isMicrophoneActivationActive = false
            startReservationToken = nil
            activeSessionID = nil
            activeCommandToken = nil
            heartbeatState = isAppAvailable ? .armed : .unavailable
            await persistHeartbeat()
            return .failed("Shared App Group storage is busy. Please try again.")
        }
        heartbeatState = .recording
        await persistHeartbeat()

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
            await self.saveCompletionStatus(for: command, result: result)
            return result
        }
        activeStartTask = activationTask
        startIntentInFlight = false
        return await withTaskCancellationHandler {
            await activationTask.value
        } onCancel: {
            activationTask.cancel()
        }
    }

    func startFromKeyboardSession(sessionID: String) async -> VoiceInputLaunchStatus {
        guard !isMicrophoneActivationActive, !startIntentInFlight else {
            return .failed("Voice input is already in progress.")
        }
        startIntentInFlight = true
        defer { startIntentInFlight = false }
        if heartbeatToken == nil {
            _ = await prepareSession()
        }
        guard heartbeatToken != nil else {
            return .failed("Voice input session is still preparing. Please try again.")
        }
        // A cold URL launch can arrive before SwiftUI's root .task has
        // prepared the heartbeat and command monitor. Prepare synchronously
        // here, then claim the exact keyboard-owned command from the URL.
        if commandMonitorTask == nil {
            _ = await prepareSession()
        }
        guard let command = (await sessionStoreCall({ $0.commandHistory() }) ?? []).reversed().first(where: {
            $0.kind == .start
                && $0.source == .keyboard
                && $0.sessionID == sessionID
                && !$0.isExpired()
        }) else {
            return .failed("The keyboard dictation request is no longer available.")
        }
        // Claim the exact command before starting. The monitor will therefore
        // ignore it and cannot create a second microphone activation.
        let ownerToken = heartbeatToken
        guard let ownerToken else {
            return .failed("Another app scene is already handling this voice input.")
        }
        startReservationToken = command.token
        activationGeneration &+= 1
        isMicrophoneActivationActive = true
        activeSessionID = command.sessionID
        activeCommandToken = command.token
        guard await sessionStoreCall({
                  $0.claimCommand(token: command.token, ownerToken: ownerToken)
              }) == true else {
            startReservationToken = nil
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            return .failed("Another app scene is already handling this voice input.")
        }
        lastClaimedCommandToken = command.token
        await startDictation(for: command)
        startIntentInFlight = false
        guard let activationTask = activeStartTask else {
            return .failed("Voice input could not be started.")
        }
        return await activationTask.value
    }

    func cancelActiveSession() async {
        commandMonitorGeneration &+= 1
        commandMonitorTask?.cancel()
        commandMonitorTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let activationTask = activeStartTask
        activeStartTask = nil
        activationTask?.cancel()
        if let activeCommandToken {
            _ = await saveOwnedStatus(.cancelled(token: activeCommandToken))
        }
        startReservationToken = nil
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
        guard (isAppAvailable || isMicrophoneActivationActive), commandMonitorTask == nil else { return }
        commandMonitorGeneration &+= 1
        let generation = commandMonitorGeneration
        commandMonitorTask = Task { [weak self] in
            defer {
                if let self, self.commandMonitorGeneration == generation {
                    self.commandMonitorTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isAppAvailable || self.isMicrophoneActivationActive else { return }
                await self.consumeCommandIfNeeded()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func consumeCommandIfNeeded() async {
        guard await recoverCompletedTranscriptIfPresent() else { return }
        guard startReservationToken == nil, !startIntentInFlight else { return }
        let lastClaimedToken = lastClaimedCommandToken
        let cursorBeforeClaim = lastClaimedToken
        let ownerToken = heartbeatToken
        guard let command = await sessionStoreCall({
            $0.claimCommand(
                afterLastClaimedToken: lastClaimedToken,
                ownerToken: ownerToken,
                source: .keyboard
            )
        }) ?? nil else {
            return
        }
        lastClaimedCommandToken = command.token
        guard command.source == .keyboard else { return }

        switch command.kind {
        case .start:
            guard !isMicrophoneActivationActive,
                  !startIntentInFlight,
                  startReservationToken == nil else {
                if startReservationToken != command.token {
                    _ = await sessionStoreCall {
                        $0.releaseCommandClaim(token: command.token, ownerToken: ownerToken)
                    }
                }
                // Keep the cursor after this command while another start is
                // being prepared so a later Stop/Cancel command can still be
                // observed. Once the active run ends, clearActivationIfOwned
                // resets the cursor and the pending start can be reconsidered.
                return
            }
            guard isAppAvailable else {
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                return
            }
            await startDictation(for: command)
        case .stop:
            guard activeSessionID == command.sessionID else {
                let ownerToken = heartbeatToken
                if let replacedToken = command.replacesCommandToken,
                   let owner = await sessionStoreCall({ $0.claimOwner(forCommandToken: replacedToken) }) ?? nil,
                   owner != ownerToken {
                    _ = await sessionStoreCall {
                        $0.releaseCommandClaim(
                            token: command.token,
                            ownerToken: ownerToken
                        )
                    }
                    // Keep the monitor cursor before this token. The owner of
                    // the start command can claim the stop on its next poll.
                    lastClaimedCommandToken = cursorBeforeClaim
                    return
                }
                if activeSessionID != nil {
                    if let replacedToken = command.replacesCommandToken {
                        _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                    }
                    _ = await saveOwnedStatus(.failed(
                        token: command.token,
                        message: "Voice input is already active in another session."
                    ))
                    return
                }
                // A stop can arrive while the containing app has not yet
                // claimed the pending start. Complete the mailbox state so
                // the keyboard's stop monitor does not wait on the replaced
                // start token until its deadline.
                if let replacedToken = command.replacesCommandToken,
                   let transcript = await transcriptStoreCall({
                       $0.latestTranscript(forSessionID: command.sessionID)
                   }) ?? nil,
                   transcript.commandToken == replacedToken,
                   !transcript.isConsumed,
                   !transcript.isExpired() {
                    // A cold restart may have completed and persisted the
                    // transcript before the stop was observed. Do not cancel
                    // a result that the keyboard can still deliver.
                    _ = await saveOwnedStatus(.transcriptReady(token: replacedToken))
                } else if let replacedToken = command.replacesCommandToken {
                    _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                return
            }
            let activationTask = activeStartTask
            _ = await saveOwnedStatus(.commandAcknowledged(
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
                if let replacedToken = command.replacesCommandToken {
                    _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
            } else {
                activeStartTask = nil
                activationTask?.cancel()
                isMicrophoneActivationActive = false
                activeSessionID = nil
                activeCommandToken = nil
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                if let activationTask {
                    _ = await activationTask.value
                }
            }
        case .cancel:
            guard activeSessionID == command.sessionID else {
                let ownerToken = heartbeatToken
                if let replacedToken = command.replacesCommandToken,
                   let owner = await sessionStoreCall({ $0.claimOwner(forCommandToken: replacedToken) }) ?? nil,
                   owner != ownerToken {
                    _ = await sessionStoreCall {
                        $0.releaseCommandClaim(
                            token: command.token,
                            ownerToken: ownerToken
                        )
                    }
                    lastClaimedCommandToken = cursorBeforeClaim
                    return
                }
                if let replacedToken = command.replacesCommandToken {
                    _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                return
            }
            let activationTask = activeStartTask
            activeStartTask = nil
            activationTask?.cancel()
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            startReservationToken = nil
            if let replacedToken = command.replacesCommandToken {
                _ = await saveOwnedStatus(.cancelled(token: replacedToken))
            }
            _ = await saveOwnedStatus(.cancelled(token: command.token))
            heartbeatState = isAppAvailable ? .armed : .unavailable
            await persistHeartbeat()
            if let activationTask { _ = await activationTask.value }
        }
    }

    private func firstUnclaimedKeyboardCommand() async -> SharedDictationSessionCommand? {
        let commands = await sessionStoreCall { $0.commandHistory() } ?? []
        for command in commands.reversed().filter({
            $0.kind == .start
                && $0.source == .keyboard
                && !$0.isExpired(at: Date())
        }) {
            guard case .idle = await sessionStoreCall({
                $0.status(forCommandToken: command.token)
            }) ?? .idle else { continue }
            guard await transcriptStoreCall({
                $0.latestTranscript(forSessionID: command.sessionID)
            }) ?? nil == nil else { continue }
            return command
        }
        return nil
    }

    private func startDictation(
        for command: SharedDictationSessionCommand
    ) async {
        guard !isMicrophoneActivationActive || startReservationToken == command.token else {
            _ = await saveOwnedStatus(.failed(
                token: command.token,
                message: "Voice input is already in progress."
            ))
            heartbeatState = isAppAvailable ? .armed : .unavailable
            await persistHeartbeat()
            return
        }

        activeSessionID = command.sessionID
        activeCommandToken = command.token
        // Reserve the command before the first detached storage await. The
        // URL route and the monitor can otherwise both pass this guard while
        // the acknowledgement/recording status is being persisted.
        isMicrophoneActivationActive = true
        startReservationToken = nil

        let startedAt = Date()
        guard await saveOwnedStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
        )),
        await saveOwnedStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        )) else {
            _ = await saveOwnedStatus(.failed(
                token: command.token,
                message: "Shared App Group storage could not persist the recording state."
            ))
            activeSessionID = nil
            activeCommandToken = nil
            isMicrophoneActivationActive = false
            return
        }
        heartbeatState = .recording
        await persistHeartbeat()

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
            await self.saveCompletionStatus(for: command, result: result)
            return result
        }
    }

    private func saveCompletionStatus(
        for command: SharedDictationSessionCommand,
        result: VoiceInputLaunchStatus
    ) async {
        let didPersist: Bool
        switch result {
        case .transcriptShared:
            didPersist = await saveOwnedStatus(.transcriptReady(token: command.token))
        case .permissionDenied:
            didPersist = await saveOwnedStatus(.failed(
                token: command.token,
                message: "Microphone permission is denied."
            ))
        case let .failed(message):
            didPersist = await saveOwnedStatus(.failed(token: command.token, message: message))
        case .idle, .sessionReady, .requestingPermission, .microphoneActive:
            didPersist = await saveOwnedStatus(.commandAcknowledged(
                token: command.token,
                acknowledgedAt: Date()
            ))
        }
        if !didPersist {
            // The transcript is written before this status. If the final
            // status write loses a race with App Group storage, immediately
            // retry promotion from that durable transcript rather than
            // silently clearing the session as if delivery were complete.
            if case .transcriptShared = result {
                _ = await recoverCompletedTranscriptIfPresent()
            }
        }
        guard activeCommandToken == command.token,
              activeSessionID == command.sessionID else { return }
        activeStartTask = nil
        activeSessionID = nil
        activeCommandToken = nil
        isMicrophoneActivationActive = false
        heartbeatState = isAppAvailable ? .armed : .unavailable
        await persistHeartbeat()
    }

    private func clearActivationIfOwned(by command: SharedDictationSessionCommand) {
        guard activeCommandToken == command.token else { return }
        isMicrophoneActivationActive = false
        activeStartTask = nil
        activeSessionID = nil
        activeCommandToken = nil
        lastClaimedCommandToken = nil
        Task { [weak self] in
            _ = await self?.saveOwnedStatus(.cancelled(token: command.token))
        }
        heartbeatState = isAppAvailable ? .armed : .unavailable
        writeHeartbeat()
    }

    private func activateMicrophone(
        sessionID: String,
        commandToken: String
    ) async -> VoiceInputLaunchStatus {
        if let sessionAwareActivator = microphoneActivator as? any SessionAwareMicrophoneActivating {
            guard let ownerToken = heartbeatToken else {
                return .failed("Voice input session ownership was lost.")
            }
            return await sessionAwareActivator.activate(
                sessionID: sessionID,
                commandToken: commandToken,
                ownerToken: ownerToken
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
                guard let self, self.isAppAvailable || self.isMicrophoneActivationActive else { return }
                self.writeHeartbeat()
            }
        }
    }

    private func persistHeartbeat() async {
        guard let heartbeatToken else { return }
        let heartbeat = SharedDictationAppHeartbeat(
            token: heartbeatToken,
            sessionID: activeSessionID,
            lastSeenAt: Date(),
            sessionState: heartbeatState
        )
        let activeCommandToken = activeCommandToken
        let activationGeneration = activationGeneration
        let didRenewClaim = await sessionStoreCall { store -> Bool in
            guard store.saveHeartbeat(heartbeat) else { return false }
            guard let activeCommandToken else { return true }
            return store.renewCommandClaim(
                token: activeCommandToken,
                ownerToken: heartbeatToken
            )
        } ?? false
        guard !Task.isCancelled else { return }
        guard self.activationGeneration == activationGeneration,
              self.activeSessionID == heartbeat.sessionID,
              self.activeCommandToken == activeCommandToken else { return }
        guard !didRenewClaim else { return }
        guard let activeSessionID,
              let activeCommandToken else { return }
        activeStartTask?.cancel()
        activeStartTask = nil
        isMicrophoneActivationActive = false
        self.activeSessionID = nil
        self.activeCommandToken = nil
        heartbeatState = isAppAvailable ? .armed : .unavailable
        if let stoppableActivator = microphoneActivator as? any StoppableSessionAwareMicrophoneActivating {
            await stoppableActivator.stop(
                sessionID: activeSessionID,
                commandToken: activeCommandToken
            )
        }
    }

    /// Production app status transitions must prove that this scene still
    /// owns the short command claim. The defaults-backed one-argument API is
    /// retained for tests and legacy migration only.
    private func saveOwnedStatus(_ status: SharedDictationSessionStatus) async -> Bool {
        guard let ownerToken = heartbeatToken else { return false }
        return await sessionStoreCall {
            $0.saveStatus(status, ownerToken: ownerToken)
        } == true
    }

    private func writeHeartbeat() {
        Task { [weak self] in
            await self?.persistHeartbeat()
        }
    }

    private func recoverStaleSession() async -> Bool {
        guard await recoverCompletedTranscriptIfPresent() else { return false }
        guard let history = await sessionStoreCall({ $0.commandHistoryResolution() }),
              case .available(let commands) = history else {
            return false
        }
        for command in commands
        where command.source == .keyboard && command.kind == .start {
            _ = await sessionStoreCall {
                $0.cancelStaleKeyboardCommand(token: command.token)
            }
        }
        return true
    }

    private func recoverCompletedTranscriptIfPresent() async -> Bool {
        guard let history = await sessionStoreCall({ $0.commandHistoryResolution() }),
              case .available(let commands) = history else {
            return false
        }
        var commandsByToken: [String: SharedDictationSessionCommand] = [:]
        for command in commands {
            commandsByToken[command.token] = command
        }
        let cancelledTranscriptTokens = Set(commands.compactMap { command -> String? in
            guard command.kind == .cancel else { return nil }
            return command.replacesCommandToken
        })

        // Some compatibility/unit-test controllers intentionally omit a
        // transcript store. In production, an existing store must be readable
        // before stale-session cancellation is allowed to proceed.
        guard let transcriptResolution = await transcriptStoreCall({
            $0.unconsumedTranscriptsResolution()
        }) else {
            return true
        }
        guard case .available(let transcripts) = transcriptResolution else {
            return false
        }
        for transcript in transcripts {
            guard let command = commandsByToken[transcript.commandToken],
                  command.kind == .start,
                  command.sessionID == transcript.sessionID,
                  !cancelledTranscriptTokens.contains(transcript.commandToken) else {
                continue
            }
            guard await sessionStoreCall({ $0.storageHealth() }) == true else {
                return false
            }
            let status = await sessionStoreCall { $0.status(forCommandToken: transcript.commandToken) } ?? .idle
            switch status {
            case .commandAcknowledged, .recording, .transcribing,
                 .idle, .commandPending:
                // The transcript is the durable completion marker. Promote
                // it even when status publication was interrupted or a newer
                // scene became the latest command.
                _ = await sessionStoreCall { $0.saveStatus(.transcriptReady(token: transcript.commandToken)) }
            case .transcriptReady, .failed, .cancelled:
                break
            }
        }
        return true
    }
}

@MainActor
protocol SessionAwareMicrophoneActivating {
    func activate(
        sessionID: String,
        commandToken: String,
        ownerToken: String
    ) async -> VoiceInputLaunchStatus
}

@MainActor
protocol StoppableSessionAwareMicrophoneActivating: SessionAwareMicrophoneActivating {
    func stop(sessionID: String, commandToken: String) async
}

@MainActor
final class AppMicrophoneActivator: MicrophoneActivating, StoppableSessionAwareMicrophoneActivating {
    private let transcriptStoreProvider: @Sendable () -> SharedDictationTranscriptStore?
    private let sessionStoreProvider: @Sendable () -> SharedDictationSessionStore?
    private var activeRun: AppSpeechDictationRun?
    private var stopRequestedSessionIDs: Set<String> = []
    private var permissionGates: [String: AppPermissionRequestGate<Bool>] = [:]

    init(
        transcriptStoreProvider: @escaping @Sendable () -> SharedDictationTranscriptStore? = {
            SharedDictationTranscriptStore.appGroupStore()
        },
        sessionStoreProvider: @escaping @Sendable () -> SharedDictationSessionStore? = {
            SharedDictationSessionStore.appGroupStore()
        }
    ) {
        self.transcriptStoreProvider = transcriptStoreProvider
        self.sessionStoreProvider = sessionStoreProvider
    }

    func activate() async -> VoiceInputLaunchStatus {
        await activate(
            sessionID: UUID().uuidString,
            commandToken: UUID().uuidString,
            ownerToken: ""
        )
    }

    func activate(
        sessionID: String,
        commandToken: String,
        ownerToken: String
    ) async -> VoiceInputLaunchStatus {
        defer { stopRequestedSessionIDs.remove(sessionID) }
        guard await requestRecordPermission(for: sessionID) else {
            return .permissionDenied
        }
        guard !stopRequestedSessionIDs.contains(sessionID), !Task.isCancelled else {
            return .failed("Cancelled")
        }

        guard await requestSpeechRecognitionAuthorization(for: sessionID) else {
            return .failed("Enable speech recognition access in Settings to use keyboard voice input.")
        }
        guard !stopRequestedSessionIDs.contains(sessionID), !Task.isCancelled else {
            return .failed("Cancelled")
        }
        guard activeRun == nil else {
            return .failed("Voice input is already active.")
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

            let transcriptStoreProvider = transcriptStoreProvider
            let sessionStoreProvider = sessionStoreProvider
            let didSave = await Task.detached {
                if !ownerToken.isEmpty {
                    guard let sessionStore = sessionStoreProvider(),
                          sessionStore.hasActiveCommandClaim(
                              forCommandToken: commandToken,
                              ownerToken: ownerToken
                          ) else { return false }
                }
                guard let transcriptStore = transcriptStoreProvider() else { return false }
                return transcriptStore.save(transcript)
            }.value
            guard didSave else {
                return .failed("Shared App Group storage is busy; transcript was not saved.")
            }
            return .transcriptShared(transcript.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func stop(sessionID: String, commandToken: String) async {
        stopRequestedSessionIDs.insert(sessionID)
        permissionGates[sessionID]?.cancel()
        activeRun?.finishForUserStop()
    }

    private func requestRecordPermission(for sessionID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let gate = AppPermissionRequestGate(cancelledValue: false)
        permissionGates[sessionID] = gate
        defer {
            if permissionGates[sessionID] === gate {
                permissionGates.removeValue(forKey: sessionID)
            }
        }
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

    private func requestSpeechRecognitionAuthorization(for sessionID: String) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            guard !Task.isCancelled else { return false }
            let gate = AppPermissionRequestGate(cancelledValue: false)
            permissionGates[sessionID] = gate
            defer {
                if permissionGates[sessionID] === gate {
                    permissionGates.removeValue(forKey: sessionID)
                }
            }
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
