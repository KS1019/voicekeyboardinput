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
                await coordinator.waitUntilPendingOperationsSettle()
                if coordinator.hasPendingOperation {
                    // A late AVAudioSession callback may still activate the
                    // session. Retain the terminal fence and ownership until
                    // the operation settles; never race a fallback
                    // deactivation against the unknown operation.
                    coordinator.markTerminal()
                    coordinator.releaseOwnershipAfterTerminal(ownershipToken)
                    return
                }
                if let audioSessionOperation {
                    if await audioSessionOperation.task.value == .succeeded {
                        let deactivation = DeferredAudioSessionOperation(session: session, activate: false)
                        guard await deactivation.task.value == .succeeded else {
                            coordinator.markTerminal()
                            coordinator.releaseOwnershipAfterTerminal(ownershipToken)
                            return
                        }
                    }
                    coordinator.releaseOwnership(ownershipToken)
                    coordinator.recoverIfIdle()
                    return
                }
                if let audioEngineOperation {
                    _ = await audioEngineOperation.task.value
                }
                tapGate.waitUntilDrained()
                let didRemoveTap = !tapWasInstalled || VKRemoveAudioEngineInputTap(engine)
                let didStopEngine = VKStopAudioEngine(engine)
                guard didRemoveTap && didStopEngine else {
                    coordinator.markTerminal()
                    coordinator.releaseOwnershipAfterTerminal(ownershipToken)
                    return
                }
                guard sessionWasActive else {
                    coordinator.releaseOwnership(ownershipToken)
                    coordinator.recoverIfIdle()
                    return
                }
                let deactivation = DeferredAudioSessionOperation(session: session, activate: false)
                let deactivationStatus = await waitForKeyboardAudioProbeOperation(
                    deactivation.task,
                    timeout: 2
                )
                if deactivationStatus == .timedOut {
                    // Keep the owner and terminal fence until the late
                    // deactivation settles. A successful late teardown must
                    // be allowed to recover the coordinator for the next
                    // probe instead of requiring an extension restart.
                    Task.detached {
                        let lateStatus = await deactivation.task.value
                        if lateStatus == .succeeded {
                            coordinator.releaseOwnership(ownershipToken)
                            coordinator.recoverIfIdle()
                        } else {
                            coordinator.markTerminal()
                            coordinator.releaseOwnershipAfterTerminal(ownershipToken)
                        }
                    }
                    return
                }
                guard deactivationStatus == .succeeded else {
                    coordinator.markTerminal()
                    coordinator.releaseOwnershipAfterTerminal(ownershipToken)
                    return
                }
                coordinator.releaseOwnership(ownershipToken)
                coordinator.recoverIfIdle()
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
                return try Self.result(false, duration: duration, peakPower: nil)
            }

            guard let inputNode = VKAudioEngineInputNode(engine),
                  let format = VKAudioEngineInputFormat(engine) else {
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }
            guard format.channelCount > 0, format.sampleRate > 0 else {
                return try Self.result(false, duration: duration, peakPower: nil)
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
                return try Self.result(false, duration: duration, peakPower: peakTracker.peakPower)
            }

            return try Self.result(true, duration: duration, peakPower: peakTracker.peakPower)
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
    ) throws(AudioCaptureProbeError) -> AudioCaptureProbeResult {
        let sanitizedPeakPower = peakPower?.isFinite == true ? peakPower : nil
        guard let result = AudioCaptureProbeResult(
            microphoneCaptureAvailable: microphoneCaptureAvailable,
            duration: duration,
            peakPower: sanitizedPeakPower
        ) else {
            throw .unavailableInCurrentProcess
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
    private let condition = NSCondition()
    private var isActive = true
    private var inFlightCallbacks = 0

    func invalidate() {
        condition.lock()
        isActive = false
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilDrained() {
        condition.lock()
        while inFlightCallbacks > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func observe(_ buffer: AVAudioPCMBuffer, using tracker: KeyboardAudioPeakTracker) {
        condition.lock()
        guard isActive else {
            condition.unlock()
            return
        }
        inFlightCallbacks += 1
        condition.unlock()
        defer {
            condition.lock()
            inFlightCallbacks -= 1
            if inFlightCallbacks == 0 { condition.broadcast() }
            condition.unlock()
        }
        tracker.observe(buffer)
    }
}

private final class KeyboardAudioPeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var peakAmplitude: Float = 0

    var peakPower: Float? {
        lock.lock()
        defer { lock.unlock() }
        guard peakAmplitude > 0 else { return nil }
        let decibels = 20 * log10(peakAmplitude)
        return decibels.isFinite ? decibels : nil
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return }

        var localPeak: Float = 0
        let frameStride = max(1, frameLength / 64)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in stride(from: 0, to: frameLength, by: frameStride) {
                localPeak = max(localPeak, abs(samples[frame]))
            }
        }

        guard lock.try() else { return }
        defer { lock.unlock() }
        peakAmplitude = max(peakAmplitude, localPeak)
    }
}
