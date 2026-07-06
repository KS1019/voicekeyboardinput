import SwiftUI
import VoiceKeyboardCore
import VoiceKeyboardModels
import VoiceKeyboardPresentation

struct ContentView: View {
    @State private var sampleTranscript = "hello comma world newline"
    @State private var commandPreview = CommandPreviewPresentationSnapshot.empty
    @State private var keyboardQAText = ""
    @State private var showsDeveloperDetails = false
    private let voiceInputLaunchModel: VoiceInputLaunchModel

    private let pipeline = VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: Locale.current.identifier))

    init(voiceInputLaunchModel: VoiceInputLaunchModel = VoiceInputLaunchModel()) {
        self.voiceInputLaunchModel = voiceInputLaunchModel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    keyboardSetupPanel
                    voiceInputPanel
                    keyboardQAPanel
                    developerDetails
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(appBackground)
            .navigationTitle("Voice Keyboard")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard-first voice input")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Set up Voice Keyboard, enable full access, then validate speech input from any host text field.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyboardSetupPanel: some View {
        Panel("Setup Checklist") {
            VStack(alignment: .leading, spacing: 12) {
                Label("Add Voice Keyboard in Settings > General > Keyboard > Keyboards.", systemImage: "keyboard")
                Label("Turn Allow Full Access on for Voice Keyboard.", systemImage: "checkmark.shield")
                Label("Tap the text field below, switch to Voice Keyboard, then press Mic.", systemImage: "mic.circle")

                Text("iOS 26 uses the legacy Speech audio-buffer path; iOS 27 can use the SpeechAnalyzer path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var voiceInputPanel: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(statusTint.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(statusTint.opacity(0.22), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(statusTint.opacity(0.14))
                        Circle()
                            .stroke(statusTint.opacity(0.28), lineWidth: 1)
                        Image(systemName: "waveform")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(statusTint)
                    }
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 8) {
                        statusBadge
                        Text(voiceInputLaunchModel.status.message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                VoiceSignalView(tint: statusTint, isActive: voiceInputLaunchModel.status.isActive)

                Button {
                    Task {
                        await voiceInputLaunchModel.startDictation()
                    }
                } label: {
                    Label("Start Voice Input", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("voiceInput.startButton")
            }
            .padding(16)
        }
    }

    private var developerDetails: some View {
        DisclosureGroup("Developer Details", isExpanded: $showsDeveloperDetails) {
            VStack(alignment: .leading, spacing: 14) {
                commandPreviewPanel
                setupPanel
                validationPanel
            }
            .padding(.top, 10)
        }
        .font(.headline)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var keyboardQAPanel: some View {
        Panel("Keyboard Extension QA") {
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    "Tap here, then switch to Voice Keyboard.",
                    text: $keyboardQAText,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("keyboard.qa.textField")

                Text("Use this field to verify the keyboard extension loads, starts keyboard STT from Mic, inserts final text or shows a specific unavailable state, and keeps Delete / Return responsive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("keyboard.qa.instructions")
            }
        }
    }

    private var commandPreviewPanel: some View {
        Panel("Command Preview") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Transcript", text: $sampleTranscript)
                    .textFieldStyle(.roundedBorder)

                Button("Preview Commands") {
                    previewSampleTranscript()
                }
                .buttonStyle(.bordered)

                Text(commandPreview.displayText)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var setupPanel: some View {
        Panel("Setup") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Add Voice Keyboard in Settings > General > Keyboard > Keyboards.", systemImage: "keyboard")
                Label("Turn Allow Full Access on before validating keyboard-side STT.", systemImage: "checkmark.shield")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var validationPanel: some View {
        Panel("Validation Notes") {
            Text("The keyboard microphone button attempts keyboard-process STT. iOS 26 uses SFSpeechRecognizer with audio buffers; iOS 27 can use SpeechAnalyzer when available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTint: Color {
        switch voiceInputLaunchModel.status {
        case .microphoneActive:
            .green
        case .failed, .permissionDenied:
            .red
        case .requestingPermission:
            .orange
        case .idle:
            .blue
        }
    }

    private var statusBadge: some View {
        Label(voiceInputLaunchModel.status.title, systemImage: "record.circle")
            .font(.headline)
            .foregroundStyle(statusTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusTint.opacity(0.12), in: Capsule())
    }

    private var appBackground: some View {
        Color(.systemGroupedBackground)
        .ignoresSafeArea()
    }

    private func previewSampleTranscript() {
        let operations = pipeline.operations(
            for: sampleTranscript,
            documentContextBeforeInput: ""
        )
        commandPreview = CommandPreviewPresentationSnapshot(operations: operations)
    }
}

private struct VoiceSignalView: View {
    let tint: Color
    let isActive: Bool

    private let barHeights: [CGFloat] = [8, 14, 22, 30, 18, 26, 12, 20, 10]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(barHeights.indices, id: \.self) { index in
                Capsule()
                    .fill(isActive || index.isMultiple(of: 3) ? tint : Color.secondary.opacity(0.22))
                    .frame(width: 6, height: isActive ? barHeights[index] : max(4, barHeights[index] * 0.35))
                    .opacity(isActive ? 0.95 : 0.62)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .accessibilityHidden(true)
    }
}

private struct Panel<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private extension VoiceInputLaunchStatus {
    var isActive: Bool {
        switch self {
        case .microphoneActive, .requestingPermission:
            true
        case .failed, .idle, .permissionDenied:
            false
        }
    }

}

#Preview("Voice Keyboard App") {
    ContentView()
}
