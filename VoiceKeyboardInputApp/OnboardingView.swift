import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case microphone, speech, keyboard

        var title: String {
            switch self {
            case .microphone: "Allow microphone access"
            case .speech: "Turn speech into text"
            case .keyboard: "Add your keyboard"
            }
        }

        var symbol: String {
            switch self {
            case .microphone: "mic.circle.fill"
            case .speech: "waveform.circle.fill"
            case .keyboard: "keyboard"
            }
        }
    }

    @State private var permissions = OnboardingPermissionModel()
    @State private var step: Step
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let finish: () -> Void
    let later: () -> Void

    init(initialStep: Step = .microphone, finish: @escaping () -> Void, later: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.finish = finish
        self.later = later
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding.progress")
                    Text(step.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.title")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                TabView(selection: $step) {
                    ForEach(Step.allCases, id: \.self) { page in
                        pageContent(page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 16) {
                    Button("Back") { move(to: Step(rawValue: step.rawValue - 1)) }
                        .buttonStyle(.bordered)
                        .disabled(step == .microphone)
                        .accessibilityIdentifier("onboarding.backButton")
                    Spacer(minLength: 0)
                    if step == .keyboard {
                        Button("Done", action: finish)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("onboarding.finishButton")
                    } else {
                        Button("Next") { move(to: Step(rawValue: step.rawValue + 1)) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("onboarding.nextButton")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Later", action: later)
                        .accessibilityIdentifier("onboarding.laterButton")
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    private func pageContent(_ page: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: page.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                switch page {
                case .microphone:
                    permissionCard(
                        title: "Microphone",
                        description: "Capture your voice when you tap Mic. Allowing access here does not start recording.",
                        state: permissions.microphone,
                        buttonTitle: "Allow Microphone",
                        identifier: "onboarding.microphoneButton"
                    ) { await permissions.allowMicrophone() }
                case .speech:
                    permissionCard(
                        title: "Speech Recognition",
                        description: "Turn speech into text with Apple Speech. Audio may be sent to Apple for recognition.",
                        state: permissions.speech,
                        buttonTitle: "Allow Speech Recognition",
                        identifier: "onboarding.speechButton"
                    ) { await permissions.allowSpeech() }
                case .keyboard:
                    keyboardCard
                }

                Text(page == .keyboard
                     ? "You can revisit setup any time from the app."
                     : "You can continue without allowing access and revisit setup any time from the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: "https://github.com/KS1019/voicekeyboardinput/blob/main/PRIVACY.md") {
                    Link("Privacy Policy", destination: url)
                }
            }
            .padding(24)
            .padding(.bottom, 32)
        }
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Voice Keyboard").font(.headline)
            Text("In Settings, go to General → Keyboard → Keyboards → Add New Keyboard and choose Voice Keyboard.")
            Text("Then select Voice Keyboard and turn on Allow Full Access. This lets the keyboard share voice-input results with this app.")
            Button("Open Settings", action: openSettings)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding.settingsButton")
            Text("These settings must be enabled manually. Return here and choose Done. Tap the app’s test field, then use the globe key to choose Voice Keyboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Mic tries to record in the keyboard. If it cannot start there, the app opens to record instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onboardingCard()
    }

    private func move(to nextStep: Step?) {
        guard let nextStep else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            step = nextStep
        }
    }

    private func permissionCard(
        title: String,
        description: String,
        state: OnboardingPermissionState,
        buttonTitle: String,
        identifier: String,
        request: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(description).foregroundStyle(.secondary)
            switch state {
            case .authorized:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button(buttonTitle) { Task { await request() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(permissions.isRequesting)
                    .accessibilityIdentifier(identifier)
            case .denied:
                Text("Access is off. You can enable it in Settings.")
                    .font(.footnote)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.bordered)
            case .restricted:
                Text("Access is restricted on this device. Check Screen Time or device management settings.")
                    .font(.footnote)
            }
        }
        .onboardingCard()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private extension View {
    func onboardingCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview("Microphone · Light") {
    OnboardingView(finish: {}, later: {})
        .preferredColorScheme(.light)
}

#Preview("Speech · Dark") {
    OnboardingView(initialStep: .speech, finish: {}, later: {})
        .preferredColorScheme(.dark)
}

#Preview("Keyboard · Large Text") {
    OnboardingView(initialStep: .keyboard, finish: {}, later: {})
        .environment(\.dynamicTypeSize, .accessibility3)
}
