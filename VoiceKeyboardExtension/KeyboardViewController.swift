import UIKit
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private lazy var sharedTranscriptStore = SharedDictationTranscriptStore.appGroupStore()
    private var renderTask: Task<Void, Never>?
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
        if speechCaptureCoordinator.shouldOpenContainingAppForDictation() {
            guard sharedTranscriptStore != nil else {
                keyboardRootView.render(
                    speechCapture: .sharedDictationUnavailable,
                    announce: true
                )
                return
            }
            openContainingAppForDictation()
            return
        }

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
}
