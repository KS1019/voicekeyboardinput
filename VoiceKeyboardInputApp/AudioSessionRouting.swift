import AVFAudio
import Foundation

enum AppAudioSessionRoutingError: Error {
    case preferredInputDidNotBecomeCurrent
    case inputDidNotStabilize
    case operationTimedOut
}

enum AppAudioSessionRouting {
    static func selectPreferredInputIfAvailable(_ session: AVAudioSession) async throws {
        // Bluetooth HFP can appear in availableInputs shortly after
        // activation/route-change notification delivery. Do not freeze a
        // built-in microphone decision from the first snapshot.
        for attempt in 0..<32 {
            if let preferredInput = preferredInput(in: session.availableInputs ?? []) {
                if let currentInput = session.currentRoute.inputs.first,
                   currentInput.portType != .builtInMic,
                   priority(of: currentInput.portType) <= priority(of: preferredInput.portType) {
                    return
                }
                guard session.currentRoute.inputs.first?.uid != preferredInput.uid else {
                    return
                }

                try await setPreferredInput(preferredInput, on: session)
                for _ in 0..<32 {
                    if session.currentRoute.inputs.contains(where: { $0.uid == preferredInput.uid }) {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw AppAudioSessionRoutingError.preferredInputDidNotBecomeCurrent
            }

            guard attempt < 31 else { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func preferredInput(
        in inputs: [AVAudioSessionPortDescription]
    ) -> AVAudioSessionPortDescription? {
        // Prefer physical input routes that have just become available over
        // HFP. In particular, avoid selecting Bluetooth while USB/wired
        // materialization is still catching up after a route change.
        let priority: [AVAudioSession.Port] = [
            .usbAudio,
            .headsetMic,
            .lineIn,
            .bluetoothHFP
        ]
        for portType in priority {
            if let input = inputs.first(where: { $0.portType == portType }) {
                return input
            }
        }
        return nil
    }

    private static func priority(of port: AVAudioSession.Port) -> Int {
        switch port {
        case .usbAudio: 0
        case .headsetMic: 1
        case .lineIn: 2
        case .bluetoothHFP: 3
        default: 4
        }
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
        let availableInputsObserver = notificationCenter.addObserver(
            forName: AVAudioSession.availableInputsChangeNotification,
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
            notificationCenter.removeObserver(availableInputsObserver)
            notificationCenter.removeObserver(engineObserver)
        }

        var stableSamples = 0
        var builtInDiscoverySamples = 0
        var lastSignature: AudioInputSignature?
        var lastChangeCount = monitor.changeCount

        // Bluetooth HFP and USB routes can materialize after several route
        // notifications. Keep the retry bounded, but give late hardware a
        // few extra seconds to settle before reporting unavailability.
        for _ in 0..<80 {
            let input = session.currentRoute.inputs.first
            guard let format = VKAudioInputNodeOutputFormat(engine.inputNode) else {
                stableSamples = 0
                lastSignature = nil
                lastChangeCount = monitor.changeCount
                try await Task.sleep(for: .milliseconds(75))
                continue
            }
            let signature = input.map {
                AudioInputSignature(
                    uid: $0.uid,
                    channelCount: format.channelCount,
                    sampleRate: format.sampleRate
                )
            }
            let changeCount = monitor.changeCount
            if changeCount != lastChangeCount {
                // An HFP route can become available after the initial
                // discovery loop has finished. Re-run the explicit selection
                // when the availability notification arrives; observing the
                // route alone does not make AVAudioSession choose it.
                try await selectPreferredInputIfAvailable(session)
            }
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
                builtInDiscoverySamples = 0
            }
            lastChangeCount = changeCount
            lastSignature = signature
            stableSamples += 1
            if stableSamples >= 4 {
                if input?.portType == .builtInMic {
                    // A Bluetooth HFP/USB route can materialize just after
                    // the preferred-input retry loop. Hold a built-in
                    // fallback for a bounded discovery window so the first
                    // stable sample does not permanently win the race.
                    builtInDiscoverySamples += 1
                    if builtInDiscoverySamples < 20 {
                        try await Task.sleep(for: .milliseconds(75))
                        continue
                    }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(75))
        }

        throw AppAudioSessionRoutingError.inputDidNotStabilize
    }

    private static func setPreferredInput(
        _ input: AVAudioSessionPortDescription,
        on session: AVAudioSession
    ) async throws {
        let coordinator = AppAudioSessionOperationCoordinator.shared
        coordinator.beginSessionOperation()
        let operation = Task.detached { () -> Bool in
            defer { coordinator.completeSessionOperation() }
            do {
                try session.setPreferredInput(input)
                return true
            } catch {
                return false
            }
        }
        let result: Bool? = await withCheckedContinuation { continuation in
            let gate = AppAudioSessionRoutingCompletionGate()
            Task {
                let result = await operation.value
                guard gate.finish() else { return }
                continuation.resume(returning: result)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard gate.finish() else { return }
                continuation.resume(returning: nil)
            }
        }
        guard let result else {
            coordinator.markTerminal()
            throw AppAudioSessionRoutingError.operationTimedOut
        }
        guard result else { throw AppAudioSessionRoutingError.preferredInputDidNotBecomeCurrent }
    }
}

private final class AppAudioSessionRoutingCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
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
