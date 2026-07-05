import UIKit
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
public final class KeyboardViewController: UIInputViewController {
    private let keyboardRootView = KeyboardRootView()
    private let speechCaptureCoordinator = KeyboardSpeechCaptureCoordinator()
    private var renderTask: Task<Void, Never>?

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
        renderTask?.cancel()

        let speechCaptureCoordinator = speechCaptureCoordinator
        renderTask = Task { [weak self] in
            if speechCaptureCoordinator.shouldOpenContainingAppForDictation() {
                guard let self else { return }
                keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(.containingAppLaunchRequired),
                    announce: true
                )
                openContainingAppForDictation()
                return
            }

            await MainActor.run {
                self?.keyboardRootView.render(
                    speechCapture: .keyboardSpeechCapture(.probing),
                    announce: true
                )
            }

            let snapshot = await speechCaptureCoordinator.probeSnapshot()
            guard !Task.isCancelled else { return }
            guard let self else { return }

            keyboardRootView.render(speechCapture: snapshot, announce: true)
        }
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
