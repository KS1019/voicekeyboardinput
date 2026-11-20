import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation
import VoiceKeyboardSharedStorage

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private struct PendingDocumentMutation: Equatable {
        enum Kind: Equatable {
            case delete
            case returnKey
        }

        let kind: Kind
        let expectedContext: SharedDictationDocumentContextFingerprint
        let expectedMutationGeneration: UInt64
        let expectedEpoch: UInt64

        init(
            kind: Kind,
            expectedContext: SharedDictationDocumentContextFingerprint,
            expectedMutationGeneration: UInt64,
            expectedEpoch: UInt64
        ) {
            self.kind = kind
            self.expectedContext = expectedContext
            self.expectedMutationGeneration = expectedMutationGeneration
            self.expectedEpoch = expectedEpoch
        }
    }

    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private let sharedDeliveryOwnerID = UUID().uuidString
    private let sharedTranscriptStoreProvider: @Sendable () -> SharedDictationTranscriptStore? = {
        SharedDictationTranscriptStore.appGroupStore()
    }
    private let sharedSessionStoreProvider: @Sendable () -> SharedDictationSessionStore? = {
        SharedDictationSessionStore.appGroupStore()
    }
    private var recognitionTask: Task<Void, Never>?
    private var sharedDictationPollingTask: Task<Void, Never>?
    private var sharedDeliveryTask: Task<Void, Never>?
    private var microphoneDecisionTask: Task<Void, Never>?
    private var isRecognitionActive = false
    private var allowsDirectStartupFallback = false
    private var isMicrophoneDecisionInFlight = false
    private var isViewVisible = false
    private var lifecycleEpoch: UInt64 = 0
    private var sharedPollingGeneration: UInt64 = 0
    private var activeSharedSessionID: String?
    private var activeSharedCommandToken: String?
    private var activeSharedTranscriptToken: String?
    private var sharedSessionDocumentContext: String?
    private var sharedSessionDocumentContextAfterInput: String?
    private var sharedSessionDocumentIdentifier: UUID?
    private var sharedSessionSelectedText: String?
    private var sharedSessionDeliveryFingerprint: SharedDictationDocumentContextFingerprint?
    private var recognitionExpectedDocumentContext: String?
    private var recognitionExpectedDocumentContextAfterInput: String?
    private var recognitionExpectedDocumentIdentifier: UUID?
    private var recognitionExpectedSelectedText: String?
    private var documentMutationGeneration: UInt64 = 0
    private var recognitionExpectedDocumentMutationGeneration: UInt64 = 0
    private var recognitionGeneration: UInt64 = 0
    private var sharedSessionDocumentMutationGeneration: UInt64?
    private var isApplyingProxyMutation = false
    private var expectedSelfMutationContext: SharedDictationDocumentContextFingerprint?
    private var expectedSelfMutationCallbacksRemaining = 0
    private var expectedSelfMutationCallbacksDeadline: Date?
    private var isOpeningContainingApp = false
    private var isSharedDeliveryRecoveryInProgress = false
    private var isSharedStorageResolutionUnknown = false
    private var sharedDeliveryRecoveryGeneration: UInt64 = 0
    private var sharedDeliveryRecoveryRetryGeneration: UInt64 = 0
    private var sharedDeliveryRecoveryRetryTask: Task<Void, Never>?
    // Only an unexpected local disappearance creates a lifecycle gap. A
    // newly-created controller can still safely recover an intentional
    // containing-app handoff because the command's durable document
    // fingerprint is checked before insertion.
    private var hasSharedDeliveryLifecycleGap = true
    private var lifecycleGapSessionID: String?
    private var lifecycleGapTranscriptToken: String?
    private var blockedLifecycleTranscriptTokens: Set<String> = []
    private static let maximumBlockedLifecycleTranscriptTokens = 32
    private var sharedCancellationTask: Task<Void, Never>?
    private var isSharedCancellationInProgress = false
    private var queuedDocumentMutations: [PendingDocumentMutation] = []
    private static let maximumQueuedDocumentMutations = 32
    private var sharedCancellationRetryTask: Task<Void, Never>?
    private var sharedCancellationRetryGeneration: UInt64 = 0
    private var sharedCancellationRecoveryWaitTask: Task<Void, Never>?
    private var sharedCancellationOperationGeneration: UInt64 = 0

    private func transcriptStoreCall<Result: Sendable>(
        _ operation: @escaping @Sendable (SharedDictationTranscriptStore) -> Result
    ) async -> Result? {
        let provider = sharedTranscriptStoreProvider
        return await Task.detached {
            guard let store = provider() else { return nil }
            return operation(store)
        }.value
    }

    private func sessionStoreCall<Result: Sendable>(
        _ operation: @escaping @Sendable (SharedDictationSessionStore) -> Result
    ) async -> Result? {
        let provider = sharedSessionStoreProvider
        return await Task.detached {
            guard let store = provider() else { return nil }
            return operation(store)
        }.value
    }

    private func persistKeyboardLifecycleBlock(for transcriptToken: String) {
        let provider = sharedSessionStoreProvider
        Task.detached {
            guard let store = provider() else { return }
            _ = store.blockKeyboardTranscript(token: transcriptToken)
        }
    }

    private func saveSharedCommandWithRetry(
        _ command: SharedDictationSessionCommand,
        attempts: Int = 3
    ) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            if await sessionStoreCall({ $0.saveCommand(command) }) == true {
                return true
            }
            if attempt + 1 < max(1, attempts) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return false
    }

    private func scheduleSharedCancellationRetry(
        _ command: SharedDictationSessionCommand,
        onSuccess: @escaping @MainActor () -> Void = {},
        onExhausted: @escaping @MainActor () -> Void = {}
    ) {
        sharedCancellationRetryTask?.cancel()
        sharedCancellationRetryGeneration &+= 1
        let retryGeneration = sharedCancellationRetryGeneration
        sharedCancellationRetryTask = Task { [weak self] in
            for _ in 0..<120 {
                guard let self,
                      self.sharedCancellationRetryGeneration == retryGeneration,
                      !Task.isCancelled else { return }
                if await self.sessionStoreCall({ $0.saveCommand(command) }) == true {
                    guard !Task.isCancelled,
                          self.sharedCancellationRetryGeneration == retryGeneration else { return }
                    self.sharedCancellationRetryTask = nil
                    onSuccess()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.sharedCancellationRetryGeneration == retryGeneration else { return }
            self.sharedCancellationRetryTask = nil
            onExhausted()
        }
    }

    private func scheduleSharedCancellationResolutionRetry(epoch: UInt64) {
        guard isViewVisible,
              lifecycleEpoch == epoch,
              sharedCancellationRetryTask == nil else { return }
        sharedCancellationRetryGeneration &+= 1
        let retryGeneration = sharedCancellationRetryGeneration
        sharedCancellationRetryTask = Task { [weak self] in
            defer {
                if let self,
                   self.sharedCancellationRetryGeneration == retryGeneration {
                    self.sharedCancellationRetryTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.sharedCancellationRetryGeneration == retryGeneration,
                      self.isViewVisible,
                      self.lifecycleEpoch == epoch,
                      self.isSharedStorageResolutionUnknown,
                      !self.isSharedCancellationInProgress else { return }
                guard let mutation = self.queuedDocumentMutations.first else { return }
                self.queuedDocumentMutations.removeFirst()
                self.cancelSharedDictationForLifecycleChange(then: mutation)
                return
            }
        }
    }

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWillResignActive),
            name: .NSExtensionHostWillResignActive,
            object: nil
        )
        renderCurrentSpeechCapture()
    }

    isolated deinit {
        speechCaptureCoordinator.cancelRecognition()
        recognitionTask?.cancel()
        sharedDictationPollingTask?.cancel()
        sharedDeliveryTask?.cancel()
        microphoneDecisionTask?.cancel()
        sharedCancellationTask?.cancel()
        sharedCancellationRetryTask?.cancel()
        sharedCancellationRecoveryWaitTask?.cancel()
        sharedDeliveryRecoveryRetryTask?.cancel()
    }

    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        microphoneDecisionTask?.cancel()
        microphoneDecisionTask = nil
        isMicrophoneDecisionInFlight = false
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        sharedDeliveryTask?.cancel()
        sharedDeliveryTask = nil
        sharedPollingGeneration &+= 1
        sharedDeliveryRecoveryGeneration &+= 1
        isSharedDeliveryRecoveryInProgress = false
        // A memory warning must not cancel the containing-app handoff. Its
        // transcript may already be persisted and waiting for this keyboard
        // instance; cancelling the shared session here could orphan it.
        cancelDirectRecognition()
        guard isViewVisible else { return }
        let epoch = lifecycleEpoch
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.isViewVisible,
                  self.lifecycleEpoch == epoch else { return }
            self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewVisible = true
        isOpeningContainingApp = false
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if hasFullAccess {
            speechCaptureCoordinator.preload(in: view)
        }
    }

    private func startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: UInt64) {
        if isSharedStorageResolutionUnknown, !queuedDocumentMutations.isEmpty {
            scheduleSharedCancellationResolutionRetry(epoch: epoch)
            return
        }
        guard isSharedCancellationInProgress,
              let cancellationTask = sharedCancellationTask else {
            startSharedDeliveryRecovery(epoch: epoch)
            return
        }
        sharedCancellationRecoveryWaitTask?.cancel()
        sharedCancellationRecoveryWaitTask = Task { [weak self] in
            await cancellationTask.value
            guard let self,
                  !Task.isCancelled,
                  self.isViewVisible,
                  self.lifecycleEpoch == epoch,
                  !self.isSharedCancellationInProgress else { return }
            self.sharedCancellationRecoveryWaitTask = nil
            self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
        }
    }

    private func startSharedDeliveryRecovery(epoch: UInt64) {
        guard !(isSharedStorageResolutionUnknown && !queuedDocumentMutations.isEmpty) else {
            scheduleSharedCancellationResolutionRetry(epoch: epoch)
            return
        }
        sharedDeliveryRecoveryRetryTask?.cancel()
        sharedDeliveryRecoveryRetryTask = nil
        sharedDeliveryTask?.cancel()
        sharedDeliveryRecoveryGeneration &+= 1
        let recoveryGeneration = sharedDeliveryRecoveryGeneration
        isSharedDeliveryRecoveryInProgress = true
        sharedDeliveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sharedDeliveryRecoveryGeneration == recoveryGeneration {
                    self.isSharedDeliveryRecoveryInProgress = false
                    self.sharedDeliveryTask = nil
                }
            }
            guard self.lifecycleEpoch == epoch,
                  self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                  self.isViewVisible else { return }
            guard await self.transcriptStoreCall({ $0.storageHealth() }) == true,
                  await self.sessionStoreCall({ $0.storageHealth() }) == true else {
                self.isSharedStorageResolutionUnknown = true
                guard self.lifecycleEpoch == epoch,
                      self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                      self.isViewVisible else { return }
                self.renderSharedDictationUnavailableIfNeeded()
                return
            }
            guard await self.repairPendingCancellationIntents() else {
                self.isSharedStorageResolutionUnknown = true
                guard self.lifecycleEpoch == epoch,
                      self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                      self.isViewVisible else { return }
                self.renderSharedDictationUnavailableIfNeeded()
                return
            }
            guard await self.repairPendingDeliveryJournals() else {
                self.isSharedStorageResolutionUnknown = true
                guard self.lifecycleEpoch == epoch,
                      self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                      self.isViewVisible else { return }
                self.renderSharedDictationUnavailableIfNeeded()
                return
            }
            guard await self.repairPendingDeliveryFailures() else {
                self.isSharedStorageResolutionUnknown = true
                guard self.lifecycleEpoch == epoch,
                      self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                      self.isViewVisible else { return }
                self.renderSharedDictationUnavailableIfNeeded()
                return
            }
            self.isSharedStorageResolutionUnknown = false
            guard !(await self.consumeSharedDictationTranscriptIfNeeded(epoch: epoch)) else { return }
            guard self.lifecycleEpoch == epoch,
                  self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                  self.isViewVisible else { return }
            await self.resumeSharedDictationPollingIfNeeded(epoch: epoch)
            guard self.lifecycleEpoch == epoch,
                  self.sharedDeliveryRecoveryGeneration == recoveryGeneration,
                  self.isViewVisible else { return }
            self.renderCurrentSpeechCapture()
        }
    }

    private func scheduleSharedDeliveryRecoveryRetry(epoch: UInt64) {
        guard isViewVisible,
              lifecycleEpoch == epoch,
              sharedDeliveryRecoveryRetryTask == nil else { return }
        sharedDeliveryRecoveryRetryGeneration &+= 1
        let retryGeneration = sharedDeliveryRecoveryRetryGeneration
        sharedDeliveryRecoveryRetryTask = Task { [weak self] in
            defer {
                if let self,
                   self.sharedDeliveryRecoveryRetryGeneration == retryGeneration {
                    self.sharedDeliveryRecoveryRetryTask = nil
                }
            }
            for _ in 0..<20 {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.sharedDeliveryRecoveryRetryGeneration == retryGeneration,
                      self.isViewVisible,
                      self.lifecycleEpoch == epoch else { return }
                if !self.isSharedCancellationInProgress {
                    self.startSharedDeliveryRecovery(epoch: epoch)
                    return
                }
            }
        }
    }

    private func repairPendingCancellationIntents() async -> Bool {
        await sessionStoreCall { store in
            var allResolved = true
            guard case .available(let intents) = store.pendingCancellationIntentsResolution() else {
                return false
            }
            for command in intents {
                guard let replacedToken = command.replacesCommandToken else {
                    guard store.discardCancellationIntent(forToken: command.token) else {
                        allResolved = false
                        continue
                    }
                    continue
                }
                switch store.commandResolution(forToken: replacedToken) {
                case .unavailable:
                    allResolved = false
                    continue
                case .missing:
                    // The referenced start has already crossed the bounded
                    // history fence. There is no durable command left that
                    // a cancel can affect, so do not leave an outbox entry
                    // that can block every future recovery forever.
                    guard store.discardCancellationIntent(forToken: command.token) else {
                        allResolved = false
                        continue
                    }
                    continue
                case .found:
                    break
                }
                switch store.statusResolution(forCommandToken: replacedToken) {
                case .unavailable:
                    allResolved = false
                    continue
                case .found(let replacedStatus):
                    switch replacedStatus {
                    case .cancelled:
                        guard store.discardCancellationIntent(forToken: command.token) else {
                            allResolved = false
                            continue
                        }
                        continue
                    case .failed:
                        // A failed producer may still have a committed
                        // transcript. Keep the cancellation fence until the
                        // cancel command is persisted and processed; dropping
                        // it here would allow that transcript to resurrect.
                        if !store.saveCommand(command) {
                            allResolved = false
                        }
                        continue
                    default:
                        break
                    }
                case .missing:
                    break
                }
                if !store.saveCommand(command) {
                    allResolved = false
                }
            }
            return allResolved
        } == true
    }

    private func repairPendingDeliveryFailures() async -> Bool {
        await sessionStoreCall { store in
            guard case .available(let intents) = store.pendingDeliveryFailureIntentsResolution() else {
                return false
            }
            var allResolved = true
            for (token, message) in intents {
                if store.saveDeliveryFailure(token: token, message: message) {
                    continue
                }
                let statusResolution = store.statusResolution(forCommandToken: token)
                switch statusResolution {
                case .unavailable:
                    allResolved = false
                    continue
                case .found(let status):
                    switch status {
                    case .failed, .cancelled:
                        guard store.discardDeliveryFailureIntent(forToken: token) else {
                            allResolved = false
                            continue
                        }
                    case .idle,
                         .commandPending,
                         .commandAcknowledged,
                         .recording,
                         .transcribing,
                         .transcriptReady:
                        // A non-terminal status cannot prove that the
                        // failure WAL is obsolete, even if its command has
                        // already fallen out of bounded command history.
                        allResolved = false
                    }
                case .missing:
                    // Only a normal read that proves both records are absent
                    // can retire the intent. An unavailable command read must
                    // remain recoverable.
                    switch store.commandResolution(forToken: token) {
                    case .missing:
                        guard store.discardDeliveryFailureIntent(forToken: token) else {
                            allResolved = false
                            continue
                        }
                    case .found, .unavailable:
                        allResolved = false
                    }
                }
            }
            return allResolved
        } == true
    }

    private func repairPendingDeliveryJournals() async -> Bool {
        guard let intents = await sessionStoreCall({
            $0.pendingDeliveryFailureIntentsResolution()
        }), case .available(let availableIntents) = intents else {
            return false
        }
        for commandToken in availableIntents.keys {
            let pendingDeliveryResolution = await transcriptStoreCall {
                $0.pendingDeliveryResolution(forCommandToken: commandToken)
            }
            guard let pendingDeliveryResolution else { return false }
            let pendingDelivery: SharedDictationTranscriptDelivery
            switch pendingDeliveryResolution {
            case .found(let delivery):
                pendingDelivery = delivery
            case .missing:
                continue
            case .unavailable:
                return false
            }
            if pendingDelivery.isQuarantined {
                // A previous recovery already wrote the no-replay tombstone.
                // Leave it in place and continue to the failure WAL; trying
                // to discard or quarantine it again would deadlock recovery.
                continue
            }
            let repaired: Bool
            if pendingDelivery.mutationInFlight || pendingDelivery.appliedOperationCount > 0 {
                repaired = await transcriptStoreCall {
                    $0.quarantinePendingDelivery(
                        transcriptToken: pendingDelivery.transcriptToken,
                        ownerID: self.sharedDeliveryOwnerID
                    )
                } == true
            } else {
                repaired = await transcriptStoreCall {
                    $0.discardPendingDelivery(
                        transcriptToken: pendingDelivery.transcriptToken,
                        ownerID: self.sharedDeliveryOwnerID
                    )
                } == true
            }
            guard repaired else { return false }
        }
        return true
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateNextKeyboardButtonVisibility()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        if isOpeningContainingApp {
            // This disappearance is the deliberate app handoff requested by
            // the user. Keep the durable transcript eligible for the next
            // keyboard instance; its document fingerprint is still checked
            // before any insertion.
            hasSharedDeliveryLifecycleGap = false
            lifecycleGapSessionID = nil
            lifecycleGapTranscriptToken = nil
        } else {
            hasSharedDeliveryLifecycleGap = true
            lifecycleGapSessionID = activeSharedSessionID
            lifecycleGapTranscriptToken = activeSharedTranscriptToken
            if let activeSharedTranscriptToken {
                blockedLifecycleTranscriptTokens.insert(activeSharedTranscriptToken)
                if blockedLifecycleTranscriptTokens.count > Self.maximumBlockedLifecycleTranscriptTokens,
                   let oldestToken = blockedLifecycleTranscriptTokens.first {
                    blockedLifecycleTranscriptTokens.remove(oldestToken)
                }
                persistKeyboardLifecycleBlock(for: activeSharedTranscriptToken)
            }
        }
        lifecycleEpoch &+= 1
        microphoneDecisionTask?.cancel()
        microphoneDecisionTask = nil
        isMicrophoneDecisionInFlight = false
        cancelDirectRecognition()
        // A cancellation requested immediately before a keyboard switch must
        // still reach the App Group after the view disappears. Keep its
        // in-memory barrier set until the durable write/retry finishes so a
        // newly recreated keyboard cannot recover and deliver the transcript
        // ahead of the cancellation intent.
        if !isSharedCancellationInProgress {
            sharedCancellationOperationGeneration &+= 1
        }
        sharedCancellationRecoveryWaitTask?.cancel()
        sharedCancellationRecoveryWaitTask = nil
        queuedDocumentMutations.removeAll()
        endSharedSession()
        // Disappearing is a normal keyboard lifecycle event (keyboard
        // switching, host navigation, or temporary dismissal). Keep the
        // durable shared handoff alive; explicit Stop/Cancel and document
        // mutations are the operations that cancel it.
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        sharedDeliveryTask?.cancel()
        sharedDeliveryTask = nil
        sharedDeliveryRecoveryGeneration &+= 1
        isSharedDeliveryRecoveryInProgress = false
    }

    @objc private func hostWillResignActive() {
        if activeSharedCommandToken == nil {
            microphoneDecisionTask?.cancel()
            microphoneDecisionTask = nil
            isMicrophoneDecisionInFlight = false
        }
        let wasRecognizing = isRecognitionActive
        cancelDirectRecognition()
        if wasRecognizing {
            renderCurrentSpeechCapture()
        }
    }

    // MARK: - View Setup

    private func configureView() {
        keyboardRootView.translatesAutoresizingMaskIntoConstraints = false
        keyboardRootView.setNextKeyboardTarget(
            self,
            action: #selector(nextKeyboardTapped(_:with:))
        )
        keyboardRootView.onMicrophone = { [weak self] in self?.microphoneTapped() }
        keyboardRootView.onDelete = { [weak self] in self?.deleteTapped() }
        keyboardRootView.onReturn = { [weak self] in self?.returnTapped() }

        view.addSubview(keyboardRootView)
        NSLayoutConstraint.activate([
            keyboardRootView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardRootView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardRootView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardRootView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateNextKeyboardButtonVisibility()
    }

    // MARK: - Rendering

    private func renderCurrentSpeechCapture(announce: Bool = false) {
        guard !isRecognitionActive else { return }
        keyboardRootView.render(
            speechCapture: speechCaptureCoordinator.currentSnapshot(hasFullAccess: hasFullAccess),
            announce: announce
        )
    }

    private func updateNextKeyboardButtonVisibility() {
        keyboardRootView.setNextKeyboardVisible(needsInputModeSwitchKey)
    }

    // UITextDocumentProxy exposes only a bounded context window. The input
    // delegate callbacks are the additional signal that the host moved the
    // insertion point or changed the document while recognition was active.
    public override func textWillChange(_ textInput: UITextInput?) {
        noteExternalDocumentMutation()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        noteExternalDocumentMutation()
    }

    public override func selectionWillChange(_ textInput: UITextInput?) {
        noteExternalDocumentMutation()
    }

    public override func selectionDidChange(_ textInput: UITextInput?) {
        noteExternalDocumentMutation()
    }

    // MARK: - Actions

    @objc private func nextKeyboardTapped(_ sender: UIView, with event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }

    @objc private func microphoneTapped() {
        guard isViewVisible,
              !isMicrophoneDecisionInFlight,
              !isSharedDeliveryRecoveryInProgress,
              !isSharedCancellationInProgress else { return }

        if activeSharedCommandToken != nil {
            isMicrophoneDecisionInFlight = true
            let epoch = lifecycleEpoch
            microphoneDecisionTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.lifecycleEpoch == epoch {
                        self.isMicrophoneDecisionInFlight = false
                        self.microphoneDecisionTask = nil
                    }
                }
                await self.stopSharedDictationSession(epoch: epoch)
            }
            return
        }

        if isRecognitionActive {
            allowsDirectStartupFallback = false
            speechCaptureCoordinator.finishRecognition()
        } else if speechCaptureCoordinator.directRecognitionIsReady(hasFullAccess: hasFullAccess) {
            startDirectKeyboardRecognition()
        } else {
            beginSharedMicrophoneDecision(epoch: lifecycleEpoch)
        }
    }

    private func beginSharedMicrophoneDecision(epoch: UInt64) {
        isMicrophoneDecisionInFlight = true
        let expectedContext = currentDocumentContextFingerprint()
        let expectedMutationGeneration = documentMutationGeneration
        microphoneDecisionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleEpoch == epoch, !Task.isCancelled {
                    self.isMicrophoneDecisionInFlight = false
                    self.microphoneDecisionTask = nil
                }
            }
            await self.handleSharedMicrophoneTap(
                epoch: epoch,
                expectedContext: expectedContext,
                expectedMutationGeneration: expectedMutationGeneration
            )
        }
    }

    private func handleSharedMicrophoneTap(
        epoch: UInt64,
        expectedContext: SharedDictationDocumentContextFingerprint,
        expectedMutationGeneration: UInt64
    ) async {
        func canStart() -> Bool {
            isCurrentInteraction(epoch)
                && documentMutationGeneration == expectedMutationGeneration
                && currentDocumentContextFingerprint() == expectedContext
        }
        guard canStart() else { return }
        let appHeartbeatIsFresh = await sessionStoreCall {
            $0.heartbeat()?.isFresh(maxAge: 5) == true
        } == true
        guard canStart() else { return }
        let decision = KeyboardDictationStartDecision.evaluate(
            directKeyboardRecognitionReady: false,
            hasSessionStore: await sessionStoreCall({ $0.storageHealth() }) == true,
            appHeartbeatIsFresh: appHeartbeatIsFresh
        )
        guard canStart() else { return }

        switch decision {
        case .startDirectKeyboardRecognition:
            return
        case .writeSharedStartCommand:
            _ = await startSharedDictationSession(epoch: epoch)
        case .openContainingApp:
            guard await transcriptStoreCall({ $0.storageHealth() }) == true else {
                guard canStart() else { return }
                keyboardRootView.render(
                    speechCapture: .sharedDictationUnavailable,
                    announce: true
                )
                return
            }
            guard canStart() else { return }
            await openContainingAppForDictation(epoch: epoch)
        case .showSharedStorageUnavailable:
            guard canStart() else { return }
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
        }
    }

    private func startDirectKeyboardRecognition() {
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        speechCaptureCoordinator.preload(in: view)

        let locale = VoiceKeyboardLocale(identifier: Locale.current.identifier)
        let context = textDocumentProxy.documentContextBeforeInput
        let epoch = lifecycleEpoch
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        isRecognitionActive = true
        allowsDirectStartupFallback = true
        recognitionExpectedDocumentContext = context
        recognitionExpectedDocumentContextAfterInput = textDocumentProxy.documentContextAfterInput
        recognitionExpectedDocumentIdentifier = textDocumentProxy.documentIdentifier
        recognitionExpectedSelectedText = textDocumentProxy.selectedText
        recognitionExpectedDocumentMutationGeneration = documentMutationGeneration
        let events = speechCaptureCoordinator.recognitionEvents(
            locale: locale,
            documentContextBeforeInput: context,
            hasFullAccess: { [weak self] in self?.hasFullAccess == true }
        )

        recognitionTask = Task { [weak self] in
            for await event in events {
                guard let self, self.isCurrentInteraction(epoch),
                      self.recognitionGeneration == currentRecognitionGeneration,
                      self.isRecognitionActive else { return }

                switch event {
                case .presentation(let snapshot):
                    self.keyboardRootView.render(speechCapture: snapshot, announce: true)
                case .final(let snapshot, let actions):
                    if self.apply(actions, epoch: epoch, recognitionGeneration: currentRecognitionGeneration) {
                        self.keyboardRootView.render(speechCapture: snapshot, announce: true)
                    }
                    self.resetDirectRecognition()
                    return
                case .startupFailed:
                    let canFallback = self.allowsDirectStartupFallback
                        && self.directRecognitionDocumentMatches()
                    self.resetDirectRecognition()
                    self.renderCurrentSpeechCapture()
                    if canFallback {
                        self.beginSharedMicrophoneDecision(epoch: epoch)
                    }
                    return
                }
            }
            guard let self, self.recognitionGeneration == currentRecognitionGeneration else { return }
            self.resetDirectRecognition()
        }
    }

    @discardableResult
    private func startSharedDictationSession(
        epoch: UInt64? = nil
    ) async -> SharedDictationSessionCommand? {
        // Keep the handoff alive long enough for a user to open the
        // containing app manually when the keyboard extension URL-open API is
        // unavailable on the current iOS release.
        let command = SharedDictationSessionCommand.start(
            source: .keyboard,
            expiryInterval: 30,
            documentContextFingerprint: SharedDictationDocumentContextFingerprint(
                beforeInput: textDocumentProxy.documentContextBeforeInput,
                afterInput: textDocumentProxy.documentContextAfterInput,
                documentIdentifier: textDocumentProxy.documentIdentifier,
                selectedText: textDocumentProxy.selectedText
            )
        )
        let startContextFingerprint = currentDocumentContextFingerprint()
        let startMutationGeneration = documentMutationGeneration
        guard isCurrentInteraction(epoch) else {
            _ = await sessionStoreCall {
                $0.cancelStaleKeyboardCommand(token: command.token)
            }
            endSharedSession(
                ifMatchingSessionID: command.sessionID,
                commandToken: command.token
            )
            return nil
        }
        guard await sessionStoreCall({ $0.saveCommand(command) }) == true else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return nil
        }
        guard isCurrentInteraction(epoch),
              documentMutationGeneration == startMutationGeneration,
              currentDocumentContextFingerprint() == startContextFingerprint else {
            let didCancelUnclaimed = await sessionStoreCall {
                $0.cancelUnclaimedKeyboardCommand(token: command.token)
            } == true
            if !didCancelUnclaimed {
                let cancelCommand = SharedDictationSessionCommand.cancel(
                    sessionID: command.sessionID,
                    source: .keyboard,
                    replacingCommandToken: command.token
                )
                let didRecordIntent = await sessionStoreCall {
                    $0.recordCancellationIntent(cancelCommand)
                } == true
                let didSave: Bool
                if didRecordIntent {
                    didSave = await saveSharedCommandWithRetry(cancelCommand, attempts: 5)
                } else {
                    didSave = false
                }
                if !didSave {
                    if didRecordIntent {
                        scheduleSharedCancellationRetry(cancelCommand)
                    }
                    keyboardRootView.render(
                        speechCapture: .sharedDictationUnavailable,
                        announce: true
                    )
                }
            }
            return nil
        }
        activeSharedSessionID = command.sessionID
        activeSharedCommandToken = command.token
        activeSharedTranscriptToken = command.token
        hasSharedDeliveryLifecycleGap = false
        lifecycleGapSessionID = nil
        lifecycleGapTranscriptToken = nil
        sharedSessionDeliveryFingerprint = startContextFingerprint
        sharedSessionDocumentContext = textDocumentProxy.documentContextBeforeInput
        sharedSessionDocumentContextAfterInput = textDocumentProxy.documentContextAfterInput
        sharedSessionDocumentIdentifier = textDocumentProxy.documentIdentifier
        sharedSessionSelectedText = textDocumentProxy.selectedText
        sharedSessionDocumentMutationGeneration = documentMutationGeneration
        keyboardRootView.render(
            speechCapture: .sharedDictationSessionStatus(.commandPending(
                token: command.token,
                requestedAt: command.requestedAt
            )),
            announce: true
        )
        monitorSharedDictationSession(command: command)
        return command
    }

    private struct SharedCancellationTarget {
        let sessionID: String
        let activeCommandToken: String
        let replacedCommandToken: String
    }

    private enum SharedCancellationResolution {
        case target(SharedCancellationTarget)
        case noActiveSession
        case storageUnavailable
    }

    private func sharedCancellationTarget() async -> SharedCancellationResolution {
        if let sessionID = activeSharedSessionID,
           let commandToken = activeSharedCommandToken {
            guard let resolution = await sessionStoreCall({ store in
                store.commandResolution(forToken: commandToken)
            }) else {
                return .storageUnavailable
            }
            switch resolution {
            case .unavailable:
                return .storageUnavailable
            case .missing:
                return .noActiveSession
            case .found(let activeCommand):
                guard activeCommand.sessionID == sessionID,
                      activeCommand.source == .keyboard else { return .noActiveSession }
                switch activeCommand.kind {
                case .start:
                    return .target(SharedCancellationTarget(
                        sessionID: sessionID,
                        activeCommandToken: commandToken,
                        replacedCommandToken: activeCommand.token
                    ))
                case .stop, .cancel:
                    guard let replacedCommandToken = activeCommand.replacesCommandToken else {
                        return .noActiveSession
                    }
                    return .target(SharedCancellationTarget(
                        sessionID: sessionID,
                        activeCommandToken: commandToken,
                        replacedCommandToken: replacedCommandToken
                    ))
                }
            }
        }

        // The extension can be recreated while recovery is still reading the
        // App Group. Resolve the durable command before applying Delete or
        // Return so a no-op edit cannot let a later transcript through.
        guard let historyResolution = await sessionStoreCall({ $0.commandHistoryResolution() }) else {
            return .storageUnavailable
        }
        guard case .available(let commands) = historyResolution else {
            return .storageUnavailable
        }
        for command in commands.reversed() where command.source == .keyboard {
            switch command.kind {
            case .cancel:
                continue
            case .stop:
                guard let replacedCommandToken = command.replacesCommandToken else { continue }
                return .target(SharedCancellationTarget(
                    sessionID: command.sessionID,
                    activeCommandToken: command.token,
                    replacedCommandToken: replacedCommandToken
                ))
            case .start:
                guard let status = await sessionStoreCall({
                    $0.status(forCommandToken: command.token)
                }) else {
                    return .storageUnavailable
                }
                switch status {
                case .cancelled:
                    continue
                case .failed:
                    // A failed producer status does not prove that its
                    // transcript journal is empty. Preserve the explicit
                    // Delete/Return cancellation fence so recovery cannot
                    // later promote a committed transcript.
                    return .target(SharedCancellationTarget(
                        sessionID: command.sessionID,
                        activeCommandToken: command.token,
                        replacedCommandToken: command.token
                    ))
                case .commandPending,
                     .commandAcknowledged,
                     .recording,
                     .transcribing,
                     .transcriptReady,
                     .idle:
                    return .target(SharedCancellationTarget(
                        sessionID: command.sessionID,
                        activeCommandToken: command.token,
                        replacedCommandToken: command.token
                    ))
                }
            }
        }
        return .noActiveSession
    }

    private func cancelSharedDictationForLifecycleChange(
        then mutation: PendingDocumentMutation
    ) {
        guard !isSharedCancellationInProgress else {
            enqueuePendingDocumentMutation(mutation)
            return
        }
        let expectedContext = mutation.expectedContext
        let expectedMutationGeneration = mutation.expectedMutationGeneration
        let expectedEpoch = mutation.expectedEpoch
        sharedCancellationOperationGeneration &+= 1
        let operationGeneration = sharedCancellationOperationGeneration
        isSharedCancellationInProgress = true
        sharedCancellationTask = Task { [weak self] in
            guard let self else { return }
            switch await self.sharedCancellationTarget() {
            case .storageUnavailable:
                guard self.sharedCancellationOperationGeneration == operationGeneration else { return }
                self.isSharedStorageResolutionUnknown = true
                self.isSharedCancellationInProgress = false
                self.sharedCancellationTask = nil
                self.retainMutationForCancellationRetry(
                    mutation
                )
                self.sharedDictationPollingTask?.cancel()
                self.sharedDictationPollingTask = nil
                self.sharedDeliveryTask?.cancel()
                self.sharedDeliveryTask = nil
                self.scheduleSharedCancellationResolutionRetry(epoch: expectedEpoch)
                guard self.lifecycleEpoch == expectedEpoch, self.isViewVisible else { return }
                self.keyboardRootView.render(
                    speechCapture: .sharedDictationUnavailable,
                    announce: true
                )
            case .noActiveSession:
                guard self.sharedCancellationOperationGeneration == operationGeneration else { return }
                // Resolve the operation barrier before checking the view
                // epoch. A cancellation that completed while the keyboard
                // disappeared must not strand every future interaction behind
                // a task that can no longer be observed by the old view.
                self.isSharedCancellationInProgress = false
                self.sharedCancellationTask = nil
                self.isSharedStorageResolutionUnknown = false
                self.cancelDirectRecognition()
                guard self.lifecycleEpoch == expectedEpoch, self.isViewVisible else {
                    self.queuedDocumentMutations.removeAll()
                    self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: self.lifecycleEpoch)
                    return
                }
                let canApplyMutation = self.documentMutationGeneration == expectedMutationGeneration
                    && self.currentDocumentContextFingerprint() == expectedContext
                if canApplyMutation {
                    self.applyPendingDocumentMutations(startingWith: mutation)
                } else {
                    self.queuedDocumentMutations.removeAll()
                }
                self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: self.lifecycleEpoch)
            case .target(let target):
                let cancelCommand = SharedDictationSessionCommand.cancel(
                    sessionID: target.sessionID,
                    source: .keyboard,
                    replacingCommandToken: target.replacedCommandToken
                )
                let didRecordIntent = await self.sessionStoreCall {
                    $0.recordCancellationIntent(cancelCommand)
                } == true
                guard didRecordIntent else {
                    self.isSharedStorageResolutionUnknown = true
                    self.isSharedCancellationInProgress = false
                    self.sharedCancellationTask = nil
                    self.retainMutationForCancellationRetry(
                        mutation
                    )
                    self.sharedDictationPollingTask?.cancel()
                    self.sharedDictationPollingTask = nil
                    self.sharedDeliveryTask?.cancel()
                    self.sharedDeliveryTask = nil
                    self.scheduleSharedCancellationResolutionRetry(epoch: expectedEpoch)
                    guard self.lifecycleEpoch == expectedEpoch, self.isViewVisible else { return }
                    self.keyboardRootView.render(
                        speechCapture: .sharedDictationUnavailable,
                        announce: true
                    )
                    return
                }
                let didSave = await self.saveSharedCommandWithRetry(cancelCommand, attempts: 5)
                guard !Task.isCancelled,
                      self.sharedCancellationOperationGeneration == operationGeneration else {
                    return
                }
                guard didSave else {
                    if self.lifecycleEpoch == expectedEpoch, self.isViewVisible {
                        self.keyboardRootView.render(
                            speechCapture: .sharedDictationUnavailable,
                            announce: true
                        )
                    }
                    self.scheduleSharedCancellationRetry(cancelCommand) { [weak self] in
                        guard let self else { return }
                        self.completeSharedCancellation(
                            target: target,
                            expectedContext: expectedContext,
                            expectedMutationGeneration: expectedMutationGeneration,
                            expectedEpoch: expectedEpoch,
                            operationGeneration: operationGeneration,
                            mutation: mutation
                        )
                    } onExhausted: { [weak self] in
                        guard let self,
                              self.sharedCancellationOperationGeneration == operationGeneration else { return }
                        self.isSharedStorageResolutionUnknown = true
                        self.isSharedCancellationInProgress = false
                        self.sharedCancellationTask = nil
                        self.retainMutationForCancellationRetry(
                            mutation
                        )
                        self.sharedDictationPollingTask?.cancel()
                        self.sharedDictationPollingTask = nil
                        self.sharedDeliveryTask?.cancel()
                        self.sharedDeliveryTask = nil
                        self.scheduleSharedCancellationResolutionRetry(epoch: self.lifecycleEpoch)
                        self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: self.lifecycleEpoch)
                        guard self.lifecycleEpoch == expectedEpoch, self.isViewVisible else { return }
                        self.keyboardRootView.render(
                            speechCapture: .sharedDictationUnavailable,
                            announce: true
                        )
                    }
                    return
                }
                self.completeSharedCancellation(
                    target: target,
                    expectedContext: expectedContext,
                    expectedMutationGeneration: expectedMutationGeneration,
                    expectedEpoch: expectedEpoch,
                    operationGeneration: operationGeneration,
                    mutation: mutation
                )
            }
        }
    }

    private func completeSharedCancellation(
        target: SharedCancellationTarget,
        expectedContext: SharedDictationDocumentContextFingerprint,
        expectedMutationGeneration: UInt64,
        expectedEpoch: UInt64,
        operationGeneration: UInt64,
        mutation: PendingDocumentMutation
    ) {
        guard sharedCancellationOperationGeneration == operationGeneration else { return }
        guard lifecycleEpoch == expectedEpoch, isViewVisible else {
            isSharedCancellationInProgress = false
            sharedCancellationTask = nil
            queuedDocumentMutations.removeAll()
            startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: lifecycleEpoch)
            return
        }
        let canApplyMutation = documentMutationGeneration == expectedMutationGeneration
            && currentDocumentContextFingerprint() == expectedContext
        endSharedSession(
            ifMatchingSessionID: target.sessionID,
            commandToken: target.activeCommandToken
        )
        cancelDirectRecognition()
        isSharedCancellationInProgress = false
        sharedCancellationTask = nil
        if canApplyMutation {
            applyPendingDocumentMutations(startingWith: mutation)
        } else {
            queuedDocumentMutations.removeAll()
        }
        startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: lifecycleEpoch)
    }

    private func retainMutationForCancellationRetry(
        _ mutation: PendingDocumentMutation
    ) {
        guard isViewVisible, lifecycleEpoch == mutation.expectedEpoch else {
            // The mutation belongs to a document that is no longer visible.
            // Never replay it against a newly focused host field.
            queuedDocumentMutations.removeAll()
            return
        }
        enqueuePendingDocumentMutation(mutation, atFront: true)
        scheduleSharedCancellationResolutionRetry(epoch: mutation.expectedEpoch)
    }

    private func isCurrentInteraction(_ epoch: UInt64?) -> Bool {
        !Task.isCancelled
            && isViewVisible
            && (epoch == nil || lifecycleEpoch == epoch)
            && !isSharedCancellationInProgress
    }

    private func stopSharedDictationSession(epoch: UInt64) async {
        guard let sessionID = activeSharedSessionID,
              let commandToken = activeSharedCommandToken,
              isCurrentInteraction(epoch),
              let activeCommand = await sessionStoreCall({ $0.command(forToken: commandToken) }) ?? nil,
              isCurrentInteraction(epoch),
              activeSharedSessionID == sessionID,
              activeSharedCommandToken == commandToken,
              activeCommand.sessionID == sessionID,
              activeCommand.token == commandToken,
              activeCommand.source == .keyboard else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return
        }
        guard activeCommand.kind == .start else {
            guard activeCommand.kind == .stop else { return }
            keyboardRootView.render(
                speechCapture: .sharedDictationStopping,
                announce: false
            )
            return
        }
        let command = SharedDictationSessionCommand.stop(
            sessionID: sessionID,
            source: .keyboard,
            expiryInterval: 20,
            replacingCommandToken: commandToken
        )
        guard await sessionStoreCall({ $0.saveCommand(command) }) == true,
              isCurrentInteraction(epoch),
              activeSharedSessionID == sessionID,
              activeSharedCommandToken == commandToken else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return
        }
        activeSharedCommandToken = command.token
        activeSharedTranscriptToken = commandToken
        keyboardRootView.render(
            speechCapture: .sharedDictationStopping,
            announce: true
        )
        monitorSharedDictationSession(command: command)
    }

    private func monitorSharedDictationSession(command: SharedDictationSessionCommand) {
        sharedDictationPollingTask?.cancel()
        sharedPollingGeneration &+= 1
        let pollingGeneration = sharedPollingGeneration
        let epoch = lifecycleEpoch
        sharedDictationPollingTask = Task { [weak self] in
            defer {
                if let self,
                   self.lifecycleEpoch == epoch,
                   self.sharedPollingGeneration == pollingGeneration {
                    self.sharedDictationPollingTask = nil
                }
            }
            let initialDeadline = Date().addingTimeInterval(16)
            let hardDeadline = max(
                initialDeadline,
                command.requestedAt.addingTimeInterval(Self.sharedTranscriptRecoveryRetention)
            )
            var didRequestContainingAppFallback = false

            while !Task.isCancelled {
                guard let self else { return }
                guard self.lifecycleEpoch == epoch else { return }
                guard self.isViewVisible else { return }
                guard self.sharedPollingGeneration == pollingGeneration,
                      self.activeSharedSessionID == command.sessionID,
                      self.activeSharedCommandToken == command.token else { return }

                if (command.kind == .start || command.kind == .stop),
                   await consumeSharedDictationTranscriptIfNeeded(for: command, epoch: epoch) {
                    return
                }
                guard self.lifecycleEpoch == epoch,
                      self.sharedPollingGeneration == pollingGeneration,
                      self.activeSharedCommandToken == command.token else { return }

                if var status = await sessionStoreCall({
                    $0.status(forCommandToken: command.token)
                }) {
                    guard self.lifecycleEpoch == epoch,
                          self.sharedPollingGeneration == pollingGeneration,
                          self.activeSharedCommandToken == command.token else { return }
                    // The transcript is a durable completion marker written
                    // before the containing app publishes transcriptReady.
                    // If that process died (or stale recovery published
                    // cancelled) while the keyboard remained alive, promote
                    // the matching unconsumed record locally so the handoff
                    // is not lost forever.
                    if command.kind == .start,
                       status.commandToken == command.token,
                       case let .found(transcript) = await self.transcriptStoreCall({
                           $0.latestTranscriptResolution(forSessionID: command.sessionID)
                       }),
                       transcript.commandToken == command.token,
                       await self.sessionStoreCall({
                           $0.saveStatus(
                               .transcriptReady(token: command.token),
                               allowRecoveryFromTranscriptReady: true
                           )
                       }) == true {
                        status = .transcriptReady(token: command.token)
                    }
                    let appHeartbeatIsFresh = await sessionStoreCall {
                        $0.heartbeat()?.isFresh(maxAge: 5) == true
                    } == true
                    guard self.lifecycleEpoch == epoch,
                          self.sharedPollingGeneration == pollingGeneration,
                          self.activeSharedCommandToken == command.token else { return }
                    if !didRequestContainingAppFallback,
                       Date().timeIntervalSince(command.requestedAt) >= 2,
                       !appHeartbeatIsFresh,
                       status.commandToken != command.token || status.isPendingSharedDictation {
                        didRequestContainingAppFallback = true
                        openContainingAppForExistingSession(
                            sessionID: command.sessionID,
                            epoch: epoch
                        )
                    }
                    guard status.commandToken == command.token else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    keyboardRootView.render(
                        speechCapture: .sharedDictationSessionStatus(status),
                        announce: false
                    )
                    let waitingForStoppedStart = command.kind == .stop
                        && command.replacesCommandToken != nil
                    if status.stopsKeyboardPolling, !waitingForStoppedStart {
                        endSharedSession(
                            ifMatchingSessionID: command.sessionID,
                            commandToken: command.token,
                            pollingGeneration: pollingGeneration
                        )
                        return
                    }
                    if waitingForStoppedStart,
                       let sourceToken = command.replacesCommandToken {
                        let sourceStatus = await sessionStoreCall {
                            $0.status(forCommandToken: sourceToken)
                        }
                        guard self.lifecycleEpoch == epoch,
                              self.sharedPollingGeneration == pollingGeneration,
                              self.activeSharedCommandToken == command.token else { return }
                        if case .some(.failed) = sourceStatus {
                            endSharedSession(
                                ifMatchingSessionID: command.sessionID,
                                commandToken: command.token,
                                pollingGeneration: pollingGeneration
                            )
                            return
                        }
                        if case .some(.cancelled) = sourceStatus {
                            endSharedSession(
                                ifMatchingSessionID: command.sessionID,
                                commandToken: command.token,
                                pollingGeneration: pollingGeneration
                            )
                            return
                        }
                    }

                }

                guard self.lifecycleEpoch == epoch,
                      self.sharedPollingGeneration == pollingGeneration,
                      self.activeSharedSessionID == command.sessionID,
                      self.activeSharedCommandToken == command.token else { return }
                if Date() >= initialDeadline {
                    let statusResolution = await self.sessionStoreCall {
                        $0.statusResolution(forCommandToken: command.token)
                    }
                    let producerIsInActiveState: Bool
                    switch statusResolution {
                    case .found(.commandAcknowledged),
                         .found(.recording),
                         .found(.transcribing):
                        producerIsInActiveState = true
                    default:
                        producerIsInActiveState = false
                    }
                    let didCancelStaleProducer: Bool
                    if producerIsInActiveState, Date() >= command.expiresAt {
                        didCancelStaleProducer = await self.sessionStoreCall {
                            $0.cancelStaleKeyboardCommand(token: command.token)
                        } == true
                    } else {
                        didCancelStaleProducer = false
                    }
                    if didCancelStaleProducer {
                        self.endSharedSession(
                            ifMatchingSessionID: command.sessionID,
                            commandToken: command.token,
                            pollingGeneration: pollingGeneration
                        )
                        self.keyboardRootView.render(
                            speechCapture: .sharedDictationTimedOut,
                            announce: true
                        )
                        return
                    }
                    let producerMayStillFinish: Bool
                    switch statusResolution {
                    case .found(.commandPending),
                         .found(.commandAcknowledged),
                         .found(.recording),
                         .found(.transcribing),
                         .found(.transcriptReady):
                        producerMayStillFinish = true
                    case .found(.idle), .found(.failed), .found(.cancelled), .missing, .unavailable, nil:
                        producerMayStillFinish = false
                    }
                    guard producerMayStillFinish, Date() < hardDeadline else {
                        endSharedSession(
                            ifMatchingSessionID: command.sessionID,
                            commandToken: command.token,
                            pollingGeneration: pollingGeneration
                        )
                        keyboardRootView.render(
                            speechCapture: .sharedDictationTimedOut,
                            announce: true
                        )
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func resumeSharedDictationPollingIfNeeded(epoch: UInt64? = nil) async {
        guard isViewVisible,
              isSharedDeliveryCurrent(epoch),
              sharedDictationPollingTask == nil,
              let command = await matchingActiveStartCommand(epoch: epoch) else { return }
        guard isSharedDeliveryCurrent(epoch) else { return }
        monitorSharedDictationSession(command: command)
    }

    private func apply(
        _ actions: [KeyboardTextInsertionAction],
        epoch: UInt64,
        recognitionGeneration: UInt64
    ) -> Bool {
        guard isRecognitionActive, hasFullAccess,
              lifecycleEpoch == epoch,
              self.recognitionGeneration == recognitionGeneration else { return false }
        guard directRecognitionDocumentMatches() else {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                    .recognitionFailed("The text field changed while voice input was active.")
                )),
                announce: true
            )
            return false
        }
        guard textDocumentProxy.selectedText == nil || !actions.contains(where: {
            if case .deleteBackward = $0 { return true }
            return false
        }) else {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(
                    "Delete commands are unavailable while text is selected."
                )),
                announce: true
            )
            return false
        }
        var totalDeletionCount = 0
        for action in actions {
            if case let .deleteBackward(count) = action {
                totalDeletionCount += count.value
            }
        }
        guard actions.count <= SharedDictationTranscriptDelivery.maximumOperationCount,
              totalDeletionCount <= SharedDictationTranscriptDelivery.maximumTotalDeletionCount else {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(
                    "Voice input contained too many editing operations."
                )),
                announce: true
            )
            return false
        }

        let documentIdentifier = recognitionExpectedDocumentIdentifier
        isApplyingProxyMutation = true
        defer { isApplyingProxyMutation = false }
        for action in actions {
            guard textDocumentProxy.documentIdentifier == documentIdentifier else { return false }
            switch action {
            case .insertText(let value):
                textDocumentProxy.insertText(value)
            case .deleteBackward(let count):
                for _ in 0..<count.value {
                    guard !Task.isCancelled,
                          isRecognitionActive,
                          lifecycleEpoch == epoch,
                          self.recognitionGeneration == recognitionGeneration,
                          textDocumentProxy.documentIdentifier == documentIdentifier else {
                        return false
                    }
                    // UITextDocumentProxy has no rollback operation. Keep a
                    // direct delete command contiguous on the main actor so
                    // lifecycle cancellation cannot leave a partial edit.
                    textDocumentProxy.deleteBackward()
                }
            case .showUnsupportedCommand:
                break
            }
            // The host controls how much context is exposed around the
            // insertion point. Refresh from the proxy after each operation so
            // a long document does not make our expected snapshot grow beyond
            // that bounded window.
            recognitionExpectedDocumentContext = textDocumentProxy.documentContextBeforeInput
            recognitionExpectedDocumentContextAfterInput = textDocumentProxy.documentContextAfterInput
            recognitionExpectedDocumentIdentifier = textDocumentProxy.documentIdentifier
            recognitionExpectedSelectedText = textDocumentProxy.selectedText
            recognitionExpectedDocumentMutationGeneration = documentMutationGeneration
            if case .showUnsupportedCommand = action {
                continue
            }
            expectSelfMutationCallbacks(for: currentDocumentContextFingerprint())
        }
        return true
    }

    private func directRecognitionDocumentMatches() -> Bool {
        recognitionExpectedDocumentContext == textDocumentProxy.documentContextBeforeInput
            && recognitionExpectedDocumentContextAfterInput == textDocumentProxy.documentContextAfterInput
            && recognitionExpectedDocumentIdentifier == textDocumentProxy.documentIdentifier
            && recognitionExpectedSelectedText == textDocumentProxy.selectedText
            && recognitionExpectedDocumentMutationGeneration == documentMutationGeneration
    }

    private func consumeSharedDictationTranscriptIfNeeded(
        for command: SharedDictationSessionCommand? = nil,
        epoch: UInt64? = nil
    ) async -> Bool {
        guard isSharedDeliveryCurrent(epoch) else { return false }
        let expectedMutationGeneration = sharedSessionDocumentMutationGeneration
            ?? documentMutationGeneration
        guard await transcriptStoreCall({ $0.storageHealth() }) == true else { return false }
        let deliveryOwnerID = sharedDeliveryOwnerID
        let resolvedCommand: SharedDictationSessionCommand?
        if let command {
            resolvedCommand = command
        } else {
            resolvedCommand = await matchingReadyStartCommand(epoch: epoch)
        }
        guard let command = resolvedCommand,
              let source = transcriptSource(for: command) else { return false }
        let deliveryPollingGeneration = sharedPollingGeneration
        func isCurrentDelivery() -> Bool {
            isSharedDeliveryCurrent(
                epoch,
                pollingGeneration: deliveryPollingGeneration,
                sessionID: source.sessionID,
                commandToken: command.token
            )
        }
        guard let status = await sessionStoreCall({
                  $0.status(forCommandToken: source.commandToken)
              }),
              case let .transcriptReady(statusToken) = status,
              statusToken == source.commandToken else {
            return false
        }
        guard isCurrentDelivery() else { return false }
        guard let latestTranscript = await transcriptStoreCall({
            $0.latestTranscript(forSessionID: source.sessionID)
        }) ?? nil,
        latestTranscript.commandToken == source.commandToken else {
            return false
        }
        guard isCurrentDelivery() else { return false }
        guard !latestTranscript.isExpired() else {
            guard await transcriptStoreCall({
                $0.markConsumed(token: source.commandToken)
            }) == true else { return false }
            guard await sessionStoreCall({
                $0.saveDeliveryFailure(
                    token: source.commandToken,
                    message: "The shared dictation result expired before it could be inserted."
                )
            }) == true else { return false }
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            keyboardRootView.render(
                speechCapture: .sharedDictationTimedOut,
                announce: true
            )
            return true
        }
        let beforeInput = textDocumentProxy.documentContextBeforeInput
        let afterInput = textDocumentProxy.documentContextAfterInput
        let documentIdentifier = textDocumentProxy.documentIdentifier
        let selectedText = textDocumentProxy.selectedText
        let currentContextFingerprint = SharedDictationDocumentContextFingerprint(
            beforeInput: beforeInput,
            afterInput: afterInput,
            documentIdentifier: documentIdentifier,
            selectedText: selectedText
        )
        let locale = VoiceKeyboardLocale(identifier: Locale.current.identifier)
        let pendingDeliveryResolution = await transcriptStoreCall {
            $0.pendingDeliveryResolution(forCommandToken: source.commandToken)
        }
        guard let pendingDeliveryResolution else { return false }
        var pendingDelivery: SharedDictationTranscriptDelivery?
        switch pendingDeliveryResolution {
        case .found(let delivery):
            pendingDelivery = delivery
        case .missing:
            pendingDelivery = nil
        case .unavailable:
            return false
        }
        guard isCurrentDelivery() else { return false }
        let isDurablyBlocked = await sessionStoreCall {
            $0.isKeyboardTranscriptBlocked(token: source.commandToken)
        } == true
        let isLocallyBlocked = blockedLifecycleTranscriptTokens.contains(source.commandToken)
        if hasSharedDeliveryLifecycleGap {
            if let lifecycleGapSessionID,
               source.sessionID != lifecycleGapSessionID {
                return false
            }
            if let lifecycleGapTranscriptToken,
               source.commandToken != lifecycleGapTranscriptToken {
                return false
            }
            let lifecycleContextMatches = await sharedDocumentContextMatches(
                sourceCommandToken: source.commandToken
            )
            if isLocallyBlocked || isDurablyBlocked || !lifecycleContextMatches {
                // UITextDocumentProxy exposes only a bounded context window,
                // so a source blocked by an unexpected keyboard disappearance
                // must never be replayed. For an intentional containing-app
                // handoff, the durable command fingerprint is the proof that
                // the same field is still active.
                let message = "The text field could not be verified after the keyboard restarted. Try again."
                guard await failSharedDelivery(
                    sourceCommandToken: source.commandToken,
                    transcriptToken: pendingDelivery?.transcriptToken ?? latestTranscript.token,
                    message: message
                ) else { return false }
                blockedLifecycleTranscriptTokens.remove(source.commandToken)
                _ = await sessionStoreCall {
                    $0.clearKeyboardTranscriptBlock(token: source.commandToken)
                }
                guard isCurrentDelivery() else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                        .recognitionFailed(message)
                    )),
                    announce: true
                )
                return true
            }
            hasSharedDeliveryLifecycleGap = false
            lifecycleGapSessionID = nil
            lifecycleGapTranscriptToken = nil
        } else if isLocallyBlocked || isDurablyBlocked {
            let message = "The text field could not be verified after the keyboard restarted. Try again."
            guard await failSharedDelivery(
                sourceCommandToken: source.commandToken,
                transcriptToken: pendingDelivery?.transcriptToken ?? latestTranscript.token,
                message: message
            ) else { return false }
            blockedLifecycleTranscriptTokens.remove(source.commandToken)
            _ = await sessionStoreCall {
                $0.clearKeyboardTranscriptBlock(token: source.commandToken)
            }
            guard isCurrentDelivery() else { return false }
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                    .recognitionFailed(message)
                )),
                announce: true
            )
            return true
        }
        if let candidate = pendingDelivery,
           candidate.transcriptToken != latestTranscript.token {
            // A session can retain a journal for an older transcript when a
            // containing-app restart publishes a newer completion. Never use
            // the old operation list with the new transcript. Only its owner
            // may discard it while it is still leased; otherwise wait for
            // that delivery to finish instead of stealing its journal.
            guard candidate.ownerID == nil
                || candidate.ownerID == sharedDeliveryOwnerID
                || !candidate.mutationInFlight else {
                return false
            }
            guard await transcriptStoreCall({
                $0.discardPendingDelivery(
                    transcriptToken: candidate.transcriptToken,
                    ownerID: deliveryOwnerID
                )
            }) == true else {
                return false
            }
            guard isCurrentDelivery() else { return false }
            pendingDelivery = nil
        }
        if let pendingDelivery,
           !pendingDelivery.operations.isEmpty {
            let expectedPlanDigest = SharedDictationTranscriptDelivery.makePlanDigest(
                transcript: latestTranscript,
                localeIdentifier: locale.identifier,
                beforeContext: pendingDelivery.beforeContext,
                afterContext: pendingDelivery.afterContext,
                operations: pendingDelivery.operations,
                stepContexts: pendingDelivery.stepContexts
            )
            guard pendingDelivery.planDigest == expectedPlanDigest else {
                guard await failSharedDelivery(
                    sourceCommandToken: source.commandToken,
                    transcriptToken: pendingDelivery.transcriptToken,
                    message: "Shared dictation delivery did not match the transcript plan. Try the dictation again."
                ) else { return false }
                guard isCurrentDelivery() else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                return true
            }
        }
        var pendingTranscript: SharedDictationTranscript?
        var pendingStartIndex = 0
        if var pendingDelivery,
           pendingDelivery.transcriptToken == latestTranscript.token {
            if pendingDelivery.isQuarantined {
                guard await sessionStoreCall({
                    $0.saveDeliveryFailure(
                        token: source.commandToken,
                        message: "Shared text delivery was quarantined after an ambiguous host edit. Try the dictation again."
                    )
                }) == true else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                        .recognitionFailed("Shared text delivery was quarantined after an ambiguous host edit. Try the dictation again.")
                    )),
                    announce: true
                )
                return true
            }
            if pendingDelivery.mutationInFlight {
                // The previous owner may have reached UITextDocumentProxy and
                // died before persisting progress. First try the durable
                // final-context proof; only an unprovable mutation is
                // quarantined and reported as a failure.
                let pendingTranscriptToken = pendingDelivery.transcriptToken
                let reconciliation = await transcriptStoreCall({
                    $0.reconcileDelivered(
                        transcriptToken: pendingTranscriptToken,
                        ownerID: deliveryOwnerID,
                        observedContext: currentContextFingerprint
                    )
                }) ?? .failed
                var didReconcileForResume = false
                switch reconciliation {
                case .completed:
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    return true
                case .progressed:
                    if case let .found(updatedDelivery) = await transcriptStoreCall({
                        $0.pendingDeliveryResolution(forCommandToken: source.commandToken)
                    }) ?? .unavailable,
                       !updatedDelivery.mutationInFlight {
                        pendingDelivery = updatedDelivery
                        pendingStartIndex = updatedDelivery.appliedOperationCount
                        pendingTranscript = await transcriptStoreCall {
                            $0.resumePendingDelivery(
                                forSessionID: source.sessionID,
                                ownerID: deliveryOwnerID
                            )
                        } ?? nil
                        didReconcileForResume = pendingTranscript != nil
                    }
                case .failed:
                    break
                }
                if !didReconcileForResume {
                    guard await failSharedDelivery(
                        sourceCommandToken: source.commandToken,
                        transcriptToken: pendingDelivery.transcriptToken,
                        message: "Shared text delivery stopped during an ambiguous host edit. Try the dictation again."
                    ) else { return false }
                    guard isCurrentDelivery() else { return false }
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    keyboardRootView.render(
                        speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                            .recognitionFailed("Shared text delivery stopped during an ambiguous host edit. Try the dictation again.")
                        )),
                        announce: true
                    )
                    return true
                }
                // The refreshed journal is now resumable. The remainder of
                // this recovery block validates its checkpoint and continues
                // with the unapplied operations.
            }
            if (hasSharedDeliveryLifecycleGap || pendingDelivery.ownerID != sharedDeliveryOwnerID),
               !pendingDelivery.beforeContext.hasStableMutationIdentity {
                // A recreated keyboard cannot distinguish two identical
                // fields when the host omitted documentIdentifier. Never
                // replay a destructive or duplicate insertion into an
                // ambiguous field; fail this handoff and require a fresh
                // dictation from the user.
                guard await failSharedDelivery(
                    sourceCommandToken: source.commandToken,
                    transcriptToken: pendingDelivery.transcriptToken,
                    message: "The text field could not be verified after the keyboard restarted. Try again."
                ) else { return false }
                guard isCurrentDelivery() else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                        .recognitionFailed("The text field could not be verified after the keyboard restarted. Try again.")
                    )),
                    announce: true
                )
                return true
            }
            if pendingDelivery.operations.isEmpty {
                // Legacy journals did not persist an operation plan. The
                // transcript must still be tied to the exact text context
                // captured before recording; documentIdentifier alone does
                // not prove that the caret or selection is unchanged.
                guard pendingDelivery.beforeContext.matches(
                    beforeInput: beforeInput,
                    afterInput: afterInput,
                    documentIdentifier: documentIdentifier,
                    selectedText: selectedText
                ) else {
                    guard await failSharedDelivery(
                        sourceCommandToken: source.commandToken,
                        transcriptToken: pendingDelivery.transcriptToken,
                        message: "The text field changed before shared dictation could be delivered. Try again."
                    ) else { return false }
                    guard isCurrentDelivery() else { return false }
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    keyboardRootView.render(
                        speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                            .recognitionFailed("The text field changed before shared dictation could be delivered. Try again.")
                        )),
                        announce: true
                    )
                    return true
                }
                pendingTranscript = await transcriptStoreCall {
                    $0.resumePendingDelivery(
                        forSessionID: source.sessionID,
                        ownerID: deliveryOwnerID
                    )
                } ?? nil
            } else {
                let appliedOperationCount = pendingDelivery.appliedOperationCount
                let recoveryContext = pendingDelivery.checkpointContext
                    ?? (appliedOperationCount < pendingDelivery.stepContexts.count
                        ? pendingDelivery.stepContexts[appliedOperationCount]
                        : nil)
                guard appliedOperationCount <= pendingDelivery.operations.count,
                      recoveryContext?.matches(
                          beforeInput: beforeInput,
                          afterInput: afterInput,
                          documentIdentifier: documentIdentifier,
                          selectedText: selectedText
                      ) == true else {
                    guard await failSharedDelivery(
                        sourceCommandToken: source.commandToken,
                        transcriptToken: pendingDelivery.transcriptToken,
                        message: "The text field changed while shared text was being delivered. Try again."
                    ) else { return false }
                    guard isCurrentDelivery() else { return false }
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    keyboardRootView.render(
                        speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                            .recognitionFailed("The text field changed while shared text was being delivered. Try again.")
                        )),
                        announce: true
                    )
                    return true
                }
                if appliedOperationCount == pendingDelivery.operations.count {
                    let completedTranscriptToken = pendingDelivery.transcriptToken
                    guard await transcriptStoreCall({
                        $0.markDelivered(
                            transcriptToken: completedTranscriptToken,
                            ownerID: deliveryOwnerID,
                        )
                    }) == true else {
                        return false
                    }
                    guard isCurrentDelivery() else { return false }
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    return true
                }
                pendingStartIndex = appliedOperationCount
                pendingTranscript = await transcriptStoreCall {
                    $0.resumePendingDelivery(
                        forSessionID: source.sessionID,
                        ownerID: deliveryOwnerID
                    )
                } ?? nil
            }
        }
        let contextMatches = await sharedDocumentContextMatches(sourceCommandToken: source.commandToken)
        guard isCurrentDelivery() else { return false }
        guard pendingTranscript != nil || contextMatches else {
            guard await failSharedDelivery(
                sourceCommandToken: source.commandToken,
                transcriptToken: nil,
                message: "The text field changed while shared dictation was active. Try again."
            ) else { return false }
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                    .recognitionFailed("The text field changed while shared dictation was active.")
                )),
                announce: true
            )
            return true
        }

        var plannedOperations: [TextOperation]
        if let pendingDelivery,
           !pendingDelivery.operations.isEmpty {
            let decodedOperations = pendingDelivery.operations.map(TextOperation.init(deliveryOperation:))
            guard !decodedOperations.contains(where: { $0 == nil }),
                  let restoredOperations = expandSharedOperations(decodedOperations.compactMap({ $0 })) else {
                guard await failSharedDelivery(
                    sourceCommandToken: source.commandToken,
                    transcriptToken: pendingDelivery.transcriptToken,
                    message: "Shared dictation contained too many editing operations. Try a shorter phrase."
                ) else { return false }
                guard isCurrentDelivery() else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                return true
            }
            plannedOperations = restoredOperations
        } else {
            guard VoiceKeyboardTextLimits.isValid(latestTranscript.text),
                  let generatedOperations = VoiceInputPipeline(locale: locale).boundedOperations(
                      for: latestTranscript.text,
                      documentContextBeforeInput: beforeInput,
                      maximumOperationCount: SharedDictationTranscriptDelivery.maximumOperationCount
                  ).flatMap(expandSharedOperations) else {
                guard await failSharedDelivery(
                    sourceCommandToken: source.commandToken,
                    transcriptToken: nil,
                    message: "Shared dictation contained too many editing operations. Try a shorter phrase."
                ) else { return false }
                guard isCurrentDelivery() else { return false }
                endSharedSession(
                    ifMatchingSessionID: source.sessionID,
                    commandToken: command.token,
                    pollingGeneration: deliveryPollingGeneration
                )
                return true
            }
            plannedOperations = generatedOperations
        }
        if plannedOperations.isEmpty {
            // A command such as "command delete word" at the beginning of
            // an empty field is a valid no-op. Persist a visible feedback
            // operation so the transcript can still be delivered exactly
            // once instead of leaving an empty journal that markDelivered
            // cannot finalize.
            plannedOperations = [.showUnsupportedCommand("Nothing to delete")]
        }
        let operations = plannedOperations
        guard operations.count <= SharedDictationTranscriptDelivery.maximumOperationCount else {
            guard await failSharedDelivery(
                sourceCommandToken: source.commandToken,
                transcriptToken: pendingDelivery?.transcriptToken,
                message: "Shared dictation contained too many editing operations. Try a shorter phrase."
            ) else { return false }
            guard isCurrentDelivery() else { return false }
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            return true
        }
        guard textDocumentProxy.selectedText == nil || !operations.contains(where: {
            if case .deleteBackward = $0 { return true }
            return false
        }) else {
            guard await failSharedDelivery(
                sourceCommandToken: source.commandToken,
                transcriptToken: pendingDelivery?.transcriptToken,
                message: "Delete commands are unavailable while text is selected."
            ) else { return false }
            guard isCurrentDelivery() else { return false }
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(
                    "Delete commands are unavailable while text is selected."
                )),
                announce: true
            )
            return true
        }
        let beforeContextFingerprint = pendingDelivery?.beforeContext ?? currentContextFingerprint
        let storedStepContexts = pendingDelivery?.stepContexts ?? []
        let stepContexts: [SharedDictationDocumentContextFingerprint]
        if storedStepContexts.count == operations.count + 1 {
            stepContexts = storedStepContexts
        } else {
            stepContexts = deliveryStepContexts(
                for: operations,
                startingFrom: beforeInput,
                afterInput: afterInput,
                documentIdentifier: documentIdentifier,
                selectedText: selectedText
            )
        }
        let expectedAfterContextFingerprint = stepContexts.last ?? currentContextFingerprint
        guard isCurrentDelivery() else { return false }
        let lastConsumedToken = await transcriptStoreCall { $0.lastConsumedToken() } ?? nil
        let claimedTranscript = await transcriptStoreCall {
            $0.claimLatestTranscript(
                forSessionID: source.sessionID,
                afterLastConsumedToken: lastConsumedToken
            )
        } ?? nil
        guard isCurrentDelivery() else { return false }
        guard let transcript = pendingTranscript ?? claimedTranscript else {
            return false
        }
        // Older at-most-once journals have no operation plan. Once the
        // transcript is available, upgrade that durable record before any
        // proxy mutation so a restart cannot fall back to an empty-success
        // delivery path.
        if pendingTranscript == nil || pendingDelivery?.operations.isEmpty == true {
            guard await transcriptStoreCall({
                $0.beginDelivery(
                    transcript,
                    beforeContext: beforeContextFingerprint,
                    afterContext: expectedAfterContextFingerprint,
                    operations: operations.map(SharedDictationTranscriptDelivery.Operation.init),
                    stepContexts: stepContexts,
                    localeIdentifier: locale.identifier,
                    ownerID: deliveryOwnerID
                )
            }) == true else { return false }
        }
        guard await applySharedOperations(
            operations,
            from: pendingStartIndex,
            transcriptToken: transcript.token,
            expectedStepContexts: stepContexts,
            epoch: epoch ?? lifecycleEpoch,
            pollingGeneration: deliveryPollingGeneration,
            sessionID: source.sessionID,
            commandToken: command.token,
            startingContext: pendingDelivery?.checkpointContext,
            expectedMutationGeneration: expectedMutationGeneration
        ) else { return false }
        let expectedAfterInput = expectedDocumentContextBeforeInput(
            after: Array(operations.dropFirst(pendingStartIndex)),
            startingFrom: beforeInput
        )
        if !expectedAfterContextFingerprint.matches(
            beforeInput: textDocumentProxy.documentContextBeforeInput,
            afterInput: textDocumentProxy.documentContextAfterInput,
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectedText: textDocumentProxy.selectedText
        ) && !hostContextMatchesExpected(
            expectedBeforeInput: expectedAfterInput,
            actualBeforeInput: textDocumentProxy.documentContextBeforeInput,
            expectedAfterInput: afterInput,
            actualAfterInput: textDocumentProxy.documentContextAfterInput,
            expectedDocumentIdentifier: documentIdentifier,
            actualDocumentIdentifier: textDocumentProxy.documentIdentifier,
            actualSelectedText: textDocumentProxy.selectedText,
            startingBeforeInput: beforeInput
        ) {
            // Leave the journal pending so a later keyboard instance never
            // replays an ambiguous destructive edit.
            endSharedSession(
                ifMatchingSessionID: source.sessionID,
                commandToken: command.token,
                pollingGeneration: deliveryPollingGeneration
            )
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.recognitionFailed(
                    .recognitionFailed("Shared text was delivered, but the host changed the text field immediately afterward.")
                )),
                announce: true
            )
            return true
        }
        guard await transcriptStoreCall({
            $0.markDelivered(
                transcriptToken: transcript.token,
                ownerID: deliveryOwnerID
            )
        }) == true else {
            return false
        }
        guard isCurrentDelivery() else { return false }
        endSharedSession(
            ifMatchingSessionID: source.sessionID,
            commandToken: command.token,
            pollingGeneration: deliveryPollingGeneration
        )
        return true
    }

    private func endSharedSession(
        ifMatchingSessionID sessionID: String? = nil,
        commandToken: String? = nil,
        pollingGeneration: UInt64? = nil
    ) {
        if let sessionID, activeSharedSessionID != sessionID {
            return
        }
        if let commandToken, activeSharedCommandToken != commandToken {
            return
        }
        if let pollingGeneration, sharedPollingGeneration != pollingGeneration {
            return
        }
        if hasSharedDeliveryLifecycleGap,
           let beforeInput = sharedSessionDocumentContext,
           let documentIdentifier = sharedSessionDocumentIdentifier {
            sharedSessionDeliveryFingerprint = SharedDictationDocumentContextFingerprint(
                beforeInput: beforeInput,
                afterInput: sharedSessionDocumentContextAfterInput,
                documentIdentifier: documentIdentifier,
                selectedText: sharedSessionSelectedText
            )
        }
        activeSharedSessionID = nil
        activeSharedCommandToken = nil
        activeSharedTranscriptToken = nil
        sharedSessionDocumentContext = nil
        sharedSessionDocumentContextAfterInput = nil
        sharedSessionDocumentIdentifier = nil
        sharedSessionSelectedText = nil
        sharedSessionDocumentMutationGeneration = nil
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
    }

    private func sharedDocumentContextMatches(
        sourceCommandToken: String
    ) async -> Bool {
        if hasSharedDeliveryLifecycleGap {
            if let documentIdentifier = sharedSessionDocumentIdentifier {
                guard documentIdentifier == textDocumentProxy.documentIdentifier else {
                    return false
                }
            } else {
                guard let fingerprint = sharedSessionDeliveryFingerprint,
                      fingerprint.matches(
                          beforeInput: textDocumentProxy.documentContextBeforeInput,
                          afterInput: textDocumentProxy.documentContextAfterInput,
                          documentIdentifier: textDocumentProxy.documentIdentifier,
                          selectedText: textDocumentProxy.selectedText
                      ) else {
                    return false
                }
            }
        }
        guard currentDocumentContextFingerprint().hasStableMutationIdentity else {
            // A secure or otherwise private host may return nil for every
            // context field. DocumentIdentifier alone cannot prove that the
            // caret has not moved, so do not deliver into an unverified field.
            return false
        }
        if let expectedDocumentContext = sharedSessionDocumentContext {
            return expectedDocumentContext == textDocumentProxy.documentContextBeforeInput
                && sharedSessionDocumentContextAfterInput == textDocumentProxy.documentContextAfterInput
                && sharedSessionDocumentIdentifier == textDocumentProxy.documentIdentifier
                && sharedSessionSelectedText == textDocumentProxy.selectedText
                && sharedSessionDocumentMutationGeneration == documentMutationGeneration
        }
        guard let fingerprint = await sessionStoreCall({ store in
            store.command(forToken: sourceCommandToken)?.documentContextFingerprint
        }) ?? nil else {
            return false
        }
        guard fingerprint.hasDocumentIdentifier else {
            // A context window without a stable field identity is not enough
            // to prove that a recreated keyboard is still attached to the
            // original host field. Do not replay a shared edit there.
            return false
        }
        return fingerprint.matches(
            beforeInput: textDocumentProxy.documentContextBeforeInput,
            afterInput: textDocumentProxy.documentContextAfterInput,
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectedText: textDocumentProxy.selectedText
        )
    }

    private func noteExternalDocumentMutation() {
        guard !isApplyingProxyMutation else { return }
        if !isRecognitionActive,
           let expectedSelfMutationContext,
           expectedSelfMutationContext.hasStableMutationIdentity,
           expectedSelfMutationCallbacksDeadline.map({ $0 >= Date() }) == true,
           expectedSelfMutationContext.matches(
               beforeInput: textDocumentProxy.documentContextBeforeInput,
               afterInput: textDocumentProxy.documentContextAfterInput,
               documentIdentifier: textDocumentProxy.documentIdentifier,
               selectedText: textDocumentProxy.selectedText
           ) {
            expectedSelfMutationCallbacksRemaining = max(0, expectedSelfMutationCallbacksRemaining - 1)
            if expectedSelfMutationCallbacksRemaining == 0 {
                self.expectedSelfMutationContext = nil
                self.expectedSelfMutationCallbacksDeadline = nil
            }
            return
        }
        expectedSelfMutationContext = nil
        expectedSelfMutationCallbacksRemaining = 0
        expectedSelfMutationCallbacksDeadline = nil
        documentMutationGeneration &+= 1
        if isRecognitionActive {
            cancelDirectRecognition()
            renderCurrentSpeechCapture()
        }
    }

    private func currentDocumentContextFingerprint() -> SharedDictationDocumentContextFingerprint {
        SharedDictationDocumentContextFingerprint(
            beforeInput: textDocumentProxy.documentContextBeforeInput,
            afterInput: textDocumentProxy.documentContextAfterInput,
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectedText: textDocumentProxy.selectedText
        )
    }

    @discardableResult
    private func applySharedOperations(
        _ operations: [TextOperation],
        from startIndex: Int,
        transcriptToken: String,
        expectedStepContexts: [SharedDictationDocumentContextFingerprint],
        epoch: UInt64,
        pollingGeneration: UInt64,
        sessionID: String,
        commandToken: String,
        startingContext: SharedDictationDocumentContextFingerprint? = nil,
        expectedMutationGeneration: UInt64
    ) async -> Bool {
        let deliveryOwnerID = sharedDeliveryOwnerID
        guard isSharedDeliveryCurrent(
            epoch,
            pollingGeneration: pollingGeneration,
            sessionID: sessionID,
            commandToken: commandToken
        ) else { return false }
        guard documentMutationGeneration == expectedMutationGeneration else { return false }
        if textDocumentProxy.selectedText != nil,
           operations.contains(where: {
               if case .deleteBackward = $0 { return true }
               return false
           }) {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(
                    "Delete commands are unavailable while text is selected."
                )),
                announce: true
            )
            return false
        }
        var unsupportedCommand: String?
        var insertedText = ""
        var didEditDocument = false
        var expectedContext = startingContext
            ?? (startIndex < expectedStepContexts.count
                ? expectedStepContexts[startIndex]
            : SharedDictationDocumentContextFingerprint(
                beforeInput: textDocumentProxy.documentContextBeforeInput,
                afterInput: textDocumentProxy.documentContextAfterInput,
                documentIdentifier: textDocumentProxy.documentIdentifier,
                selectedText: textDocumentProxy.selectedText
            ))
        for (index, operation) in operations.enumerated() where index >= startIndex {
            guard isSharedDeliveryCurrent(
                epoch,
                pollingGeneration: pollingGeneration,
                sessionID: sessionID,
                commandToken: commandToken
            ) else { return false }
            guard documentMutationGeneration == expectedMutationGeneration else { return false }
            guard expectedContext.matches(
                beforeInput: textDocumentProxy.documentContextBeforeInput,
                afterInput: textDocumentProxy.documentContextAfterInput,
                documentIdentifier: textDocumentProxy.documentIdentifier,
                selectedText: textDocumentProxy.selectedText
            ) else {
                return false
            }
            guard await transcriptStoreCall({
                $0.renewDeliveryLease(
                    transcriptToken: transcriptToken,
                    ownerID: deliveryOwnerID
                )
            }) == true else {
                return false
            }
            guard documentMutationGeneration == expectedMutationGeneration else { return false }
            guard isSharedDeliveryCurrent(
                epoch,
                pollingGeneration: pollingGeneration,
                sessionID: sessionID,
                commandToken: commandToken
            ) else { return false }
            // Storage renewal can block while the host app changes focus.
            // Re-read the proxy after the I/O and immediately before the
            // mutation so a stale lease cannot target a different field.
            guard expectedContext.matches(
                beforeInput: textDocumentProxy.documentContextBeforeInput,
                afterInput: textDocumentProxy.documentContextAfterInput,
                documentIdentifier: textDocumentProxy.documentIdentifier,
                selectedText: textDocumentProxy.selectedText
            ) else {
                return false
            }
            let hostMutationIsRequired: Bool
            switch operation {
            case .insertText, .deleteBackward:
                hostMutationIsRequired = true
            case .showUnsupportedCommand:
                hostMutationIsRequired = false
            }
            if hostMutationIsRequired {
                guard await transcriptStoreCall({
                    $0.beginDeliveryMutation(
                        transcriptToken: transcriptToken,
                        operationIndex: index,
                        ownerID: deliveryOwnerID
                    )
                }) == true else {
                    return false
                }
                guard documentMutationGeneration == expectedMutationGeneration else {
                    _ = await transcriptStoreCall {
                        $0.abortDeliveryMutation(
                            transcriptToken: transcriptToken,
                            operationIndex: index,
                            ownerID: deliveryOwnerID
                        )
                    }
                    return false
                }
                guard isSharedDeliveryCurrent(
                    epoch,
                    pollingGeneration: pollingGeneration,
                    sessionID: sessionID,
                    commandToken: commandToken
                ) else {
                    _ = await transcriptStoreCall {
                        $0.abortDeliveryMutation(
                            transcriptToken: transcriptToken,
                            operationIndex: index,
                            ownerID: deliveryOwnerID
                        )
                    }
                    return false
                }
                guard expectedContext.matches(
                    beforeInput: textDocumentProxy.documentContextBeforeInput,
                    afterInput: textDocumentProxy.documentContextAfterInput,
                    documentIdentifier: textDocumentProxy.documentIdentifier,
                    selectedText: textDocumentProxy.selectedText
                ) else {
                    _ = await transcriptStoreCall {
                        $0.abortDeliveryMutation(
                            transcriptToken: transcriptToken,
                            operationIndex: index,
                            ownerID: deliveryOwnerID
                        )
                    }
                    return false
                }
            }
            guard documentMutationGeneration == expectedMutationGeneration else { return false }
            switch operation {
            case .insertText(let value):
                guard isSharedDeliveryCurrent(
                    epoch,
                    pollingGeneration: pollingGeneration,
                    sessionID: sessionID,
                    commandToken: commandToken
                ) else {
                    if hostMutationIsRequired {
                        _ = await transcriptStoreCall {
                            $0.abortDeliveryMutation(
                                transcriptToken: transcriptToken,
                                operationIndex: index,
                                ownerID: deliveryOwnerID
                            )
                        }
                    }
                    return false
                }
                isApplyingProxyMutation = true
                textDocumentProxy.insertText(value)
                isApplyingProxyMutation = false
                insertedText.append(value)
                didEditDocument = true
            case .deleteBackward(let count):
                guard textDocumentProxy.selectedText == nil else {
                    if hostMutationIsRequired {
                        _ = await transcriptStoreCall {
                            $0.abortDeliveryMutation(
                                transcriptToken: transcriptToken,
                                operationIndex: index,
                                ownerID: deliveryOwnerID
                            )
                        }
                    }
                    return false
                }
                guard isSharedDeliveryCurrent(
                    epoch,
                    pollingGeneration: pollingGeneration,
                    sessionID: sessionID,
                    commandToken: commandToken
                ) else {
                    if hostMutationIsRequired {
                        _ = await transcriptStoreCall {
                            $0.abortDeliveryMutation(
                                transcriptToken: transcriptToken,
                                operationIndex: index,
                                ownerID: deliveryOwnerID
                            )
                        }
                    }
                    return false
                }
                do {
                    isApplyingProxyMutation = true
                    defer { isApplyingProxyMutation = false }
                    for _ in 0..<count.value {
                        guard isSharedDeliveryCurrent(
                            epoch,
                            pollingGeneration: pollingGeneration,
                            sessionID: sessionID,
                            commandToken: commandToken
                        ) else { return false }
                        textDocumentProxy.deleteBackward()
                    }
                }
                didEditDocument = true
            case .showUnsupportedCommand(let phrase):
                unsupportedCommand = unsupportedCommand ?? phrase
            }
            let observedContext = SharedDictationDocumentContextFingerprint(
                beforeInput: textDocumentProxy.documentContextBeforeInput,
                afterInput: textDocumentProxy.documentContextAfterInput,
                documentIdentifier: textDocumentProxy.documentIdentifier,
                selectedText: textDocumentProxy.selectedText
            )
            if hostMutationIsRequired {
                expectSelfMutationCallbacks(for: observedContext)
            }
            guard await transcriptStoreCall({
                $0.markDeliveryProgress(
                    transcriptToken: transcriptToken,
                    appliedOperationCount: index + 1,
                    ownerID: deliveryOwnerID,
                    observedContext: observedContext
                )
            }) == true else {
                // The host mutation may already have happened, so leave the
                // journal intact and stop immediately. A recreated keyboard
                // can reconcile the resulting step context without applying
                // later operations under a lost lease.
                return false
            }
            guard isSharedDeliveryCurrent(
                epoch,
                pollingGeneration: pollingGeneration,
                sessionID: sessionID,
                commandToken: commandToken
            ) else { return false }
            // Use the host's actual post-mutation window as the next
            // checkpoint. UITextDocumentProxy may drop the oldest prefix as
            // inserted text grows; the durable checkpoint lets recovery
            // continue without treating that normal truncation as a field
            // switch.
            expectedContext = observedContext
        }

        if let unsupportedCommand {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(unsupportedCommand)),
                announce: true
            )
        } else if didEditDocument {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(
                    .inserted(insertedText.isEmpty ? "Text edited" : insertedText)
                ),
                announce: true
            )
        } else {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.listening),
                announce: true
            )
        }
        return true
    }

    private func isSharedDeliveryCurrent(
        _ epoch: UInt64?,
        pollingGeneration: UInt64? = nil,
        sessionID: String? = nil,
        commandToken: String? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              !isRecognitionActive,
              !isSharedCancellationInProgress,
              !isSharedStorageResolutionUnknown,
              isViewVisible else { return false }
        if let epoch, lifecycleEpoch != epoch { return false }
        if let pollingGeneration, sharedPollingGeneration != pollingGeneration { return false }
        if let sessionID, activeSharedSessionID != sessionID { return false }
        if let commandToken, activeSharedCommandToken != commandToken { return false }
        return true
    }

    private func expectSelfMutationCallbacks(
        for context: SharedDictationDocumentContextFingerprint
    ) {
        guard context.hasStableMutationIdentity else {
            expectedSelfMutationContext = nil
            expectedSelfMutationCallbacksRemaining = 0
            expectedSelfMutationCallbacksDeadline = nil
            return
        }
        expectedSelfMutationContext = context
        expectedSelfMutationCallbacksRemaining = 4
        expectedSelfMutationCallbacksDeadline = Date().addingTimeInterval(0.25)
    }

    private func failSharedDelivery(
        sourceCommandToken: String,
        transcriptToken: String?,
        message: String
    ) async -> Bool {
        let deliveryOwnerID = sharedDeliveryOwnerID
        guard await sessionStoreCall({
            $0.recordDeliveryFailureIntent(
                token: sourceCommandToken,
                message: message
            )
        }) == true else {
            return false
        }
        var canWriteFailure = true
        if let transcriptToken {
            let didQuarantine = await transcriptStoreCall {
                $0.quarantinePendingDelivery(
                    transcriptToken: transcriptToken,
                    ownerID: deliveryOwnerID
                )
            } == true
            if !didQuarantine {
                canWriteFailure = await transcriptStoreCall {
                    $0.discardPendingDelivery(
                        transcriptToken: transcriptToken,
                        ownerID: deliveryOwnerID
                    )
                } == true
                if !canWriteFailure,
                   case .missing = await transcriptStoreCall({
                       $0.pendingDeliveryResolution(forCommandToken: sourceCommandToken)
                   }) ?? .unavailable {
                    // A transcript can become visible before its delivery
                    // journal is created. There is no host mutation to
                    // reconcile in that state; redact the transcript and
                    // persist the terminal failure fence instead of leaving
                    // recovery stuck forever.
                    canWriteFailure = await transcriptStoreCall {
                        $0.markConsumed(token: transcriptToken)
                    } == true
                }
            }
        }
        guard canWriteFailure else {
            // A different live delivery owner may still be inside a host edit.
            // Do not publish a failed status that contradicts its journal.
            return false
        }
        return await sessionStoreCall {
            $0.saveDeliveryFailure(token: sourceCommandToken, message: message)
        } == true
    }

    private func deliveryStepContexts(
        for operations: [TextOperation],
        startingFrom context: String?,
        afterInput: String?,
        documentIdentifier: UUID?,
        selectedText: String?
    ) -> [SharedDictationDocumentContextFingerprint] {
        var virtualContext = context
        var virtualSelectedText = selectedText
        var result = [SharedDictationDocumentContextFingerprint(
            beforeInput: virtualContext,
            afterInput: afterInput,
            documentIdentifier: documentIdentifier,
            selectedText: selectedText
        )]
        for operation in operations {
            switch operation {
            case .insertText(let value):
                virtualContext = virtualContext.map { $0 + value }
                virtualSelectedText = nil
            case .deleteBackward(let count):
                virtualContext = virtualContext.map {
                    String($0.dropLast(min(count.value, $0.count)))
                }
                virtualSelectedText = nil
            case .showUnsupportedCommand:
                break
            }
            result.append(SharedDictationDocumentContextFingerprint(
                beforeInput: virtualContext,
                afterInput: afterInput,
                documentIdentifier: documentIdentifier,
                selectedText: virtualSelectedText
            ))
        }
        return result
    }

    private func expectedDocumentContextBeforeInput(
        after operations: [TextOperation],
        startingFrom context: String?
    ) -> String? {
        var virtualContext = context
        for operation in operations {
            switch operation {
            case .insertText(let value):
                virtualContext = virtualContext.map { $0 + value }
            case .deleteBackward(let count):
                virtualContext = virtualContext.map {
                    String($0.dropLast(min(count.value, $0.count)))
                }
            case .showUnsupportedCommand:
                break
            }
        }
        return virtualContext
    }

    private func expandSharedOperations(_ operations: [TextOperation]) -> [TextOperation]? {
        guard operations.count <= SharedDictationTranscriptDelivery.maximumOperationCount else {
            return nil
        }
        guard operations.allSatisfy({ operation in
            if case let .deleteBackward(count) = operation {
                return count.value <= TextDeletionCount.maximumValue
            }
            return true
        }) else {
            return nil
        }
        let totalDeletionCount = operations.reduce(into: 0) { total, operation in
            if case let .deleteBackward(count) = operation {
                total += count.value
            }
        }
        guard totalDeletionCount <= SharedDictationTranscriptDelivery.maximumTotalDeletionCount else {
            return nil
        }
        // Keep a multi-character deletion as one journal operation. The host
        // proxy still performs the bounded per-character calls, but the
        // durable journal checkpoints the whole non-transactional mutation
        // without overflowing its operation budget.
        return operations
    }

    private static let sharedTranscriptRecoveryRetention: TimeInterval = 360

    private func hostContextMatchesExpected(
        expectedBeforeInput: String?,
        actualBeforeInput: String?,
        expectedAfterInput: String?,
        actualAfterInput: String?,
        expectedDocumentIdentifier: UUID?,
        actualDocumentIdentifier: UUID?,
        actualSelectedText: String?,
        startingBeforeInput: String?
    ) -> Bool {
        guard expectedAfterInput == actualAfterInput,
              expectedDocumentIdentifier == actualDocumentIdentifier,
              actualSelectedText == nil else { return false }
        guard let expectedBeforeInput, let actualBeforeInput else {
            return expectedBeforeInput == actualBeforeInput
        }
        guard expectedBeforeInput != actualBeforeInput else { return true }
        // A bounded context is useful evidence only when it changed from the
        // pre-operation window and became shorter than the expected result.
        // This avoids accepting an unchanged "abc" as proof that inserting
        // another "abc" succeeded merely because it is a suffix.
        guard let startingBeforeInput,
              actualBeforeInput != startingBeforeInput,
              expectedBeforeInput.count > actualBeforeInput.count else {
            return false
        }
        return expectedBeforeInput.hasSuffix(actualBeforeInput)
    }

    private func matchingReadyStartCommand(epoch: UInt64? = nil) async -> SharedDictationSessionCommand? {
        guard let command = await matchingActiveStartCommand(epoch: epoch),
              isSharedDeliveryCurrent(epoch),
              let source = transcriptSource(for: command) else { return nil }
        guard let status = await sessionStoreCall({
            $0.status(forCommandToken: source.commandToken)
        }),
              case .transcriptReady = status else { return nil }
        return command
    }

    private func commandMatchesCurrentDocument(
        _ command: SharedDictationSessionCommand,
        commands: [SharedDictationSessionCommand]
    ) -> Bool {
        let expectedFingerprint: SharedDictationDocumentContextFingerprint?
        switch command.kind {
        case .start:
            expectedFingerprint = command.documentContextFingerprint
        case .stop:
            expectedFingerprint = command.replacesCommandToken.flatMap { token in
                commands.first { $0.token == token }?.documentContextFingerprint
            }
        case .cancel:
            expectedFingerprint = nil
        }
        guard let expectedFingerprint,
              expectedFingerprint.hasStableMutationIdentity else {
            return false
        }
        return expectedFingerprint.matches(currentDocumentContextFingerprint())
    }

    private func matchingActiveStartCommand(epoch: UInt64? = nil) async -> SharedDictationSessionCommand? {
        guard isSharedDeliveryCurrent(epoch) else { return nil }
        guard let historyResolution = await sessionStoreCall({ $0.commandHistoryResolution() }),
              case .available(let commands) = historyResolution else {
            isSharedStorageResolutionUnknown = true
            scheduleSharedDeliveryRecoveryRetry(epoch: epoch ?? lifecycleEpoch)
            return nil
        }
        guard isSharedDeliveryCurrent(epoch) else { return nil }
        var cancelledStartTokens = Set(commands.compactMap { command in
            command.kind == .cancel ? command.replacesCommandToken : nil
        })
        for (index, command) in commands.enumerated()
        where command.kind == .cancel && command.replacesCommandToken == nil {
            if let priorStart = commands[..<index].last(where: {
                $0.kind == .start && $0.sessionID == command.sessionID
            }) {
                cancelledStartTokens.insert(priorStart.token)
            }
        }
        for command in commands.reversed()
        where command.source == .keyboard {
            guard command.kind == .start ||
                    (command.kind == .stop && command.replacesCommandToken != nil) else {
                continue
            }
            if command.kind == .start && cancelledStartTokens.contains(command.token) {
                continue
            }
            guard commandMatchesCurrentDocument(command, commands: commands) else {
                // A global command history can contain a completed session
                // from another host field. Do not terminally consume it here;
                // let the keyboard attached to its durable document identity
                // recover it instead.
                continue
            }
            if await isConsumedSharedTranscript(for: command) {
                continue
            }
            guard isSharedDeliveryCurrent(epoch) else { return nil }
            if command.kind == .stop {
                guard !command.isExpired() else { continue }
                guard isSharedDeliveryCurrent(epoch) else { return nil }
                activeSharedSessionID = command.sessionID
                activeSharedCommandToken = command.token
                activeSharedTranscriptToken = command.replacesCommandToken
                sharedSessionDeliveryFingerprint = command.replacesCommandToken.flatMap { replacedToken in
                    commands.first { $0.token == replacedToken }?.documentContextFingerprint
                }
                return command
            }
            guard let statusResolution = await sessionStoreCall({
                $0.statusResolution(forCommandToken: command.token)
            }) else { continue }
            let status: SharedDictationSessionStatus
            switch statusResolution {
            case .unavailable:
                isSharedStorageResolutionUnknown = true
                scheduleSharedDeliveryRecoveryRetry(epoch: epoch ?? lifecycleEpoch)
                return nil
            case .missing:
                status = .idle
            case .found(let resolvedStatus):
                status = resolvedStatus
            }
            guard isSharedDeliveryCurrent(epoch) else { return nil }
            if case .idle = status {
                guard !command.isExpired() else { continue }
                activeSharedSessionID = command.sessionID
                activeSharedCommandToken = command.token
                activeSharedTranscriptToken = command.token
                sharedSessionDeliveryFingerprint = command.documentContextFingerprint
                return command
            }
            guard status.commandToken == command.token else { continue }
            switch status {
            case .commandPending,
                 .commandAcknowledged,
                 .recording,
                 .transcribing:
                guard !command.isExpired() else { continue }
            case .transcriptReady:
                // The transcript has its own expiry window, checked when it
                // is claimed. Keep polling long enough to insert a valid
                // result even if the original start command has expired.
                break
            case .idle,
                 .failed,
                 .cancelled:
                continue
            }
            guard isSharedDeliveryCurrent(epoch) else { return nil }
            activeSharedSessionID = command.sessionID
            activeSharedCommandToken = command.token
            activeSharedTranscriptToken = command.token
            // A recreated controller may recover the command after the
            // original controller has already cleared its in-memory context.
            // Preserve the durable start fingerprint so the lifecycle-gap
            // check can still prove that the host field is the same one.
            sharedSessionDeliveryFingerprint = command.documentContextFingerprint
            return command
        }
        return nil
    }

    private func isConsumedSharedTranscript(
        for command: SharedDictationSessionCommand
    ) async -> Bool {
        guard let source = transcriptSource(for: command) else {
            return false
        }
        let pendingDeliveryResolution = await transcriptStoreCall {
            $0.pendingDeliveryResolution(forCommandToken: source.commandToken)
        }
        if case .found(let pendingDelivery) = pendingDeliveryResolution,
           pendingDelivery.isQuarantined {
            // A quarantined journal carries a terminal failure that must be
            // retried even though its transcript was marked consumed as a
            // no-replay fence.
            return false
        }
        if case .unavailable = pendingDeliveryResolution { return false }
        guard let transcript = await transcriptStoreCall({
                  $0.latestTranscript(forSessionID: source.sessionID)
              }) ?? nil,
              transcript.commandToken == source.commandToken else {
            return false
        }
        return transcript.isConsumed
    }

    private func transcriptSource(
        for command: SharedDictationSessionCommand
    ) -> (sessionID: String, commandToken: String)? {
        switch command.kind {
        case .start:
            guard command.source == .keyboard else { return nil }
            return (command.sessionID, command.token)
        case .stop:
            guard command.source == .keyboard,
                  let replacesCommandToken = command.replacesCommandToken else {
                return nil
            }
            return (command.sessionID, replacesCommandToken)
        case .cancel:
            return nil
        }
    }

    private func renderSharedDictationUnavailableIfNeeded() {
        scheduleSharedDeliveryRecoveryRetry(epoch: lifecycleEpoch)
        guard !speechCaptureCoordinator.directRecognitionIsReady(hasFullAccess: hasFullAccess) else {
            renderCurrentSpeechCapture()
            return
        }
        keyboardRootView.render(
            speechCapture: .sharedDictationUnavailable,
            announce: true
        )
    }

    private func openContainingAppForDictation(epoch: UInt64) async {
        guard isCurrentInteraction(epoch),
              let command = await startSharedDictationSession(epoch: epoch),
              isCurrentInteraction(epoch) else { return }
        openContainingAppForExistingSession(sessionID: command.sessionID, epoch: epoch)
    }

    private func openContainingAppForExistingSession(sessionID: String, epoch: UInt64? = nil) {
        let epoch = epoch ?? lifecycleEpoch
        isOpeningContainingApp = true
        ExtensionContextContainingAppOpener { [weak self] in
            self?.extensionContext
        }
        .openContainingAppForDictation(sessionID: sessionID) { [weak self] didOpen in
            guard !didOpen else { return }
            Task { @MainActor in
                guard let self, self.lifecycleEpoch == epoch else { return }
                // Keep the handoff intent alive after an URL-opening failure.
                // The user may switch to the containing app manually; the
                // durable document fingerprint remains the final safety gate.
                self.keyboardRootView.render(
                    speechCapture: .containingAppOpenFailed,
                    announce: true
                )
            }
        }
    }

    @objc private func deleteTapped() {
        performDocumentMutationAfterVoiceCancellation(.delete)
    }

    @objc private func returnTapped() {
        performDocumentMutationAfterVoiceCancellation(.returnKey)
    }

    private func performDocumentMutationAfterVoiceCancellation(
        _ kind: PendingDocumentMutation.Kind
    ) {
        microphoneDecisionTask?.cancel()
        microphoneDecisionTask = nil
        isMicrophoneDecisionInFlight = false
        let mutation = PendingDocumentMutation(
            kind: kind,
            expectedContext: currentDocumentContextFingerprint(),
            expectedMutationGeneration: documentMutationGeneration,
            expectedEpoch: lifecycleEpoch
        )
        if isRecognitionActive {
            cancelDirectRecognition()
            renderCurrentSpeechCapture()
        }
        if isSharedCancellationInProgress {
            enqueuePendingDocumentMutation(mutation)
            return
        }
        if isSharedStorageResolutionUnknown
                || activeSharedSessionID != nil
                || activeSharedCommandToken != nil
                || isSharedDeliveryRecoveryInProgress {
            cancelSharedDictationForLifecycleChange(then: mutation)
        } else {
            applyDocumentMutation(mutation)
        }
    }

    private func enqueuePendingDocumentMutation(
        _ mutation: PendingDocumentMutation,
        atFront: Bool = false
    ) {
        // App Group outages can otherwise turn repeated Delete/Return taps
        // into an unbounded extension-resident queue. A Return is a focus
        // boundary, so never retain edits captured after one has already
        // been queued; replaying them against a new field is unsafe.
        guard !queuedDocumentMutations.contains(where: { $0.kind == .returnKey }),
              queuedDocumentMutations.count < Self.maximumQueuedDocumentMutations else {
            return
        }
        if atFront {
            queuedDocumentMutations.insert(mutation, at: 0)
        } else {
            queuedDocumentMutations.append(mutation)
        }
    }

    private func applyDocumentMutation(_ mutation: PendingDocumentMutation) {
        isApplyingProxyMutation = true
        switch mutation.kind {
        case .delete:
            textDocumentProxy.deleteBackward()
        case .returnKey:
            textDocumentProxy.insertText("\n")
        }
        isApplyingProxyMutation = false
        expectSelfMutationCallbacks(for: currentDocumentContextFingerprint())
    }

    private func applyPendingDocumentMutations(startingWith mutation: PendingDocumentMutation) {
        let pendingMutations = [mutation] + queuedDocumentMutations
        queuedDocumentMutations.removeAll()
        guard mutation.expectedEpoch == lifecycleEpoch,
              mutation.expectedMutationGeneration == documentMutationGeneration,
              mutation.expectedContext.hasStableMutationIdentity,
              currentDocumentContextFingerprint() == mutation.expectedContext else {
            return
        }
        for pendingMutation in pendingMutations {
            guard pendingMutation.expectedEpoch == mutation.expectedEpoch,
                  pendingMutation.expectedMutationGeneration == mutation.expectedMutationGeneration,
                  pendingMutation.expectedContext == mutation.expectedContext else {
                // Never combine queued edits captured from different host
                // fields or external document generations.
                break
            }
            applyDocumentMutation(pendingMutation)
            // Return may move focus in the host. Do not replay subsequent
            // edits against an unverified document after that boundary.
            if pendingMutation.kind == .returnKey {
                break
            }
        }
    }

    private func cancelDirectRecognition() {
        speechCaptureCoordinator.cancelRecognition()
        recognitionTask?.cancel()
        resetDirectRecognition()
    }

    private func resetDirectRecognition() {
        recognitionGeneration &+= 1
        recognitionTask = nil
        isRecognitionActive = false
        allowsDirectStartupFallback = false
        recognitionExpectedDocumentContext = nil
        recognitionExpectedDocumentContextAfterInput = nil
        recognitionExpectedDocumentIdentifier = nil
        recognitionExpectedSelectedText = nil
    }
}

private extension TextOperation {
    init?(deliveryOperation: SharedDictationTranscriptDelivery.Operation) {
        switch deliveryOperation {
        case .insertText(let value):
            self = .insertText(value)
        case .deleteBackward(let count):
            guard let count = TextDeletionCount(count) else { return nil }
            self = .deleteBackward(count: count)
        case .showUnsupportedCommand(let phrase):
            self = .showUnsupportedCommand(phrase)
        }
    }
}

private extension SharedDictationTranscriptDelivery.Operation {
    init(_ operation: TextOperation) {
        switch operation {
        case .insertText(let value):
            self = .insertText(value)
        case .deleteBackward(let count):
            self = .deleteBackward(count.value)
        case .showUnsupportedCommand(let phrase):
            self = .showUnsupportedCommand(phrase)
        }
    }
}

private extension SpeechCapturePresentationSnapshot {
    static let containingAppOpenFailed = SpeechCapturePresentationSnapshot(
        transcriptText: "Open Voice Keyboard Input to start voice input.",
        statusText: "Could not open the app from this keyboard.",
        microphoneTitle: "Open app",
        microphoneTone: .critical,
        activeMicrophoneBars: .inactive,
        voiceActivityState: .idle
    )

    static let sharedDictationTimedOut = SpeechCapturePresentationSnapshot(
        transcriptText: "Voice input timed out.",
        statusText: "Open Voice Keyboard Input and try again.",
        microphoneTitle: "Open app",
        microphoneTone: .critical,
        activeMicrophoneBars: .inactive,
        voiceActivityState: .idle
    )

    static let sharedDictationStopping = SpeechCapturePresentationSnapshot(
        transcriptText: "Stopping voice input...",
        statusText: "Stopping voice input...",
        microphoneTitle: "Speak",
        microphoneTone: .warning,
        activeMicrophoneBars: .inactive,
        voiceActivityState: .processing
    )
}

private extension SharedDictationSessionStatus {
    var commandToken: String? {
        switch self {
        case .idle:
            nil
        case let .commandPending(token, _):
            token
        case let .commandAcknowledged(token, _):
            token
        case let .recording(token, _, _):
            token
        case let .transcribing(token):
            token
        case let .transcriptReady(token):
            token
        case let .failed(token, _):
            token
        case let .cancelled(token):
            token
        }
    }

    var stopsKeyboardPolling: Bool {
        switch self {
        case .failed, .cancelled:
            true
        case .idle,
             .commandPending,
             .commandAcknowledged,
             .recording,
             .transcribing,
             .transcriptReady:
            false
        }
    }

    var isPendingSharedDictation: Bool {
        switch self {
        case .idle, .commandPending:
            true
        case .commandAcknowledged,
             .recording,
             .transcribing,
             .transcriptReady,
             .failed,
             .cancelled:
            false
        }
    }

    var isActiveDictationStatus: Bool {
        switch self {
        case .commandPending,
             .commandAcknowledged,
             .recording,
             .transcribing:
            true
        case .idle,
             .transcriptReady,
             .failed,
             .cancelled:
            false
        }
    }
}
