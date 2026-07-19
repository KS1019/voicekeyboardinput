import AVFAudio
import Foundation

enum AppAudioSessionRoutingError: Error {
    case preferredInputDidNotBecomeCurrent
}

enum AppAudioSessionRouting {
    static func selectPreferredInputIfAvailable(_ session: AVAudioSession) async throws {
        guard let preferredInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            return
        }
        guard session.currentRoute.inputs.first?.uid != preferredInput.uid else {
            return
        }

        try session.setPreferredInput(preferredInput)
        for _ in 0..<20 {
            if session.currentRoute.inputs.contains(where: { $0.uid == preferredInput.uid }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AppAudioSessionRoutingError.preferredInputDidNotBecomeCurrent
    }
}
