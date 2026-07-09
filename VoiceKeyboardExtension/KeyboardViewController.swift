import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private lazy var sharedTranscriptStore = SharedDictationTranscriptStore.appGroupStore()
    private lazy var sharedSessionStore = SharedDictationSessionStore.appGroupStore()
    private var renderTask: Task<Void, Never>?
    private var sharedDictationPollingTask: Task<Void, Never>?
    private var isRecognitionActive = false

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
        sharedDictationPollingTask?.cancel()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard sharedTranscriptStore != nil else {
            renderSharedDictationUnavailableIfNeeded()
            return
        }
        guard !consumeSharedDictationTranscriptIfNeeded() else { return }
        renderCurrentSpeechCapture()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateNextKeyboardButtonVisibility()
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
        renderTask = Task { [weak self] in
            let snapshot = await speechCaptureCoordinator.currentSnapshot()
            guard !Task.isCancelled else { return }
            guard let self else { return }
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
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil

        if isRecognitionActive {
            renderTask?.cancel()
            isRecognitionActive = false
            renderCurrentSpeechCapture(announce: true)
            return
        }

        renderTask?.cancel()

        let speechCaptureCoordinator = speechCaptureCoordinator
        let locale = VoiceKeyboardLocale(identifier: Locale.current.identifier)
        let context = textDocumentProxy.documentContextBeforeInput

        renderTask = Task { [weak self] in
            guard let self else { return }
            isRecognitionActive = true
            defer { isRecognitionActive = false }

            for await event in speechCaptureCoordinator.recognitionEvents(
                locale: locale,
                documentContextBeforeInput: context
            ) {
                guard !Task.isCancelled else { return }
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(event.state),
                    announce: true
                )
                apply(event.actions)
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
        let command = SharedDictationSessionCommand.stop(source: .keyboard)
        sharedSessionStore.saveCommand(command)
        keyboardRootView.render(
            speechCapture: .sharedDictationStopping,
            announce: true
        )
        monitorSharedDictationSession(command: command)
    }

    private func monitorSharedDictationSession(command: SharedDictationSessionCommand) {
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(16)

            while !Task.isCancelled {
                guard let self else { return }

                if consumeSharedDictationTranscriptIfNeeded() {
                    return
                }

                if let status = sharedSessionStore?.status() {
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

    private func apply(_ actions: [KeyboardTextInsertionAction]) {
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

    private func consumeSharedDictationTranscriptIfNeeded() -> Bool {
        guard let sharedTranscriptStore else { return false }
        let lastConsumedToken = sharedTranscriptStore.lastConsumedToken()
        guard let transcript = sharedTranscriptStore.claimLatestTranscript(
            afterLastConsumedToken: lastConsumedToken
        ) else {
            return false
        }

        textDocumentProxy.insertText(transcript.text)
        sharedDictationPollingTask?.cancel()
        sharedDictationPollingTask = nil
        keyboardRootView.render(
            speechCapture: .keyboardSpeechCapture(.inserted(transcript.text)),
            announce: true
        )
        return true
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
        ExtensionContextContainingAppOpener { [weak self] in
            self?.extensionContext
        }
        .openContainingAppForDictation { [weak self] didOpen in
            guard !didOpen else { return }
            Task { @MainActor in
                self?.keyboardRootView.render(
                    speechCapture: .containingAppOpenFailed,
                    announce: true
                )
            }
        }
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
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
}
