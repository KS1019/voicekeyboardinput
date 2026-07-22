import Foundation
import Darwin
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
        expiryInterval: TimeInterval = 300
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

    private struct DeliveryLease: Codable {
        let transcriptToken: String
        let expiresAt: Date
    }

    private enum Key {
        static let transcriptRecord = "sharedDictation.transcriptRecord"
        static let consumedToken = "sharedDictation.consumedToken"
        static let deliveryLease = "sharedDictation.deliveryLease"
    }

    private static let deliveryLeaseInterval: TimeInterval = 5
    private static let inProcessLock = NSLock()

    private let defaults: UserDefaults
    private let lockFileDescriptor: Int32?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.lockFileDescriptor = nil
    }

    private init(defaults: UserDefaults, lockFileDescriptor: Int32) {
        self.defaults = defaults
        self.lockFileDescriptor = lockFileDescriptor
    }

    deinit {
        if let lockFileDescriptor {
            close(lockFileDescriptor)
        }
    }

    public static func appGroupStore() -> SharedDictationTranscriptStore? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else { return nil }
        let lockFileURL = containerURL.appendingPathComponent(
            "SharedDictationTranscriptStore.lock",
            isDirectory: false
        )
        let lockFileDescriptor = open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard lockFileDescriptor >= 0 else { return nil }
        return SharedDictationTranscriptStore(
            defaults: defaults,
            lockFileDescriptor: lockFileDescriptor
        )
    }

    public func save(_ transcript: SharedDictationTranscript) {
        withExclusiveAccess {
            saveRecord(transcript)
            if let lease = loadDeliveryLease(), lease.transcriptToken != transcript.token {
                defaults.removeObject(forKey: Key.deliveryLease)
            }
        }
    }

    public func latestTranscript() -> SharedDictationTranscript? {
        withExclusiveAccess {
            loadRecord()
        }
    }

    public func latestTranscript(forSessionID sessionID: String) -> SharedDictationTranscript? {
        withExclusiveAccess {
            guard let transcript = loadRecord(), transcript.sessionID == sessionID else {
                return nil
            }
            return transcript
        }
    }

    public func consumeLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            loadMatchingTranscript(
                forSessionID: nil,
                afterLastConsumedToken: lastConsumedToken,
                now: now
            )
        }
    }

    public func consumeLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            loadMatchingTranscript(
                forSessionID: sessionID,
                afterLastConsumedToken: lastConsumedToken,
                now: now
            )
        }
    }

    private func loadMatchingTranscript(
        forSessionID sessionID: String?,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date
    ) -> SharedDictationTranscript? {
        guard let transcript = loadRecord(),
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
        withExclusiveAccess {
            claimMatchingTranscript(
                forSessionID: nil,
                afterLastConsumedToken: lastConsumedToken,
                now: now
            )
        }
    }

    public func claimLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            claimMatchingTranscript(
                forSessionID: sessionID,
                afterLastConsumedToken: lastConsumedToken,
                now: now
            )
        }
    }

    private func claimMatchingTranscript(
        forSessionID sessionID: String?,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date
    ) -> SharedDictationTranscript? {
        guard let transcript = loadMatchingTranscript(
            forSessionID: sessionID,
            afterLastConsumedToken: lastConsumedToken,
            now: now
        ) else { return nil }
        if let lease = loadDeliveryLease(),
           lease.transcriptToken == transcript.token,
           now < lease.expiresAt {
            return nil
        }
        saveDeliveryLease(DeliveryLease(
            transcriptToken: transcript.token,
            expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval)
        ))
        return transcript
    }

    public func markConsumed(_ transcript: SharedDictationTranscript) {
        withExclusiveAccess {
            guard let current = loadRecord(), current.token == transcript.token else { return }
            defaults.set(current.token, forKey: Key.consumedToken)
            if loadDeliveryLease()?.transcriptToken == current.token {
                defaults.removeObject(forKey: Key.deliveryLease)
            }
        }
    }

    public func lastConsumedToken() -> String? {
        withExclusiveAccess {
            if let consumedToken = defaults.string(forKey: Key.consumedToken) {
                return consumedToken
            }
            guard let transcript = loadRecord(), transcript.isConsumed else { return nil }
            return transcript.token
        }
    }

    private func saveRecord(_ transcript: SharedDictationTranscript) {
        guard let data = try? encoder.encode(transcript) else { return }
        defaults.set(data, forKey: Key.transcriptRecord)
    }

    private func saveDeliveryLease(_ lease: DeliveryLease) {
        guard let data = try? encoder.encode(lease) else { return }
        defaults.set(data, forKey: Key.deliveryLease)
    }

    private func loadDeliveryLease() -> DeliveryLease? {
        guard let data = defaults.data(forKey: Key.deliveryLease) else { return nil }
        return try? decoder.decode(DeliveryLease.self, from: data)
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

    private func withExclusiveAccess<Result>(_ body: () -> Result) -> Result {
        Self.inProcessLock.lock()
        defer { Self.inProcessLock.unlock() }

        let hasFileLock = acquireFileLock()
        defer {
            if hasFileLock, let lockFileDescriptor {
                flock(lockFileDescriptor, LOCK_UN)
            }
        }

        if lockFileDescriptor != nil {
            defaults.synchronize()
        }
        let result = body()
        if lockFileDescriptor != nil {
            defaults.synchronize()
        }
        return result
    }

    private func acquireFileLock() -> Bool {
        guard let lockFileDescriptor else { return false }
        while flock(lockFileDescriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }
}
