import SwiftUI

struct OnboardingView: View {
    @State private var permissions = OnboardingPermissionModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    let finish: () -> Void
    let later: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Your voice, wherever you type")
                            .font(.largeTitle.bold())
                            .accessibilityIdentifier("onboarding.title")
                        Text("Allow voice input, then add Voice Keyboard. You control when recording starts.")
                            .foregroundStyle(.secondary)
                    }

                    permissionCard(
                        title: "1. Microphone",
                        description: "Capture your voice when you tap Mic. Allowing access here does not start recording.",
                        state: permissions.microphone,
                        buttonTitle: "Allow Microphone",
                        identifier: "onboarding.microphoneButton"
                    ) { await permissions.allowMicrophone() }

                    permissionCard(
                        title: "2. Speech Recognition",
                        description: "Turn speech into text with Apple Speech. Audio may be sent to Apple for recognition.",
                        state: permissions.speech,
                        buttonTitle: "Allow Speech Recognition",
                        identifier: "onboarding.speechButton"
                    ) { await permissions.allowSpeech() }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("3. Add your keyboard", systemImage: "keyboard")
                            .font(.headline)
                        Text("In Settings, go to General → Keyboard → Keyboards → Add New Keyboard and choose Voice Keyboard.")
                        Text("Then select Voice Keyboard and turn on Allow Full Access. This lets the keyboard share voice-input results with this app.")
                        Button("Open Settings", action: openSettings)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("onboarding.settingsButton")
                        Text("These settings must be enabled manually. Return here and choose Continue to App. Tap the app’s test field, then use the globe key to choose Voice Keyboard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Mic tries to record in the keyboard. If it cannot start there, the app opens to record instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .onboardingCard()

                    Button("Continue to App", action: finish)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.finishButton")
                    if let url = URL(string: "https://github.com/KS1019/voicekeyboardinput/blob/main/PRIVACY.md") {
                        Link("Privacy Policy", destination: url)
                            .frame(maxWidth: .infinity)
                    }
                    Text("You can revisit setup any time from the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
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

#Preview("Onboarding") {
    OnboardingView(finish: {}, later: {})
}
