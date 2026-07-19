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
        let tapGate = AudioInputProbeTapGate()
        let coordinator = AppAudioSessionOperationCoordinator.shared
        guard let operationToken = coordinator.begin() else {
            throw .unavailableInCurrentProcess
        }

        defer {
            tapGate.invalidate()
            if tapIsInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            if sessionIsActive, coordinator.isCurrent(operationToken) {
                // Keep the same ownership token through deactivation so a
                // new speech run cannot start between these two operations.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            coordinator.finish(operationToken)
        }

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
            )
            guard coordinator.isCurrent(operationToken) else { throw CancellationError() }
            try session.setActive(true)
            guard coordinator.isCurrent(operationToken) else { throw CancellationError() }
            sessionIsActive = true
            try await AppAudioSessionRouting.selectPreferredInputIfAvailable(session)

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
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                tapGate.observe(buffer, using: peakTracker)
            }
            tapIsInstalled = true

            engine.prepare()
            try engine.start()
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
