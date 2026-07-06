import Foundation

public struct SharedDictationTranscript: Equatable, Sendable {
    public let text: String
    public let createdAt: Date

    public var token: String {
        "\(createdAt.timeIntervalSince1970):\(text)"
    }

    public init?(text: String, createdAt: Date = Date()) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        self.text = trimmedText
        self.createdAt = createdAt
    }
}

public final class SharedDictationTranscriptStore {
    public static let appGroupIdentifier = "group.com.ks1019.voicekeyboardinput"

    private enum Key {
        static let transcriptText = "sharedDictation.transcriptText"
        static let transcriptCreatedAt = "sharedDictation.transcriptCreatedAt"
        static let consumedToken = "sharedDictation.consumedToken"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func appGroupStore() -> SharedDictationTranscriptStore? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        return SharedDictationTranscriptStore(defaults: defaults)
    }

    public func save(_ transcript: SharedDictationTranscript) {
        defaults.set(transcript.text, forKey: Key.transcriptText)
        defaults.set(transcript.createdAt.timeIntervalSince1970, forKey: Key.transcriptCreatedAt)
        defaults.removeObject(forKey: Key.consumedToken)
    }

    public func latestTranscript() -> SharedDictationTranscript? {
        guard let text = defaults.string(forKey: Key.transcriptText) else { return nil }
        let createdAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.transcriptCreatedAt))
        return SharedDictationTranscript(text: text, createdAt: createdAt)
    }

    public func consumeLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?
    ) -> SharedDictationTranscript? {
        guard let transcript = latestTranscript() else { return nil }
        guard transcript.token != lastConsumedToken else { return nil }
        return transcript
    }

    public func claimLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?
    ) -> SharedDictationTranscript? {
        guard let transcript = consumeLatestTranscript(
            afterLastConsumedToken: lastConsumedToken
        ) else {
            return nil
        }
        markConsumed(transcript)
        return transcript
    }

    public func markConsumed(_ transcript: SharedDictationTranscript) {
        defaults.set(transcript.token, forKey: Key.consumedToken)
    }

    public func lastConsumedToken() -> String? {
        defaults.string(forKey: Key.consumedToken)
    }
}
