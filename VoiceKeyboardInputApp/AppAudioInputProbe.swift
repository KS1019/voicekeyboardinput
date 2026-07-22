import AVFAudio
import Darwin
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

struct AppAudioInputProbe: AudioCaptureProbing {
    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        var sessionIsActive = false
        var tapIsInstalled = false
        var lingeringAudioSessionOperation: Task<AppAudioEngineOperationStatus, Never>?
        var lingeringAudioEngineOperation: Task<AppAudioEngineOperationStatus, Never>?
        let tapGate = AudioInputProbeTapGate()
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let ownershipToken = coordinator.acquireOwnership() else {
            throw .unavailableInCurrentProcess
        }
        guard let operationToken = coordinator.begin() else {
            coordinator.releaseOwnership(ownershipToken)
            throw .unavailableInCurrentProcess
        }

        defer {
            tapGate.invalidate()
            let tapWasInstalled = tapIsInstalled
            let sessionWasActive = sessionIsActive
            let audioSessionOperation = lingeringAudioSessionOperation
            let audioEngineOperation = lingeringAudioEngineOperation
            Task.detached {
                if let audioSessionOperation {
                    if await audioSessionOperation.value == .succeeded {
                        let deactivation = Self.makeSessionOperation(
                            session,
                            active: false,
                            coordinator: coordinator
                        )
                        _ = await Self.waitForOperation(deactivation, timeout: 2)
                    }
                    coordinator.releaseOwnership(ownershipToken)
                    coordinator.markTerminalAndRelease(operationToken)
                    return
                }
                if let audioEngineOperation {
                    _ = await audioEngineOperation.value
                }
                if tapWasInstalled {
                    _ = VKRemoveAudioInputTap(engine.inputNode)
                }
                engine.stop()
                guard sessionWasActive, coordinator.isCurrent(operationToken) else {
                    coordinator.finish(operationToken)
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                guard await coordinator.waitForPendingSessionOperations(timeout: 10) else {
                    coordinator.markTerminalAndRelease(operationToken)
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                let deactivation = Self.makeSessionOperation(
                    session,
                    active: false,
                    coordinator: coordinator
                )
                guard await Self.waitForOperation(deactivation, timeout: 2) == .succeeded else {
                    coordinator.markTerminalAndRelease(operationToken)
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                if coordinator.isCurrent(operationToken) {
                    coordinator.finish(operationToken)
                }
                coordinator.releaseOwnership(ownershipToken)
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                coordinator.terminateOperationIfNeeded(operationToken)
            }
        }

        do {
            let activation = Self.makeSessionOperation(
                session,
                active: true,
                coordinator: coordinator
            )
            switch await Self.waitForOperation(activation, timeout: 2) {
            case .succeeded:
                sessionIsActive = true
            case .failed:
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            case .timedOut:
                lingeringAudioSessionOperation = activation
                coordinator.markTerminal()
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            guard coordinator.isCurrent(operationToken) else { throw CancellationError() }
            try await AppAudioSessionRouting.selectPreferredInputIfAvailable(session)
            try await AppAudioSessionRouting.waitForStableInput(
                session: session,
                engine: engine
            )

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            guard format.channelCount > 0, format.sampleRate > 0 else {
                return Self.result(
                    microphoneCaptureAvailable: false,
                    duration: duration,
                    peakPower: nil
                )
            }

            let peakTracker = AudioInputPeakTracker()
            guard VKInstallAudioInputTap(inputNode, { buffer, _ in
                tapGate.observe(buffer, using: peakTracker)
            }) else {
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            tapIsInstalled = true

            let audioEngineOperation = Self.makeEngineOperation(engine)
            switch await Self.waitForOperation(audioEngineOperation, timeout: 2) {
            case .succeeded:
                break
            case .failed:
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            case .timedOut:
                lingeringAudioEngineOperation = audioEngineOperation
                coordinator.markTerminal()
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            try await Task.sleep(for: .seconds(duration.seconds))

            guard session.isInputAvailable,
                  !session.currentRoute.inputs.isEmpty,
                  engine.isRunning else {
                return Self.result(
                    microphoneCaptureAvailable: false,
                    duration: duration,
                    peakPower: await peakTracker.peakPower
                )
            }

            return Self.result(
                microphoneCaptureAvailable: true,
                duration: duration,
                peakPower: await peakTracker.peakPower
            )
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unavailableInCurrentProcess
        }
    }

    private static func makeSessionOperation(
        _ session: AVAudioSession,
        active: Bool,
        coordinator: AppAudioSessionOperationCoordinator
    ) -> Task<AppAudioEngineOperationStatus, Never> {
        coordinator.beginSessionOperation()
        return Task.detached {
            defer { coordinator.completeSessionOperation() }
            do {
                if active {
                    try session.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
                    )
                    try session.setActive(true)
                } else {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
                return .succeeded
            } catch {
                return .failed
            }
        }
    }

    private static func makeEngineOperation(
        _ engine: AVAudioEngine
    ) -> Task<AppAudioEngineOperationStatus, Never> {
        Task.detached {
            do {
                engine.prepare()
                try engine.start()
                return .succeeded
            } catch {
                return .failed
            }
        }
    }

    private static func waitForOperation(
        _ operation: Task<AppAudioEngineOperationStatus, Never>,
        timeout: TimeInterval
    ) async -> AppAudioEngineOperationStatus {
        await withCheckedContinuation { continuation in
            let gate = AppAudioProbeCompletionGate()
            Task {
                let status = await operation.value
                guard gate.finish() else { return }
                continuation.resume(returning: status)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard gate.finish() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
    }

    private static func result(
        microphoneCaptureAvailable: Bool,
        duration: AudioCaptureProbeDuration,
        peakPower: Float?
    ) -> AudioCaptureProbeResult {
        guard let result = AudioCaptureProbeResult(
            microphoneCaptureAvailable: microphoneCaptureAvailable,
            duration: duration,
            peakPower: peakPower
        ) else {
            preconditionFailure("Invalid audio input probe result")
        }
        return result
    }

}

private final class AppAudioProbeCompletionGate: @unchecked Sendable {
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

private final class AudioInputProbeTapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true

    func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func observe(_ buffer: AVAudioPCMBuffer, using tracker: AudioInputPeakTracker) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        tracker.observe(buffer)
    }
}

private actor AudioInputPeakTracker {
    private var peakAmplitude: Float = 0

    var peakPower: Float? {
        guard peakAmplitude > 0 else { return nil }
        let decibels = 20 * log10(peakAmplitude)
        return decibels.isFinite ? decibels : nil
    }

    nonisolated func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return }

        var localPeak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                localPeak = max(localPeak, abs(samples[frame]))
            }
        }

        Task {
            await record(localPeak)
        }
    }

    private func record(_ amplitude: Float) {
        peakAmplitude = max(peakAmplitude, amplitude)
    }
}
