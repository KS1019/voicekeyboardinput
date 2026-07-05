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

        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionIsActive = true
            defer {
                if tapIsInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                }
                engine.stop()
                if sessionIsActive {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                }
            }

            guard session.isInputAvailable else {
                return Self.result(false, duration: duration, peakPower: nil)
            }

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                return Self.result(false, duration: duration, peakPower: nil)
            }

            let peakTracker = KeyboardAudioPeakTracker()
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                peakTracker.observe(buffer)
            }
            tapIsInstalled = true

            engine.prepare()
            try engine.start()
            try await Task.sleep(for: .seconds(duration.seconds))

            return Self.result(true, duration: duration, peakPower: await peakTracker.peakPower)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unavailableInCurrentProcess
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
