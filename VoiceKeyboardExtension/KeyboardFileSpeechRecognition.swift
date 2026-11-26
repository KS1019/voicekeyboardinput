import AVFAudio
import Foundation
import Speech
import VoiceKeyboardModels

@MainActor
protocol KeyboardSegmentRecognizing: AnyObject {
    func start(_ pcm: DictationPCM, locale: VoiceKeyboardLocale,
               completion: @escaping (Result<String, SpeechRecognitionError>) -> Void)
    func cancel()
}

/// Encodes a completed audio segment and owns its file until recognition terminates.
@MainActor
final class KeyboardFileSpeechRecognition: KeyboardSegmentRecognizing {
    private var id: UUID?
    private var encoding: Task<URL, any Error>?
    private var deadline: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var audioURL: URL?
    private var completion: ((Result<String, SpeechRecognitionError>) -> Void)?

    isolated deinit {
        cancel()
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func start(
        _ pcm: DictationPCM,
        locale: VoiceKeyboardLocale,
        completion: @escaping (Result<String, SpeechRecognitionError>) -> Void
    ) {
        cancel()
        guard Self.isAuthorized else {
            completion(.failure(.speechAuthorizationDenied))
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.identifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            completion(.failure(.speechRecognizerUnavailable))
            return
        }

        let id = UUID()
        self.id = id
        self.recognizer = recognizer
        self.completion = completion
        let encoding = Task.detached(priority: .userInitiated) {
            try Self.encode(pcm, id: id)
        }
        self.encoding = encoding
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            self?.finish(.failure(.recognitionFailed("Voice input timed out.")), id: id)
        }
        Task { [weak self] in
            switch await encoding.result {
            case .success(let url):
                guard let self, self.id == id else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.startFileRecognition(url, id: id)
            case .failure:
                self?.finish(.failure(.recognitionStartFailed("Could not prepare the recording.")), id: id)
            }
        }
    }

    func cancel() {
        id = nil
        completion = nil
        deadline?.cancel()
        deadline = nil
        encoding?.cancel()
        encoding = nil
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        audioURL = nil
    }

    private func startFileRecognition(_ url: URL, id: UUID) {
        audioURL = url
        encoding = nil
        guard Self.isAuthorized, let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            finish(.failure(.speechRecognizerUnavailable), id: id)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.taskHint = .dictation
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let finalTranscript = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
            let failed = error != nil
            Task { @MainActor [weak self] in
                if let finalTranscript,
                   !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.finish(.success(finalTranscript), id: id)
                } else if failed || finalTranscript != nil {
                    self?.finish(.failure(.recognitionFailed("No final speech result.")), id: id)
                }
            }
        }
    }

    private func finish(_ result: Result<String, SpeechRecognitionError>, id: UUID) {
        guard self.id == id else { return }
        let completion = completion
        cancel()
        completion?(result)
    }

    private nonisolated static func encode(_ pcm: DictationPCM, id: UUID) throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("WebKitDictation", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleRecordings(in: directory, manager: manager)
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("m4a")

        do {
            let samples = pcm.normalizedSamples()
            try Task.checkCancellation()
            try writeAudio(samples, to: url)
            try Task.checkCancellation()
            return url
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
    }

    private nonisolated static func writeAudio(_ samples: [Float], to url: URL) throws {
        let sampleRate = Double(DictationPCM.sampleRate)
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SpeechRecognitionError.audioInputUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let address = source.baseAddress {
                channel.update(from: address, count: source.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        file.close()
    }

    private nonisolated static func removeStaleRecordings(in directory: URL, manager: FileManager) {
        let cutoff = Date().addingTimeInterval(-300)
        let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in urls ?? [] where url.pathExtension == "m4a" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            let resources = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = resources?.contentModificationDate, modified < cutoff {
                try? manager.removeItem(at: url)
            }
        }
    }
}
