import AVFAudio
import Observation
import Speech

enum OnboardingPermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

@MainActor
@Observable
final class OnboardingPermissionModel {
    private(set) var microphone: OnboardingPermissionState = .notDetermined
    private(set) var speech: OnboardingPermissionState = .notDetermined
    private(set) var isRequesting = false

    private let microphoneStatus: () -> OnboardingPermissionState
    private let speechStatus: () -> OnboardingPermissionState
    private let requestMicrophone: () async -> Void
    private let requestSpeech: () async -> Void

    init(
        microphoneStatus: @escaping () -> OnboardingPermissionState = {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .authorized
            case .denied: .denied
            case .undetermined: .notDetermined
            @unknown default: .restricted
            }
        },
        speechStatus: @escaping () -> OnboardingPermissionState = {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .authorized
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .restricted
            }
        },
        requestMicrophone: @escaping () async -> Void = {
            _ = await AVAudioApplication.requestRecordPermission()
        },
        requestSpeech: @escaping () async -> Void = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
    ) {
        self.microphoneStatus = microphoneStatus
        self.speechStatus = speechStatus
        self.requestMicrophone = requestMicrophone
        self.requestSpeech = requestSpeech
        refresh()
    }

    func refresh() {
        microphone = microphoneStatus()
        speech = speechStatus()
    }

    func allowMicrophone() async {
        guard !isRequesting, microphone == .notDetermined else { return }
        isRequesting = true
        await requestMicrophone()
        refresh()
        isRequesting = false
    }

    func allowSpeech() async {
        guard !isRequesting, speech == .notDetermined else { return }
        isRequesting = true
        await requestSpeech()
        refresh()
        isRequesting = false
    }
}
