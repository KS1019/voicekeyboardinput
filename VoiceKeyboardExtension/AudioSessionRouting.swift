import AVFAudio
import Foundation

enum KeyboardAudioSessionRoutingError: Error {
    case preferredInputDidNotBecomeCurrent
    case inputDidNotStabilize
}

enum KeyboardAudioSessionRouting {
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
        throw KeyboardAudioSessionRoutingError.preferredInputDidNotBecomeCurrent
    }

    static func waitForStableInput(
        session: AVAudioSession,
        engine: AVAudioEngine
    ) async throws {
        let monitor = AudioRouteStabilityMonitor()
        let notificationCenter = NotificationCenter.default
        let routeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { _ in
            monitor.markChanged()
        }
        let engineObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            monitor.markChanged()
        }
        defer {
            notificationCenter.removeObserver(routeObserver)
            notificationCenter.removeObserver(engineObserver)
        }

        var stableSamples = 0
        var lastSignature: AudioInputSignature?
        var lastChangeCount = monitor.changeCount

        for _ in 0..<20 {
            let input = session.currentRoute.inputs.first
            let format = engine.inputNode.outputFormat(forBus: 0)
            let signature = input.map {
                AudioInputSignature(
                    uid: $0.uid,
                    channelCount: format.channelCount,
                    sampleRate: format.sampleRate
                )
            }
            let changeCount = monitor.changeCount
            guard let signature,
                  signature.channelCount > 0,
                  signature.sampleRate > 0 else {
                stableSamples = 0
                lastSignature = nil
                lastChangeCount = changeCount
                try await Task.sleep(for: .milliseconds(75))
                continue
            }

            if changeCount != lastChangeCount || signature != lastSignature {
                stableSamples = 0
            }
            lastChangeCount = changeCount
            lastSignature = signature
            stableSamples += 1
            if stableSamples >= 2 {
                return
            }
            try await Task.sleep(for: .milliseconds(75))
        }

        throw KeyboardAudioSessionRoutingError.inputDidNotStabilize
    }
}

private struct AudioInputSignature: Equatable {
    let uid: String
    let channelCount: UInt32
    let sampleRate: Double
}

private final class AudioRouteStabilityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markChanged() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
