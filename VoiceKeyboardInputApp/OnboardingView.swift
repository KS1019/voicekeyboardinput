import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case microphone, speech, keyboard

        var title: String {
            switch self {
            case .microphone: "Less typing.\nMore you."
            case .speech: "A thought,\ninto words."
            case .keyboard: "Right where\nyou write."
            }
        }

        var detail: String {
            switch self {
            case .microphone: "Give your voice a way in. Microphone access lets you dictate when you choose."
            case .speech: "Apple Speech turns your voice into text. Audio may be sent to Apple for recognition."
            case .keyboard: "Add Voice Keyboard in Settings, then choose it with the globe key when you type."
            }
        }
    }

    @State private var permissions = OnboardingPermissionModel()
    @State private var step: Step
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let finish: () -> Void
    let later: () -> Void

    init(initialStep: Step = .microphone, finish: @escaping () -> Void, later: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.finish = finish
        self.later = later
    }

    private var accent: Color {
        Color(uiColor: VoiceKeyboardPalette.accent)
    }

    private var background: Color {
        Color(uiColor: VoiceKeyboardPalette.background)
    }

    private var permission: OnboardingPermissionState? {
        switch step {
        case .microphone: permissions.microphone
        case .speech: permissions.speech
        case .keyboard: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $step) {
                ForEach(Step.allCases, id: \.self) { page in
                    pageContent(page).tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(background.ignoresSafeArea())
        .tint(accent)
        .interactiveDismissDisabled()
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("VOICE KEYBOARD")
                .font(.caption.weight(.semibold))
                .tracking(2)
            Spacer()
            Button("Later", action: later)
                .font(.subheadline)
                .accessibilityIdentifier("onboarding.laterButton")
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    private func pageContent(_ page: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(page.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(page == step ? "onboarding.title" : "onboarding.offscreenTitle")

                OnboardingIllustration(
                    step: page,
                    accent: accent,
                    animates: page == step && scenePhase == .active && !reduceMotion
                )
                .frame(height: 230)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(page == .keyboard ? "Voice Keyboard preview" : "Illustration of voice becoming text. Not recording.")

                Text(page.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if page == .keyboard {
                    keyboardInstructions
                } else {
                    permissionNote(page == .microphone ? permissions.microphone : permissions.speech)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
    }

    private var keyboardInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings → General → Keyboard → Keyboards → Add New Keyboard")
                .font(.footnote.weight(.medium))
            Text("Choose Voice Keyboard, then enable Allow Full Access to share voice-input results with the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Return here and tap Done. You can try the keyboard in the app’s test field.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionNote(_ state: OnboardingPermissionState) -> some View {
        switch state {
        case .authorized:
            Label("Access allowed", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)
        case .notDetermined:
            Text("Permission only. Recording starts when you tap Speak.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .denied:
            Text("Access is off. Enable it in Settings to use voice input.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .restricted:
            Text("Access is restricted. Check Screen Time or device management settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { page in
                    Capsule()
                        .fill(page == step ? accent : accent.opacity(0.15))
                        .frame(width: page == step ? 28 : 8, height: 4)
                }
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.progress")
            }
            .accessibilityElement(children: .contain)

            primaryAction
                .buttonStyle(OnboardingPrimaryButtonStyle(
                    accent: accent,
                    foreground: Color(uiColor: VoiceKeyboardPalette.onAccent)
                ))
                .disabled(permissions.isRequesting)

            HStack {
                Button { move(to: Step(rawValue: step.rawValue - 1)) } label: {
                    Text("Back").frame(minWidth: 44, minHeight: 44)
                }
                    .disabled(step == .microphone)
                    .accessibilityIdentifier("onboarding.backButton")
                Spacer()
                if step == .keyboard {
                    Button(action: finish) {
                        Text("Done").frame(minWidth: 44, minHeight: 44)
                    }
                        .accessibilityIdentifier("onboarding.finishButton")
                } else if permission != .authorized && permission != .restricted {
                    Button { move(to: Step(rawValue: step.rawValue + 1)) } label: {
                        Text("Not now").frame(minWidth: 44, minHeight: 44)
                    }
                        .accessibilityIdentifier("onboarding.nextButton")
                }
            }
            .font(.subheadline)
            .frame(minHeight: 44)

            if let url = URL(string: "https://github.com/KS1019/voicekeyboardinput/blob/main/PRIVACY.md") {
                Link("Privacy Policy", destination: url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(background)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if step == .keyboard {
            Button("Open Settings", action: openSettings)
                .accessibilityIdentifier("onboarding.settingsButton")
        } else {
            switch permission {
            case .authorized, .restricted:
                Button("Continue") { move(to: Step(rawValue: step.rawValue + 1)) }
                    .accessibilityIdentifier("onboarding.nextButton")
            case .denied:
                Button("Open Settings", action: openSettings)
            default:
                Button(dynamicTypeSize.isAccessibilitySize ? "Allow" : (step == .microphone ? "Enable microphone" : "Enable speech recognition")) {
                    let requestedStep = step
                    Task {
                        if requestedStep == .microphone { await permissions.allowMicrophone() }
                        else { await permissions.allowSpeech() }
                    }
                }
                .accessibilityLabel(step == .microphone ? "Enable microphone" : "Enable speech recognition")
                .accessibilityIdentifier(step == .microphone ? "onboarding.microphoneButton" : "onboarding.speechButton")
            }
        }
    }

    private func move(to nextStep: Step?) {
        guard let nextStep else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = nextStep }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let accent: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .background(accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

#Preview("Microphone · Light") {
    OnboardingView(finish: {}, later: {}).preferredColorScheme(.light)
}

#Preview("Speech · Light") {
    OnboardingView(initialStep: .speech, finish: {}, later: {}).preferredColorScheme(.light)
}

#Preview("Keyboard · Light") {
    OnboardingView(initialStep: .keyboard, finish: {}, later: {}).preferredColorScheme(.light)
}

#Preview("Speech · Dark") {
    OnboardingView(initialStep: .speech, finish: {}, later: {}).preferredColorScheme(.dark)
}

#Preview("Keyboard · Large Text") {
    OnboardingView(initialStep: .keyboard, finish: {}, later: {})
        .environment(\.dynamicTypeSize, .accessibility3)
}
