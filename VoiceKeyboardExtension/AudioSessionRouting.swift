import AVFAudio
import Foundation

enum KeyboardAudioSessionRoutingError: Error {
    case preferredInputDidNotBecomeCurrent
    case inputDidNotStabilize
    case operationTimedOut
}

final class KeyboardAudioSessionOperationCoordinator: @unchecked Sendable {
    static let shared = KeyboardAudioSessionOperationCoordinator()

    private let lock = NSLock()
    private var pendingOperations = 0
    private var terminal = false
    private var nextOwnerToken: UInt64 = 0
    private var ownerToken: UInt64?

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    var hasPendingOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingOperations > 0
    }

    func acquireOwnership() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, ownerToken == nil else { return nil }
        nextOwnerToken &+= 1
        ownerToken = nextOwnerToken
        return nextOwnerToken
    }

    func releaseOwnership(_ token: UInt64) {
        lock.lock()
        if ownerToken == token {
            ownerToken = nil
        }
        lock.unlock()
    }

    func beginOperation() {
        lock.lock()
        pendingOperations += 1
        lock.unlock()
    }

    func completeOperation() {
        lock.lock()
        pendingOperations = max(0, pendingOperations - 1)
        lock.unlock()
    }

    func markTerminal() {
        lock.lock()
        terminal = true
        lock.unlock()
    }

    func waitForPendingOperations(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while hasPendingOperation {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func waitUntilAvailable(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let snapshot = availabilitySnapshot()
            let available = snapshot.available
            let isTerminal = snapshot.isTerminal
            if isTerminal { return false }
            if available { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func availabilitySnapshot() -> (available: Bool, isTerminal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            ownerToken == nil && pendingOperations == 0,
            terminal
        )
    }
}

enum KeyboardAudioSessionRouting {
    static func selectPreferredInputIfAvailable(_ session: AVAudioSession) async throws {
        guard let preferredInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            return
        }
        guard session.currentRoute.inputs.first?.uid != preferredInput.uid else {
            return
        }

        try await setPreferredInput(preferredInput, on: session)
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

    private static func setPreferredInput(
        _ input: AVAudioSessionPortDescription,
        on session: AVAudioSession
    ) async throws {
        let coordinator = KeyboardAudioSessionOperationCoordinator.shared
        coordinator.beginOperation()
        let operation = Task.detached { () -> Bool in
            defer { coordinator.completeOperation() }
            do {
                try session.setPreferredInput(input)
                return true
            } catch {
                return false
            }
        }
        let result: Bool? = await withCheckedContinuation { continuation in
            let gate = KeyboardAudioSessionRoutingCompletionGate()
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
            throw KeyboardAudioSessionRoutingError.operationTimedOut
        }
        guard result else { throw KeyboardAudioSessionRoutingError.preferredInputDidNotBecomeCurrent }
    }
}

private final class KeyboardAudioSessionRoutingCompletionGate: @unchecked Sendable {
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
