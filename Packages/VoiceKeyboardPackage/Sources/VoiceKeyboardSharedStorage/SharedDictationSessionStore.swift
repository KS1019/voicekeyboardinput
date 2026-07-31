import Darwin
import Foundation
import VoiceKeyboardModels

public final class SharedDictationSessionStore {
    public enum CommandResolution: Equatable, Sendable {
        case found(SharedDictationSessionCommand)
        case missing
        case unavailable
    }

    public enum CommandHistoryResolution: Equatable, Sendable {
        case available([SharedDictationSessionCommand])
        case unavailable
    }

    public enum CancellationIntentResolution: Equatable, Sendable {
        case available([SharedDictationSessionCommand])
        case unavailable
    }

    public enum DeliveryFailureIntentResolution: Equatable, Sendable {
        case available([String: String])
        case unavailable
    }

    public enum StatusResolution: Equatable, Sendable {
        case found(SharedDictationSessionStatus)
        case missing
        case unavailable
    }

    private struct SessionEnvelope: Codable {
        var revision: UInt64 = 0
        var commands: [String: SharedDictationSessionCommand] = [:]
        var commandOrder: [String] = []
        var statuses: [String: SharedDictationSessionStatus] = [:]
        var statusOrder: [String] = []
        var latestStatus: SharedDictationSessionStatus = .idle
        var heartbeat: SharedDictationAppHeartbeat?
        var heartbeats: [String: SharedDictationAppHeartbeat] = [:]
        var claims: [String: Date] = [:]
        var claimOwners: [String: String] = [:]
        var deliveryFailureIntents: [String: String] = [:]
        var cancellationIntents: [String: SharedDictationSessionCommand] = [:]

        private enum CodingKeys: String, CodingKey {
            case revision
            case commands
            case commandOrder
            case statuses
            case statusOrder
            case latestStatus
            case heartbeat
            case heartbeats
            case claims
            case claimOwners
            case deliveryFailureIntents
            case cancellationIntents
        }

        init(
            revision: UInt64 = 0,
            commands: [String: SharedDictationSessionCommand] = [:],
            commandOrder: [String] = [],
            statuses: [String: SharedDictationSessionStatus] = [:],
            statusOrder: [String] = [],
            latestStatus: SharedDictationSessionStatus = .idle,
            heartbeat: SharedDictationAppHeartbeat? = nil,
            heartbeats: [String: SharedDictationAppHeartbeat] = [:],
            claims: [String: Date] = [:],
            claimOwners: [String: String] = [:],
            deliveryFailureIntents: [String: String] = [:],
            cancellationIntents: [String: SharedDictationSessionCommand] = [:]
        ) {
            self.revision = revision
            self.commands = commands
            self.commandOrder = commandOrder
            self.statuses = statuses
            self.statusOrder = statusOrder
            self.latestStatus = latestStatus
            self.heartbeat = heartbeat
            self.heartbeats = heartbeats
            self.claims = claims
            self.claimOwners = claimOwners
            self.deliveryFailureIntents = deliveryFailureIntents
            self.cancellationIntents = cancellationIntents
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
            commands = try container.decodeIfPresent(
                [String: SharedDictationSessionCommand].self,
                forKey: .commands
            ) ?? [:]
            commandOrder = try container.decodeIfPresent([String].self, forKey: .commandOrder) ?? []
            statuses = try container.decodeIfPresent(
                [String: SharedDictationSessionStatus].self,
                forKey: .statuses
            ) ?? [:]
            statusOrder = try container.decodeIfPresent([String].self, forKey: .statusOrder) ?? []
            if statusOrder.isEmpty {
                statusOrder = statuses.keys.sorted()
            }
            latestStatus = try container.decodeIfPresent(
                SharedDictationSessionStatus.self,
                forKey: .latestStatus
            ) ?? .idle
            heartbeat = try container.decodeIfPresent(SharedDictationAppHeartbeat.self, forKey: .heartbeat)
            heartbeats = try container.decodeIfPresent(
                [String: SharedDictationAppHeartbeat].self,
                forKey: .heartbeats
            ) ?? [:]
            if let heartbeat, heartbeats[heartbeat.token] == nil {
                heartbeats[heartbeat.token] = heartbeat
            }
            claims = try container.decodeIfPresent([String: Date].self, forKey: .claims) ?? [:]
            claimOwners = try container.decodeIfPresent([String: String].self, forKey: .claimOwners) ?? [:]
            claimOwners = claimOwners.filter { claims[$0.key] != nil }
            deliveryFailureIntents = try container.decodeIfPresent(
                [String: String].self,
                forKey: .deliveryFailureIntents
            ) ?? [:]
            cancellationIntents = try container.decodeIfPresent(
                [String: SharedDictationSessionCommand].self,
                forKey: .cancellationIntents
            ) ?? [:]
            guard SharedDictationSessionStore.isValidEnvelope(self) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .commands,
                    in: container,
                    debugDescription: "Invalid or oversized shared dictation session envelope"
                )
            }
        }
    }

    private enum Key {
        static let command = "sharedDictation.session.command"
        static let commandPrefix = "sharedDictation.session.command."
        static let commandIndex = "sharedDictation.session.commandIndex"
        static let status = "sharedDictation.session.status"
        static let statusPrefix = "sharedDictation.session.status."
        static let statusIndex = "sharedDictation.session.statusIndex"
        static let heartbeat = "sharedDictation.session.heartbeat"
        static let claims = "sharedDictation.session.claims"
        static let claimOwners = "sharedDictation.session.claimOwners"
        static let deliveryFailureIntents = "sharedDictation.session.deliveryFailureIntents"
        static let cancellationIntents = "sharedDictation.session.cancellationIntents"
        static let envelopeMigrationMarker = "sharedDictation.session.envelopeMigrationComplete"
    }

    private static let historyLimit = 32
    private static let maximumEnvelopeByteCount = 1_000_000
    private static let maximumTokenByteCount = 256
    private static let maximumMessageByteCount = 4_096
    private static let transcriptRetentionInterval: TimeInterval = 360
    private static let claimInterval: TimeInterval = 10
    private static let heartbeatRetentionInterval: TimeInterval = 30
    private static let heartbeatHistoryLimit = 16
    private static let maximumFutureClockSkew: TimeInterval = 300
    private static let maximumCommandHorizon: TimeInterval = 600
    private static let inProcessLock = NSRecursiveLock()

    private let defaults: UserDefaults
    private let envelopeURL: URL?
    private let lockFileDescriptor: Int32?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var envelopeReadBlocked = false

    private enum LegacyValueResolution<Value> {
        case missing
        case found(Value)
        case unavailable
    }

    /// In-process compatibility backend for tests and legacy migration only.
    /// App Group production callers must use `appGroupStore()`, which uses a
    /// single file-backed envelope and an interprocess lock.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.envelopeURL = nil
        self.lockFileDescriptor = nil
    }

    /// Creates the same file-backed store used by App Group clients. The URL
    /// initializer is also used by tests to exercise cross-instance locking
    /// without requiring an application-group entitlement.
    public init?(
        defaults: UserDefaults,
        envelopeURL: URL,
        lockFileURL: URL
    ) {
        let lockFileDescriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else { return nil }
        self.defaults = defaults
        self.envelopeURL = envelopeURL
        self.lockFileDescriptor = lockFileDescriptor
    }

    private init(defaults: UserDefaults, envelopeURL: URL, lockFileDescriptor: Int32) {
        self.defaults = defaults
        self.envelopeURL = envelopeURL
        self.lockFileDescriptor = lockFileDescriptor
    }

    deinit {
        if let lockFileDescriptor {
            close(lockFileDescriptor)
        }
    }

    public static func appGroupStore() -> SharedDictationSessionStore? {
        guard let defaults = UserDefaults(suiteName: SharedDictationTranscriptStore.appGroupIdentifier),
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedDictationTranscriptStore.appGroupIdentifier
              ) else {
            return nil
        }
        let lockFileURL = containerURL.appendingPathComponent(
            "SharedDictationSessionStore.lock",
            isDirectory: false
        )
        let envelopeURL = containerURL.appendingPathComponent(
            "SharedDictationSessionStore.json",
            isDirectory: false
        )
        let lockFileDescriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else { return nil }
        return SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileDescriptor: lockFileDescriptor
        )
    }

    public func storageHealth() -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                _ = loadEnvelope()
                return !envelopeReadBlocked
            }
            return true
        } ?? false
    }

    @discardableResult
    public func saveCommand(_ command: SharedDictationSessionCommand) -> Bool {
        for attempt in 0..<2 {
            let didSave = withExclusiveAccess {
                if envelopeURL != nil {
                    var envelope = loadEnvelope()
                    if let existing = envelope.commands[command.token] {
                        guard existing == command else { return false }
                        guard envelope.cancellationIntents.removeValue(forKey: command.token) != nil else {
                            return true
                        }
                        return saveEnvelope(envelope)
                    }
                    pruneClaims(&envelope, now: Date())
                    envelope.commands[command.token] = command
                    envelope.cancellationIntents.removeValue(forKey: command.token)
                    envelope.commandOrder.removeAll { $0 == command.token }
                    envelope.commandOrder.append(command.token)
                    guard pruneCommands(&envelope) else { return false }
                    // A newly published command must never be silently
                    // pruned just because every older command is still
                    // protected by an active session. Fail the write so the
                    // caller can surface storage pressure instead of losing
                    // the handoff while returning success.
                    guard envelope.commands[command.token] != nil,
                          envelope.commandOrder.contains(command.token) else {
                        return false
                    }
                    return saveEnvelope(envelope)
                }
                if let existing = loadCommand(forToken: command.token) {
                    guard existing == command else { return false }
                    var cancellationIntents = load(
                        [String: SharedDictationSessionCommand].self,
                        forKey: Key.cancellationIntents
                    ) ?? [:]
                    guard cancellationIntents.removeValue(forKey: command.token) != nil else {
                        return true
                    }
                    save(cancellationIntents, forKey: Key.cancellationIntents)
                    return true
                }
                save(command, forKey: Key.command)
                save(command, forKey: Key.commandPrefix + command.token)
                appendToken(command.token, toIndex: Key.commandIndex, removingWithPrefix: Key.commandPrefix)
                var cancellationIntents = load(
                    [String: SharedDictationSessionCommand].self,
                    forKey: Key.cancellationIntents
                ) ?? [:]
                cancellationIntents.removeValue(forKey: command.token)
                save(cancellationIntents, forKey: Key.cancellationIntents)
                return true
            } ?? false
            if didSave { return true }
            if attempt == 0 { usleep(1_000) }
        }
        return false
    }

    public func command(forToken token: String) -> SharedDictationSessionCommand? {
        switch commandResolution(forToken: token) {
        case .found(let command): return command
        case .missing, .unavailable: return nil
        }
    }

    public func commandResolution(forToken token: String) -> CommandResolution {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                guard !envelopeReadBlocked else { return .unavailable }
                return envelope.commands[token].map(CommandResolution.found) ?? .missing
            }
            if let command = loadCommand(forToken: token) {
                return .found(command)
            }
            if defaults.object(forKey: Key.commandPrefix + token) != nil
                || (defaults.object(forKey: Key.command) != nil
                    && loadLatestCommand() == nil) {
                return .unavailable
            }
            return .missing
        } ?? .unavailable
    }

    public func latestCommand() -> SharedDictationSessionCommand? {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                return envelope.commandOrder.reversed().compactMap { envelope.commands[$0] }.first
            }
            return loadLatestCommand()
        } ?? nil
    }

    /// Returns the bounded command history in publication order. Recovery
    /// uses this instead of assuming the newest scene owns every session.
    public func commandHistory() -> [SharedDictationSessionCommand] {
        switch commandHistoryResolution() {
        case .available(let commands): return commands
        case .unavailable: return []
        }
    }

    public func commandHistoryResolution() -> CommandHistoryResolution {
        withExclusiveAccess {
            if envelopeURL == nil { return loadCommandHistoryResolution() }
            let envelope = loadEnvelope()
            guard !envelopeReadBlocked else { return .unavailable }
            return .available(envelope.commandOrder.compactMap { envelope.commands[$0] })
        } ?? .unavailable
    }

    public func claimCommand(
        afterLastClaimedToken lastClaimedToken: String?,
        now: Date = Date(),
        ownerToken: String? = nil,
        source: SharedDictationSessionCommand.Source? = nil
    ) -> SharedDictationSessionCommand? {
        withExclusiveAccess {
            if envelopeURL != nil {
                guard ownerToken != nil else { return nil }
                var envelope = loadEnvelope()
                pruneClaims(&envelope, now: now)
                let allCommands = envelope.commandOrder.compactMap { envelope.commands[$0] }
                let supersededTokens = supersededCommandTokens(
                    in: allCommands + Array(envelope.cancellationIntents.values)
                )
                let commands = envelope.commandOrder.compactMap { token -> SharedDictationSessionCommand? in
                    guard envelope.claims[token] == nil else { return nil }
                    // A command with a persisted status has already entered
                    // the state machine. It must not be re-delivered after a
                    // short claim lease expires.
                    guard envelope.statuses[token] == nil else { return nil }
                    guard let command = envelope.commands[token],
                          source == nil || command.source == source,
                          !supersededTokens.contains(command.token),
                          !isRoutedToAnotherOwner(command, in: envelope, ownerToken: ownerToken) else {
                        return nil
                    }
                    return command
                }
                guard let command = claimNextCommand(
                    commands: commands,
                    afterLastClaimedToken: lastClaimedToken,
                    now: now,
                    supersededTokens: supersededTokens
                ) else { return nil }
                envelope.claims[command.token] = now.addingTimeInterval(Self.claimInterval)
                if let ownerToken {
                    envelope.claimOwners[command.token] = ownerToken
                }
                guard saveEnvelope(envelope) else { return nil }
                return command
            }
            var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
            var claimOwners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
            pruneDefaultClaims(&claims, owners: &claimOwners, now: now)
            let allCommands = loadCommandHistory()
            let pendingCancellations = load(
                [String: SharedDictationSessionCommand].self,
                forKey: Key.cancellationIntents
            ) ?? [:]
            let supersededTokens = supersededCommandTokens(
                in: allCommands + Array(pendingCancellations.values)
            )
            let commands = allCommands.filter { command in
                guard (source == nil || command.source == source),
                      claims[command.token] == nil,
                      load(SharedDictationSessionStatus.self, forKey: Key.statusPrefix + command.token) == nil,
                      !supersededTokens.contains(command.token) else {
                    return false
                }
                return true
            }
            guard let command = claimNextCommand(
                commands: commands,
                afterLastClaimedToken: lastClaimedToken,
                now: now,
                supersededTokens: supersededTokens
            ) else { return nil }
            claims[command.token] = now.addingTimeInterval(Self.claimInterval)
            if let ownerToken {
                claimOwners[command.token] = ownerToken
            }
            save(claims, forKey: Key.claims)
            save(claimOwners, forKey: Key.claimOwners)
            return command
        } ?? nil
    }

    /// Claims a known command for a containing-app route before the monitor
    /// gets a chance to observe it. The claim is persisted for the short
    /// lifetime of the handoff, preventing duplicate scene controllers from
    /// starting the same recording.
    @discardableResult
    public func claimCommand(
        token: String,
        now: Date = Date(),
        ownerToken: String? = nil
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL != nil else {
                guard ownerToken != nil else { return false }
                var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                var claimOwners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                pruneDefaultClaims(&claims, owners: &claimOwners, now: now)
                let allCommands = loadCommandHistory()
                let pendingCancellations = load(
                    [String: SharedDictationSessionCommand].self,
                    forKey: Key.cancellationIntents
                ) ?? [:]
                guard let command = loadCommand(forToken: token),
                      !command.isExpired(at: now),
                      !isSuperseded(command, in: allCommands + Array(pendingCancellations.values)),
                      load(SharedDictationSessionStatus.self, forKey: Key.statusPrefix + token) == nil else {
                    return false
                }
                if let expiresAt = claims[token] {
                    return expiresAt > now && claimOwners[token] == ownerToken
                }
                claims[token] = now.addingTimeInterval(Self.claimInterval)
                claimOwners[token] = ownerToken
                save(claims, forKey: Key.claims)
                save(claimOwners, forKey: Key.claimOwners)
                return true
            }
            guard ownerToken != nil else { return false }
            var envelope = loadEnvelope()
            pruneClaims(&envelope, now: now)
            guard let command = envelope.commands[token],
                  !command.isExpired(at: now),
                  !isSuperseded(command, in: envelope),
                  !isRoutedToAnotherOwner(command, in: envelope, ownerToken: ownerToken),
                  envelope.statuses[token] == nil else { return false }
            if let expiresAt = envelope.claims[token] {
                guard expiresAt > now,
                      ownerToken != nil,
                      envelope.claimOwners[token] == ownerToken else { return false }
                return true
            }
            envelope.claims[token] = now.addingTimeInterval(Self.claimInterval)
            if let ownerToken {
                envelope.claimOwners[token] = ownerToken
            }
            return saveEnvelope(envelope)
        } ?? false
    }

    public func claimOwner(forCommandToken token: String, now: Date = Date()) -> String? {
        withExclusiveAccess {
            guard envelopeURL != nil else {
                let claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                let owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                guard let expiresAt = claims[token],
                      expiresAt > now,
                      let owner = owners[token],
                      let heartbeat = load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat),
                      heartbeat.token == owner,
                      heartbeat.isFresh(at: now, maxAge: 5) else { return nil }
                return owner
            }
            let envelope = loadEnvelope()
            guard let expiresAt = envelope.claims[token],
                  expiresAt > now,
                  let owner = envelope.claimOwners[token],
                  let heartbeat = envelope.heartbeats[owner],
                  heartbeat.isFresh(at: now, maxAge: 5) else { return nil }
            return owner
        } ?? nil
    }

    /// Returns true while a command's short claim lease is still active. This
    /// is intentionally independent from the owner's heartbeat: recovery must
    /// not cancel a command in the narrow transaction window between claim and
    /// the first session-bound heartbeat/status write.
    public func hasActiveCommandClaim(
        forCommandToken token: String,
        ownerToken: String? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL != nil else {
                let claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                let owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                return claims[token].map { expiresAt in
                    expiresAt > now && (ownerToken == nil || owners[token] == ownerToken)
                } ?? false
            }
            let envelope = loadEnvelope()
            guard let expiresAt = envelope.claims[token],
                  envelope.claimOwners[token] != nil,
                  expiresAt > now else { return false }
            return ownerToken == nil || envelope.claimOwners[token] == ownerToken
        } ?? false
    }

    @discardableResult
    public func releaseCommandClaim(token: String, ownerToken: String?) -> Bool {
        withExclusiveAccess {
            guard envelopeURL != nil else {
                var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                var owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                guard claims[token] != nil,
                      ownerToken == nil || owners[token] == ownerToken else { return false }
                claims.removeValue(forKey: token)
                owners.removeValue(forKey: token)
                save(claims, forKey: Key.claims)
                save(owners, forKey: Key.claimOwners)
                return true
            }
            var envelope = loadEnvelope()
            guard envelope.claims[token] != nil,
                  ownerToken == nil || envelope.claimOwners[token] == ownerToken else {
                return false
            }
            envelope.claims.removeValue(forKey: token)
            envelope.claimOwners.removeValue(forKey: token)
            return saveEnvelope(envelope)
        } ?? false
    }

    @discardableResult
    public func recoverCompletedTranscriptStatus(
        sourceCommandToken: String,
        throughCommandToken ownerCommandToken: String,
        ownerToken: String,
        now: Date = Date()
    ) -> Bool {
        saveStatus(
            .transcriptReady(token: sourceCommandToken),
            ownerToken: ownerToken,
            allowRecoveryFromTranscriptReady: true,
            recoveryOwnerCommandToken: ownerCommandToken,
            now: now
        )
    }

    /// Recovers a completed transcript after its replacement Stop command's
    /// short claim has expired. The transcript store already proves that the
    /// source command completed; the Stop command is only used as a durable
    /// replacement fence. This path never accepts Cancel and refuses to
    /// override another live owner's claim.
    @discardableResult
    public func recoverCompletedTranscriptAfterExpiredStop(
        sourceCommandToken: String,
        throughCommandToken ownerCommandToken: String,
        now: Date = Date()
    ) -> Bool {
        saveStatus(
            .transcriptReady(token: sourceCommandToken),
            allowRecoveryFromTranscriptReady: true,
            recoveryOwnerCommandToken: ownerCommandToken,
            allowExpiredStopRecovery: true,
            now: now
        )
    }

    @discardableResult
    public func saveStatus(
        _ status: SharedDictationSessionStatus,
        ownerToken: String? = nil,
        allowRecoveryFromTranscriptReady: Bool = false,
        recoveryOwnerCommandToken: String? = nil,
        allowExpiredStopRecovery: Bool = false,
        now: Date = Date()
    ) -> Bool {
        for attempt in 0..<2 {
            if (withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                pruneClaims(&envelope, now: now)
                let isAuthorizedTranscriptRecovery: Bool
                let isExpiredStopRecovery: Bool
                if let recoveryOwnerCommandToken {
                    guard case .transcriptReady = status,
                          let sourceCommandToken = status.commandToken,
                          let ownerCommand = envelope.commands[recoveryOwnerCommandToken],
                          ownerCommand.kind == .stop,
                          ownerCommand.source == .keyboard,
                          ownerCommand.replacesCommandToken == sourceCommandToken else {
                        return false
                    }
                    let commands = envelope.commandOrder.compactMap { envelope.commands[$0] }
                    let cancellationIntents = Array(envelope.cancellationIntents.values)
                    guard isCurrentRecoveryReplacement(
                        sourceCommandToken: sourceCommandToken,
                        ownerCommand: ownerCommand,
                        commands: commands,
                        cancellationIntents: cancellationIntents
                    ) else { return false }
                    let hasLiveClaim = envelope.claims[recoveryOwnerCommandToken].map {
                        $0 > now && envelope.claimOwners[recoveryOwnerCommandToken] == ownerToken
                    } == true
                    isExpiredStopRecovery = allowExpiredStopRecovery
                        && ownerCommand.kind == .stop
                        && ownerCommand.isExpired(at: now)
                        && envelope.claims[recoveryOwnerCommandToken] == nil
                    guard hasLiveClaim || isExpiredStopRecovery else { return false }
                    isAuthorizedTranscriptRecovery = true
                } else {
                    isAuthorizedTranscriptRecovery = false
                    isExpiredStopRecovery = false
                }
                let previousLatestStatus = envelope.latestStatus
                if let commandToken = status.commandToken {
                    let currentStatus = envelope.statuses[commandToken]
                        ?? (previousLatestStatus.commandToken == commandToken ? previousLatestStatus : nil)
                    if isExpiredStopRecovery,
                       case .cancelled = currentStatus {
                        return false
                    }
                    if case .cancelled = currentStatus,
                       case .transcriptReady = status,
                       recoveryOwnerCommandToken == nil {
                        // A transcript written after a cancellation must not
                        // be resurrected by the independent transcript store.
                        // Only a live, replacement stop/cancel claim can
                        // prove that this is an intentional recovery.
                        return false
                    }
                    if allowRecoveryFromTranscriptReady,
                       case .transcriptReady = status,
                       let command = envelope.commands[commandToken],
                       isSuperseded(command, in: envelope),
                       !isAuthorizedTranscriptRecovery {
                        // Historical delivery failures may settle an old
                        // token, but a transcriptReady promotion must not
                        // cross a cancellation/replacement fence.
                        return false
                    }
                    if allowRecoveryFromTranscriptReady,
                       previousLatestStatus.commandToken != commandToken {
                        // A delivery failure may be reported after a newer
                        // command owns the mailbox. Settle the old token in
                        // its token-scoped history without regressing the
                        // newer latestStatus value.
                        guard Self.isAllowedStatusTransition(
                            from: currentStatus,
                            to: status,
                            allowRecoveryFromTranscriptReady: true
                        ) else { return false }
                        envelope.statuses[commandToken] = status
                        envelope.statusOrder.removeAll { $0 == commandToken }
                        envelope.statusOrder.append(commandToken)
                        envelope.claims.removeValue(forKey: commandToken)
                        envelope.claimOwners.removeValue(forKey: commandToken)
                        envelope.deliveryFailureIntents.removeValue(forKey: commandToken)
                        pruneStatus(&envelope)
                        return saveEnvelope(envelope)
                    }
                    if let ownerToken, !isExpiredStopRecovery {
                        let claimToken = isAuthorizedTranscriptRecovery
                            ? recoveryOwnerCommandToken!
                            : commandToken
                        guard let expiresAt = envelope.claims[claimToken],
                              expiresAt > now,
                              envelope.claimOwners[claimToken] == ownerToken else {
                            return false
                        }
                    }
                    guard Self.isAllowedStatusTransition(
                        from: currentStatus,
                        to: status,
                        allowRecoveryFromTranscriptReady: allowRecoveryFromTranscriptReady
                    ) else {
                        return false
                    }
                    envelope.statuses[commandToken] = status
                    envelope.statusOrder.removeAll { $0 == commandToken }
                    envelope.statusOrder.append(commandToken)
                    if status.isTerminal {
                        envelope.claims.removeValue(forKey: commandToken)
                        envelope.claimOwners.removeValue(forKey: commandToken)
                        envelope.deliveryFailureIntents.removeValue(forKey: commandToken)
                    }
                    pruneStatus(&envelope)
                }
                envelope.latestStatus = status
                return saveEnvelope(envelope)
            }
            if let commandToken = status.commandToken {
                let latestStatus = loadStatus()
                let isAuthorizedTranscriptRecovery: Bool
                let isExpiredStopRecovery: Bool
                if let recoveryOwnerCommandToken {
                    guard case .transcriptReady = status,
                          let ownerCommand = loadCommand(forToken: recoveryOwnerCommandToken),
                          ownerCommand.kind == .stop,
                          ownerCommand.source == .keyboard,
                          ownerCommand.replacesCommandToken == commandToken else {
                        return false
                    }
                    let commands = loadCommandHistory()
                    let cancellationIntents = load(
                        [String: SharedDictationSessionCommand].self,
                        forKey: Key.cancellationIntents
                    ).map { Array($0.values) } ?? []
                    guard isCurrentRecoveryReplacement(
                        sourceCommandToken: commandToken,
                        ownerCommand: ownerCommand,
                        commands: commands,
                        cancellationIntents: cancellationIntents
                    ) else { return false }
                    let claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                    let owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                    let hasLiveClaim = claims[recoveryOwnerCommandToken].map {
                        $0 > now && owners[recoveryOwnerCommandToken] == ownerToken
                    } == true
                    isExpiredStopRecovery = allowExpiredStopRecovery
                        && ownerCommand.kind == .stop
                        && ownerCommand.isExpired(at: now)
                        && claims[recoveryOwnerCommandToken].map { $0 > now } != true
                    guard hasLiveClaim || isExpiredStopRecovery else { return false }
                    isAuthorizedTranscriptRecovery = true
                } else {
                    isAuthorizedTranscriptRecovery = false
                    isExpiredStopRecovery = false
                }
                let currentStatus = load(
                    SharedDictationSessionStatus.self,
                    forKey: Key.statusPrefix + commandToken
                ) ?? (latestStatus.commandToken == commandToken ? latestStatus : nil)
                if isExpiredStopRecovery,
                   case .cancelled = currentStatus {
                    return false
                }
                if case .cancelled = currentStatus,
                   case .transcriptReady = status,
                   recoveryOwnerCommandToken == nil {
                    // See the file-backed branch above: cancellation is a
                    // fence unless an active replacement command authorizes
                    // recovery.
                    return false
                }
                if allowRecoveryFromTranscriptReady,
                   case .transcriptReady = status,
                   let command = loadCommand(forToken: commandToken),
                   isSuperseded(command, in: loadCommandHistory()),
                   !isAuthorizedTranscriptRecovery {
                    return false
                }
                if allowRecoveryFromTranscriptReady,
                   latestStatus.commandToken != commandToken {
                    guard Self.isAllowedStatusTransition(
                        from: currentStatus,
                        to: status,
                        allowRecoveryFromTranscriptReady: true
                    ) else { return false }
                    save(status, forKey: Key.statusPrefix + commandToken)
                    appendToken(commandToken, toIndex: Key.statusIndex, removingWithPrefix: Key.statusPrefix)
                    var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                    var owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                    claims.removeValue(forKey: commandToken)
                    owners.removeValue(forKey: commandToken)
                    save(claims, forKey: Key.claims)
                    save(owners, forKey: Key.claimOwners)
                    var intents = load([String: String].self, forKey: Key.deliveryFailureIntents) ?? [:]
                    intents.removeValue(forKey: commandToken)
                    save(intents, forKey: Key.deliveryFailureIntents)
                    return true
                }
                if let ownerToken, !isExpiredStopRecovery {
                    let claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                    let owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                    let claimToken = isAuthorizedTranscriptRecovery
                        ? recoveryOwnerCommandToken!
                        : commandToken
                    guard let expiresAt = claims[claimToken],
                          expiresAt > now,
                          owners[claimToken] == ownerToken else {
                        return false
                    }
                }
                guard Self.isAllowedStatusTransition(
                    from: currentStatus,
                    to: status,
                    allowRecoveryFromTranscriptReady: allowRecoveryFromTranscriptReady
                ) else {
                    return false
                }
            }
            if status.isTerminal, let commandToken = status.commandToken {
                var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                var owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                claims.removeValue(forKey: commandToken)
                owners.removeValue(forKey: commandToken)
                save(claims, forKey: Key.claims)
                save(owners, forKey: Key.claimOwners)
                var intents = load([String: String].self, forKey: Key.deliveryFailureIntents) ?? [:]
                intents.removeValue(forKey: commandToken)
                save(intents, forKey: Key.deliveryFailureIntents)
            }
            save(status, forKey: Key.status)
            if let commandToken = status.commandToken {
                save(status, forKey: Key.statusPrefix + commandToken)
                appendToken(commandToken, toIndex: Key.statusIndex, removingWithPrefix: Key.statusPrefix)
            }
            return true
            } ?? false) { return true }
            if attempt == 0 { usleep(1_000) }
        }
        return false
    }

    /// Delivery is a non-transactional host boundary. Once the transcript is
    /// quarantined or discarded, the keyboard must be able to persist that
    /// terminal outcome instead of leaving a permanently retryable
    /// `transcriptReady` status behind.
    @discardableResult
    public func saveDeliveryFailure(
        token: String,
        message: String,
        now: Date = Date()
    ) -> Bool {
        saveStatus(
            .failed(token: token, message: message),
            allowRecoveryFromTranscriptReady: true,
            now: now
        )
    }

    /// Records the terminal outcome before the transcript journal is
    /// quarantined. Session and transcript persistence are separate files, so
    /// this intent is the recovery WAL if the second write is interrupted.
    @discardableResult
    public func recordDeliveryFailureIntent(
        token: String,
        message: String
    ) -> Bool {
        guard Self.bounded(token),
              message.utf8.count <= Self.maximumMessageByteCount,
              !message.contains("\0") else { return false }
        return withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                envelope.deliveryFailureIntents[token] = message
                return saveEnvelope(envelope)
            }
            var intents = load([String: String].self, forKey: Key.deliveryFailureIntents) ?? [:]
            intents[token] = message
            save(intents, forKey: Key.deliveryFailureIntents)
            return true
        } ?? false
    }

    public func pendingDeliveryFailureIntents() -> [String: String] {
        switch pendingDeliveryFailureIntentsResolution() {
        case .available(let intents): return intents
        case .unavailable: return [:]
        }
    }

    public func pendingDeliveryFailureIntentsResolution() -> DeliveryFailureIntentResolution {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                guard !envelopeReadBlocked else { return .unavailable }
                return .available(envelope.deliveryFailureIntents)
            }
            return .available(load([String: String].self, forKey: Key.deliveryFailureIntents) ?? [:])
        } ?? .unavailable
    }

    @discardableResult
    public func discardDeliveryFailureIntent(forToken token: String) -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                envelope.deliveryFailureIntents.removeValue(forKey: token)
                return saveEnvelope(envelope)
            }
            var intents = load([String: String].self, forKey: Key.deliveryFailureIntents) ?? [:]
            intents.removeValue(forKey: token)
            save(intents, forKey: Key.deliveryFailureIntents)
            return true
        } ?? false
    }

    /// Persists a cancellation before the producer starts retrying its
    /// command write. This is a small cross-process outbox: an extension
    /// termination cannot turn an explicit Delete/Return into a lost cancel.
    @discardableResult
    public func recordCancellationIntent(
        _ command: SharedDictationSessionCommand
    ) -> Bool {
        guard command.kind == .cancel,
              command.source == .keyboard,
              let replacedToken = command.replacesCommandToken,
              Self.bounded(command.token),
              Self.bounded(command.sessionID),
              Self.bounded(replacedToken) else { return false }
        return withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                if let existing = envelope.cancellationIntents[command.token] {
                    return existing == command
                }
                guard envelope.cancellationIntents.count < Self.historyLimit else {
                    return false
                }
                envelope.cancellationIntents[command.token] = command
                return saveEnvelope(envelope)
            }
            var intents = load(
                [String: SharedDictationSessionCommand].self,
                forKey: Key.cancellationIntents
            ) ?? [:]
            guard intents[command.token] == nil,
                  intents.count < Self.historyLimit else {
                return intents[command.token] == command
            }
            intents[command.token] = command
            save(intents, forKey: Key.cancellationIntents)
            return true
        } ?? false
    }

    public func pendingCancellationIntents() -> [SharedDictationSessionCommand] {
        switch pendingCancellationIntentsResolution() {
        case .available(let intents): return intents
        case .unavailable: return []
        }
    }

    public func pendingCancellationIntentsResolution() -> CancellationIntentResolution {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                guard !envelopeReadBlocked else { return .unavailable }
                return .available(Array(envelope.cancellationIntents.values))
            }
            return .available(Array(
                (load(
                    [String: SharedDictationSessionCommand].self,
                    forKey: Key.cancellationIntents
                ) ?? [:]).values
            ))
        } ?? .unavailable
    }

    @discardableResult
    public func discardCancellationIntent(forToken token: String) -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                envelope.cancellationIntents.removeValue(forKey: token)
                return saveEnvelope(envelope)
            }
            var intents = load(
                [String: SharedDictationSessionCommand].self,
                forKey: Key.cancellationIntents
            ) ?? [:]
            intents.removeValue(forKey: token)
            save(intents, forKey: Key.cancellationIntents)
            return true
        } ?? false
    }

    public func status() -> SharedDictationSessionStatus {
        withExclusiveAccess {
            envelopeURL == nil ? loadStatus() : loadEnvelope().latestStatus
        } ?? .idle
    }

    /// Resolves a token-scoped status without collapsing a locked, corrupt, or
    /// otherwise unreadable store into the ordinary `.idle` fallback.
    public func statusResolution(
        forCommandToken commandToken: String
    ) -> StatusResolution {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                guard !envelopeReadBlocked else { return .unavailable }
                if let status = envelope.statuses[commandToken]
                    ?? (envelope.latestStatus.commandToken == commandToken
                        ? envelope.latestStatus
                        : nil) {
                    return .found(status)
                }
                return .missing
            }

            if let status = load(
                SharedDictationSessionStatus.self,
                forKey: Key.statusPrefix + commandToken
            ) {
                return .found(status)
            }
            let statusKey = Key.statusPrefix + commandToken
            if defaults.object(forKey: statusKey) != nil {
                return .unavailable
            }
            guard let latestStatus = load(
                SharedDictationSessionStatus.self,
                forKey: Key.status
            ) else {
                return defaults.object(forKey: Key.status) == nil
                    ? .missing
                    : .unavailable
            }
            if latestStatus.commandToken == commandToken {
                return .found(latestStatus)
            }
            return .missing
        } ?? .unavailable
    }

    public func status(forCommandToken commandToken: String) -> SharedDictationSessionStatus {
        switch statusResolution(forCommandToken: commandToken) {
        case .found(let status): return status
        case .missing, .unavailable: return .idle
        }
    }

    /// Returns token-scoped statuses for cold recovery. The latest status is
    /// not sufficient when a stop/cancel command was published after an
    /// earlier start status.
    public func statusHistory() -> [String: SharedDictationSessionStatus] {
        withExclusiveAccess {
            if envelopeURL != nil { return loadEnvelope().statuses }
            return loadStatusHistory()
        } ?? [:]
    }

    /// Atomically cancels a stale keyboard start. Recovery validates the claim,
    /// the session-bound heartbeat, and the current status under the same file
    /// lock as the transition. Active recording states are cancellable only
    /// after command expiry and when no producer claim or fresh heartbeat
    /// remains; a live producer therefore keeps its transcript handoff alive.
    @discardableResult
    public func cancelStaleKeyboardCommand(
        token: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                guard let command = envelope.commands[token],
                      command.source == .keyboard,
                      command.kind == .start else { return false }
                pruneClaims(&envelope, now: now)
                guard envelope.claims[token] == nil,
                      !envelope.heartbeats.values.contains(where: {
                          $0.sessionID == command.sessionID && $0.isFresh(at: now, maxAge: 5)
                      }) else { return false }
                let currentStatus = envelope.statuses[token]
                    ?? (envelope.latestStatus.commandToken == token ? envelope.latestStatus : .idle)
                // A producer can still be committing a transcript after its
                // short command deadline. Never blind-cancel an acknowledged,
                // recording, or transcribing state based on a separate-store
                // read; terminal cancellation would permanently strand a
                // transcript that wins the race immediately afterward.
                let shouldCancel: Bool
                switch currentStatus {
                case .idle, .commandPending:
                    shouldCancel = command.isExpired(at: now)
                case .commandAcknowledged, .recording, .transcribing:
                    shouldCancel = command.isExpired(at: now)
                case .transcriptReady, .failed, .cancelled:
                    shouldCancel = false
                }
                guard shouldCancel else { return false }
                let status: SharedDictationSessionStatus
                switch currentStatus {
                case .commandAcknowledged, .recording, .transcribing:
                    // The transcript store is a separate durable resource.
                    // Keep this state recoverable because a producer may be
                    // between its final audio callback and transcript commit.
                    status = .failed(
                        token: token,
                        message: "Keyboard producer timed out; a committed transcript may still be recovered."
                    )
                default:
                    status = .cancelled(token: token)
                }
                let latestStatusToken = envelope.latestStatus.commandToken
                let shouldReplaceLatestStatus = latestStatusToken == nil
                    || latestStatusToken == token
                    || (envelope.commands[latestStatusToken!]?.requestedAt
                        ?? .distantPast) <= command.requestedAt
                if shouldReplaceLatestStatus {
                    envelope.latestStatus = status
                }
                envelope.statuses[token] = status
                envelope.statusOrder.removeAll { $0 == token }
                envelope.statusOrder.append(token)
                envelope.claims.removeValue(forKey: token)
                envelope.claimOwners.removeValue(forKey: token)
                pruneStatus(&envelope)
                return saveEnvelope(envelope)
            }

            guard let command = loadCommand(forToken: token),
                  command.source == .keyboard,
                  command.kind == .start else { return false }
            var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
            var claimOwners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
            pruneDefaultClaims(&claims, owners: &claimOwners, now: now)
            guard claims[token] == nil,
                  !(load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat).map {
                      $0.sessionID == command.sessionID && $0.isFresh(at: now, maxAge: 5)
                  } ?? false) else { return false }
            let currentStatus = load(
                SharedDictationSessionStatus.self,
                forKey: Key.statusPrefix + token
            ) ?? (loadStatus().commandToken == token ? loadStatus() : .idle)
            let shouldCancel: Bool
            switch currentStatus {
            case .idle, .commandPending:
                shouldCancel = command.isExpired(at: now)
            case .commandAcknowledged, .recording, .transcribing:
                shouldCancel = command.isExpired(at: now)
            case .transcriptReady, .failed, .cancelled:
                shouldCancel = false
            }
            guard shouldCancel else { return false }
            let status: SharedDictationSessionStatus
            switch currentStatus {
            case .commandAcknowledged, .recording, .transcribing:
                status = .failed(
                    token: token,
                    message: "Keyboard producer timed out; a committed transcript may still be recovered."
                )
            default:
                status = .cancelled(token: token)
            }
            let latestStatus = loadStatus()
            let shouldReplaceLatestStatus = latestStatus.commandToken == nil
                || latestStatus.commandToken == token
                || (loadCommand(forToken: latestStatus.commandToken ?? "")?.requestedAt
                    ?? .distantPast) <= command.requestedAt
            claims.removeValue(forKey: token)
            claimOwners.removeValue(forKey: token)
            save(claims, forKey: Key.claims)
            save(claimOwners, forKey: Key.claimOwners)
            if shouldReplaceLatestStatus {
                save(status, forKey: Key.status)
            }
            save(status, forKey: Key.statusPrefix + token)
            appendToken(token, toIndex: Key.statusIndex, removingWithPrefix: Key.statusPrefix)
            return true
        } ?? false
    }

    /// Cancels a keyboard start that this extension published but never
    /// successfully handed to the containing app. Unlike stale recovery,
    /// this narrow transition is allowed before command expiry, but only
    /// while the command has no claim and no token-scoped status.
    @discardableResult
    public func cancelUnclaimedKeyboardCommand(
        token: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                guard let command = envelope.commands[token],
                      command.source == .keyboard,
                      command.kind == .start,
                      envelope.claims[token] == nil,
                      envelope.statuses[token] == nil,
                      envelope.latestStatus.commandToken != token else {
                    return false
                }
                let status = SharedDictationSessionStatus.cancelled(token: token)
                let latestStatusToken = envelope.latestStatus.commandToken
                let shouldReplaceLatestStatus = latestStatusToken == nil
                    || (envelope.commands[latestStatusToken!]?.requestedAt
                        ?? .distantPast) <= command.requestedAt
                if shouldReplaceLatestStatus {
                    envelope.latestStatus = status
                }
                envelope.statuses[token] = status
                envelope.statusOrder.removeAll { $0 == token }
                envelope.statusOrder.append(token)
                pruneStatus(&envelope)
                return saveEnvelope(envelope)
            }

            var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
            var owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
            pruneDefaultClaims(&claims, owners: &owners, now: now)
            guard let command = loadCommand(forToken: token),
                  command.source == .keyboard,
                  command.kind == .start,
                  claims[token] == nil,
                  load(SharedDictationSessionStatus.self, forKey: Key.statusPrefix + token) == nil,
                  loadStatus().commandToken != token else {
                return false
            }
            let status = SharedDictationSessionStatus.cancelled(token: token)
            save(status, forKey: Key.status)
            save(status, forKey: Key.statusPrefix + token)
            appendToken(token, toIndex: Key.statusIndex, removingWithPrefix: Key.statusPrefix)
            return true
        } ?? false
    }

    @discardableResult
    public func saveHeartbeat(_ heartbeat: SharedDictationAppHeartbeat) -> Bool {
        withExclusiveAccess {
            if envelopeURL != nil {
                var envelope = loadEnvelope()
                if let existing = envelope.heartbeats[heartbeat.token],
                   existing.lastSeenAt > heartbeat.lastSeenAt {
                    return true
                }
                pruneHeartbeats(&envelope, now: Date())
                envelope.heartbeats[heartbeat.token] = heartbeat
                if envelope.heartbeat?.lastSeenAt ?? .distantPast <= heartbeat.lastSeenAt {
                    envelope.heartbeat = heartbeat
                }
                pruneHeartbeats(&envelope, now: heartbeat.lastSeenAt)
                guard envelope.heartbeats[heartbeat.token] != nil else {
                    // Every retained heartbeat may be protected by a live
                    // claim. Do not report success after pruning the new
                    // owner's heartbeat; the caller must retry later.
                    return false
                }
                return saveEnvelope(envelope)
            }
            if heartbeat.sessionState == .unavailable,
               let existing = load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat),
               existing.sessionState != .unavailable,
               existing.isFresh(maxAge: 5) {
                return true
            }
            if let existing = load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat),
               existing.lastSeenAt > heartbeat.lastSeenAt {
                return true
            }
            save(heartbeat, forKey: Key.heartbeat)
            return true
        } ?? false
    }

    public func heartbeat() -> SharedDictationAppHeartbeat? {
        withExclusiveAccess {
            if envelopeURL != nil {
                let envelope = loadEnvelope()
                return envelope.heartbeats.values.max { $0.lastSeenAt < $1.lastSeenAt }
                    ?? envelope.heartbeat
            }
            return load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat)
        } ?? nil
    }

    public func heartbeat(forSessionID sessionID: String) -> SharedDictationAppHeartbeat? {
        withExclusiveAccess {
            guard envelopeURL != nil else { return nil }
            return loadEnvelope().heartbeats.values
                .filter { $0.sessionID == sessionID }
                .max { $0.lastSeenAt < $1.lastSeenAt }
        } ?? nil
    }

    @discardableResult
    public func renewCommandClaim(
        token: String,
        ownerToken: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL != nil else {
                var claims = load([String: Date].self, forKey: Key.claims) ?? [:]
                var owners = load([String: String].self, forKey: Key.claimOwners) ?? [:]
                pruneDefaultClaims(&claims, owners: &owners, now: now)
                guard claims[token] != nil,
                      owners[token] == ownerToken,
                      let heartbeat = load(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat),
                      heartbeat.token == ownerToken,
                      heartbeat.isFresh(at: now, maxAge: 5) else { return false }
                claims[token] = now.addingTimeInterval(Self.claimInterval)
                save(claims, forKey: Key.claims)
                save(owners, forKey: Key.claimOwners)
                return true
            }
            var envelope = loadEnvelope()
            guard envelope.commands[token] != nil,
                  envelope.claimOwners[token] == ownerToken,
                  let expiresAt = envelope.claims[token],
                  expiresAt > now,
                  let heartbeat = envelope.heartbeats[ownerToken],
                  heartbeat.isFresh(at: now, maxAge: 5) else {
                return false
            }
            envelope.claims[token] = now.addingTimeInterval(Self.claimInterval)
            return saveEnvelope(envelope)
        } ?? false
    }

    private func claimNextCommand(
        commands: [SharedDictationSessionCommand],
        afterLastClaimedToken lastClaimedToken: String?,
        now: Date,
        supersededTokens: Set<String>? = nil
    ) -> SharedDictationSessionCommand? {
        guard !commands.isEmpty else { return nil }
        let startIndex = lastClaimedToken.flatMap { token in
            commands.firstIndex { $0.token == token }.map { commands.index(after: $0) }
        } ?? commands.startIndex
        let candidates = Array(commands[startIndex...])
        let supersededTokens = supersededTokens ?? supersededCommandTokens(in: commands)
        for command in candidates {
            guard !supersededTokens.contains(command.token), !command.isExpired(at: now) else { continue }
            return command
        }
        return nil
    }

    private func supersededCommandTokens(
        in commands: [SharedDictationSessionCommand]
    ) -> Set<String> {
        var result = Set(commands.compactMap { $0.replacesCommandToken })
        for (index, command) in commands.enumerated()
        where (command.kind == .stop || command.kind == .cancel)
            && command.replacesCommandToken == nil {
            if let priorStart = commands[..<index].last(where: {
                $0.kind == .start && $0.sessionID == command.sessionID
            }) {
                result.insert(priorStart.token)
            }
        }
        return result
    }

    private func isCurrentRecoveryReplacement(
        sourceCommandToken: String,
        ownerCommand: SharedDictationSessionCommand,
        commands: [SharedDictationSessionCommand],
        cancellationIntents: [SharedDictationSessionCommand]
    ) -> Bool {
        guard ownerCommand.kind == .stop,
              ownerCommand.replacesCommandToken == sourceCommandToken,
              let ownerIndex = commands.firstIndex(where: { $0.token == ownerCommand.token }) else {
            return false
        }
        let laterReplacementExists = commands[(ownerIndex + 1)...].contains {
            guard $0.kind == .stop || $0.kind == .cancel else { return false }
            if $0.replacesCommandToken == sourceCommandToken { return true }
            return $0.replacesCommandToken == nil
                && $0.sessionID == commands.first(where: { $0.token == sourceCommandToken })?.sessionID
        }
        let cancellationExists = commands.contains {
            $0.kind == .cancel && $0.replacesCommandToken == sourceCommandToken
        } || cancellationIntents.contains {
            $0.kind == .cancel && $0.replacesCommandToken == sourceCommandToken
        }
        return !laterReplacementExists && !cancellationExists
    }

    private func loadCommandHistory() -> [SharedDictationSessionCommand] {
        var tokens = Self.uniqueTokens(load([String].self, forKey: Key.commandIndex) ?? [])
        if let latestCommand = loadLatestCommand(), !tokens.contains(latestCommand.token) {
            tokens.append(latestCommand.token)
        }
        guard tokens.count > Self.historyLimit else {
            return tokens.compactMap { loadCommand(forToken: $0) }
        }

        // A stop/cancel command is not self-contained. Keep the referenced
        // start command through legacy migration even when it is older than
        // the ordinary bounded history window.
        var requiredTokens = Set<String>()
        for token in tokens {
            if let command = load(
                SharedDictationSessionCommand.self,
                forKey: Key.commandPrefix + token
            ), let replacement = command.replacesCommandToken {
                requiredTokens.insert(replacement)
            }
        }
        var didAddDependency = true
        while didAddDependency {
            didAddDependency = false
            for token in requiredTokens {
                guard let replacement = load(
                    SharedDictationSessionCommand.self,
                    forKey: Key.commandPrefix + token
                )?.replacesCommandToken,
                !requiredTokens.contains(replacement) else { continue }
                requiredTokens.insert(replacement)
                didAddDependency = true
            }
        }
        guard requiredTokens.count <= Self.historyLimit else {
            return []
        }
        let ordinaryCapacity = Self.historyLimit - requiredTokens.count
        let ordinary = tokens.reversed()
            .filter { !requiredTokens.contains($0) }
            .prefix(ordinaryCapacity)
        let retained = Set(requiredTokens).union(ordinary)
        return tokens.filter(retained.contains).compactMap { loadCommand(forToken: $0) }
    }

    private func loadCommandHistoryResolution() -> CommandHistoryResolution {
        guard defaults.object(forKey: Key.commandIndex) != nil else {
            if defaults.object(forKey: Key.command) != nil,
               loadLatestCommand() == nil {
                return .unavailable
            }
            return .available(loadCommandHistory())
        }
        guard let indexData = defaults.data(forKey: Key.commandIndex) else {
            return .unavailable
        }
        guard indexData.count <= Self.maximumEnvelopeByteCount,
              let tokens = try? decoder.decode([String].self, from: indexData) else {
            return .unavailable
        }
        if defaults.object(forKey: Key.command) != nil,
           loadLatestCommand() == nil {
            return .unavailable
        }
        for token in Self.uniqueTokens(tokens) {
            let key = Key.commandPrefix + token
            guard defaults.object(forKey: key) != nil else {
                return .unavailable
            }
            guard load(SharedDictationSessionCommand.self, forKey: key) != nil else {
                return .unavailable
            }
        }
        return .available(loadCommandHistory())
    }

    private func loadEnvelope() -> SessionEnvelope {
        if let envelopeURL {
            let primaryEnvelope = decodeEnvelope(at: envelopeURL)
            let backupEnvelope = backupEnvelopeURL.flatMap { decodeEnvelope(at: $0) }
            if let primaryEnvelope,
               backupEnvelope.map({ $0.revision <= primaryEnvelope.revision }) ?? true {
                envelopeReadBlocked = false
                return primaryEnvelope
            }
            if let backupURL = backupEnvelopeURL,
               let backupEnvelope {
                // Atomic replacement normally makes corruption impossible,
                // but a validated backup keeps a transient damaged App Group
                // file from permanently disabling the handoff. Restore the
                // primary as well so the next write cannot preserve a stale
                // or missing primary indefinitely.
                if let backupData = try? Data(contentsOf: backupURL) {
                    try? backupData.write(to: envelopeURL, options: [.atomic])
                }
                envelopeReadBlocked = false
                return backupEnvelope
            }
            if FileManager.default.fileExists(atPath: envelopeURL.path)
                || defaults.bool(forKey: Key.envelopeMigrationMarker) {
                envelopeReadBlocked = true
                return SessionEnvelope()
            }
        }
        guard !defaults.bool(forKey: Key.envelopeMigrationMarker) else {
            return SessionEnvelope()
        }
        let commandHistory: [SharedDictationSessionCommand]
        switch loadCommandHistoryResolution() {
        case .available(let commands):
            commandHistory = commands
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let statusTokens: [String]
        switch loadLegacyValue([String].self, forKey: Key.statusIndex) {
        case .missing:
            statusTokens = []
        case .found(let tokens):
            guard tokens.count <= Self.historyLimit,
                  tokens.count == Set(tokens).count,
                  tokens.allSatisfy(Self.bounded) else {
                envelopeReadBlocked = true
                return SessionEnvelope()
            }
            statusTokens = tokens
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        var statuses = loadStatusHistory()
        guard !envelopeReadBlocked else { return SessionEnvelope() }
        var statusOrder = statusTokens
        guard statusOrder.allSatisfy({ statuses[$0] != nil }) else {
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let latestStatus: SharedDictationSessionStatus
        switch loadLegacyValue(SharedDictationSessionStatus.self, forKey: Key.status) {
        case .missing:
            latestStatus = .idle
        case .found(let status):
            latestStatus = status
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        // Older releases stored only the latest token-scoped status. Preserve
        // it during migration so a later status cannot erase the only record
        // from which that command can be recovered.
        if let latestToken = latestStatus.commandToken,
           commandHistory.contains(where: { $0.token == latestToken }),
           statuses[latestToken] == nil {
            statuses[latestToken] = latestStatus
            statusOrder.append(latestToken)
        }
        let commands = Self.dictionaryByToken(commandHistory)
        let claims: [String: Date]
        switch loadLegacyValue([String: Date].self, forKey: Key.claims) {
        case .missing:
            claims = [:]
        case .found(let value):
            claims = value
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let filteredClaims = claims.filter { commands[$0.key] != nil }
        let claimOwners: [String: String]
        switch loadLegacyValue([String: String].self, forKey: Key.claimOwners) {
        case .missing:
            claimOwners = [:]
        case .found(let value):
            claimOwners = value.filter { filteredClaims[$0.key] != nil }
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let heartbeat: SharedDictationAppHeartbeat?
        switch loadLegacyValue(SharedDictationAppHeartbeat.self, forKey: Key.heartbeat) {
        case .missing:
            heartbeat = nil
        case .found(let value):
            heartbeat = value
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let deliveryFailureIntents: [String: String]
        switch loadLegacyValue([String: String].self, forKey: Key.deliveryFailureIntents) {
        case .missing:
            deliveryFailureIntents = [:]
        case .found(let value):
            deliveryFailureIntents = value
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let cancellationIntents: [String: SharedDictationSessionCommand]
        switch loadLegacyValue([String: SharedDictationSessionCommand].self, forKey: Key.cancellationIntents) {
        case .missing:
            cancellationIntents = [:]
        case .found(let value):
            cancellationIntents = value
        case .unavailable:
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        let candidate = SessionEnvelope(
            commands: commands,
            commandOrder: Self.uniqueTokens(commandHistory.map(\.token)),
            statuses: statuses,
            statusOrder: Self.uniqueTokens(statusOrder),
            latestStatus: latestStatus,
            heartbeat: heartbeat,
            heartbeats: heartbeat.map { [$0.token: $0] } ?? [:],
            claims: filteredClaims,
            claimOwners: claimOwners,
            deliveryFailureIntents: deliveryFailureIntents,
            cancellationIntents: cancellationIntents
        )
        guard Self.isValidEnvelope(candidate) else {
            envelopeReadBlocked = true
            return SessionEnvelope()
        }
        return candidate
    }

    private func saveEnvelope(_ envelope: SessionEnvelope) -> Bool {
        var envelope = envelope
        guard !envelopeReadBlocked,
              let envelopeURL,
              Self.isValidEnvelope(envelope) else { return false }
        let currentRevision = max(
            decodeEnvelope(at: envelopeURL)?.revision ?? 0,
            backupEnvelopeURL.flatMap { decodeEnvelope(at: $0)?.revision } ?? 0
        )
        guard currentRevision < UInt64.max - 1 else { return false }
        envelope.revision = currentRevision + 1
        guard let data = try? encoder.encode(envelope),
              data.count <= Self.maximumEnvelopeByteCount else { return false }
        do {
            var didWriteBackup = false
            if let backupEnvelopeURL {
                // Commit the recovery copy first. If it cannot be written,
                // leave the primary at its previous revision; otherwise a
                // newer primary paired with an older backup could replay an
                // already-applied command after primary corruption.
                try data.write(to: backupEnvelopeURL, options: [.atomic])
                didWriteBackup = true
            }
            do {
                try data.write(to: envelopeURL, options: [.atomic])
            } catch {
                // The backup is the authoritative recovery copy on the next
                // open. Report success when it committed so callers do not
                // proceed as though the durable command update was lost.
                guard didWriteBackup else { return false }
            }
            defaults.set(true, forKey: Key.envelopeMigrationMarker)
            return true
        } catch {
            return false
        }
    }

    private var backupEnvelopeURL: URL? {
        envelopeURL?.appendingPathExtension("backup")
    }

    private func decodeEnvelope(at url: URL) -> SessionEnvelope? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue <= Self.maximumEnvelopeByteCount,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumEnvelopeByteCount else {
            return nil
        }
        guard let envelope = try? decoder.decode(SessionEnvelope.self, from: data),
              Self.isValidEnvelope(envelope) else {
            return nil
        }
        return envelope
    }

    private func loadStatusHistory() -> [String: SharedDictationSessionStatus] {
        let tokens: [String]
        if let data = defaults.data(forKey: Key.statusIndex) {
            guard data.count <= Self.maximumEnvelopeByteCount,
                  let decodedTokens = try? decoder.decode([String].self, from: data) else {
                envelopeReadBlocked = true
                return [:]
            }
            tokens = Array(decodedTokens.suffix(Self.historyLimit))
        } else {
            tokens = []
        }
        var statuses: [String: SharedDictationSessionStatus] = [:]
        for token in Self.uniqueTokens(tokens) {
            let key = Key.statusPrefix + token
            guard defaults.object(forKey: key) != nil,
                  load(SharedDictationSessionStatus.self, forKey: key) != nil else {
                envelopeReadBlocked = true
                return [:]
            }
            if let status = load(SharedDictationSessionStatus.self, forKey: key) {
                statuses[token] = status
            }
        }
        return statuses
    }

    private static func isValidEnvelope(_ envelope: SessionEnvelope) -> Bool {
        guard envelope.revision < UInt64.max,
              envelope.commands.count <= historyLimit,
              envelope.commandOrder.count <= historyLimit,
              envelope.statuses.count <= historyLimit,
              envelope.statusOrder.count <= historyLimit,
              envelope.claims.count <= historyLimit,
              envelope.claimOwners.count <= historyLimit,
              envelope.deliveryFailureIntents.count <= historyLimit,
              envelope.cancellationIntents.count <= historyLimit,
              envelope.heartbeats.count <= heartbeatHistoryLimit,
              isValidStatus(envelope.latestStatus),
              commandOrderIsValid(envelope.commandOrder, keys: envelope.commands),
              commandOrderIsValid(envelope.statusOrder, keys: envelope.statuses),
              Set(envelope.commandOrder) == Set(envelope.commands.keys),
              Set(envelope.statusOrder) == Set(envelope.statuses.keys),
              Set(envelope.claimOwners.keys) == Set(envelope.claims.keys),
              Set(envelope.commandOrder).count == envelope.commandOrder.count,
              Set(envelope.statusOrder).count == envelope.statusOrder.count else {
            return false
        }
        for (token, command) in envelope.commands {
            guard token == command.token,
                  bounded(command.token),
                  bounded(command.sessionID),
                  command.replacesCommandToken.map(bounded) ?? true,
                  command.requestedAt.timeIntervalSinceReferenceDate.isFinite,
                  command.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  command.requestedAt <= Date().addingTimeInterval(maximumFutureClockSkew),
                  command.expiresAt <= Date().addingTimeInterval(
                      maximumCommandHorizon + maximumFutureClockSkew
                  ),
                  command.expiresAt >= command.requestedAt else {
                return false
            }
        }
        for (index, token) in envelope.commandOrder.enumerated() {
            guard let command = envelope.commands[token] else { return false }
            switch command.kind {
            case .start:
                guard command.replacesCommandToken == nil else { return false }
            case .stop, .cancel:
                if let replacedToken = command.replacesCommandToken {
                    guard let replacedCommand = envelope.commands[replacedToken],
                          replacedCommand.kind == .start,
                          replacedCommand.sessionID == command.sessionID,
                          command.requestedAt >= replacedCommand.requestedAt,
                          envelope.commandOrder[..<index].contains(replacedToken) else {
                        return false
                    }
                }
            }
        }
        for (token, status) in envelope.statuses {
            guard bounded(token), isValidStatus(status), status.commandToken == token else {
                return false
            }
        }
        for (token, expiresAt) in envelope.claims {
            guard bounded(token),
                  expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  expiresAt <= Date().addingTimeInterval(
                      claimInterval + maximumFutureClockSkew
                  ) else { return false }
        }
        for (token, owner) in envelope.claimOwners {
            guard bounded(token), bounded(owner) else { return false }
        }
        for (token, message) in envelope.deliveryFailureIntents {
            guard bounded(token),
                  message.utf8.count <= maximumMessageByteCount,
                  !message.contains("\0") else { return false }
        }
        for (token, command) in envelope.cancellationIntents {
            guard token == command.token,
                  command.kind == .cancel,
                  command.source == .keyboard,
                  bounded(command.token),
                  bounded(command.sessionID),
                  command.replacesCommandToken.map(bounded) ?? false,
                  command.requestedAt.timeIntervalSinceReferenceDate.isFinite,
                  command.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  command.requestedAt <= Date().addingTimeInterval(maximumFutureClockSkew),
                  command.expiresAt >= command.requestedAt,
                  command.expiresAt <= Date().addingTimeInterval(
                      maximumCommandHorizon + maximumFutureClockSkew
                  ) else { return false }
        }
        for token in envelope.claims.keys {
            guard envelope.commands.keys.contains(token) else { return false }
        }
        for token in envelope.claimOwners.keys {
            guard envelope.claims[token] != nil else { return false }
        }
        for (token, heartbeat) in envelope.heartbeats {
            guard token == heartbeat.token else { return false }
            guard bounded(heartbeat.token),
                  heartbeat.sessionID.map(bounded) ?? true,
                  heartbeat.lastSeenAt.timeIntervalSinceReferenceDate.isFinite,
                  heartbeat.lastSeenAt <= Date().addingTimeInterval(maximumFutureClockSkew) else {
                return false
            }
        }
        return true
    }

    private static func commandOrderIsValid<Value>(
        _ order: [String],
        keys: [String: Value]
    ) -> Bool {
        order.allSatisfy { keys[$0] != nil && bounded($0) }
    }

    private static func bounded(_ value: String) -> Bool {
        value.utf8.count <= maximumTokenByteCount && !value.contains("\0")
    }

    private static func isValidStatus(_ status: SharedDictationSessionStatus) -> Bool {
        switch status {
        case .idle:
            return true
        case let .commandPending(token, requestedAt),
             let .commandAcknowledged(token, requestedAt):
            return bounded(token)
                && requestedAt.timeIntervalSinceReferenceDate.isFinite
        case let .transcribing(token),
             let .transcriptReady(token):
            return bounded(token)
        case let .recording(token, startedAt, timeoutSeconds):
            return bounded(token)
                && startedAt.timeIntervalSinceReferenceDate.isFinite
                && timeoutSeconds.isFinite
                && timeoutSeconds >= 0
        case let .failed(token, message):
            return (token.map(bounded) ?? true)
                && message.utf8.count <= maximumMessageByteCount
                && !message.contains("\0")
        case let .cancelled(token):
            return token.map(bounded) ?? true
        }
    }

    private static func isAllowedStatusTransition(
        from current: SharedDictationSessionStatus?,
        to next: SharedDictationSessionStatus,
        allowRecoveryFromTranscriptReady: Bool = false
    ) -> Bool {
        guard let current else { return true }
        if allowRecoveryFromTranscriptReady,
           case .transcriptReady(let currentToken) = current,
           case .failed(let nextToken, _) = next,
           currentToken == nextToken {
            return true
        }
        if allowRecoveryFromTranscriptReady,
           case .cancelled(let currentToken) = current,
           case .transcriptReady(let nextToken) = next,
           currentToken == nextToken {
            return true
        }
        if allowRecoveryFromTranscriptReady,
           case .failed(let currentToken, _) = current,
           case .transcriptReady(let nextToken) = next,
           currentToken == nextToken {
            return true
        }
        if current.isTerminal { return current == next }
        switch (current, next) {
        case (.commandPending, .commandPending),
             (.commandPending, .commandAcknowledged),
             (.commandPending, .recording),
             (.commandPending, .transcribing),
             (.commandPending, .transcriptReady),
             (.commandPending, .failed),
             (.commandPending, .cancelled),
             (.commandAcknowledged, .commandAcknowledged),
             (.commandAcknowledged, .recording),
             (.commandAcknowledged, .transcribing),
             (.commandAcknowledged, .transcriptReady),
             (.commandAcknowledged, .failed),
             (.commandAcknowledged, .cancelled),
             (.recording, .recording),
             (.recording, .transcribing),
             (.recording, .transcriptReady),
             (.recording, .failed),
             (.recording, .cancelled),
             (.transcribing, .transcribing),
             (.transcribing, .transcriptReady),
             (.transcribing, .failed),
             (.transcribing, .cancelled):
            return true
        default:
            return false
        }
    }

    private func pruneStatus(_ envelope: inout SessionEnvelope) {
        envelope.statusOrder = envelope.statusOrder.filter { envelope.statuses[$0] != nil }
        guard envelope.statusOrder.count > Self.historyLimit else { return }
        let protectedTokens = Set(envelope.statusOrder.compactMap { token -> String? in
            guard let status = envelope.statuses[token],
                  let command = envelope.commands[token],
                  Date().timeIntervalSince(command.requestedAt) <= Self.transcriptRetentionInterval else {
                return nil
            }
            switch status {
            case .commandPending, .commandAcknowledged, .recording, .transcribing, .transcriptReady:
                return token
            case .idle, .failed, .cancelled:
                return nil
            }
        })
        let retainedTokens = retainedHistoryTokens(
            envelope.statusOrder,
            protectedTokens: protectedTokens
        )
        for token in envelope.statusOrder where !retainedTokens.contains(token) {
            envelope.statuses.removeValue(forKey: token)
        }
        envelope.statusOrder = envelope.statusOrder.filter(retainedTokens.contains)
    }

    private func pruneCommands(_ envelope: inout SessionEnvelope) -> Bool {
        envelope.commandOrder = envelope.commandOrder.filter { envelope.commands[$0] != nil }
        guard envelope.commandOrder.count > Self.historyLimit else { return true }
        let now = Date()
        let protectedTokens = Set(envelope.commandOrder.compactMap { token -> String? in
            if envelope.claims[token] != nil {
                // A claimed command has not necessarily published a status
                // yet. Pruning it would invalidate the claim and strand the
                // containing app's handoff.
                return token
            }
            guard let command = envelope.commands[token],
                  now.timeIntervalSince(command.requestedAt) <= Self.transcriptRetentionInterval else {
                return nil
            }
            // A live command without a status is still waiting to be
            // consumed by the containing app. Treating it as ordinary history
            // can silently delete the handoff while saveCommand reports
            // success.
            guard let status = envelope.statuses[token] else {
                // An unstated command is safe to retain only while it can
                // still be claimed by its producer. Once its lease expires,
                // it is ordinary stale history.
                return command.isExpired(at: now) ? nil : token
            }
            switch status {
            case .commandPending, .commandAcknowledged, .recording, .transcribing, .transcriptReady:
                return token
            case .idle, .failed, .cancelled:
                return nil
            }
        })
        guard protectedTokens.count <= Self.historyLimit else { return false }
        let retainedTokens = retainedHistoryTokens(
            envelope.commandOrder,
            protectedTokens: protectedTokens
        )
        // A replacement command is not self-contained. Keep the full
        // dependency closure for every retained command, including a newly
        // published stop/cancel whose start is older than the history window.
        var requiredTokens = protectedTokens
        for cancellation in envelope.cancellationIntents.values {
            if let replacedToken = cancellation.replacesCommandToken,
               envelope.commands[replacedToken] != nil {
                requiredTokens.insert(replacedToken)
            }
        }
        var dependencyTokens = Set(retainedTokens).union(requiredTokens)
        var didAddDependency = true
        while didAddDependency {
            didAddDependency = false
            for token in dependencyTokens {
                guard let replacement = envelope.commands[token]?.replacesCommandToken,
                      !dependencyTokens.contains(replacement) else { continue }
                dependencyTokens.insert(replacement)
                requiredTokens.insert(replacement)
                didAddDependency = true
            }
        }
        guard requiredTokens.count <= Self.historyLimit else { return false }
        var retainedSet = Set(retainedTokens).union(requiredTokens)
        if retainedSet.count > Self.historyLimit {
            let removable = envelope.commandOrder
                .filter { retainedSet.contains($0) && !requiredTokens.contains($0) }
                .sorted { lhs, rhs in
                    let left = envelope.commands[lhs]?.requestedAt ?? .distantPast
                    let right = envelope.commands[rhs]?.requestedAt ?? .distantPast
                    return left < right
                }
            for token in removable where retainedSet.count > Self.historyLimit {
                retainedSet.remove(token)
            }
        }
        for token in envelope.commandOrder where !retainedSet.contains(token) {
            envelope.commands.removeValue(forKey: token)
        }
        envelope.commandOrder = envelope.commandOrder.filter(retainedSet.contains)
        return true
    }

    private func retainedHistoryTokens(
        _ order: [String],
        protectedTokens: Set<String>
    ) -> Set<String> {
        // Protected entries are part of the same bounded history, not an
        // addition to it. Keep the newest protected entries first, then fill
        // the remaining capacity with the newest ordinary history entries.
        let protectedInOrder = order.filter(protectedTokens.contains)
        let retainedProtected = protectedInOrder.suffix(Self.historyLimit)
        let remainingCapacity = max(0, Self.historyLimit - retainedProtected.count)
        let retainedOrdinary = order.reversed()
            .filter { !protectedTokens.contains($0) }
            .prefix(remainingCapacity)
        return Set(retainedProtected).union(retainedOrdinary)
    }

    private func pruneClaims(_ envelope: inout SessionEnvelope, now: Date) {
        envelope.claims = envelope.claims.filter { token, expiresAt in
            guard let ownerToken = envelope.claimOwners[token],
                  let heartbeat = envelope.heartbeats[ownerToken],
                  heartbeat.sessionState != .unavailable else {
                return expiresAt > now
            }
            // A process that claimed a command must keep publishing a live
            // heartbeat. This lets a cold restart recover immediately after
            // a crash instead of waiting for the command's full expiry.
            // A live general heartbeat is an additional liveness fence, not a
            // replacement for the short claim lease. An owner may remain
            // healthy while abandoning this handoff, so the claim must still
            // become reclaimable when its lease expires.
            return expiresAt > now && heartbeat.isFresh(at: now, maxAge: 5)
        }
        envelope.claimOwners = envelope.claimOwners.filter { envelope.claims[$0.key] != nil }
    }

    private func pruneDefaultClaims(
        _ claims: inout [String: Date],
        owners: inout [String: String],
        now: Date
    ) {
        claims = claims.filter { $0.value > now }
        owners = owners.filter { claims[$0.key] != nil }
        save(claims, forKey: Key.claims)
        save(owners, forKey: Key.claimOwners)
    }

    private func pruneHeartbeats(_ envelope: inout SessionEnvelope, now: Date) {
        let protectedTokens = Set(envelope.claimOwners.values)
        envelope.heartbeats = envelope.heartbeats.filter { token, heartbeat in
            protectedTokens.contains(token)
                || now.timeIntervalSince(heartbeat.lastSeenAt) <= Self.heartbeatRetentionInterval
        }
        guard envelope.heartbeats.count > Self.heartbeatHistoryLimit else { return }
        let removable = envelope.heartbeats
            .filter { !protectedTokens.contains($0.key) }
            .sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
        for (token, _) in removable.prefix(envelope.heartbeats.count - Self.heartbeatHistoryLimit) {
            envelope.heartbeats.removeValue(forKey: token)
        }
    }

    private func isSuperseded(
        _ command: SharedDictationSessionCommand,
        in envelope: SessionEnvelope
    ) -> Bool {
        isSuperseded(
            command,
            in: envelope.commandOrder.compactMap { envelope.commands[$0] }
                + Array(envelope.cancellationIntents.values)
        )
    }

    private func isSuperseded(
        _ command: SharedDictationSessionCommand,
        in commands: [SharedDictationSessionCommand]
    ) -> Bool {
        commands.contains { candidate in
            if candidate.replacesCommandToken == command.token {
                return (candidate.kind == .stop || candidate.kind == .cancel)
                    && candidate.sessionID == command.sessionID
                    && candidate.requestedAt >= command.requestedAt
            }
            return candidate.sessionID == command.sessionID
                && (candidate.kind == .stop || candidate.kind == .cancel)
                && candidate.replacesCommandToken == nil
                && candidate.requestedAt >= command.requestedAt
        }
    }

    private func isRoutedToAnotherOwner(
        _ command: SharedDictationSessionCommand,
        in envelope: SessionEnvelope,
        ownerToken: String?
    ) -> Bool {
        guard (command.kind == .stop || command.kind == .cancel),
              let replacedToken = command.replacesCommandToken,
              let owner = envelope.claimOwners[replacedToken] else {
            return false
        }
        return ownerToken != owner
    }

    private static func uniqueTokens(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    private static func dictionaryByToken(
        _ commands: [SharedDictationSessionCommand]
    ) -> [String: SharedDictationSessionCommand] {
        var result: [String: SharedDictationSessionCommand] = [:]
        for command in commands {
            result[command.token] = command
        }
        return result
    }

    private func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEnvelopeByteCount else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func loadLegacyValue<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String
    ) -> LegacyValueResolution<Value> {
        guard defaults.object(forKey: key) != nil else { return .missing }
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEnvelopeByteCount,
              let value = try? decoder.decode(type, from: data) else {
            return .unavailable
        }
        return .found(value)
    }

    private func loadCommand(forToken token: String) -> SharedDictationSessionCommand? {
        load(SharedDictationSessionCommand.self, forKey: Key.commandPrefix + token)
            ?? (loadLatestCommand()?.token == token ? loadLatestCommand() : nil)
    }

    private func loadLatestCommand() -> SharedDictationSessionCommand? {
        load(SharedDictationSessionCommand.self, forKey: Key.command)
    }

    private func loadStatus() -> SharedDictationSessionStatus {
        load(SharedDictationSessionStatus.self, forKey: Key.status) ?? .idle
    }

    private func withExclusiveAccess<Result>(_ body: () -> Result) -> Result? {
        if lockFileDescriptor == nil {
            Self.inProcessLock.lock()
        } else {
            guard acquireProcessLock() else { return nil }
        }
        defer { Self.inProcessLock.unlock() }

        let hasFileLock: Bool
        if lockFileDescriptor != nil {
            guard acquireFileLock() else { return nil }
            hasFileLock = true
        } else {
            hasFileLock = false
        }
        defer {
            if hasFileLock, let lockFileDescriptor {
                flock(lockFileDescriptor, LOCK_UN)
            }
        }
        return body()
    }

    private func acquireProcessLock() -> Bool {
        Self.inProcessLock.lock()
        return true
    }

    private func acquireFileLock() -> Bool {
        guard let lockFileDescriptor else { return false }
        let deadline = Date().addingTimeInterval(2)
        while flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN else { return false }
            guard Date() < deadline else { return false }
            usleep(5_000)
        }
        return true
    }

    private func appendToken(
        _ token: String,
        toIndex indexKey: String,
        removingWithPrefix prefix: String
    ) {
        var tokens = load([String].self, forKey: indexKey) ?? []
        tokens.removeAll { $0 == token }
        tokens.append(token)
        let requiredTokens: Set<String>
        if indexKey == Key.commandIndex, prefix == Key.commandPrefix {
            requiredTokens = Set(tokens.compactMap {
                load(SharedDictationSessionCommand.self, forKey: prefix + $0)?.replacesCommandToken
            })
        } else {
            requiredTokens = []
        }
        let ordinaryCapacity = max(0, Self.historyLimit - requiredTokens.count)
        let ordinary = tokens.reversed()
            .filter { !requiredTokens.contains($0) }
            .prefix(ordinaryCapacity)
        let retained = Set(requiredTokens).union(ordinary)
        let removedTokens = tokens.filter { !retained.contains($0) }
        tokens = tokens.filter(retained.contains)
        removedTokens.forEach { defaults.removeObject(forKey: prefix + $0) }
        save(tokens, forKey: indexKey)
    }
}

extension SharedDictationSessionStore: @unchecked Sendable {}

private extension SharedDictationSessionStatus {
    var isTerminal: Bool {
        switch self {
        case .transcriptReady, .failed, .cancelled, .idle:
            true
        case .commandPending, .commandAcknowledged, .recording, .transcribing:
            false
        }
    }

    var commandToken: String? {
        switch self {
        case let .commandPending(token, _),
             let .commandAcknowledged(token, _),
             let .recording(token, _, _),
             let .transcribing(token),
             let .transcriptReady(token):
            return token
        case let .failed(token, _),
             let .cancelled(token):
            return token
        case .idle:
            return nil
        }
    }

}
