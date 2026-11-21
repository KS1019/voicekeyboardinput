import SwiftUI
import UIKit
import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels
import VoiceKeyboardPresentation

private actor LiteralTranscriptPreviewWorker {
    func preview(
        using pipeline: LiteralTranscriptCommandPipeline,
        transcript: String,
        documentContext: String
    ) -> LiteralTranscriptPreview {
        guard !Task.isCancelled else {
            return LiteralTranscriptPreview(elements: [], operations: [])
        }
        return pipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContext
        )
    }
}

struct ContentView: View {
    @State private var sampleTranscript = "comma newline"
    @State private var commandPreview = CommandPreviewPresentationSnapshot.empty
    @State private var keyboardQAText = ""
    @State private var showsDeveloperDetails = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration: UInt64 = 0
    @State private var previewWorker = LiteralTranscriptPreviewWorker()
    private let voiceInputLaunchModel: VoiceInputLaunchModel

    private let pipeline = LiteralTranscriptCommandPipeline(
        locale: VoiceKeyboardLocale(identifier: Locale.current.identifier)
    )

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
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard-first voice input")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Set up Voice Keyboard, allow microphone and speech access, then try it in an app that supports custom keyboards.")
                .font(.callout)
                .foregroundStyle(.secondary)
            privacyPolicyLink
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyboardSetupPanel: some View {
        Panel("Setup Checklist") {
            VStack(alignment: .leading, spacing: 12) {
                Label("Add Voice Keyboard in Settings > General > Keyboard > Keyboards.", systemImage: "keyboard")
                Label("Turn Allow Full Access on for Voice Keyboard.", systemImage: "checkmark.shield")
                Label("Use Start Voice Input to allow microphone and speech access and try recording.", systemImage: "mic.circle")
                Label("Tap the text field below, switch to Voice Keyboard, then press Mic.", systemImage: "keyboard")

                Button {
                    openApplicationSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.openButton")

                Text("With permission and Full Access, Mic tries to record in the keyboard. If recording cannot start there, voice input falls back to this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.voiceInputInstructions")
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
                            .foregroundStyle(statusForeground)
                            .accessibilityHidden(true)
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
                        if voiceInputLaunchModel.status.isStoppable {
                            await voiceInputLaunchModel.stopDictation()
                        } else {
                            await voiceInputLaunchModel.startDictation()
                        }
                    }
                } label: {
                    Label(
                        voiceInputLaunchModel.status.isStoppable ? "Stop Voice Input" : "Start Voice Input",
                        systemImage: voiceInputLaunchModel.status.isStoppable ? "stop.fill" : "mic.fill"
                    )
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

                Text("Use this field to try voice input, check final text insertion, and test Delete / Return.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("keyboard.qa.instructions")
            }
        }
    }

    private var commandPreviewPanel: some View {
        Panel("Command Preview") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Transcript", text: boundedBinding(for: $sampleTranscript))
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
                Label("Turn Allow Full Access on before using voice input.", systemImage: "checkmark.shield")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var validationPanel: some View {
        Panel("Validation Notes") {
            Text("In-keyboard recording is experimental and still needs real-device testing. If no audio arrives within 2 seconds, the keyboard falls back to app recording. Final text is inserted only if the original text field is still valid.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTint: Color {
        switch voiceInputLaunchModel.status {
        case .microphoneActive, .transcriptShared:
            .green
        case .failed, .permissionDenied:
            .red
        case .requestingPermission:
            .orange
        case .idle, .sessionReady:
            .blue
        }
    }

    private var statusForeground: Color {
        switch voiceInputLaunchModel.status {
        case .failed, .permissionDenied, .requestingPermission:
            .primary
        case .microphoneActive, .transcriptShared, .idle, .sessionReady:
            statusTint
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle")
                .foregroundStyle(statusForeground)
                .accessibilityHidden(true)
            Text(voiceInputLaunchModel.status.title)
                .foregroundStyle(.primary)
        }
        .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusTint.opacity(0.12), in: Capsule())
    }

    private var appBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var privacyPolicyLink: some View {
        if let url = URL(string: "https://github.com/KS1019/voicekeyboardinput/blob/main/PRIVACY.md") {
            Link("Privacy Policy", destination: url)
                .font(.footnote.weight(.medium))
                .accessibilityIdentifier("privacyPolicy.link")
        }
    }

    private func previewSampleTranscript() {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        let pipeline = pipeline
        let transcript = sampleTranscript
        previewTask = Task { @MainActor in
            let preview = await previewWorker.preview(
                using: pipeline,
                transcript: transcript,
                documentContext: ""
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            commandPreview = CommandPreviewPresentationSnapshot(
                operations: preview.operations
            )
        }
    }

    private func boundedBinding(for source: Binding<String>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: {
                let bounded = VoiceKeyboardTextLimits.bounded($0)
                guard bounded != source.wrappedValue else { return }
                source.wrappedValue = bounded
                previewGeneration &+= 1
                previewTask?.cancel()
                previewTask = nil
                commandPreview = .empty
            }
        )
    }

    private func openApplicationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
        case .failed, .idle, .sessionReady, .permissionDenied, .transcriptShared:
            false
        }
    }

}

#Preview("Voice Keyboard App") {
    ContentView()
}

#Preview("Voice Keyboard App Light") {
    ContentView()
        .preferredColorScheme(.light)
}

#Preview("Voice Keyboard App Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
