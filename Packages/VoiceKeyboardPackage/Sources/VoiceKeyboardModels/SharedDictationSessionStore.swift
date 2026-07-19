import Foundation

public final class SharedDictationSessionStore {
    private enum Key {
        static let command = "sharedDictation.session.command"
        static let status = "sharedDictation.session.status"
        static let heartbeat = "sharedDictation.session.heartbeat"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func appGroupStore() -> SharedDictationSessionStore? {
        guard let defaults = UserDefaults(suiteName: SharedDictationTranscriptStore.appGroupIdentifier) else {
            return nil
        }
        return SharedDictationSessionStore(defaults: defaults)
    }

    public func saveCommand(_ command: SharedDictationSessionCommand) {
        save(command, forKey: Key.command)
    }

    public func latestCommand() -> SharedDictationSessionCommand? {
        load(SharedDictationSessionCommand.self, forKey: Key.command)
    }

    public func claimCommand(
        afterLastClaimedToken lastClaimedToken: String?,
        now: Date = Date()
    ) -> SharedDictationSessionCommand? {
        guard let command = latestCommand() else { return nil }
        guard command.token != lastClaimedToken else { return nil }
        guard !command.isExpired(at: now) else { return nil }
        return command
    }

    public func saveStatus(_ status: SharedDictationSessionStatus) {
        save(status, forKey: Key.status)
    }

    public func status() -> SharedDictationSessionStatus {
        load(SharedDictationSessionStatus.self, forKey: Key.status) ?? .idle
    }

    public func saveHeartbeat(_ heartbeat: SharedDictationAppHeartbeat) {
        save(heartbeat, forKey: Key.heartbeat)
    }

    public func heartbeat() -> SharedDictationAppHeartbeat? {
        load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat)
    }

    private func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
