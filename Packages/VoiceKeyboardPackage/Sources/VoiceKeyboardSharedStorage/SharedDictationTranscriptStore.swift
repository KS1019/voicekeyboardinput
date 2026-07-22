import Foundation
import VoiceKeyboardModels

public struct SharedDictationTranscript: Codable, Equatable, Sendable {
    public let sessionID: String
    public let commandToken: String
    public let text: String
    public let createdAt: Date
    public let expiresAt: Date
    public let isConsumed: Bool

    public var token: String {
        commandToken
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }

    public init?(text: String, createdAt: Date = Date()) {
        self.init(
            sessionID: "",
            commandToken: "\(createdAt.timeIntervalSince1970):\(text)",
            text: text,
            createdAt: createdAt
        )
    }

    public init?(
        sessionID: String,
        commandToken: String,
        text: String,
        createdAt: Date = Date(),
        expiryInterval: TimeInterval = 10
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        self.sessionID = sessionID
        self.commandToken = commandToken
        self.text = trimmedText
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(expiryInterval)
        self.isConsumed = false
    }

    fileprivate init(
        sessionID: String,
        commandToken: String,
        text: String,
        createdAt: Date,
        expiresAt: Date,
        isConsumed: Bool
    ) {
        self.sessionID = sessionID
        self.commandToken = commandToken
        self.text = text
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isConsumed = isConsumed
    }
}

public final class SharedDictationTranscriptStore {
    public static let appGroupIdentifier = "group.com.ks1019.voicekeyboardinput"

    private enum Key {
        static let transcriptRecord = "sharedDictation.transcriptRecord"
        static let consumedToken = "sharedDictation.consumedToken"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func appGroupStore() -> SharedDictationTranscriptStore? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        return SharedDictationTranscriptStore(defaults: defaults)
    }

    public func save(_ transcript: SharedDictationTranscript) {
        saveRecord(transcript)
    }

    public func latestTranscript() -> SharedDictationTranscript? {
        loadRecord()
    }

    public func latestTranscript(forSessionID sessionID: String) -> SharedDictationTranscript? {
        guard let transcript = latestTranscript(), transcript.sessionID == sessionID else {
            return nil
        }
        return transcript
    }

    public func consumeLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        loadMatchingTranscript(
            forSessionID: nil,
            afterLastConsumedToken: lastConsumedToken,
            now: now
        )
    }

    public func consumeLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        loadMatchingTranscript(
            forSessionID: sessionID,
            afterLastConsumedToken: lastConsumedToken,
            now: now
        )
    }

    private func loadMatchingTranscript(
        forSessionID sessionID: String?,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date
    ) -> SharedDictationTranscript? {
        guard let transcript = latestTranscript(),
              sessionID == nil || transcript.sessionID == sessionID,
              !transcript.isConsumed,
              !transcript.isExpired(at: now) else { return nil }
        guard transcript.token != lastConsumedToken else { return nil }
        return transcript
    }

    public func claimLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        guard let transcript = consumeLatestTranscript(
            afterLastConsumedToken: lastConsumedToken,
            now: now
        ) else {
            return nil
        }
        markConsumed(transcript)
        return transcript
    }

    public func claimLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        guard let transcript = consumeLatestTranscript(
            forSessionID: sessionID,
            afterLastConsumedToken: lastConsumedToken,
            now: now
        ) else {
            return nil
        }
        markConsumed(transcript)
        return transcript
    }

    public func markConsumed(_ transcript: SharedDictationTranscript) {
        guard let current = loadRecord(), current.token == transcript.token else { return }
        defaults.set(current.token, forKey: Key.consumedToken)
    }

    public func lastConsumedToken() -> String? {
        if let consumedToken = defaults.string(forKey: Key.consumedToken) {
            return consumedToken
        }
        guard let transcript = loadRecord(), transcript.isConsumed else { return nil }
        return transcript.token
    }

    private func saveRecord(_ transcript: SharedDictationTranscript) {
        guard let data = try? encoder.encode(transcript) else { return }
        defaults.set(data, forKey: Key.transcriptRecord)
    }

    private func loadRecord() -> SharedDictationTranscript? {
        guard let data = defaults.data(forKey: Key.transcriptRecord) else { return nil }
        guard let transcript = try? decoder.decode(SharedDictationTranscript.self, from: data) else {
            return nil
        }
        guard defaults.string(forKey: Key.consumedToken) == transcript.token,
              !transcript.isConsumed else { return transcript }
        return SharedDictationTranscript(
            sessionID: transcript.sessionID,
            commandToken: transcript.commandToken,
            text: transcript.text,
            createdAt: transcript.createdAt,
            expiresAt: transcript.expiresAt,
            isConsumed: true
        )
    }
}
