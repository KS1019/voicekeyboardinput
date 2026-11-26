import Foundation
import NaturalLanguage

// Experimental ranking of ASR outputs, NOT calibrated acoustic LID posteriors.
struct AppleSpeechLanguageContext {
    enum Language: String, CaseIterable { case japanese = "ja", english = "en" }
    enum Decision: Equatable {
        case needMoreAudio
        case acousticHeuristic(Language)
        case contextSuggestion(Language)
        case unresolved
    }

    static func textPrior(before: String?, after: String?) -> [Language: Double] {
        let text = String((before ?? "").suffix(256)) + " " + String((after ?? "").prefix(256))
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 12 else {
            return [:]
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)
        let japanese = hypotheses[.japanese] ?? 0
        let english = hypotheses[.english] ?? 0
        // Do not force unrelated languages into the configured candidate set.
        guard japanese + english >= 0.8 else { return [:] }
        return [.japanese: japanese / (japanese + english), .english: english / (japanese + english)]
    }

    static func decide(
        scores: [Language: Double], seconds: Double, isFinal: Bool,
        prior: [Language: Double], lastConfirmed: Language?
    ) -> Decision {
        guard seconds.isFinite, seconds > 0,
              let ja = scores[.japanese], let en = scores[.english],
              ja.isFinite, en.isFinite, (0...1).contains(ja), (0...1).contains(en) else {
            return isFinal ? .unresolved : .needMoreAudio
        }
        // These thresholds are experiment parameters, not accuracy guarantees.
        if seconds >= 2, max(ja, en) >= 0.7, abs(ja - en) >= 0.12 {
            return .acousticHeuristic(ja > en ? .japanese : .english)
        }
        if !isFinal && seconds < 4 { return .needMoreAudio }
        guard max(ja, en) >= 0.55 else { return .unresolved }
        let textDifference = min(1, max(-1, (prior[.japanese] ?? 0) - (prior[.english] ?? 0)))
        let historyDifference: Double = lastConfirmed.map { $0 == .japanese ? 1 : -1 } ?? 0
        let contextAdjustment = 0.12 * textDifference + 0.08 * historyDifference
        guard abs(contextAdjustment) >= 0.04 else { return .unresolved }
        let difference = ja - en + contextAdjustment
        guard abs(difference) >= 0.08 else { return .unresolved }
        return .contextSuggestion(difference > 0 ? .japanese : .english)
    }

    static func runChecks() {
        let japanese = textPrior(before: "今日は天気が良いので公園に散歩に行きます。", after: nil)
        let english = textPrior(before: nil, after: "We are planning a walk in the park this afternoon.")
        precondition((japanese[.japanese] ?? 0) > 0.8)
        precondition((english[.english] ?? 0) > 0.8)
        precondition(textPrior(before: nil, after: nil).isEmpty)
        precondition(textPrior(before: "Hi", after: nil).isEmpty)
        precondition(textPrior(before: "今日は", after: nil).isEmpty)
        precondition(textPrior(before: "12345678901234567890", after: nil).isEmpty)
        precondition(textPrior(before: "Это длинное предложение написано на русском языке.", after: nil).isEmpty)
        let ambiguous: [Language: Double] = [.japanese: 0.75, .english: 0.76]
        precondition(decide(scores: ambiguous, seconds: 1, isFinal: false, prior: japanese,
                            lastConfirmed: .japanese) == .needMoreAudio)
        precondition(decide(scores: ambiguous, seconds: 1, isFinal: true, prior: japanese,
                            lastConfirmed: .japanese) == .contextSuggestion(.japanese))
        precondition(decide(scores: ambiguous, seconds: 1, isFinal: true, prior: english,
                            lastConfirmed: .english) == .contextSuggestion(.english))
        precondition(decide(scores: ambiguous, seconds: 1, isFinal: true, prior: [:],
                            lastConfirmed: nil) == .unresolved)
        precondition(decide(scores: ambiguous, seconds: 1, isFinal: true, prior: english,
                            lastConfirmed: .japanese) == .unresolved)
        // Strong evidence for a switch wins over both stale context signals.
        precondition(decide(scores: [.japanese: 0.78, .english: 0.96], seconds: 2, isFinal: false,
                            prior: japanese, lastConfirmed: .japanese) == .acousticHeuristic(.english))
        precondition(decide(scores: [.japanese: 0.95, .english: 0.35], seconds: 2, isFinal: true,
                            prior: english, lastConfirmed: .english) == .acousticHeuristic(.japanese))
        precondition(decide(scores: [:], seconds: 4, isFinal: true, prior: japanese,
                            lastConfirmed: .japanese) == .unresolved)
        precondition(decide(scores: [.japanese: .nan, .english: 0.9], seconds: 4, isFinal: true,
                            prior: japanese, lastConfirmed: nil) == .unresolved)
        precondition(decide(scores: [.japanese: 0.1, .english: 0.2], seconds: 4, isFinal: true,
                            prior: japanese, lastConfirmed: .japanese) == .unresolved)
        precondition(decide(scores: ambiguous, seconds: 4, isFinal: false, prior: [:],
                            lastConfirmed: nil) == .unresolved)
        print("PASS: 17 context/ranking checks; suggestions never authorize text insertion or commands.")
    }
}
