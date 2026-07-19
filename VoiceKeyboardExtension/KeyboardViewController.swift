import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation
import VoiceKeyboardSharedStorage

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private lazy var sharedTranscriptStore = SharedDictationTranscriptStore.appGroupStore()
    private lazy var sharedSessionStore = SharedDictationSessionStore.appGroupStore()
    private var renderTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var sharedDictationPollingTask: Task<Void, Never>?
    private var isRecognitionActive = false
    private var isRecognitionStopping = false
    private var lifecycleEpoch: UInt64 = 0
    private var activeSharedSessionID: String?
    private var activeSharedCommandToken: String?

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
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lifecycleEpoch &+= 1
        if isRecognitionStopping {
            finishRecognitionStopAfterAppearance()
            return
        }
        guard sharedTranscriptStore != nil else {
            renderSharedDictationUnavailableIfNeeded()
            return
        }
        guard !consumeSharedDictationTranscriptIfNeeded() else { return }
        resumeSharedDictationPollingIfNeeded()
        renderCurrentSpeechCapture()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateNextKeyboardButtonVisibility()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycleEpoch &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognitionActive = false
        isRecognitionStopping = true
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        let coordinator = speechCaptureCoordinator
        let epoch = lifecycleEpoch
        Task { [weak self] in
            await coordinator.stopRecognition()
            guard let self,
                  self.isViewLoaded,
                  self.lifecycleEpoch == epoch else { return }
            self.isRecognitionStopping = false
            self.resumeSharedDictationPollingIfNeeded()
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

    // MARK: - Actions

    @objc private func nextKeyboardTapped(_ sender: UIView, with event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }

    @objc private func microphoneTapped() {
        guard !isRecognitionStopping else { return }

        if sharedSessionStore?.status().acceptsKeyboardStopCommand == true {
            stopSharedDictationSession()
            return
        }

        let decision = KeyboardDictationStartDecision.evaluate(
            directKeyboardRecognitionReady: !speechCaptureCoordinator.shouldOpenContainingAppForDictation(),
            hasSessionStore: sharedSessionStore != nil,
            appHeartbeatIsFresh: sharedSessionStore?.heartbeat()?.isFresh(maxAge: 5) == true
        )

        switch decision {
        case .startDirectKeyboardRecognition:
            startDirectKeyboardRecognition()
        case .writeSharedStartCommand:
            startSharedDictationSession()
        case .openContainingApp:
            guard sharedTranscriptStore != nil else {
                keyboardRootView.render(
                    speechCapture: .sharedDictationUnavailable,
                    announce: true
                )
                return
            }
            openContainingAppForDictation()
        case .showSharedStorageUnavailable:
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
            recognitionTask?.cancel()
            isRecognitionActive = false
            let coordinator = speechCaptureCoordinator
            let epoch = lifecycleEpoch
            Task { [weak self] in
                await coordinator.stopRecognition()
                guard let self, self.lifecycleEpoch == epoch else { return }
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
        isRecognitionActive = true

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleEpoch == epoch {
                    self.isRecognitionActive = false
                    self.recognitionTask = nil
                }
            }

            for await event in speechCaptureCoordinator.recognitionEvents(
                locale: locale,
                documentContextBeforeInput: context
            ) {
                guard !Task.isCancelled else { return }
                guard lifecycleEpoch == epoch, isRecognitionActive else { return }
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(event.state),
                    announce: true
                )
                apply(event.actions, epoch: epoch)
            }
        }
    }

    private func startSharedDictationSession() {
        guard let sharedSessionStore else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return
        }
        let command = SharedDictationSessionCommand.start(source: .keyboard)
        activeSharedSessionID = command.sessionID
        activeSharedCommandToken = command.token
        sharedSessionStore.saveCommand(command)
        keyboardRootView.render(
            speechCapture: .sharedDictationSessionStatus(.commandPending(
                token: command.token,
                requestedAt: command.requestedAt
            )),
            announce: true
        )
        monitorSharedDictationSession(command: command)
    }

    private func stopSharedDictationSession() {
        guard let sharedSessionStore else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return
        }
        guard let sessionID = activeSharedSessionID
            ?? sharedSessionStore.latestCommand()?.sessionID else {
            keyboardRootView.render(
                speechCapture: .sharedDictationUnavailable,
                announce: true
            )
            return
        }
        let command = SharedDictationSessionCommand.stop(
            sessionID: sessionID,
            source: .keyboard,
            expiryInterval: 20
        )
        sharedSessionStore.saveCommand(command)
        keyboardRootView.render(
            speechCapture: .sharedDictationStopping,
            announce: true
        )
        monitorSharedDictationSession(command: command)
    }

    private func monitorSharedDictationSession(command: SharedDictationSessionCommand) {
        sharedDictationPollingTask?.cancel()
        let epoch = lifecycleEpoch
        sharedDictationPollingTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(16)

            while !Task.isCancelled {
                guard let self else { return }
                guard self.lifecycleEpoch == epoch else { return }

                if command.kind == .start,
                   consumeSharedDictationTranscriptIfNeeded(for: command, epoch: epoch) {
                    return
                }

                if let status = sharedSessionStore?.status() {
                    guard status.commandToken == command.token else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if command.kind == .start,
                       command.isExpired(),
                       status.isActiveDictationStatus {
                        keyboardRootView.render(
                            speechCapture: .sharedDictationTimedOut,
                            announce: true
                        )
                        return
                    }
                    keyboardRootView.render(
                        speechCapture: .sharedDictationSessionStatus(status),
                        announce: false
                    )
                    if status.stopsKeyboardPolling {
                        return
                    }
                }

                if Date() >= deadline {
                    keyboardRootView.render(
                        speechCapture: .sharedDictationTimedOut,
                        announce: true
                    )
                    return
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func resumeSharedDictationPollingIfNeeded() {
        guard !isRecognitionStopping,
              sharedDictationPollingTask == nil,
              let command = matchingActiveStartCommand() else { return }
        monitorSharedDictationSession(command: command)
    }

    private func finishRecognitionStopAfterAppearance() {
        let coordinator = speechCaptureCoordinator
        let epoch = lifecycleEpoch
        Task { [weak self] in
            await coordinator.stopRecognition()
            guard let self, self.lifecycleEpoch == epoch else { return }
            self.isRecognitionStopping = false
            guard !self.consumeSharedDictationTranscriptIfNeeded() else { return }
            self.resumeSharedDictationPollingIfNeeded()
            self.renderCurrentSpeechCapture()
        }
    }

    private func apply(
        _ actions: [KeyboardTextInsertionAction],
        epoch: UInt64
    ) {
        guard isRecognitionActive, !isRecognitionStopping else { return }
        guard lifecycleEpoch == epoch else { return }
        for action in actions {
            switch action {
            case .insertText(let value):
                textDocumentProxy.insertText(value)
            case .deleteBackward(let count):
                for _ in 0..<count.value {
                    textDocumentProxy.deleteBackward()
                }
            }
        }
    }

    private func consumeSharedDictationTranscriptIfNeeded(
        for command: SharedDictationSessionCommand? = nil,
        epoch: UInt64? = nil
    ) -> Bool {
        guard !isRecognitionStopping else { return false }
        guard let sharedTranscriptStore else { return false }
        guard let command = command ?? matchingReadyStartCommand(),
              command.kind == .start else { return false }
        guard let status = sharedSessionStore?.status(),
              case let .transcriptReady(statusToken) = status,
              statusToken == command.token else {
            return false
        }
        if let epoch, lifecycleEpoch != epoch { return false }
        guard let latestTranscript = sharedTranscriptStore.latestTranscript(
            forSessionID: command.sessionID
        ), latestTranscript.commandToken == command.token else {
            return false
        }
        guard !latestTranscript.isExpired() else {
            sharedDictationPollingTask?.cancel()
            sharedDictationPollingTask = nil
            keyboardRootView.render(
                speechCapture: .sharedDictationTimedOut,
                announce: true
            )
            return true
        }
        let lastConsumedToken = sharedTranscriptStore.lastConsumedToken()
        guard let transcript = sharedTranscriptStore.claimLatestTranscript(
            forSessionID: command.sessionID,
            afterLastConsumedToken: lastConsumedToken
        ) else {
            return false
        }

        textDocumentProxy.insertText(transcript.text)
        activeSharedSessionID = nil
        activeSharedCommandToken = nil
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        keyboardRootView.render(
            speechCapture: .keyboardSpeechCapture(.inserted(transcript.text)),
            announce: true
        )
        return true
    }

    private func matchingReadyStartCommand() -> SharedDictationSessionCommand? {
        guard let command = matchingActiveStartCommand() else { return nil }
        guard let status = sharedSessionStore?.status(),
              case .transcriptReady = status else { return nil }
        return command
    }

    private func matchingActiveStartCommand() -> SharedDictationSessionCommand? {
        guard let sharedSessionStore else { return nil }
        let status = sharedSessionStore.status()
        guard let latestCommand = sharedSessionStore.latestCommand(),
              latestCommand.kind == .start,
              latestCommand.source == .keyboard,
              !latestCommand.isExpired() else {
            return nil
        }
        if case .idle = status {
            activeSharedSessionID = latestCommand.sessionID
            activeSharedCommandToken = latestCommand.token
            return latestCommand
        }
        guard status.commandToken == latestCommand.token else { return nil }
        switch status {
        case .commandPending,
             .commandAcknowledged,
             .recording,
             .transcribing:
            guard !latestCommand.isExpired() else { return nil }
        case .transcriptReady:
            // The transcript has its own expiry window, checked when it is
            // claimed. Keep polling long enough to insert a valid result
            // even if the original start command has expired.
            break
        case .idle,
             .failed,
             .cancelled:
            return nil
        }
        activeSharedSessionID = latestCommand.sessionID
        activeSharedCommandToken = latestCommand.token
        return latestCommand
    }

    private func renderSharedDictationUnavailableIfNeeded() {
        guard speechCaptureCoordinator.shouldOpenContainingAppForDictation() else {
            renderCurrentSpeechCapture()
            return
        }
        keyboardRootView.render(
            speechCapture: .sharedDictationUnavailable,
            announce: true
        )
    }

    private func openContainingAppForDictation() {
        let epoch = lifecycleEpoch
        ExtensionContextContainingAppOpener { [weak self] in
            self?.extensionContext
        }
        .openContainingAppForDictation { [weak self] didOpen in
            guard !didOpen else { return }
            Task { @MainActor in
                guard let self, self.lifecycleEpoch == epoch else { return }
                self.keyboardRootView.render(
                    speechCapture: .containingAppOpenFailed,
                    announce: true
                )
            }
        }
    }

    @objc private func deleteTapped() {
        guard !isRecognitionStopping else { return }
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
        guard !isRecognitionStopping else { return }
        textDocumentProxy.insertText("\n")
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
