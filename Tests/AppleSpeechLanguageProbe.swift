import AVFAudio
import Darwin
import Foundation
import Speech

// A macOS-only experiment. Suggestions never insert text or execute commands.
@main
struct AppleSpeechLanguageProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Speech language probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--self-test") { AppleSpeechLanguageContext.runChecks() }
        let windows = arguments.contains("--windows")
        guard arguments.allSatisfy({ !$0.hasPrefix("--") || ["--self-test", "--windows"].contains($0) }) else {
            throw ProbeError.invalidArguments
        }
        let paths = arguments.filter { !$0.hasPrefix("--") }
        guard !paths.isEmpty else {
            print("Usage: AppleSpeechLanguageProbe [--self-test] [--windows] audio-file ... (installed models only)")
            return
        }
        guard SpeechTranscriber.isAvailable else {
            throw ProbeError.unavailable
        }

        let locales = ["ja-JP", "en-US"]
        for identifier in locales {
            let module = makeTranscriber(identifier)
            let status = await AssetInventory.status(forModules: [module])
            print("MODEL", identifier, status)
            guard status == .installed else { throw ProbeError.missingModel(identifier) }
        }

        for path in paths {
            let source = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let duration = Double(source.length) / source.processingFormat.sampleRate
            guard duration > 0, duration <= 60 else { throw ProbeError.invalidDuration }
            let lengths = windows ? Array(Set([1, 2, 4, duration].map { min($0, duration) })).sorted() : [duration]
            for seconds in lengths {
                let prefix = try makePrefix(source, seconds: seconds)
                defer { try? FileManager.default.removeItem(at: prefix) }
                var scores: [AppleSpeechLanguageContext.Language: Double] = [:]
                for identifier in locales {
                    let module = makeTranscriber(identifier)
                    let analyzer = SpeechAnalyzer(modules: [module])
                    let results = Task { () throws -> [(String, [Double])] in
                        var output: [(String, [Double])] = []
                        for try await result in module.results {
                            output.append((
                                String(result.text.characters),
                                result.text.runs.compactMap { $0.transcriptionConfidence }
                            ))
                        }
                        return output
                    }
                    let start = ContinuousClock.now
                    do {
                        try await analyzer.start(
                            inputAudioFile: AVAudioFile(forReading: prefix),
                            finishAfterFile: true
                        )
                        let output = try await results.value
                        let confidences = output.flatMap { $0.1 }.filter { $0.isFinite && (0...1).contains($0) }
                        if !confidences.isEmpty {
                            scores[identifier == "ja-JP" ? .japanese : .english] = confidences.reduce(0, +) / Double(confidences.count)
                        }
                        print("RESULT", path, "SECONDS", seconds, identifier, output, "TIME", start.duration(to: .now))
                    } catch {
                        await analyzer.cancelAndFinishNow()
                        results.cancel()
                        _ = await results.result
                        throw error
                    }
                }
                reportContextMatrix(scores: scores, seconds: seconds, isFinal: seconds == duration)
            }
        }
    }

    private static func makePrefix(_ source: AVAudioFile, seconds: Double) throws -> URL {
        let frames = AVAudioFrameCount(min(Double(source.length), seconds * source.processingFormat.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else {
            throw ProbeError.invalidDuration
        }
        source.framePosition = 0
        try source.read(into: buffer, frameCount: frames)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: source.processingFormat.settings)
            try file.write(from: buffer)
            file.close()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func reportContextMatrix(
        scores: [AppleSpeechLanguageContext.Language: Double], seconds: Double, isFinal: Bool
    ) {
        typealias Context = AppleSpeechLanguageContext
        let japanese = Context.textPrior(before: "今日は天気が良いので公園に散歩に行きます。", after: nil)
        let english = Context.textPrior(before: nil, after: "We are planning a walk in the park this afternoon.")
        let scenarios: [(String, [Context.Language: Double], Context.Language?)] = [
            ("none", [:], nil), ("ja-context+ja-history", japanese, .japanese),
            ("en-context+en-history", english, .english),
            ("ja-context+en-history", japanese, .english),
            ("en-context+ja-history", english, .japanese)
        ]
        for (name, prior, history) in scenarios {
            print("RANKING", name, Context.decide(scores: scores, seconds: seconds, isFinal: isFinal,
                                                 prior: prior, lastConfirmed: history))
        }
    }

    private static func makeTranscriber(_ identifier: String) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: identifier),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private enum ProbeError: Error {
        case unavailable
        case missingModel(String)
        case invalidArguments
        case invalidDuration
    }
}
