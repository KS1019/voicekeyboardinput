import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation
import VoiceKeyboardSharedStorage

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private let sharedDeliveryOwnerID = UUID().uuidString
    private let sharedTranscriptStoreProvider: @Sendable () -> SharedDictationTranscriptStore? = {
        SharedDictationTranscriptStore.appGroupStore()
    }
    private let sharedSessionStoreProvider: @Sendable () -> SharedDictationSessionStore? = {
        SharedDictationSessionStore.appGroupStore()
    }
    private var renderTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var sharedDictationPollingTask: Task<Void, Never>?
    private var sharedDeliveryTask: Task<Void, Never>?
    private var microphoneDecisionTask: Task<Void, Never>?
    private var isRecognitionActive = false
    private var isRecognitionStopping = false
    private var isMicrophoneDecisionInFlight = false
    private var isViewVisible = false
    private var lifecycleEpoch: UInt64 = 0
    private var sharedPollingGeneration: UInt64 = 0
    private var activeSharedSessionID: String?
    private var activeSharedCommandToken: String?
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
    private var sharedDeliveryRecoveryRetryTask: Task<Void, Never>?
    private var hasSharedDeliveryLifecycleGap = false
    private var sharedCancellationTask: Task<Void, Never>?
    private var isSharedCancellationInProgress = false
    private var queuedDocumentMutations: [() -> Void] = []
    private var sharedCancellationRetryTask: Task<Void, Never>?
    private var sharedCancellationRecoveryWaitTask: Task<Void, Never>?
    private var sharedCancellationOperationGeneration: UInt64 = 0
    private var directRecognitionStopTask: Task<Void, Never>?

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
        sharedCancellationRetryTask = Task { [weak self] in
            for _ in 0..<120 {
                guard let self else { return }
                if await self.sessionStoreCall({ $0.saveCommand(command) }) == true {
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
            guard let self else { return }
            self.sharedCancellationRetryTask = nil
            onExhausted()
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
        renderCurrentSpeechCapture()
    }

    deinit {
        renderTask?.cancel()
        recognitionTask?.cancel()
        sharedDictationPollingTask?.cancel()
        sharedDeliveryTask?.cancel()
        microphoneDecisionTask?.cancel()
        sharedCancellationTask?.cancel()
        sharedCancellationRetryTask?.cancel()
        sharedCancellationRecoveryWaitTask?.cancel()
        sharedDeliveryRecoveryRetryTask?.cancel()
        directRecognitionStopTask?.cancel()
    }

    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        renderTask?.cancel()
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
        guard isViewVisible, !isRecognitionStopping else { return }
        let epoch = lifecycleEpoch
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.isViewVisible,
                  !self.isRecognitionStopping,
                  self.lifecycleEpoch == epoch else { return }
            self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewVisible = true
        isOpeningContainingApp = false
        lifecycleEpoch &+= 1
        if isRecognitionStopping {
            finishRecognitionStopAfterAppearance()
            return
        }
        let epoch = lifecycleEpoch
        startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
    }

    private func startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: UInt64) {
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
        sharedDeliveryRecoveryRetryTask = Task { [weak self] in
            defer {
                if let self {
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
                    case .failed, .cancelled:
                        guard store.discardCancellationIntent(forToken: command.token) else {
                            allResolved = false
                            continue
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
        hasSharedDeliveryLifecycleGap = true
        lifecycleEpoch &+= 1
        microphoneDecisionTask?.cancel()
        microphoneDecisionTask = nil
        isMicrophoneDecisionInFlight = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionGeneration &+= 1
        isRecognitionActive = false
        recognitionExpectedDocumentContext = nil
        recognitionExpectedDocumentContextAfterInput = nil
        recognitionExpectedDocumentIdentifier = nil
        recognitionExpectedSelectedText = nil
        isRecognitionStopping = true
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
        directRecognitionStopTask?.cancel()
        directRecognitionStopTask = nil
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
        let coordinator = speechCaptureCoordinator
        let epoch = lifecycleEpoch
        Task { [weak self] in
            await coordinator.stopRecognition()
            guard let self,
                  self.isViewLoaded,
                  self.isViewVisible,
                  self.lifecycleEpoch == epoch else { return }
            self.isRecognitionStopping = false
            await self.resumeSharedDictationPollingIfNeeded(epoch: epoch)
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
        renderTask?.cancel()
        let speechCaptureCoordinator = speechCaptureCoordinator
        let epoch = lifecycleEpoch
        renderTask = Task { [weak self] in
            let snapshot = await speechCaptureCoordinator.currentSnapshot()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.lifecycleEpoch == epoch else { return }
            keyboardRootView.render(speechCapture: snapshot, announce: announce)
        }
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
        guard !isRecognitionStopping,
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
            startDirectKeyboardRecognition()
            return
        }

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
            let directRecognitionReady = await speechCaptureCoordinator.directRecognitionIsReady()
            guard !Task.isCancelled,
                  self.isViewVisible,
                  self.lifecycleEpoch == epoch,
                  !self.isRecognitionStopping else { return }
            await self.handleMicrophoneTap(
                directRecognitionReady: directRecognitionReady,
                epoch: epoch
            )
        }
    }

    private func handleMicrophoneTap(
        directRecognitionReady: Bool,
        epoch: UInt64
    ) async {
        guard isCurrentInteraction(epoch) else { return }

        let appHeartbeatIsFresh = await sessionStoreCall {
            $0.heartbeat()?.isFresh(maxAge: 5) == true
        } == true
        guard isCurrentInteraction(epoch) else { return }
        let decision = KeyboardDictationStartDecision.evaluate(
            directKeyboardRecognitionReady: directRecognitionReady,
            hasSessionStore: await sessionStoreCall({ $0.storageHealth() }) == true,
            appHeartbeatIsFresh: appHeartbeatIsFresh
        )
        guard isCurrentInteraction(epoch) else { return }

        switch decision {
        case .startDirectKeyboardRecognition:
            startDirectKeyboardRecognition()
        case .writeSharedStartCommand:
            _ = await startSharedDictationSession(epoch: epoch)
        case .openContainingApp:
            guard await transcriptStoreCall({ $0.storageHealth() }) == true else {
                guard isCurrentInteraction(epoch) else { return }
                keyboardRootView.render(
                    speechCapture: .sharedDictationUnavailable,
                    announce: true
                )
                return
            }
            guard isCurrentInteraction(epoch) else { return }
            await openContainingAppForDictation(epoch: epoch)
        case .showSharedStorageUnavailable:
            guard isCurrentInteraction(epoch) else { return }
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
        }
    }

    private func startDirectKeyboardRecognition() {
        guard !isRecognitionStopping else { return }
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil

        if isRecognitionActive {
            isRecognitionStopping = true
            let coordinator = speechCaptureCoordinator
            let epoch = lifecycleEpoch
            let recognitionGeneration = self.recognitionGeneration
            Task { [weak self] in
                await coordinator.stopRecognition()
                guard let self,
                      self.lifecycleEpoch == epoch,
                      self.recognitionGeneration == recognitionGeneration else { return }
                self.isRecognitionStopping = false
                self.renderCurrentSpeechCapture(announce: true)
            }
            return
        }

        renderTask?.cancel()

        let speechCaptureCoordinator = speechCaptureCoordinator
        let locale = VoiceKeyboardLocale(identifier: Locale.current.identifier)
        let context = textDocumentProxy.documentContextBeforeInput
        let epoch = lifecycleEpoch
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        isRecognitionActive = true
        recognitionExpectedDocumentContext = context
        recognitionExpectedDocumentContextAfterInput = textDocumentProxy.documentContextAfterInput
        recognitionExpectedDocumentIdentifier = textDocumentProxy.documentIdentifier
        recognitionExpectedSelectedText = textDocumentProxy.selectedText
        recognitionExpectedDocumentMutationGeneration = documentMutationGeneration

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            var hasTerminalPresentation = false
            defer {
                if self.lifecycleEpoch == epoch,
                   self.recognitionGeneration == currentRecognitionGeneration {
                    self.isRecognitionActive = false
                    self.recognitionTask = nil
                    self.recognitionExpectedDocumentContext = nil
                    self.recognitionExpectedDocumentContextAfterInput = nil
                    self.recognitionExpectedDocumentIdentifier = nil
                    self.recognitionExpectedSelectedText = nil
                    if !self.isRecognitionStopping, !hasTerminalPresentation {
                        self.renderCurrentSpeechCapture(announce: true)
                    }
                }
            }

            for await event in speechCaptureCoordinator.recognitionEvents(
                locale: locale,
                documentContextBeforeInput: context
            ) {
                guard !Task.isCancelled else { return }
                guard lifecycleEpoch == epoch,
                      self.recognitionGeneration == currentRecognitionGeneration,
                      isRecognitionActive else { return }
                switch event.state {
                case .recognitionFailed:
                    hasTerminalPresentation = true
                default:
                    break
                }
                keyboardRootView.render(
                    speechCapture: activeSpeechCaptureSnapshot(for: event.state),
                    announce: true
                )
                guard await apply(
                    event.actions,
                    epoch: epoch,
                    recognitionGeneration: currentRecognitionGeneration
                ) else {
                    hasTerminalPresentation = true
                    return
                }
            }
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
        hasSharedDeliveryLifecycleGap = false
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
                case .failed, .cancelled:
                    continue
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
        then mutation: @escaping @MainActor () -> Void
    ) {
        guard !isSharedCancellationInProgress else {
            queuedDocumentMutations.append(mutation)
            return
        }
        let expectedContext = currentDocumentContextFingerprint()
        let expectedMutationGeneration = documentMutationGeneration
        let expectedEpoch = lifecycleEpoch
        sharedCancellationOperationGeneration &+= 1
        let operationGeneration = sharedCancellationOperationGeneration
        isSharedCancellationInProgress = true
        sharedCancellationTask = Task { [weak self] in
            guard let self else { return }
            switch await self.sharedCancellationTarget() {
            case .storageUnavailable:
                guard self.sharedCancellationOperationGeneration == operationGeneration else { return }
                self.isSharedCancellationInProgress = false
                self.sharedCancellationTask = nil
                self.queuedDocumentMutations.removeAll()
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
                self.cancelDirectRecognition()
                self.queuedDocumentMutations.removeAll()
                guard self.lifecycleEpoch == expectedEpoch, self.isViewVisible else {
                    self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: self.lifecycleEpoch)
                    return
                }
                let canApplyMutation = self.documentMutationGeneration == expectedMutationGeneration
                    && self.currentDocumentContextFingerprint() == expectedContext
                if canApplyMutation {
                    mutation()
                }
                // A proxy mutation can submit a form or move focus. Do not
                // replay taps captured before cancellation onto an unverified
                // field; fail closed and let the user retry in the new field.
                self.queuedDocumentMutations.removeAll()
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
                    self.queuedDocumentMutations.removeAll()
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
                        self.queuedDocumentMutations.removeAll()
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
        mutation: @escaping @MainActor () -> Void
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
            mutation()
        }
        // The first proxy mutation may change focus synchronously. Queued
        // taps were captured against the previous field, so never replay them
        // without a fresh document identity check.
        queuedDocumentMutations.removeAll()
        startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: lifecycleEpoch)
    }

    private func isCurrentInteraction(_ epoch: UInt64?) -> Bool {
        !Task.isCancelled
            && isViewVisible
            && (epoch == nil || lifecycleEpoch == epoch)
            && !isRecognitionStopping
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
        guard !isRecognitionStopping,
              isViewVisible,
              isSharedDeliveryCurrent(epoch),
              sharedDictationPollingTask == nil,
              let command = await matchingActiveStartCommand(epoch: epoch) else { return }
        guard isSharedDeliveryCurrent(epoch) else { return }
        monitorSharedDictationSession(command: command)
    }

    private func finishRecognitionStopAfterAppearance() {
        let coordinator = speechCaptureCoordinator
        let epoch = lifecycleEpoch
        Task { [weak self] in
            await coordinator.stopRecognition()
            guard let self, self.lifecycleEpoch == epoch else { return }
            self.isRecognitionStopping = false
            self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: epoch)
        }
    }

    private func apply(
        _ actions: [KeyboardTextInsertionAction],
        epoch: UInt64,
        recognitionGeneration: UInt64
    ) async -> Bool {
        guard isRecognitionActive,
              lifecycleEpoch == epoch,
              self.recognitionGeneration == recognitionGeneration else { return false }
        guard recognitionExpectedDocumentContext == textDocumentProxy.documentContextBeforeInput,
              recognitionExpectedDocumentContextAfterInput == textDocumentProxy.documentContextAfterInput,
              recognitionExpectedDocumentIdentifier == textDocumentProxy.documentIdentifier,
              recognitionExpectedSelectedText == textDocumentProxy.selectedText,
              recognitionExpectedDocumentMutationGeneration == documentMutationGeneration else {
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
              totalDeletionCount <= Self.maximumSharedDeletionCount else {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.unsupportedCommand(
                    "Voice input contained too many editing operations."
                )),
                announce: true
            )
            return false
        }

        isApplyingProxyMutation = true
        defer { isApplyingProxyMutation = false }
        for action in actions {
            switch action {
            case .insertText(let value):
                textDocumentProxy.insertText(value)
            case .deleteBackward(let count):
                for _ in 0..<count.value {
                    guard !Task.isCancelled,
                          isRecognitionActive,
                          lifecycleEpoch == epoch,
                          self.recognitionGeneration == recognitionGeneration else {
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

    private func activeSpeechCaptureSnapshot(
        for state: KeyboardSpeechCaptureState
    ) -> SpeechCapturePresentationSnapshot {
        let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(state)
        guard isRecognitionActive else { return snapshot }
        switch state {
        case .inserted, .unsupportedCommand:
            return SpeechCapturePresentationSnapshot(
                transcriptText: snapshot.transcriptText,
                statusText: snapshot.statusText,
                microphoneTitle: "Stop",
                microphoneTone: snapshot.microphoneTone,
                activeMicrophoneBars: .ready,
                voiceActivityState: .listening(level: nil)
            )
        default:
            return snapshot
        }
    }

    private func consumeSharedDictationTranscriptIfNeeded(
        for command: SharedDictationSessionCommand? = nil,
        epoch: UInt64? = nil
    ) async -> Bool {
        guard isSharedDeliveryCurrent(epoch) else { return false }
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
        if let pendingDelivery,
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
                if await transcriptStoreCall({
                    $0.reconcileDelivered(
                        transcriptToken: pendingDelivery.transcriptToken,
                        ownerID: deliveryOwnerID,
                        observedContext: currentContextFingerprint
                    )
                }) == true {
                    endSharedSession(
                        ifMatchingSessionID: source.sessionID,
                        commandToken: command.token,
                        pollingGeneration: deliveryPollingGeneration
                    )
                    return true
                }
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
            if (hasSharedDeliveryLifecycleGap || pendingDelivery.ownerID != sharedDeliveryOwnerID),
               !pendingDelivery.beforeContext.hasDocumentIdentifier {
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
                    guard await transcriptStoreCall({
                        $0.reconcileDelivered(
                            transcriptToken: pendingDelivery.transcriptToken,
                            ownerID: deliveryOwnerID,
                            observedContext: currentContextFingerprint
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

        let operations: [TextOperation]
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
            operations = restoredOperations
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
            operations = generatedOperations
        }
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
            startingContext: pendingDelivery?.checkpointContext
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
        if let expectedSelfMutationContext,
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
        startingContext: SharedDictationDocumentContextFingerprint? = nil
    ) async -> Bool {
        let deliveryOwnerID = sharedDeliveryOwnerID
        guard isSharedDeliveryCurrent(
            epoch,
            pollingGeneration: pollingGeneration,
            sessionID: sessionID,
            commandToken: commandToken
        ) else { return false }
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
        } else if didEditDocument, !insertedText.isEmpty {
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(.inserted(insertedText)),
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
              !isRecognitionStopping,
              !isSharedCancellationInProgress,
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
        var totalDeletionCount = 0
        for operation in operations {
            if case let .deleteBackward(count) = operation,
               count.value > Self.maximumSharedDeletionCount {
                return nil
            }
            if case let .deleteBackward(count) = operation {
                totalDeletionCount += count.value
                guard totalDeletionCount <= Self.maximumSharedDeletionCount else { return nil }
            }
        }
        return operations
    }

    private static let maximumSharedDeletionCount = 512
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
            if await isConsumedSharedTranscript(for: command) {
                continue
            }
            guard isSharedDeliveryCurrent(epoch) else { return nil }
            if command.kind == .stop {
                guard !command.isExpired() else { continue }
                guard isSharedDeliveryCurrent(epoch) else { return nil }
                activeSharedSessionID = command.sessionID
                activeSharedCommandToken = command.token
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
        guard speechCaptureCoordinator.shouldOpenContainingAppForDictation() else {
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
                self.isOpeningContainingApp = false
                self.keyboardRootView.render(
                    speechCapture: .containingAppOpenFailed,
                    announce: true
                )
            }
        }
    }

    @objc private func deleteTapped() {
        guard !isRecognitionStopping else { return }
        performDocumentMutationAfterVoiceCancellation {
            self.isApplyingProxyMutation = true
            self.textDocumentProxy.deleteBackward()
            self.isApplyingProxyMutation = false
            self.expectSelfMutationCallbacks(for: self.currentDocumentContextFingerprint())
        }
    }

    @objc private func returnTapped() {
        guard !isRecognitionStopping else { return }
        performDocumentMutationAfterVoiceCancellation {
            self.isApplyingProxyMutation = true
            self.textDocumentProxy.insertText("\n")
            self.isApplyingProxyMutation = false
            self.expectSelfMutationCallbacks(for: self.currentDocumentContextFingerprint())
        }
    }

    private func performDocumentMutationAfterVoiceCancellation(
        _ mutation: @escaping @MainActor () -> Void
    ) {
        microphoneDecisionTask?.cancel()
        microphoneDecisionTask = nil
        isMicrophoneDecisionInFlight = false
        if isSharedCancellationInProgress {
            queuedDocumentMutations.append(mutation)
            return
        }
        if isSharedStorageResolutionUnknown
                || activeSharedSessionID != nil
                || activeSharedCommandToken != nil
                || isSharedDeliveryRecoveryInProgress {
            cancelSharedDictationForLifecycleChange(then: mutation)
        } else {
            cancelDirectRecognition()
            mutation()
        }
    }

    private func cancelDirectRecognition() {
        guard isRecognitionActive || recognitionTask != nil else { return }
        recognitionGeneration &+= 1
        let stopGeneration = recognitionGeneration
        let stopEpoch = lifecycleEpoch
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognitionActive = false
        recognitionExpectedDocumentContext = nil
        recognitionExpectedDocumentContextAfterInput = nil
        recognitionExpectedDocumentIdentifier = nil
        recognitionExpectedSelectedText = nil
        isRecognitionStopping = true
        let coordinator = speechCaptureCoordinator
        directRecognitionStopTask?.cancel()
        directRecognitionStopTask = Task { [weak self] in
            await coordinator.stopRecognition()
            guard let self,
                  self.recognitionGeneration == stopGeneration,
                  self.lifecycleEpoch == stopEpoch,
                  self.isViewVisible else { return }
            self.directRecognitionStopTask = nil
            self.isRecognitionStopping = false
            if self.isViewVisible {
                self.startSharedDeliveryRecoveryAfterCancellationIfNeeded(epoch: self.lifecycleEpoch)
            }
        }
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
