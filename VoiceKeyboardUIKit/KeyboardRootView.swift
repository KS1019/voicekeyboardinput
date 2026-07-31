import UIKit
import VoiceKeyboardModels
import VoiceKeyboardPresentation

@MainActor
final class KeyboardRootView: UIView {
    var onMicrophone: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    private enum Metrics {
        static let stackSpacing: CGFloat = 6
        static let horizontalMargin: CGFloat = 12
        static let verticalMargin: CGFloat = 6
        static let controlPadding: CGFloat = 4
        static let controlCornerRadius: CGFloat = 12
        static let transcriptPadding: CGFloat = 6
        static let transcriptCornerRadius: CGFloat = 10
        static let buttonHeight: CGFloat = 38
        static let primaryButtonHeight: CGFloat = 46
        static let buttonMinimumScaleFactor: CGFloat = 0.72
        static let minimumKeyboardHeight: CGFloat = 180
    }

    private enum Copy {
        static let voiceInputAccessibilityLabel = "Voice input"
        static let transcriptAccessibilityLabel = "Transcript"
        static let emptyTranscriptAccessibilityValue = "No transcript"
        static let nextAccessibilityLabel = "Next keyboard"
        static let microphoneTitle = "Speak"
        static let microphoneAccessibilityLabel = "Start voice input"
        static let deleteAccessibilityLabel = "Delete previous character"
        static let returnAccessibilityLabel = "Insert newline"
    }

    private enum AccessibilityIdentifier {
        static let nextKeyboardButton = "keyboard.next"
        static let microphoneButton = "keyboard.mic"
        static let deleteButton = "keyboard.delete"
        static let returnButton = "keyboard.return"
    }

    private let transcriptGlassEffect = UIGlassEffect(style: .clear)
    private lazy var transcriptContainerView = UIVisualEffectView(
        effect: transcriptGlassEffect
    )
    private let transcriptIconView = UIImageView(image: UIImage(systemName: "waveform"))
    private let transcriptLabel = UILabel()
    private let voiceActivityLabel = UILabel()
    private let voiceActivityMeterView = VoiceActivityMeterView()
    private let voiceActivityStrip = UIStackView()
    // The buttons are the interactive glass surfaces. Keeping their parent
    // plain avoids stacking regular glass behind every glass button.
    private let controlsContainerView = UIView()
    private var nextKeyboardButton: UIButton?
    private var microphoneButton: UIButton?
    private var transcriptTone: PresentationTone = .muted

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func setNextKeyboardVisible(_ isVisible: Bool) {
        nextKeyboardButton?.isHidden = !isVisible
        nextKeyboardButton?.isEnabled = isVisible
    }

    func setNextKeyboardTarget(_ target: Any?, action: Selector) {
        nextKeyboardButton?.removeTarget(nil, action: nil, for: .allTouchEvents)
        nextKeyboardButton?.addTarget(target, action: action, for: .allTouchEvents)
    }

    func render(
        speechCapture: SpeechCapturePresentationSnapshot,
        announce: Bool = false
    ) {
        updateTranscript(speechCapture.transcriptText)
        updateTranscriptChrome(tone: speechCapture.microphoneTone)
        updateVoiceActivity(speechCapture.voiceActivityState)
        updateMicrophoneButton(
            isAvailable: speechCapture.voiceActivityState.phase != .unavailable,
            tone: speechCapture.microphoneTone,
            title: speechCapture.microphoneTitle
        )
        updateStatus(speechCapture.statusText, announce: announce)
    }

    private func configureView() {
        // Let Liquid Glass pick up the host keyboard/background environment.
        // An opaque grouped background here makes every nested material look
        // like a flat gray card instead of a translucent surface.
        backgroundColor = .clear

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Metrics.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        transcriptLabel.numberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.font = .preferredFont(forTextStyle: .callout)
        transcriptLabel.adjustsFontSizeToFitWidth = true
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.minimumScaleFactor = 0.88
        transcriptLabel.isAccessibilityElement = false

        configureCaptionLabel(voiceActivityLabel)
        voiceActivityStrip.addArrangedSubview(voiceActivityLabel)
        voiceActivityStrip.addArrangedSubview(voiceActivityMeterView)
        voiceActivityStrip.axis = .horizontal
        voiceActivityStrip.alignment = .center
        voiceActivityStrip.spacing = Metrics.stackSpacing
        voiceActivityStrip.isAccessibilityElement = false
        configureTranscriptContainer()

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.distribution = .fill
        controls.spacing = Metrics.stackSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false

        let nextButton = button(
            title: nil,
            systemImageName: "globe",
            accessibilityLabel: Copy.nextAccessibilityLabel
        )
        nextButton.accessibilityIdentifier = AccessibilityIdentifier.nextKeyboardButton
        nextKeyboardButton = nextButton
        controls.addArrangedSubview(nextButton)
        let microphoneButton = button(
            title: Copy.microphoneTitle,
            systemImageName: "mic.fill",
            accessibilityLabel: Copy.microphoneAccessibilityLabel
        ) { [weak self] in
            self?.onMicrophone?()
        }
        microphoneButton.accessibilityIdentifier = AccessibilityIdentifier.microphoneButton
        self.microphoneButton = microphoneButton
        controls.addArrangedSubview(microphoneButton)

        let deleteButton = button(
            title: nil,
            systemImageName: "delete.left",
            accessibilityLabel: Copy.deleteAccessibilityLabel
        ) { [weak self] in
            self?.onDelete?()
        }
        deleteButton.accessibilityIdentifier = AccessibilityIdentifier.deleteButton
        controls.addArrangedSubview(deleteButton)

        let returnButton = button(
            title: nil,
            systemImageName: "return",
            accessibilityLabel: Copy.returnAccessibilityLabel
        ) { [weak self] in
            self?.onReturn?()
        }
        returnButton.accessibilityIdentifier = AccessibilityIdentifier.returnButton
        controls.addArrangedSubview(returnButton)

        NSLayoutConstraint.activate([
            nextButton.widthAnchor.constraint(equalTo: deleteButton.widthAnchor),
            returnButton.widthAnchor.constraint(equalTo: deleteButton.widthAnchor),
            microphoneButton.widthAnchor.constraint(equalTo: deleteButton.widthAnchor, multiplier: 1.55)
        ])

        stack.addArrangedSubview(transcriptContainerView)
        configureControlsContainer(with: controls)
        stack.addArrangedSubview(controlsContainerView)
        addSubview(stack)

        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumKeyboardHeight)
        minimumHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalMargin),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.verticalMargin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Metrics.verticalMargin),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimumHeight
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyboardRootView, _) in
            // CALayer stores a resolved CGColor rather than the dynamic
            // UIColor provider. Reapply Liquid Glass chrome after an
            // appearance change so a border resolved in light mode cannot
            // remain in dark mode.
            view.updateAdaptiveChromeColors()
            view.microphoneButton?.setNeedsUpdateConfiguration()
        }
    }

    private func configureTranscriptContainer() {
        transcriptContainerView.contentView.backgroundColor = .clear
        transcriptContainerView.clipsToBounds = true
        transcriptContainerView.layer.cornerRadius = Metrics.transcriptCornerRadius
        transcriptContainerView.layer.cornerCurve = .continuous
        transcriptContainerView.layer.borderWidth = 1
        transcriptContainerView.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        transcriptContainerView.isAccessibilityElement = true
        transcriptContainerView.accessibilityLabel = Copy.voiceInputAccessibilityLabel
        transcriptContainerView.translatesAutoresizingMaskIntoConstraints = false

        transcriptIconView.contentMode = .scaleAspectFit
        transcriptIconView.tintColor = .secondaryLabel
        transcriptIconView.translatesAutoresizingMaskIntoConstraints = false

        let transcriptStack = UIStackView(arrangedSubviews: [transcriptIconView, transcriptLabel])
        transcriptStack.axis = .horizontal
        transcriptStack.alignment = .center
        transcriptStack.spacing = Metrics.stackSpacing
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = UIStackView(arrangedSubviews: [transcriptStack, voiceActivityStrip])
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = Metrics.stackSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        transcriptStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceActivityStrip.setContentCompressionResistancePriority(.required, for: .horizontal)
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptContainerView.contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            transcriptIconView.widthAnchor.constraint(equalToConstant: 18),
            transcriptIconView.heightAnchor.constraint(equalToConstant: 18),
            contentStack.leadingAnchor.constraint(
                equalTo: transcriptContainerView.leadingAnchor,
                constant: Metrics.transcriptPadding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: transcriptContainerView.trailingAnchor,
                constant: -Metrics.transcriptPadding
            ),
            contentStack.topAnchor.constraint(
                equalTo: transcriptContainerView.topAnchor,
                constant: Metrics.transcriptPadding
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: transcriptContainerView.bottomAnchor,
                constant: -Metrics.transcriptPadding
            )
        ])
    }

    private func configureControlsContainer(with controls: UIStackView) {
        controlsContainerView.clipsToBounds = true
        controlsContainerView.layer.cornerRadius = Metrics.controlCornerRadius
        controlsContainerView.layer.cornerCurve = .continuous
        controlsContainerView.layer.borderWidth = 1
        controlsContainerView.layer.borderColor = UIColor.separator.withAlphaComponent(0.16).cgColor
        controlsContainerView.addSubview(controls)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(
                equalTo: controlsContainerView.leadingAnchor,
                constant: Metrics.controlPadding
            ),
            controls.trailingAnchor.constraint(
                equalTo: controlsContainerView.trailingAnchor,
                constant: -Metrics.controlPadding
            ),
            controls.topAnchor.constraint(
                equalTo: controlsContainerView.topAnchor,
                constant: Metrics.controlPadding
            ),
            controls.bottomAnchor.constraint(
                equalTo: controlsContainerView.bottomAnchor,
                constant: -Metrics.controlPadding
            )
        ])
    }

    private func configureCaptionLabel(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.isAccessibilityElement = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func button(
        title: String?,
        systemImageName: String,
        accessibilityLabel: String,
        action: (() -> Void)? = nil
    ) -> UIButton {
        var configuration = baseButtonConfiguration(title: title)
        configuration.image = UIImage(systemName: systemImageName)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityTraits.insert(.keyboardKey)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.minimumScaleFactor = Metrics.buttonMinimumScaleFactor
        button.titleLabel?.numberOfLines = 1
        if let action {
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        let height = title == Copy.microphoneTitle ? Metrics.primaryButtonHeight : Metrics.buttonHeight
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return button
    }

    private func baseButtonConfiguration(title: String?) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.imagePlacement = title == nil ? .leading : .top
        configuration.imagePadding = 2
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 4, bottom: 7, trailing: 4)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        return configuration
    }

    private func updateVoiceActivity(_ state: VoiceActivityState) {
        let presentation = VoiceActivityPresentationSnapshot(
            state: state,
            meterBarCount: voiceActivityMeterView.barCount
        )
        let color = presentation.tone.uiColor

        voiceActivityLabel.text = presentation.title
        voiceActivityLabel.textColor = color
        voiceActivityStrip.accessibilityValue = presentation.accessibilityValue
        voiceActivityMeterView.render(snapshot: presentation.meterSnapshot, color: color)
        updateVoiceInputAccessibilityValue(activity: presentation.accessibilityValue)
    }

    private func updateMicrophoneButton(
        isAvailable: Bool,
        tone: PresentationTone,
        title: String
    ) {
        microphoneButton?.isEnabled = isAvailable
        microphoneButton?.configuration = microphoneButtonConfiguration(
            title: title,
            isAvailable: isAvailable,
            tone: tone
        )
        microphoneButton?.accessibilityLabel = title
        removeMicrophoneButtonShadow()
    }

    private func microphoneButtonConfiguration(
        title: String,
        isAvailable: Bool,
        tone: PresentationTone
    ) -> UIButton.Configuration {
        var configuration = baseButtonConfiguration(title: title)
        configuration.image = UIImage(systemName: "mic.fill")

        guard isAvailable else {
            configuration.baseForegroundColor = .secondaryLabel
            configuration.baseBackgroundColor = .tertiarySystemFill
            return configuration
        }

        switch tone {
        case .positive:
            // `systemBackground` is a dynamic color. It keeps the positive
            // control readable when the system appearance changes instead of
            // pinning the glyph and title to a light-mode-only color.
            configuration.baseForegroundColor = .systemBackground
            configuration.baseBackgroundColor = .systemGreen.withAlphaComponent(0.82)
        case .warning:
            configuration.baseForegroundColor = .systemOrange
            configuration.baseBackgroundColor = .systemOrange.withAlphaComponent(0.22)
        case .critical:
            configuration.baseForegroundColor = .systemRed
            configuration.baseBackgroundColor = .systemRed.withAlphaComponent(0.20)
        case .muted:
            configuration.baseForegroundColor = .label
            configuration.baseBackgroundColor = .clear
        }
        return configuration
    }

    private func removeMicrophoneButtonShadow() {
        guard let microphoneButton else { return }

        microphoneButton.layer.shadowOpacity = 0
    }

    private func updateStatus(_ message: String, announce: Bool = false) {
        if announce {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func updateTranscript(_ text: String) {
        transcriptLabel.text = text
        transcriptLabel.accessibilityValue = text.isEmpty ? Copy.emptyTranscriptAccessibilityValue : text
        updateVoiceInputAccessibilityValue(activity: voiceActivityStrip.accessibilityValue)
    }

    private func updateTranscriptChrome(tone: PresentationTone) {
        transcriptTone = tone
        updateAdaptiveChromeColors()
    }

    private func updateAdaptiveChromeColors() {
        let color = transcriptTone.uiColor
        transcriptIconView.tintColor = color
        transcriptContainerView.layer.borderColor = color.withAlphaComponent(0.22).cgColor
        transcriptGlassEffect.tintColor = color.withAlphaComponent(0.12)
        controlsContainerView.layer.borderColor = UIColor.separator.withAlphaComponent(0.16).cgColor
    }

    private func updateVoiceInputAccessibilityValue(activity: String?) {
        let transcript = (transcriptLabel.text?.isEmpty == false ? transcriptLabel.text : nil)
            ?? Copy.emptyTranscriptAccessibilityValue
        let activity = activity ?? ""
        transcriptContainerView.accessibilityValue = [transcript, activity]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
