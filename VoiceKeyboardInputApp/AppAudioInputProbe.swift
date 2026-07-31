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
                    switch await audioSessionOperation.value {
                    case .succeeded:
                        let deactivation = Self.makeSessionOperation(
                            session,
                            active: false,
                            coordinator: coordinator
                        )
                        await Self.settleDeactivation(
                            deactivation,
                            timeout: 2,
                            coordinator: coordinator,
                            operationToken: operationToken,
                            ownershipToken: ownershipToken
                        )
                    case .failed, .timedOut:
                        // Activation never became usable, so no late
                        // deactivation is required and the owner can be
                        // released without quarantining the process.
                        coordinator.finish(operationToken)
                        coordinator.releaseOwnership(ownershipToken)
                    }
                    return
                }
                if let audioEngineOperation {
                    _ = await audioEngineOperation.value
                }
                tapGate.waitUntilDrained()
                if tapWasInstalled {
                    _ = VKRemoveAudioInputTap(engine.inputNode)
                }
                engine.stop()
                // `terminateOperationIfNeeded` invalidates the token so a
                // late engine callback cannot start new work. It must not
                // suppress teardown of a session that was already activated.
                guard sessionWasActive else {
                    coordinator.finish(operationToken)
                    coordinator.releaseOwnership(ownershipToken)
                    return
                }
                if !(await coordinator.waitForPendingSessionOperations(timeout: 10)) {
                    // setPreferredInput can complete after the user-facing
                    // timeout, especially while a Bluetooth HFP route is
                    // materializing. Keep the fence and ownership until the
                    // AVAudioSession operation has actually settled. Do not
                    // issue a deactivation while that operation is unknown.
                    coordinator.markTerminal()
                    return
                }
                let deactivation = Self.makeSessionOperation(
                    session,
                    active: false,
                    coordinator: coordinator
                )
                await Self.settleDeactivation(
                    deactivation,
                    timeout: 2,
                    coordinator: coordinator,
                    operationToken: operationToken,
                    ownershipToken: ownershipToken
                )
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
            guard let format = VKAudioInputNodeOutputFormat(inputNode) else {
                throw AudioCaptureProbeError.unavailableInCurrentProcess
            }

            guard format.channelCount > 0, format.sampleRate > 0 else {
                return try Self.result(
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
                return try Self.result(
                    microphoneCaptureAvailable: false,
                    duration: duration,
                    peakPower: peakTracker.peakPower
                )
            }

            return try Self.result(
                microphoneCaptureAvailable: true,
                duration: duration,
                peakPower: peakTracker.peakPower
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

    private static func settleDeactivation(
        _ operation: Task<AppAudioEngineOperationStatus, Never>,
        timeout: TimeInterval,
        coordinator: AppAudioSessionOperationCoordinator,
        operationToken: UInt64,
        ownershipToken: UInt64
    ) async {
        let status = await waitForOperation(operation, timeout: timeout)
        let finalStatus: AppAudioEngineOperationStatus
        switch status {
        case .timedOut:
            coordinator.markTerminal()
            finalStatus = await operation.value
        case .succeeded, .failed:
            finalStatus = status
        }

        coordinator.finish(operationToken)
        switch finalStatus {
        case .succeeded:
            coordinator.releaseOwnership(ownershipToken)
        case .failed, .timedOut:
            coordinator.markTerminal()
            coordinator.releaseOwnershipAfterTerminal(ownershipToken)
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

    func observe(_ buffer: AVAudioPCMBuffer, using tracker: AudioInputPeakTracker) {
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

private final class AudioInputPeakTracker: @unchecked Sendable {
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
