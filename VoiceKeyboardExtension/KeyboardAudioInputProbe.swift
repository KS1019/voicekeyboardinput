import AVFAudio
import Darwin
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

struct KeyboardAudioCapabilityChecker: CapabilityChecking {
    func currentCapabilities() -> RuntimeCapabilities {
        RuntimeCapabilities(
            microphoneCaptureAvailable: AVAudioApplication.shared.recordPermission == .granted,
            speechRecognitionAvailable: true,
            textCleanupAvailable: false
        )
    }
}

struct KeyboardAudioInputProbe: AudioCaptureProbing {
    func probe(duration: AudioCaptureProbeDuration) async throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw .unavailableInCurrentProcess
        }

        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        var sessionIsActive = false
        var tapIsInstalled = false
        var lingeringAudioSessionOperation: DeferredAudioSessionOperation?
        var lingeringAudioEngineOperation: DeferredAudioEngineOperation?
        let tapGate = AudioInputProbeTapGate()
        let coordinator = KeyboardAudioSessionOperationCoordinator.shared
        guard let ownershipToken = coordinator.acquireOwnership() else {
            throw .unavailableInCurrentProcess
        }

        defer {
            tapGate.invalidate()
            let tapWasInstalled = tapIsInstalled
            let sessionWasActive = sessionIsActive
            let audioSessionOperation = lingeringAudioSessionOperation
            let audioEngineOperation = lingeringAudioEngineOperation
            Task.detached {
                guard await coordinator.waitForPendingOperations(
                    timeout: 10
                ) else {
                    coordinator.markTerminal()
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                if let audioSessionOperation {
                    if await audioSessionOperation.task.value == .succeeded {
                        _ = await DeferredAudioSessionOperation(session: session, activate: false).task.value
                    }
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                if let audioEngineOperation {
                    _ = await audioEngineOperation.task.value
                }
                if tapWasInstalled {
                    _ = VKRemoveAudioInputTap(engine.inputNode)
                }
                engine.stop()
                guard sessionWasActive else {
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                let deactivation = DeferredAudioSessionOperation(session: session, activate: false)
                guard await waitForKeyboardAudioProbeOperation(deactivation.task, timeout: 2) == .succeeded else {
                    coordinator.markTerminal()
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                coordinator.releaseOwnership(ownershipToken)
            }
        }

        do {
            let activation = DeferredAudioSessionOperation(session: session, activate: true)
            switch await waitForKeyboardAudioProbeOperation(activation.task, timeout: 2) {
            case .succeeded:
                sessionIsActive = true
            case .failed:
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            case .timedOut:
                lingeringAudioSessionOperation = activation
                coordinator.markTerminal()
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            try await KeyboardAudioSessionRouting.selectPreferredInputIfAvailable(session)
            try await KeyboardAudioSessionRouting.waitForStableInput(
                session: session,
                engine: engine
            )

            guard session.isInputAvailable else {
                return Self.result(false, duration: duration, peakPower: nil)
            }

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                return Self.result(false, duration: duration, peakPower: nil)
            }

            let peakTracker = KeyboardAudioPeakTracker()
            guard VKInstallAudioInputTap(inputNode, { buffer, _ in
                tapGate.observe(buffer, using: peakTracker)
            }) else {
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            tapIsInstalled = true

            let audioEngineOperation = DeferredAudioEngineOperation(engine: engine)
            switch await waitForKeyboardAudioProbeOperation(audioEngineOperation.task, timeout: 2) {
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
                return Self.result(false, duration: duration, peakPower: await peakTracker.peakPower)
            }

            return Self.result(true, duration: duration, peakPower: await peakTracker.peakPower)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unavailableInCurrentProcess
        }
    }

    private func waitForKeyboardAudioProbeOperation(
        _ operation: Task<AudioSessionOperationStatus, Never>,
        timeout: TimeInterval
    ) async -> AudioSessionOperationStatus {
        await withCheckedContinuation { continuation in
            let gate = KeyboardAudioProbeCompletionGate()
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
        _ microphoneCaptureAvailable: Bool,
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

private final class KeyboardAudioProbeCompletionGate: @unchecked Sendable {
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

    func observe(_ buffer: AVAudioPCMBuffer, using tracker: KeyboardAudioPeakTracker) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        tracker.observe(buffer)
    }
}

private actor KeyboardAudioPeakTracker {
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
