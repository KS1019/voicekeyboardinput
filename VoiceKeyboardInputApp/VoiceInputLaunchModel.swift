import AVFAudio
import Observation
import VoiceKeyboardModels

enum VoiceInputLaunchStatus: Equatable {
    case idle
    case requestingPermission
    case microphoneActive(peakPower: Float?)
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

protocol MicrophoneActivating: Sendable {
    func activate() async -> VoiceInputLaunchStatus
}

struct AppMicrophoneActivator: MicrophoneActivating {
    func activate() async -> VoiceInputLaunchStatus {
        guard await requestRecordPermission() else {
            return .permissionDenied
        }

        do {
            guard let duration = AudioCaptureProbeDuration(seconds: 0.8) else {
                preconditionFailure("Invalid audio input probe duration")
            }
            let result = try await AppAudioInputProbe().probe(duration: duration)
            return result.microphoneCaptureAvailable
                ? .microphoneActive(peakPower: result.peakPower)
                : .failed("Audio input probe did not receive a microphone route.")
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
}
