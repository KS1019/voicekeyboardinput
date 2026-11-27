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
            "Ready for Voice Input"
        case .requestingPermission:
            "Preparing Voice Input"
        case .microphoneActive:
            "Voice Input in Progress"
        case .transcriptShared:
            "Transcript Ready"
        case .permissionDenied:
            "Microphone Permission Denied"
        case .failed:
            "Voice Input Failed"
        }
    }

    var message: String {
        switch self {
        case .idle:
            "Start Voice Input to grant permissions and try recording in this app."
        case .sessionReady:
            "Ready to request voice input. Use Start Voice Input to record here."
        case .requestingPermission:
            "Allow microphone and Speech Recognition access if iOS asks."
        case .microphoneActive:
            "Voice input is in progress. Allow access if prompted. Tap Stop when you have finished speaking."
        case let .transcriptShared(transcript):
            "Transcript saved for the keyboard: \(transcript)"
        case .permissionDenied:
            "Enable microphone access in Settings to use keyboard voice input."
        case let .failed(message):
            message
        }
    }

    var isStoppable: Bool {
        switch self {
        case .microphoneActive, .requestingPermission:
            true
        case .idle, .sessionReady, .transcriptShared, .permissionDenied, .failed:
            false
        }
    }
}

@MainActor
@Observable
final class VoiceInputLaunchModel {
    private let sessionController: any DictationSessionControlling
    private var routeStartTask: Task<Void, Never>?
    private var sessionPreparationTask: Task<VoiceInputLaunchStatus, Never>?
    private var sessionPreparationGeneration: UInt64 = 0
    private var startInFlight = false
    private var stopInFlight = false
    private var startGeneration: UInt64 = 0

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
        guard !startInFlight, !stopInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        startGeneration &+= 1
        let generation = startGeneration

        let preparationStatus = await prepareSessionResult()
        guard case .sessionReady = preparationStatus else {
            status = preparationStatus
            return
        }
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        // Keep the control state truthful while the app-side audio session
        // and recognizer are still running. The final result arrives later;
        // users must be able to issue Stop during that interval.
        status = .microphoneActive(peakPower: nil)
        let result = await sessionController.startFromContainingApp()
        guard generation == startGeneration else { return }
        status = result
    }

    private func startDictation(forKeyboardSessionID sessionID: String) async {
        guard !startInFlight, !stopInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        startGeneration &+= 1
        let generation = startGeneration

        let preparationStatus = await prepareSessionResult()
        guard case .sessionReady = preparationStatus else {
            status = preparationStatus
            return
        }
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        status = .microphoneActive(peakPower: nil)
        let result = await sessionController.startFromKeyboardSession(sessionID: sessionID)
        guard generation == startGeneration else { return }
        status = result
    }

    func stopDictation() async {
        guard status.isStoppable, !stopInFlight else { return }
        stopInFlight = true
        defer { stopInFlight = false }
        // A late start continuation must not restore a terminal result after
        // Stop has already published the session-ready state.
        startGeneration &+= 1
        let generation = startGeneration
        await sessionController.cancelActiveSession()
        guard generation == startGeneration else { return }
        status = .sessionReady
    }

    func prepareSession() async {
        guard status == .idle else { return }
        let preparedStatus = await prepareSessionResult()
        // A URL/button start may have advanced the UI while preparation was
        // suspended. Do not let the older preparation completion roll the
        // state back to `.sessionReady`.
        guard status == .idle else { return }
        status = preparedStatus
    }

    private func prepareSessionResult() async -> VoiceInputLaunchStatus {
        if let sessionPreparationTask {
            return await sessionPreparationTask.value
        }
        let controller = sessionController
        sessionPreparationGeneration &+= 1
        let preparationGeneration = sessionPreparationGeneration
        let task = Task { @MainActor in
            await controller.prepareSession()
        }
        sessionPreparationTask = task
        let result = await task.value
        if sessionPreparationGeneration == preparationGeneration {
            sessionPreparationTask = nil
        }
        return result
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
    private var isStoppingMicrophoneActivation = false
    private var stoppingBarrierGeneration: UInt64 = 0
    private var activeStoppingBarrierGeneration: UInt64?
    private var stoppingBarrierCommandToken: String?
    private var startReservationToken: String?
    private var startIntentInFlight = false
    private var startCancellationGeneration: UInt64 = 0
    private var lastClaimedCommandToken: String?
    private var isAppAvailable = true

    private enum KeyboardCommandLookup {
        case found(SharedDictationSessionCommand)
        case none
        case unavailable
    }

    private enum ActiveStopTranscriptResolution {
        case recovered
        case absent
        case unavailable
    }

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
            _ = await transcriptStoreCall({ $0.storageHealth() })
            if heartbeatTask == nil,
               isAppAvailable || isMicrophoneActivationActive || isStoppingMicrophoneActivation {
                startHeartbeatTask()
            }
            if commandMonitorTask == nil,
               isAppAvailable || isMicrophoneActivationActive || isStoppingMicrophoneActivation {
                startCommandMonitor()
            }
            return .sessionReady
        }
        guard await transcriptStoreCall({ $0.storageHealth() }) == true,
              await sessionStoreCall({ $0.storageHealth() }) == true else {
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
            if isMicrophoneActivationActive || isStoppingMicrophoneActivation {
                // The containing app can become inactive while the keyboard
                // is visible. Keep the command monitor alive until an audio
                // stop barrier settles; otherwise a scene transition can
                // cancel the monitor after the activation task finishes and
                // leave the barrier latched for the rest of the process.
                startCommandMonitor()
            } else {
                commandMonitorGeneration &+= 1
                commandMonitorTask?.cancel()
                commandMonitorTask = nil
            }
            if !isMicrophoneActivationActive && !isStoppingMicrophoneActivation {
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
        guard !isMicrophoneActivationActive, !isStoppingMicrophoneActivation else {
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
        startCancellationGeneration &+= 1
        let startGeneration = startCancellationGeneration
        let command: SharedDictationSessionCommand
        let shouldPublishCommand: Bool
        switch await firstUnclaimedKeyboardCommand() {
        case .found(let pendingKeyboardCommand):
            // If the user opened the app manually after the keyboard wrote a
            // handoff command, keep the keyboard's session identity. This
            // preserves delivery even when the extension cannot open the app
            // directly on a given iOS release.
            command = pendingKeyboardCommand
            shouldPublishCommand = false
        case .none:
            command = SharedDictationSessionCommand.start(source: .containingApp)
            shouldPublishCommand = true
        case .unavailable:
            return .failed("Shared App Group storage is unavailable.")
        }
        guard isCurrentStart(startGeneration) else {
            await cancelUnclaimedStart(command, ownerToken: heartbeatToken)
            return .failed("Cancelled")
        }
        if shouldPublishCommand {
            guard await sessionStoreCall({ $0.saveCommand(command) }) == true else {
                return .failed("Shared App Group storage is busy. Please try again.")
            }
            guard isCurrentStart(startGeneration) else {
                await cancelUnclaimedStart(command, ownerToken: heartbeatToken)
                return .failed("Cancelled")
            }
        }
        let ownerToken = heartbeatToken
        guard let ownerToken,
              isCurrentStart(startGeneration) else {
            return .failed("Another app scene is already handling this voice input.")
        }
        startReservationToken = command.token
        activationGeneration &+= 1
        isMicrophoneActivationActive = true
        activeSessionID = command.sessionID
        activeCommandToken = command.token
        let didClaim = await sessionStoreCall({
                  $0.claimCommand(token: command.token, ownerToken: ownerToken)
              }) == true
        guard isCurrentStart(startGeneration) else {
            if didClaim {
                await cancelClaimedStart(command, ownerToken: ownerToken)
            }
            return .failed("Cancelled")
        }
        guard didClaim else {
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
        guard isCurrentStart(startGeneration) else {
            await cancelClaimedStart(command, ownerToken: ownerToken)
            return .failed("Cancelled")
        }
        guard await saveOwnedStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
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
        guard isCurrentStart(startGeneration) else {
            await cancelClaimedStart(command, ownerToken: ownerToken)
            return .failed("Cancelled")
        }
        guard await saveOwnedStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        )) else {
            _ = await saveOwnedStatus(.failed(
                token: command.token,
                message: "Shared App Group storage could not persist the recording state."
            ))
            isMicrophoneActivationActive = false
            startReservationToken = nil
            activeSessionID = nil
            activeCommandToken = nil
            heartbeatState = isAppAvailable ? .armed : .unavailable
            await persistHeartbeat()
            return .failed("Shared App Group storage is busy. Please try again.")
        }
        guard isCurrentStart(startGeneration) else {
            await cancelClaimedStart(command, ownerToken: ownerToken)
            return .failed("Cancelled")
        }
        heartbeatState = .recording
        await persistHeartbeat()
        guard isCurrentStart(startGeneration) else {
            await cancelClaimedStart(command, ownerToken: ownerToken)
            return .failed("Cancelled")
        }

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
        guard !isMicrophoneActivationActive,
              !isStoppingMicrophoneActivation,
              !startIntentInFlight else {
            return .failed("Voice input is already in progress.")
        }
        startIntentInFlight = true
        defer { startIntentInFlight = false }
        startCancellationGeneration &+= 1
        let startGeneration = startCancellationGeneration
        if heartbeatToken == nil {
            _ = await prepareSession()
        }
        guard isCurrentStart(startGeneration), heartbeatToken != nil else {
            return .failed("Voice input session is still preparing. Please try again.")
        }
        // A cold URL launch can arrive before SwiftUI's root .task has
        // prepared the heartbeat and command monitor. Prepare synchronously
        // here, then claim the exact keyboard-owned command from the URL.
        if commandMonitorTask == nil {
            _ = await prepareSession()
        }
        guard isCurrentStart(startGeneration) else { return .failed("Cancelled") }
        guard let historyResolution = await sessionStoreCall({ $0.commandHistoryResolution() }),
              isCurrentStart(startGeneration) else {
            return .failed("Shared App Group storage is unavailable.")
        }
        guard case .available(let commands) = historyResolution else {
            return .failed("Shared App Group storage is unavailable.")
        }
        guard let command = commands.reversed().first(where: {
            $0.kind == .start
                && $0.source == .keyboard
                && $0.sessionID == sessionID
                && !$0.isExpired()
        }) else {
            return .failed("The keyboard dictation request is no longer available.")
        }
        guard isCurrentStart(startGeneration) else {
            await cancelUnclaimedStart(command, ownerToken: heartbeatToken)
            return .failed("Cancelled")
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
        let didClaim = await sessionStoreCall({
                  $0.claimCommand(token: command.token, ownerToken: ownerToken)
              }) == true
        guard isCurrentStart(startGeneration) else {
            if didClaim {
                await cancelClaimedStart(command, ownerToken: ownerToken)
            }
            return .failed("Cancelled")
        }
        guard didClaim else {
            startReservationToken = nil
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            return .failed("Another app scene is already handling this voice input.")
        }
        lastClaimedCommandToken = command.token
        await startDictation(for: command, startGeneration: startGeneration)
        startIntentInFlight = false
        guard isCurrentStart(startGeneration) else { return .failed("Cancelled") }
        guard let activationTask = activeStartTask else {
            return .failed("Voice input could not be started.")
        }
        return await activationTask.value
    }

    func cancelActiveSession() async {
        startCancellationGeneration &+= 1
        commandMonitorGeneration &+= 1
        commandMonitorTask?.cancel()
        commandMonitorTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let activationTask = activeStartTask
        activeStartTask = nil
        let sessionID = activeSessionID
        let commandToken = activeCommandToken
        if let stoppableActivator = microphoneActivator as? any StoppableSessionAwareMicrophoneActivating,
           let sessionID,
           let commandToken {
            // A user Stop is a finalize request, not a recognition abort.
            // The concrete activator lets the active run publish its last
            // Speech result before the task is released.
            await stoppableActivator.stop(
                sessionID: sessionID,
                commandToken: commandToken
            )
        } else {
            activationTask?.cancel()
        }
        let stoppingBarrier = activationTask.map { _ in
            beginStoppingBarrier(for: activeCommandToken)
        }
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
        if let stoppingBarrier {
            releaseStoppingBarrier(stoppingBarrier)
        }
        if isAppAvailable {
            heartbeatState = .armed
            writeHeartbeat()
            startHeartbeatTask()
            startCommandMonitor()
        }
    }

    private func makeStopClaimRenewalTask(
        commandToken: String,
        ownerToken: String
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let renewed = await self.sessionStoreCall {
                    $0.renewCommandClaim(token: commandToken, ownerToken: ownerToken)
                } ?? false
                if renewed {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    // A short App Group/file-lock failure is recoverable. A
                    // sustained false result means ownership was lost; stop
                    // renewing rather than masking an owner mismatch forever.
                    guard consecutiveFailures < 8 else { return }
                }
            }
        }
    }

    private func startCommandMonitor() {
        guard (isAppAvailable || isMicrophoneActivationActive || isStoppingMicrophoneActivation),
              commandMonitorTask == nil else { return }
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
                guard self.isAppAvailable
                    || self.isMicrophoneActivationActive
                    || self.isStoppingMicrophoneActivation else { return }
                await self.consumeCommandIfNeeded(monitorGeneration: generation)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func consumeCommandIfNeeded(monitorGeneration: UInt64) async {
        guard isCurrentCommandMonitor(monitorGeneration) else { return }
        guard await recoverCompletedTranscriptIfPresent() else { return }
        guard isCurrentCommandMonitor(monitorGeneration) else { return }
        guard startReservationToken == nil,
              !isStoppingMicrophoneActivation,
              !startIntentInFlight else { return }
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
        guard isCurrentCommandMonitor(monitorGeneration) else {
            // Do not release a stale claim here. The same heartbeat owner can
            // reclaim this token after the lease expires, creating an ABA
            // window where an old monitor releases the new monitor's claim.
            return
        }
        lastClaimedCommandToken = command.token
        guard command.source == .keyboard else { return }

        switch command.kind {
        case .start:
            guard !isMicrophoneActivationActive,
                  !isStoppingMicrophoneActivation,
                  !startIntentInFlight,
                  startReservationToken == nil else {
                if startReservationToken != command.token,
                   activeCommandToken != command.token {
                    guard isCurrentCommandMonitor(monitorGeneration) else { return }
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
            guard isCurrentCommandMonitor(monitorGeneration) else {
                return
            }
            let startGeneration = startCancellationGeneration
            await startDictation(
                for: command,
                startGeneration: startGeneration
            )
        case .stop:
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            guard let ownerToken = heartbeatToken else { return }
            guard activeSessionID == command.sessionID else {
                if let replacedToken = command.replacesCommandToken,
                   let owner = await sessionStoreCall({ $0.claimOwner(forCommandToken: replacedToken) }) ?? nil,
                   owner != ownerToken {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                if activeSessionID != nil {
                    if let replacedToken = command.replacesCommandToken {
                        _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                        guard isCurrentCommandMonitor(monitorGeneration) else {
                            await abandonStaleCommandClaim(
                                command,
                                ownerToken: ownerToken,
                                cursor: cursorBeforeClaim,
                                monitorGeneration: monitorGeneration
                            )
                            return
                        }
                    }
                    _ = await saveOwnedStatus(.failed(
                        token: command.token,
                        message: "Voice input is already active in another session."
                    ))
                    guard isCurrentCommandMonitor(monitorGeneration) else {
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    }
                    return
                }
                // A stop can arrive while the containing app has not yet
                // claimed the pending start. Complete the mailbox state so
                // the keyboard's stop monitor does not wait on the replaced
                // start token until its deadline.
                if let replacedToken = command.replacesCommandToken {
                    guard let transcriptResolution = await transcriptStoreCall({
                        $0.latestTranscriptResolution(forSessionID: command.sessionID)
                    }) else {
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    }
                    guard isCurrentCommandMonitor(monitorGeneration) else {
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    }
                    switch transcriptResolution {
                    case .unavailable:
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    case .found(let transcript)
                        where transcript.commandToken == replacedToken
                            && !transcript.isConsumed
                            && !transcript.isExpired():
                        // A cold restart may have completed and persisted the
                        // transcript before the stop was observed. Do not cancel
                        // a result that the keyboard can still deliver.
                        guard await sessionStoreCall({
                            $0.recoverCompletedTranscriptStatus(
                                sourceCommandToken: replacedToken,
                                throughCommandToken: command.token,
                                ownerToken: ownerToken
                            )
                        }) == true else {
                            await abandonStaleCommandClaim(
                                command,
                                ownerToken: ownerToken,
                                cursor: cursorBeforeClaim,
                                monitorGeneration: monitorGeneration
                            )
                            return
                        }
                        guard isCurrentCommandMonitor(monitorGeneration) else {
                            await abandonStaleCommandClaim(
                                command,
                                ownerToken: ownerToken,
                                cursor: cursorBeforeClaim,
                                monitorGeneration: monitorGeneration
                            )
                            return
                        }
                    case .found, .missing:
                        _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                        guard isCurrentCommandMonitor(monitorGeneration) else {
                            await abandonStaleCommandClaim(
                                command,
                                ownerToken: ownerToken,
                                cursor: cursorBeforeClaim,
                                monitorGeneration: monitorGeneration
                            )
                            return
                        }
                    }
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                return
            }
            let activationTask = activeStartTask
            _ = await sessionStoreCall {
                $0.renewCommandClaim(token: command.token, ownerToken: ownerToken)
            }
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            let stopClaimRenewalTask = makeStopClaimRenewalTask(
                commandToken: command.token,
                ownerToken: ownerToken
            )
            defer { stopClaimRenewalTask.cancel() }
            _ = await saveOwnedStatus(.commandAcknowledged(
                token: command.token,
                acknowledgedAt: Date()
            ))
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            if let stoppableActivator = microphoneActivator as? any StoppableSessionAwareMicrophoneActivating {
                let stoppingBarrier = beginStoppingBarrier(for: command.token)
                await stoppableActivator.stop(
                    sessionID: command.sessionID,
                    commandToken: activeCommandToken ?? ""
                )
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                if let activationTask {
                    _ = await activationTask.value
                }
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                releaseStoppingBarrier(stoppingBarrier)
                if let replacedToken = command.replacesCommandToken {
                    switch await resolveActiveStopTranscript(
                        sessionID: command.sessionID,
                        sourceCommandToken: replacedToken,
                        stopCommandToken: command.token,
                        ownerToken: ownerToken
                    ) {
                    case .recovered:
                        break
                    case .absent:
                        _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                    case .unavailable:
                        // The audio run has stopped, but the transcript and
                        // command stores did not provide a safe answer. Keep
                        // the source non-terminal so cold recovery can still
                        // promote a transcript that was committed in the
                        // cross-store race window.
                        heartbeatState = isAppAvailable ? .armed : .unavailable
                        await persistHeartbeat()
                        guard isCurrentCommandMonitor(monitorGeneration) else {
                            await abandonStaleCommandClaim(
                                command,
                                ownerToken: ownerToken,
                                cursor: cursorBeforeClaim,
                                monitorGeneration: monitorGeneration
                            )
                            return
                        }
                        return
                    }
                    guard isCurrentCommandMonitor(monitorGeneration) else {
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    }
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
            } else {
                activeStartTask = nil
                activationTask?.cancel()
                isMicrophoneActivationActive = false
                activeSessionID = nil
                activeCommandToken = nil
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                if let activationTask {
                    _ = await activationTask.value
                }
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
            }
        case .cancel:
            guard activeSessionID == command.sessionID else {
                let ownerToken = heartbeatToken
                if let replacedToken = command.replacesCommandToken,
                   let owner = await sessionStoreCall({ $0.claimOwner(forCommandToken: replacedToken) }) ?? nil,
                   owner != ownerToken {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                guard isCurrentCommandMonitor(monitorGeneration) else { return }
                if let replacedToken = command.replacesCommandToken {
                    _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                    guard isCurrentCommandMonitor(monitorGeneration) else {
                        await abandonStaleCommandClaim(
                            command,
                            ownerToken: ownerToken,
                            cursor: cursorBeforeClaim,
                            monitorGeneration: monitorGeneration
                        )
                        return
                    }
                }
                _ = await saveOwnedStatus(.cancelled(token: command.token))
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                heartbeatState = isAppAvailable ? .armed : .unavailable
                await persistHeartbeat()
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
                return
            }
            let activationTask = activeStartTask
            activeStartTask = nil
            activationTask?.cancel()
            let stoppingBarrier = beginStoppingBarrier(for: command.token)
            isMicrophoneActivationActive = false
            activeSessionID = nil
            activeCommandToken = nil
            startReservationToken = nil
            if let replacedToken = command.replacesCommandToken {
                _ = await saveOwnedStatus(.cancelled(token: replacedToken))
                guard isCurrentCommandMonitor(monitorGeneration) else {
                    await abandonStaleCommandClaim(
                        command,
                        ownerToken: ownerToken,
                        cursor: cursorBeforeClaim,
                        monitorGeneration: monitorGeneration
                    )
                    return
                }
            }
            _ = await saveOwnedStatus(.cancelled(token: command.token))
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            heartbeatState = isAppAvailable ? .armed : .unavailable
            await persistHeartbeat()
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            if let activationTask { _ = await activationTask.value }
            guard isCurrentCommandMonitor(monitorGeneration) else {
                await abandonStaleCommandClaim(
                    command,
                    ownerToken: ownerToken,
                    cursor: cursorBeforeClaim,
                    monitorGeneration: monitorGeneration
                )
                return
            }
            releaseStoppingBarrier(stoppingBarrier)
        }
    }

    private func resolveActiveStopTranscript(
        sessionID: String,
        sourceCommandToken: String,
        stopCommandToken: String,
        ownerToken: String
    ) async -> ActiveStopTranscriptResolution {
        guard let resolution = await transcriptStoreCall({
            $0.latestTranscriptResolution(forSessionID: sessionID)
        }) else {
            return .unavailable
        }
        switch resolution {
        case .unavailable:
            return .unavailable
        case .missing:
            return .absent
        case .found(let transcript):
            guard transcript.commandToken == sourceCommandToken,
                  !transcript.isConsumed,
                  !transcript.isExpired() else {
                return .absent
            }
            guard await sessionStoreCall({
                $0.recoverCompletedTranscriptStatus(
                    sourceCommandToken: sourceCommandToken,
                    throughCommandToken: stopCommandToken,
                    ownerToken: ownerToken
                )
            }) == true else {
                return .unavailable
            }
            return .recovered
        }
    }

    private func firstUnclaimedKeyboardCommand() async -> KeyboardCommandLookup {
        guard let historyResolution = await sessionStoreCall({ $0.commandHistoryResolution() }),
              case .available(let commands) = historyResolution else { return .unavailable }
        for command in commands.reversed().filter({
            $0.kind == .start
                && $0.source == .keyboard
                && !$0.isExpired(at: Date())
        }) {
            guard let statusResolution = await sessionStoreCall({
                $0.statusResolution(forCommandToken: command.token)
            }) else { return .unavailable }
            let status: SharedDictationSessionStatus
            switch statusResolution {
            case .unavailable:
                return .unavailable
            case .missing:
                status = .idle
            case .found(let resolvedStatus):
                status = resolvedStatus
            }
            guard case .idle = status else { continue }
            guard let transcriptResolution = await transcriptStoreCall({
                $0.latestTranscriptResolution(forSessionID: command.sessionID)
            }) else { return .unavailable }
            switch transcriptResolution {
            case .missing:
                return .found(command)
            case .found:
                continue
            case .unavailable:
                return .unavailable
            }
        }
        return .none
    }

    private func startDictation(
        for command: SharedDictationSessionCommand,
        startGeneration: UInt64? = nil
    ) async {
        if let startGeneration,
           !isCurrentStart(startGeneration) {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }
        guard !isStoppingMicrophoneActivation,
              (!isMicrophoneActivationActive || startReservationToken == command.token) else {
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
        if let startGeneration,
           !isCurrentStart(startGeneration) {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }
        guard await saveOwnedStatus(.commandAcknowledged(
            token: command.token,
            acknowledgedAt: startedAt
        )) else {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }
        if let startGeneration,
           !isCurrentStart(startGeneration) {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }
        guard await saveOwnedStatus(.recording(
            token: command.token,
            startedAt: startedAt,
            timeoutSeconds: 8
        )) else {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            activeSessionID = nil
            activeCommandToken = nil
            isMicrophoneActivationActive = false
            return
        }
        if let startGeneration,
           !isCurrentStart(startGeneration) {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }
        heartbeatState = .recording
        await persistHeartbeat()
        if let startGeneration,
           !isCurrentStart(startGeneration) {
            await cancelClaimedStart(command, ownerToken: heartbeatToken)
            return
        }

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

    private func isCurrentStart(_ generation: UInt64) -> Bool {
        generation == startCancellationGeneration && !Task.isCancelled
    }

    private func isCurrentCommandMonitor(_ generation: UInt64) -> Bool {
        generation == commandMonitorGeneration && !Task.isCancelled
    }

    private func beginStoppingBarrier(for commandToken: String?) -> UInt64 {
        stoppingBarrierGeneration &+= 1
        let barrierGeneration = stoppingBarrierGeneration
        activeStoppingBarrierGeneration = barrierGeneration
        stoppingBarrierCommandToken = commandToken
        isStoppingMicrophoneActivation = true
        return barrierGeneration
    }

    private func releaseStoppingBarrier(_ barrierGeneration: UInt64) {
        guard activeStoppingBarrierGeneration == barrierGeneration else { return }
        activeStoppingBarrierGeneration = nil
        stoppingBarrierCommandToken = nil
        isStoppingMicrophoneActivation = false
    }

    private func releaseStoppingBarrierOwned(by commandToken: String) {
        guard stoppingBarrierCommandToken == commandToken,
              let barrierGeneration = activeStoppingBarrierGeneration else {
            return
        }
        releaseStoppingBarrier(barrierGeneration)
    }

    private func abandonStaleCommandClaim(
        _ command: SharedDictationSessionCommand,
        ownerToken: String?,
        cursor: String?,
        monitorGeneration: UInt64
    ) async {
        guard isCurrentCommandMonitor(monitorGeneration) else {
            // A cancelled monitor must not release a claim or restore shared
            // cursor/barrier state. Its lease will expire safely; releasing
            // by heartbeat owner alone is vulnerable to an ABA race with a
            // replacement monitor.
            return
        }
        _ = await sessionStoreCall {
            $0.releaseCommandClaim(token: command.token, ownerToken: ownerToken)
        }
        guard isCurrentCommandMonitor(monitorGeneration) else { return }
        lastClaimedCommandToken = cursor
        releaseStoppingBarrierOwned(by: command.token)
    }

    private func cancelClaimedStart(
        _ command: SharedDictationSessionCommand,
        ownerToken: String?
    ) async {
        if let ownerToken {
            _ = await sessionStoreCall {
                $0.saveStatus(.cancelled(token: command.token), ownerToken: ownerToken)
            }
        }
        guard activeCommandToken == command.token else { return }
        activeStartTask = nil
        activeSessionID = nil
        activeCommandToken = nil
        isMicrophoneActivationActive = false
        startReservationToken = nil
        heartbeatState = isAppAvailable ? .armed : .unavailable
    }

    private func cancelUnclaimedStart(
        _ command: SharedDictationSessionCommand,
        ownerToken: String?
    ) async {
        guard let ownerToken,
              await sessionStoreCall({
                  $0.claimCommand(token: command.token, ownerToken: ownerToken)
              }) == true else {
            return
        }
        _ = await sessionStoreCall {
            $0.saveStatus(.cancelled(token: command.token), ownerToken: ownerToken)
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
            var transcriptCleanupTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self,
                      self.isAppAvailable
                        || self.isMicrophoneActivationActive
                        || self.isStoppingMicrophoneActivation else { return }
                self.writeHeartbeat()
                transcriptCleanupTicks += 1
                if transcriptCleanupTicks >= 60 {
                    transcriptCleanupTicks = 0
                    _ = await self.transcriptStoreCall({ $0.storageHealth() })
                }
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
        let stoppingBarrier = beginStoppingBarrier(for: activeCommandToken)
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
        releaseStoppingBarrier(stoppingBarrier)
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
        guard let transcriptResolution = await transcriptStoreCall({
            $0.unconsumedTranscriptsResolution()
        }), case .available(let transcripts) = transcriptResolution else {
            return false
        }
        let completedCommandTokens = Set(transcripts.map(\.commandToken))
        for command in commands.filter({
            $0.source == .keyboard
                && $0.kind == .start
                && !completedCommandTokens.contains($0.token)
        }) {
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
        guard let transcriptResolution = await transcriptStoreCall({
            $0.unconsumedTranscriptsResolution()
        }) else {
            // SessionStore alone cannot prove that a completed transcript is
            // absent. Refuse stale-session cancellation until both durable
            // stores are readable; otherwise a cold-started app can turn a
            // completed handoff into a permanent cancelled status.
            return false
        }
        guard case .available(let transcripts) = transcriptResolution else {
            return false
        }
        for transcript in transcripts {
            guard let command = commandsByToken[transcript.commandToken],
                  command.kind == .start,
                  command.sessionID == transcript.sessionID else {
                continue
            }
            guard await sessionStoreCall({ $0.storageHealth() }) == true else {
                return false
            }
            guard let statusResolution = await sessionStoreCall({
                $0.statusResolution(forCommandToken: transcript.commandToken)
            }) else {
                return false
            }
            let status: SharedDictationSessionStatus
            switch statusResolution {
            case .unavailable:
                return false
            case .missing:
                status = .idle
            case .found(let resolvedStatus):
                status = resolvedStatus
            }
            switch status {
            case .failed:
                // A failed delivery is a durable no-replay fence. Only an
                // explicit, owner-authorized Stop recovery may promote a
                // transcript; cold startup must never do so implicitly.
                continue
            case .commandAcknowledged, .recording, .transcribing,
                 .idle, .commandPending, .cancelled:
                // The transcript is the durable completion marker. Promote
                // it even when status publication was interrupted or a newer
                // scene became the latest command.
                guard await sessionStoreCall({
                    $0.saveStatus(
                        .transcriptReady(token: transcript.commandToken),
                        allowRecoveryFromTranscriptReady: true
                    )
                    }) == true else {
                        let replacement = commands.reversed().first {
                            guard $0.kind == .stop || $0.kind == .cancel else { return false }
                            if $0.replacesCommandToken == transcript.commandToken { return true }
                            return $0.replacesCommandToken == nil
                                && $0.sessionID == command.sessionID
                        }
                    if let replacement,
                       replacement.kind == .stop,
                       replacement.isExpired(at: Date()),
                       await sessionStoreCall({
                           $0.recoverCompletedTranscriptAfterExpiredStop(
                               sourceCommandToken: transcript.commandToken,
                               throughCommandToken: replacement.token
                           )
                       }) == true {
                        // The completed transcript is the durable result. An
                        // expired Stop may recover it only when no live claim
                        // remains; Cancel never uses this fallback.
                        continue
                    }
                    if let replacement,
                       let ownerToken = heartbeatToken,
                       await sessionStoreCall({
                           $0.claimOwner(forCommandToken: replacement.token)
                       }) == ownerToken,
                       await sessionStoreCall({
                           $0.recoverCompletedTranscriptStatus(
                               sourceCommandToken: transcript.commandToken,
                               throughCommandToken: replacement.token,
                               ownerToken: ownerToken
                           )
                       }) == true {
                        // The replacement owns the recovery claim. Mark only
                        // that replacement terminal; the source remains
                        // transcriptReady and therefore deliverable.
                        _ = await sessionStoreCall {
                            $0.saveStatus(
                                .cancelled(token: replacement.token),
                                ownerToken: ownerToken
                            )
                        }
                        continue
                    }
                    if replacement != nil { continue }
                    return false
                }
            case .transcriptReady:
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
    private struct RequestKey: Hashable {
        let sessionID: String
        let commandToken: String
    }

    private final class ActiveRunLease {
        let sessionID: String
        let commandToken: String
        let run: AppSpeechDictationRun

        init(sessionID: String, commandToken: String, run: AppSpeechDictationRun) {
            self.sessionID = sessionID
            self.commandToken = commandToken
            self.run = run
        }
    }

    private let transcriptStoreProvider: @Sendable () -> SharedDictationTranscriptStore?
    private let sessionStoreProvider: @Sendable () -> SharedDictationSessionStore?
    private var activeRun: ActiveRunLease?
    private var stopRequestedRequests: Set<RequestKey> = []
    private var permissionGates: [RequestKey: AppPermissionRequestGate<Bool>] = [:]

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
        let requestKey = RequestKey(sessionID: sessionID, commandToken: commandToken)
        defer { stopRequestedRequests.remove(requestKey) }
        guard await requestRecordPermission(for: requestKey) else {
            return .permissionDenied
        }
        guard !stopRequestedRequests.contains(requestKey), !Task.isCancelled else {
            return .failed("Cancelled")
        }

        guard await requestSpeechRecognitionAuthorization(for: requestKey) else {
            return .failed("Enable speech recognition access in Settings to use keyboard voice input.")
        }
        guard !stopRequestedRequests.contains(requestKey), !Task.isCancelled else {
            return .failed("Cancelled")
        }
        guard activeRun == nil else {
            return .failed("Voice input is already active.")
        }

        let run = AppSpeechDictationRun(locale: Locale.current)
        activeRun = ActiveRunLease(
            sessionID: sessionID,
            commandToken: commandToken,
            run: run
        )

        do {
            let transcriptText = try await run.start()
            retainRunUntilAudioOwnershipRelease(run)
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
            retainRunUntilAudioOwnershipRelease(run)
            return .failed(error.localizedDescription)
        }
    }

    func stop(sessionID: String, commandToken: String) async {
        let requestKey = RequestKey(sessionID: sessionID, commandToken: commandToken)
        stopRequestedRequests.insert(requestKey)
        permissionGates[requestKey]?.cancel()
        guard let activeRun,
              activeRun.sessionID == sessionID,
              activeRun.commandToken == commandToken else { return }
        activeRun.run.finishForUserStop()
    }

    private func retainRunUntilAudioOwnershipRelease(_ run: AppSpeechDictationRun) {
        Task { @MainActor [weak self, run] in
            await run.waitForAudioOwnershipRelease()
            guard let self,
                  self.activeRun?.run === run else { return }
            self.activeRun = nil
        }
    }

    private func requestRecordPermission(for requestKey: RequestKey) async -> Bool {
        guard !Task.isCancelled else { return false }
        let gate = AppPermissionRequestGate(cancelledValue: false)
        permissionGates[requestKey] = gate
        defer {
            if permissionGates[requestKey] === gate {
                permissionGates.removeValue(forKey: requestKey)
            }
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.install(continuation)
                guard !Task.isCancelled else {
                    gate.cancel()
                    return
                }
                AVAudioApplication.requestRecordPermission { @Sendable isGranted in
                    gate.finish(isGranted)
                }
            }
        }, onCancel: {
            gate.cancel()
        })
    }

    private func requestSpeechRecognitionAuthorization(for requestKey: RequestKey) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            guard !Task.isCancelled else { return false }
            let gate = AppPermissionRequestGate(cancelledValue: false)
            permissionGates[requestKey] = gate
            defer {
                if permissionGates[requestKey] === gate {
                    permissionGates.removeValue(forKey: requestKey)
                }
            }
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    gate.install(continuation)
                    guard !Task.isCancelled else {
                        gate.cancel()
                        return
                    }
                    // TCC invokes this legacy callback off-main. Explicit
                    // Sendable prevents inheriting this method's MainActor.
                    SFSpeechRecognizer.requestAuthorization { @Sendable status in
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
