import AVFAudio
import Observation
import Speech
import VoiceKeyboardModels

enum VoiceInputLaunchStatus: Equatable {
    case idle
    case requestingPermission
    case microphoneActive(peakPower: Float?)
    case transcriptShared(String)
    case permissionDenied
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .requestingPermission:
            "Requesting Microphone"
        case .microphoneActive:
            "Microphone Active"
        case .transcriptShared:
            "Transcript Ready"
        case .permissionDenied:
            "Microphone Permission Denied"
        case .failed:
            "Microphone Activation Failed"
        }
    }

    var message: String {
        switch self {
        case .idle:
            "Tap Mic in the keyboard to open this app and start the microphone flow."
        case .requestingPermission:
            "Waiting for the iOS microphone permission prompt."
        case let .microphoneActive(peakPower):
            if let peakPower {
                "Audio input probe passed. Peak input: \(peakPower.formatted(.number.precision(.fractionLength(1)))) dB."
            } else {
                "Audio input probe passed. No non-silent input was detected during the short probe."
            }
        case let .transcriptShared(transcript):
            "Transcript saved for the keyboard: \(transcript)"
        case .permissionDenied:
            "Enable microphone access in Settings to use keyboard voice input."
        case let .failed(message):
            message
        }
    }
}

@MainActor
@Observable
final class VoiceInputLaunchModel {
    private let microphoneActivator: any MicrophoneActivating

    var status = VoiceInputLaunchStatus.idle

    init(microphoneActivator: any MicrophoneActivating = AppMicrophoneActivator()) {
        self.microphoneActivator = microphoneActivator
    }

    func handleOpenURL(_ url: URL) {
        guard ContainingAppRoute(url: url) == .startDictation else { return }

        Task {
            await startDictation()
        }
    }

    func startDictation() async {
        guard status != .requestingPermission else { return }
        status = .requestingPermission
        status = await microphoneActivator.activate()
    }
}

@MainActor
protocol MicrophoneActivating {
    func activate() async -> VoiceInputLaunchStatus
}

struct AppMicrophoneActivator: MicrophoneActivating {
    private let transcriptStoreProvider: () -> SharedDictationTranscriptStore?

    init(
        transcriptStoreProvider: @escaping () -> SharedDictationTranscriptStore? = {
            SharedDictationTranscriptStore.appGroupStore()
        }
    ) {
        self.transcriptStoreProvider = transcriptStoreProvider
    }

    func activate() async -> VoiceInputLaunchStatus {
        guard await requestRecordPermission() else {
            return .permissionDenied
        }

        guard await requestSpeechRecognitionAuthorization() else {
            return .failed("Enable speech recognition access in Settings to use keyboard voice input.")
        }

        do {
            let transcriptText = try await AppSpeechDictationService().transcribe(
                locale: Locale.current,
                maximumDuration: 8
            )
            guard let transcript = SharedDictationTranscript(text: transcriptText) else {
                return .failed("Speech recognition returned an empty transcript.")
            }

            guard let transcriptStore = transcriptStoreProvider() else {
                return .failed("Shared App Group storage is unavailable.")
            }

            transcriptStore.save(transcript)
            return .transcriptShared(transcript.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }

    private func requestSpeechRecognitionAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
