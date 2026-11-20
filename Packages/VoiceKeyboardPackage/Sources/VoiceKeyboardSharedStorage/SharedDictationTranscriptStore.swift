import Darwin
import CryptoKit
import Foundation
import VoiceKeyboardModels

public struct SharedDictationTranscript: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = VoiceKeyboardTextLimits.maximumCharacterCount
    public static let maximumUTF8ByteCount = VoiceKeyboardTextLimits.maximumUTF8ByteCount
    public static let maximumIdentifierByteCount = 256
    public static let maximumLifetime: TimeInterval = 86_400
    public static let redactedText = "[consumed]"
    private static let maximumFutureClockSkew: TimeInterval = 300
    public let sessionID: String
    public let commandToken: String
    public let text: String
    public let createdAt: Date
    public let expiresAt: Date
    public let isConsumed: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case commandToken
        case text
        case createdAt
        case expiresAt
        case isConsumed
    }

    public var token: String { commandToken }

    public func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }

    public init?(text: String, createdAt: Date = Date()) {
        let identity = "\(createdAt.timeIntervalSince1970):\(text)"
        let commandToken = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.init(
            sessionID: "",
            commandToken: commandToken,
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
        guard !text.isEmpty,
              VoiceKeyboardTextLimits.isValid(text),
              sessionID.utf8.count <= Self.maximumIdentifierByteCount,
              commandToken.utf8.count <= Self.maximumIdentifierByteCount,
              !sessionID.contains("\0"),
              !commandToken.contains("\0"),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt <= Date().addingTimeInterval(Self.maximumFutureClockSkew),
              expiryInterval.isFinite,
              (0...Self.maximumLifetime).contains(expiryInterval) else { return nil }
        self.sessionID = sessionID
        self.commandToken = commandToken
        // Keep the recognizer's literal boundaries. The command planner can
        // interpret aliases, but the durable handoff must not silently
        // remove a leading/trailing newline, tab, or space.
        self.text = text
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        let commandToken = try container.decode(String.self, forKey: .commandToken)
        let text = try container.decode(String.self, forKey: .text)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        let isConsumed = try container.decodeIfPresent(Bool.self, forKey: .isConsumed) ?? false
        guard !text.isEmpty,
              VoiceKeyboardTextLimits.isValid(text),
              sessionID.utf8.count <= Self.maximumIdentifierByteCount,
              commandToken.utf8.count <= Self.maximumIdentifierByteCount,
              !sessionID.contains("\0"),
              !commandToken.contains("\0"),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt <= Date().addingTimeInterval(Self.maximumFutureClockSkew),
              expiresAt >= createdAt,
              expiresAt.timeIntervalSince(createdAt) <= Self.maximumLifetime else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "Invalid shared dictation transcript"
            )
        }
        self.init(
            sessionID: sessionID,
            commandToken: commandToken,
            text: text,
            createdAt: createdAt,
            expiresAt: expiresAt,
            isConsumed: isConsumed
        )
    }
}

/// A crash-recoverable handoff record for the non-transactional text proxy.
/// The extension persists this before editing and clears it after verifying
/// the resulting proxy context. A recreated extension can therefore retry an
/// unapplied edit or acknowledge an edit that already reached the host.
public struct SharedDictationTranscriptDelivery: Codable, Equatable, Sendable {
    // Each operation is durably fenced and checkpointed. Keep the journal
    // small enough that a keyboard extension cannot spend its entire budget
    // rewriting the App Group envelope for one transcript.
    public static let maximumOperationCount = 64
    public static let maximumTotalDeletionCount = 512

    public enum Operation: Codable, Equatable, Sendable {
        case insertText(String)
        case deleteBackward(Int)
        case showUnsupportedCommand(String)
    }

    public let transcriptToken: String
    public let sessionID: String
    public let beforeContext: SharedDictationDocumentContextFingerprint
    public let afterContext: SharedDictationDocumentContextFingerprint
    public let startedAt: Date
    public let ownerID: String?
    /// The locale used to create the operation plan. Persisting it lets the
    /// store recompute the plan digest instead of trusting a caller-provided
    /// hexadecimal string.
    public let localeIdentifier: String
    public let operations: [Operation]
    public let stepContexts: [SharedDictationDocumentContextFingerprint]
    /// The last context observed after a durable progress checkpoint. Hosts
    /// may truncate their context window as text grows, so recovery must use
    /// this runtime checkpoint instead of replaying the original virtual
    /// context fingerprint.
    public let checkpointContext: SharedDictationDocumentContextFingerprint?
    /// Binds the persisted operation journal to the exact transcript and
    /// context it was planned from. A missing digest is treated as legacy
    /// data and must not be replayed by a destructive delivery path.
    public let planDigest: String?
    public let appliedOperationCount: Int
    /// True only while the owner is inside a non-transactional host mutation.
    /// A recreated keyboard must never replay such an operation automatically:
    /// the host call may have completed even when the progress write did not.
    public let mutationInFlight: Bool
    /// A durable fail-closed marker for a host mutation whose result could not
    /// be proven. Quarantined journals are retained for diagnostics and are
    /// never eligible for replay or deletion by a normal delivery path.
    public let isQuarantined: Bool

    public static func isValidJournal(
        operations: [Operation],
        stepContexts: [SharedDictationDocumentContextFingerprint],
        appliedOperationCount: Int = 0,
        beforeContext: SharedDictationDocumentContextFingerprint? = nil,
        afterContext: SharedDictationDocumentContextFingerprint? = nil
    ) -> Bool {
        guard operations.count <= maximumOperationCount,
              operations.allSatisfy({ operation in
                  switch operation {
                  case let .insertText(value), let .showUnsupportedCommand(value):
                      return VoiceKeyboardTextLimits.isValid(value)
                  case let .deleteBackward(count):
                      return count > 0 && count <= TextDeletionCount.maximumValue
                  }
              }) else {
            return false
        }
        let totalDeletionCount = operations.reduce(into: 0) { total, operation in
            if case let .deleteBackward(count) = operation {
                total += count
            }
        }
        guard totalDeletionCount <= maximumTotalDeletionCount,
              (operations.isEmpty
                  ? stepContexts.isEmpty
                  : stepContexts.count == operations.count + 1),
              appliedOperationCount >= 0,
              appliedOperationCount <= operations.count else {
            return false
        }
        if let beforeContext, let firstContext = stepContexts.first {
            guard firstContext == beforeContext else { return false }
        }
        if let afterContext, let lastContext = stepContexts.last {
            guard lastContext == afterContext else { return false }
        }
        // An empty journal is also used for legacy/at-most-once delivery
        // records, whose before/after fingerprints describe the caller's
        // surrounding state rather than an operation checkpoint. There are
        // no step endpoints to validate in that representation.
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptToken
        case sessionID
        case beforeContext
        case afterContext
        case startedAt
        case ownerID
        case localeIdentifier
        case operations
        case stepContexts
        case checkpointContext
        case planDigest
        case appliedOperationCount
        case mutationInFlight
        case isQuarantined
    }

    public init(
        transcriptToken: String,
        sessionID: String,
        beforeContext: SharedDictationDocumentContextFingerprint,
        afterContext: SharedDictationDocumentContextFingerprint,
        startedAt: Date = Date(),
        ownerID: String? = nil,
        localeIdentifier: String = "",
        operations: [Operation] = [],
        stepContexts: [SharedDictationDocumentContextFingerprint] = [],
        checkpointContext: SharedDictationDocumentContextFingerprint? = nil,
        planDigest: String? = nil,
        appliedOperationCount: Int = 0,
        mutationInFlight: Bool = false,
        isQuarantined: Bool = false
    ) {
        self.transcriptToken = transcriptToken
        self.sessionID = sessionID
        self.beforeContext = beforeContext
        self.afterContext = afterContext
        self.startedAt = startedAt
        self.ownerID = ownerID
        self.localeIdentifier = localeIdentifier
        self.operations = operations
        self.stepContexts = stepContexts
        self.checkpointContext = checkpointContext
        self.planDigest = planDigest
        self.appliedOperationCount = appliedOperationCount
        self.mutationInFlight = mutationInFlight
        self.isQuarantined = isQuarantined
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptToken = try container.decode(String.self, forKey: .transcriptToken)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        beforeContext = try container.decode(
            SharedDictationDocumentContextFingerprint.self,
            forKey: .beforeContext
        )
        afterContext = try container.decode(
            SharedDictationDocumentContextFingerprint.self,
            forKey: .afterContext
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        ownerID = try container.decodeIfPresent(String.self, forKey: .ownerID)
        localeIdentifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? ""
        operations = try container.decodeIfPresent([Operation].self, forKey: .operations) ?? []
        stepContexts = try container.decodeIfPresent(
            [SharedDictationDocumentContextFingerprint].self,
            forKey: .stepContexts
        ) ?? []
        checkpointContext = try container.decodeIfPresent(
            SharedDictationDocumentContextFingerprint.self,
            forKey: .checkpointContext
        )
        planDigest = try container.decodeIfPresent(String.self, forKey: .planDigest)
        appliedOperationCount = try container.decodeIfPresent(Int.self, forKey: .appliedOperationCount) ?? 0
        mutationInFlight = try container.decodeIfPresent(Bool.self, forKey: .mutationInFlight) ?? false
        isQuarantined = try container.decodeIfPresent(Bool.self, forKey: .isQuarantined) ?? false
        guard Self.isValidJournal(
            operations: operations,
            stepContexts: stepContexts,
            appliedOperationCount: appliedOperationCount,
            beforeContext: beforeContext,
            afterContext: afterContext
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .operations,
                in: container,
                debugDescription: "Invalid shared dictation delivery journal"
            )
        }
    }

    private struct PlanDigestPayload: Codable {
        let transcript: SharedDictationTranscript
        let localeIdentifier: String
        let beforeContext: SharedDictationDocumentContextFingerprint
        let afterContext: SharedDictationDocumentContextFingerprint
        let operations: [Operation]
        let stepContexts: [SharedDictationDocumentContextFingerprint]
    }

    public static func makePlanDigest(
        transcript: SharedDictationTranscript,
        localeIdentifier: String,
        beforeContext: SharedDictationDocumentContextFingerprint,
        afterContext: SharedDictationDocumentContextFingerprint,
        operations: [Operation],
        stepContexts: [SharedDictationDocumentContextFingerprint]
    ) -> String {
        let payload = PlanDigestPayload(
            transcript: transcript,
            localeIdentifier: localeIdentifier,
            beforeContext: beforeContext,
            afterContext: afterContext,
            operations: operations,
            stepContexts: stepContexts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func progressed(
        to operationCount: Int,
        observedContext: SharedDictationDocumentContextFingerprint? = nil
    ) -> SharedDictationTranscriptDelivery {
        let boundedOperationCount = min(max(0, operationCount), operations.count)
        return SharedDictationTranscriptDelivery(
            transcriptToken: transcriptToken,
            sessionID: sessionID,
            beforeContext: beforeContext,
            afterContext: afterContext,
            startedAt: startedAt,
            ownerID: ownerID,
            localeIdentifier: localeIdentifier,
            operations: operations,
            stepContexts: stepContexts,
            checkpointContext: observedContext ?? checkpointContext,
            planDigest: planDigest,
            appliedOperationCount: boundedOperationCount,
            mutationInFlight: false,
            isQuarantined: isQuarantined
        )
    }

    public func owned(by ownerID: String?) -> SharedDictationTranscriptDelivery {
        SharedDictationTranscriptDelivery(
            transcriptToken: transcriptToken,
            sessionID: sessionID,
            beforeContext: beforeContext,
            afterContext: afterContext,
            startedAt: startedAt,
            ownerID: ownerID,
            localeIdentifier: localeIdentifier,
            operations: operations,
            stepContexts: stepContexts,
            checkpointContext: checkpointContext,
            planDigest: planDigest,
            appliedOperationCount: appliedOperationCount,
            mutationInFlight: mutationInFlight,
            isQuarantined: isQuarantined
        )
    }

    fileprivate func withMutationInFlight() -> SharedDictationTranscriptDelivery {
        SharedDictationTranscriptDelivery(
            transcriptToken: transcriptToken,
            sessionID: sessionID,
            beforeContext: beforeContext,
            afterContext: afterContext,
            startedAt: startedAt,
            ownerID: ownerID,
            localeIdentifier: localeIdentifier,
            operations: operations,
            stepContexts: stepContexts,
            checkpointContext: checkpointContext,
            planDigest: planDigest,
            appliedOperationCount: appliedOperationCount,
            mutationInFlight: true,
            isQuarantined: isQuarantined
        )
    }

    fileprivate func quarantined() -> SharedDictationTranscriptDelivery {
        SharedDictationTranscriptDelivery(
            transcriptToken: transcriptToken,
            sessionID: sessionID,
            beforeContext: beforeContext,
            afterContext: afterContext,
            startedAt: startedAt,
            ownerID: nil,
            localeIdentifier: localeIdentifier,
            // Keep the tombstone bounded and redact transcript-derived text.
            operations: [],
            stepContexts: [],
            checkpointContext: nil,
            planDigest: planDigest,
            appliedOperationCount: 0,
            mutationInFlight: false,
            isQuarantined: true
        )
    }
}

public final class SharedDictationTranscriptStore {
    public enum TranscriptResolution: Equatable, Sendable {
        case available([SharedDictationTranscript])
        case unavailable
    }

    public enum TranscriptLookupResolution: Equatable, Sendable {
        case found(SharedDictationTranscript)
        case missing
        case unavailable
    }

    public enum PendingDeliveryResolution: Equatable, Sendable {
        case found(SharedDictationTranscriptDelivery)
        case missing
        case unavailable
    }

    public enum DeliveryReconciliationResult: Equatable, Sendable {
        case progressed
        case completed
        case failed
    }

    public static let appGroupIdentifier = "group.com.ks1019.voicekeyboardinput"
    // Bound both the bytes read from the App Group and the aggregate text
    // retained after JSON decoding. This protects the keyboard extension from
    // a damaged or unexpectedly large shared envelope before Codable expands
    // it into multiple String copies.
    private static let maximumEnvelopeByteCount = 2_000_000
    private static let maximumDecodedTextPayloadByteCount = 1_000_000

    private struct DeliveryLease: Codable {
        let transcriptToken: String
        let expiresAt: Date
        let ownerID: String?

        init(transcriptToken: String, expiresAt: Date, ownerID: String? = nil) {
            self.transcriptToken = transcriptToken
            self.expiresAt = expiresAt
            self.ownerID = ownerID
        }
    }

    private struct TranscriptEnvelope: Codable {
        var revision: UInt64
        var records: [String: SharedDictationTranscript]
        var consumedTokens: [String]
        var consumedTokenDates: [String: Date]
        var pendingDeliveries: [String: SharedDictationTranscriptDelivery]
        var deliveryLeases: [String: DeliveryLease]

        private enum CodingKeys: String, CodingKey {
            case revision
            case records
            case consumedTokens
            case consumedTokenDates
            case pendingDeliveries
            case deliveryLeases
            case pendingDelivery
            case deliveryLease
        }

        init(
            revision: UInt64 = 0,
            records: [String: SharedDictationTranscript],
            consumedTokens: [String],
            consumedTokenDates: [String: Date] = [:],
            pendingDeliveries: [String: SharedDictationTranscriptDelivery] = [:],
            deliveryLeases: [String: DeliveryLease] = [:]
        ) {
            self.revision = revision
            self.records = records
            self.consumedTokens = consumedTokens
            self.consumedTokenDates = consumedTokenDates
            self.pendingDeliveries = pendingDeliveries
            self.deliveryLeases = deliveryLeases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
            records = try container.decode([String: SharedDictationTranscript].self, forKey: .records)
            consumedTokens = try container.decode([String].self, forKey: .consumedTokens)
            guard consumedTokens.count == Set(consumedTokens).count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .consumedTokens,
                    in: container,
                    debugDescription: "Duplicate consumed transcript token"
                )
            }
            consumedTokenDates = try container.decodeIfPresent(
                [String: Date].self,
                forKey: .consumedTokenDates
            ) ?? Dictionary(uniqueKeysWithValues: consumedTokens.map { ($0, Date()) })
            let legacyPending = try container.decodeIfPresent(
                SharedDictationTranscriptDelivery.self,
                forKey: .pendingDelivery
            )
            pendingDeliveries = try container.decodeIfPresent(
                [String: SharedDictationTranscriptDelivery].self,
                forKey: .pendingDeliveries
            ) ?? legacyPending.map { [$0.transcriptToken: $0] } ?? [:]
            let legacyLease = try container.decodeIfPresent(DeliveryLease.self, forKey: .deliveryLease)
            deliveryLeases = try container.decodeIfPresent(
                [String: DeliveryLease].self,
                forKey: .deliveryLeases
            ) ?? legacyLease.map { [$0.transcriptToken: $0] } ?? [:]
            guard revision < UInt64.max,
                  SharedDictationTranscriptStore.isValidEnvelope(
                    records: records,
                    consumedTokens: consumedTokens,
                    consumedTokenDates: consumedTokenDates,
                    pendingDeliveries: pendingDeliveries,
                deliveryLeases: deliveryLeases
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .records,
                    in: container,
                    debugDescription: "Invalid or oversized shared dictation envelope"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revision, forKey: .revision)
            try container.encode(records, forKey: .records)
            try container.encode(consumedTokens, forKey: .consumedTokens)
            try container.encode(consumedTokenDates, forKey: .consumedTokenDates)
            try container.encode(pendingDeliveries, forKey: .pendingDeliveries)
            try container.encode(deliveryLeases, forKey: .deliveryLeases)
        }
    }

    private enum Key {
        static let transcriptEnvelope = "sharedDictation.transcriptEnvelope"
        static let transcriptRecord = "sharedDictation.transcriptRecord"
        static let transcriptRecordPrefix = "sharedDictation.transcriptRecord."
        static let transcriptIndex = "sharedDictation.transcriptIndex"
        static let consumedToken = "sharedDictation.consumedToken"
        static let consumedTokenIndex = "sharedDictation.consumedTokenIndex"
        static let deliveryLease = "sharedDictation.deliveryLease"
        static let deliveryLeasePrefix = "sharedDictation.deliveryLease."
        static let envelopeMigrationMarker = "sharedDictation.transcriptEnvelopeMigrationComplete"
    }

    // UITextDocumentProxy is a non-transactional cross-process boundary.
    // Keep the fencing lease comfortably longer than a route/host hiccup;
    // every operation still renews it immediately before mutation and
    // persists progress immediately afterward.
    private static let deliveryLeaseInterval: TimeInterval = 30
    private static let maximumDeliveryLeaseHorizon: TimeInterval = 5 * 60
    private static let transcriptIndexLimit = 32
    private static let pendingDeliveryLimit = 32
    // Tombstones are retained for the maximum period in which a producer can
    // legally publish late. Expired tombstones are compacted under the same
    // store lock; live fences are never dropped merely to make room.
    private static let quarantinedDeliveryRetentionLimit = 8
    private static let ambiguousDeliveryRetentionLimit = 8
    private static let consumedTokenIndexLimit = 1_024
    private static let consumedTokenRetention: TimeInterval =
        SharedDictationTranscript.maximumLifetime + maximumDeliveryLeaseHorizon
    private static let inProcessLock = NSLock()

    private static func isValidEnvelope(
        records: [String: SharedDictationTranscript],
        consumedTokens: [String],
        consumedTokenDates: [String: Date],
        pendingDeliveries: [String: SharedDictationTranscriptDelivery],
        deliveryLeases: [String: DeliveryLease]
    ) -> Bool {
        guard records.count <= transcriptIndexLimit,
              consumedTokens.count <= consumedTokenIndexLimit,
              consumedTokenDates.count <= consumedTokenIndexLimit,
              pendingDeliveries.count <= pendingDeliveryLimit,
              deliveryLeases.count <= pendingDeliveryLimit,
              consumedTokens.count == Set(consumedTokens).count,
              consumedTokens.allSatisfy(Self.isBoundedIdentifier),
              Set(consumedTokenDates.keys).isSubset(of: Set(consumedTokens)),
              consumedTokenDates.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return false
        }
        var payloadBytes = 0
        for (token, transcript) in records {
            guard token == transcript.token else { return false }
            guard transcript.createdAt <= Date().addingTimeInterval(300),
                  transcript.expiresAt <= Date().addingTimeInterval(
                      SharedDictationTranscript.maximumLifetime + 300
                  ) else { return false }
            payloadBytes += transcript.text.utf8.count
            guard payloadBytes <= maximumDecodedTextPayloadByteCount else { return false }
        }
        for (token, delivery) in pendingDeliveries {
            guard token == delivery.transcriptToken,
                  let transcript = records[token],
                  transcript.sessionID == delivery.sessionID,
                  SharedDictationTranscriptDelivery.isValidJournal(
                      operations: delivery.operations,
                      stepContexts: delivery.stepContexts,
                      appliedOperationCount: delivery.appliedOperationCount,
                      beforeContext: delivery.beforeContext,
                      afterContext: delivery.afterContext
                  ),
                  isValidPlanDigest(
                      delivery.planDigest,
                      delivery: delivery,
                      transcript: transcript
                  ) else { return false }
            if let ownerID = delivery.ownerID {
                guard let lease = deliveryLeases[token], lease.ownerID == ownerID else {
                    return false
                }
            }
            if delivery.mutationInFlight {
                guard delivery.ownerID != nil,
                      deliveryLeases[token]?.ownerID == delivery.ownerID else {
                    return false
                }
            }
            for operation in delivery.operations {
                switch operation {
                case let .insertText(value), let .showUnsupportedCommand(value):
                    payloadBytes += value.utf8.count
                case .deleteBackward:
                    break
                }
                guard payloadBytes <= maximumDecodedTextPayloadByteCount else { return false }
            }
        }
        let maximumLeaseExpiry = Date().addingTimeInterval(maximumDeliveryLeaseHorizon)
        for (token, lease) in deliveryLeases {
            guard token == lease.transcriptToken,
                  records[token] != nil,
                  isBoundedIdentifier(token),
                  lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  lease.expiresAt <= maximumLeaseExpiry,
                  lease.ownerID.map(isBoundedIdentifier) ?? true else { return false }
        }
        return true
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        value.utf8.count <= SharedDictationTranscript.maximumIdentifierByteCount
            && !value.contains("\0")
    }

    private static func isValidPlanDigest(_ digest: String?) -> Bool {
        guard let digest, digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isValidPlanDigest(
        _ digest: String?,
        delivery: SharedDictationTranscriptDelivery,
        transcript: SharedDictationTranscript
    ) -> Bool {
        guard !delivery.operations.isEmpty else { return true }
        guard let digest else { return false }
        guard isValidPlanDigest(digest) else { return false }
        // Legacy journals did not persist the locale. Their exact digest is
        // still checked by the keyboard, while the store keeps accepting the
        // legacy record here so it can be upgraded safely.
        guard !delivery.localeIdentifier.isEmpty else { return true }
        return digest == SharedDictationTranscriptDelivery.makePlanDigest(
            transcript: transcript,
            localeIdentifier: delivery.localeIdentifier,
            beforeContext: delivery.beforeContext,
            afterContext: delivery.afterContext,
            operations: delivery.operations,
            stepContexts: delivery.stepContexts
        )
    }

    private let defaults: UserDefaults
    private let envelopeURL: URL?
    private let lockFileDescriptor: Int32?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var envelopeReadBlocked = false

    private enum LegacyDataResolution {
        case missing
        case found(Data)
        case unavailable
    }

    private enum LegacyLeaseResolution {
        case missing
        case found(DeliveryLease)
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

    /// Creates the file-backed store used by App Group clients. The explicit
    /// URLs also let tests exercise the production locking and atomic-write
    /// path without requiring an application-group entitlement.
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

    public static func appGroupStore() -> SharedDictationTranscriptStore? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else { return nil }
        let lockFileURL = containerURL.appendingPathComponent(
            "SharedDictationTranscriptStore.lock",
            isDirectory: false
        )
        let envelopeURL = containerURL.appendingPathComponent(
            "SharedDictationTranscriptStore.json",
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
            envelopeURL: envelopeURL,
            lockFileDescriptor: lockFileDescriptor
        )
    }

    public func storageHealth() -> Bool {
        withExclusiveAccess {
            let loadedEnvelope = loadTranscriptEnvelope()
            guard !envelopeReadBlocked,
                  migrateLegacyTranscriptPayloadsIfNeeded(loadedEnvelope),
                  redactExpiredAndConsumedPayloads() else { return false }
            if hasFileBackedEnvelope || defaults.bool(forKey: Key.envelopeMigrationMarker) {
                cleanupLegacyTranscriptPayloads()
            }
            return !envelopeReadBlocked
        } ?? false
    }

    @discardableResult
    public func save(_ transcript: SharedDictationTranscript) -> Bool {
        withExclusiveAccess {
            let existingEnvelope = loadTranscriptEnvelope()
            var records = existingEnvelope?.records ?? loadLegacyRecords()
            let now = Date()
            // A command token is the handoff identity, while transcript
            // tokens are per-attempt record IDs. If an old owner finishes
            // just as a new owner takes over the command lease, accept the
            // already-published result instead of creating a second result
            // that the keyboard could deliver twice.
            if let existing = records.values.first(where: {
                $0.commandToken == transcript.commandToken
                    && $0.sessionID == transcript.sessionID
            }) {
                // A command/session publishes at most one transcript. A
                // reclaimed owner must not report success for a conflicting
                // result or overwrite the text another owner published.
                return existing.text == transcript.text
            }
            if let existing = records[transcript.token],
               existing.sessionID != transcript.sessionID
                || existing.commandToken != transcript.commandToken
                || existing.text != transcript.text {
                return false
            }
            let knownConsumedTokens = existingEnvelope?.consumedTokens ?? loadConsumedTokenIndex()
            guard !knownConsumedTokens.contains(transcript.token) else {
                // An evicted ambiguous journal leaves a tombstone. The same
                // handoff token must remain write-once even after its payload
                // is compacted away.
                return false
            }
            if records[transcript.token] == nil {
                let activeUnconsumedCount = records.values.filter {
                    !$0.isConsumed && !$0.isExpired(at: now)
                }.count
                guard activeUnconsumedCount < Self.transcriptIndexLimit else {
                    // Never evict a live transcript merely to make room for a
                    // new one. The caller can surface this as a durable save
                    // failure and retry after the keyboard consumes one.
                    return false
                }
            }
            records[transcript.token] = transcript
            // Once a validated file-backed envelope exists, its records are
            // authoritative. Do not read the retired UserDefaults index on
            // every save: an unrelated malformed legacy index must not poison
            // an otherwise healthy migrated mailbox.
            var tokens = (envelopeURL != nil && existingEnvelope != nil
                ? Array(records.keys)
                : loadTranscriptIndex()
            ).filter {
                records[$0] != nil && $0 != transcript.token
            }
            for token in records.keys.sorted(by: { lhs, rhs in
                records[lhs]?.createdAt ?? .distantPast < records[rhs]?.createdAt ?? .distantPast
            }) where !tokens.contains(token) && token != transcript.token {
                tokens.append(token)
            }
            tokens.append(transcript.token)
            var deliveryLeases = existingEnvelope?.deliveryLeases ?? [:]
            var pendingDeliveries = existingEnvelope?.pendingDeliveries ?? [:]
            var evictedAmbiguousTokens = Set<String>()
            pendingDeliveries = pendingDeliveries.filter { token, delivery in
                guard records[token] != nil else {
                    deliveryLeases.removeValue(forKey: token)
                    return false
                }
                if delivery.isQuarantined
                    || delivery.mutationInFlight
                    || delivery.appliedOperationCount > 0 {
                    // A journal that crossed into host mutation is durable
                    // no-replay evidence. Keep both the journal and its
                    // transcript even after the user-facing TTL and lease
                    // expire; a later save must not make an ambiguous edit
                    // look deliverable again.
                    return true
                }
                if let lease = deliveryLeases[token], lease.expiresAt > now {
                    return true
                }
                return records[token]?.isExpired(at: now) == false
            }
            if pendingDeliveries.values.filter(\.isQuarantined).count
                > Self.quarantinedDeliveryRetentionLimit {
                let quarantinedToRemove = pendingDeliveries.values
                    .filter(\.isQuarantined)
                    .sorted { $0.startedAt < $1.startedAt }
                    .prefix(
                        pendingDeliveries.values.filter(\.isQuarantined).count
                            - Self.quarantinedDeliveryRetentionLimit
                    )
                for delivery in quarantinedToRemove {
                    pendingDeliveries.removeValue(forKey: delivery.transcriptToken)
                    deliveryLeases.removeValue(forKey: delivery.transcriptToken)
                    records.removeValue(forKey: delivery.transcriptToken)
                    evictedAmbiguousTokens.insert(delivery.transcriptToken)
                }
            }
            let expiredAmbiguousDeliveries = pendingDeliveries.values
                .filter { delivery in
                    !delivery.isQuarantined
                        && (delivery.mutationInFlight || delivery.appliedOperationCount > 0)
                        && (deliveryLeases[delivery.transcriptToken]?.expiresAt ?? .distantPast) <= now
                }
                .sorted { $0.startedAt < $1.startedAt }
            if expiredAmbiguousDeliveries.count > Self.ambiguousDeliveryRetentionLimit {
                for delivery in expiredAmbiguousDeliveries
                    .prefix(expiredAmbiguousDeliveries.count - Self.ambiguousDeliveryRetentionLimit) {
                    pendingDeliveries.removeValue(forKey: delivery.transcriptToken)
                    deliveryLeases.removeValue(forKey: delivery.transcriptToken)
                    records.removeValue(forKey: delivery.transcriptToken)
                    evictedAmbiguousTokens.insert(delivery.transcriptToken)
                }
            }
            pruneExpiredDeliveryLeases(
                in: &deliveryLeases,
                records: records,
                pendingDeliveries: pendingDeliveries,
                now: now
            )
            if pendingDeliveries.count > Self.pendingDeliveryLimit {
                let protected = Set<String>(pendingDeliveries.compactMap { token, _ in
                    guard let delivery = pendingDeliveries[token] else { return nil }
                    if delivery.isQuarantined
                        || delivery.mutationInFlight
                        || ((deliveryLeases[token]?.expiresAt ?? .distantPast) > now) {
                        return token
                    }
                    return nil
                })
                let removable = pendingDeliveries.values
                    .filter { !protected.contains($0.transcriptToken) }
                    .sorted { $0.startedAt < $1.startedAt }
                for delivery in removable where pendingDeliveries.count > Self.pendingDeliveryLimit {
                    pendingDeliveries.removeValue(forKey: delivery.transcriptToken)
                    deliveryLeases.removeValue(forKey: delivery.transcriptToken)
                }
                guard pendingDeliveries.count <= Self.pendingDeliveryLimit else {
                    // All remaining journals are either inside a host
                    // mutation or still leased. Refuse the new transcript
                    // rather than allowing durable delivery state to grow
                    // without a safe eviction candidate.
                    return false
                }
            }
            let unconsumedTokens = records.values
                .filter { !$0.isConsumed && !$0.isExpired(at: now) }
                .map(\.token)
            let protectedTokens = Set(
                unconsumedTokens
                    + pendingDeliveries.keys.filter { records[$0] != nil }
            )
            guard protectedTokens.count <= Self.transcriptIndexLimit else {
                // Never evict a live transcript or a journal that is needed
                // to prove whether a host mutation already happened.
                return false
            }
            let newestUnprotectedTokens = tokens.reversed()
                .filter { !protectedTokens.contains($0) }
                .prefix(Self.transcriptIndexLimit - protectedTokens.count)
            let retainedTokenSet = protectedTokens.union(newestUnprotectedTokens)
            let retainedTokenList = tokens.filter(retainedTokenSet.contains)
            let removedTokens = tokens.filter { !retainedTokenSet.contains($0) }
            tokens = retainedTokenList
            records = records.filter { retainedTokenSet.contains($0.key) }
            let existingTombstones = existingEnvelope?.consumedTokens ?? loadConsumedTokenIndex()
            var tombstoneCandidates: [String] = []
            for token in evictedAmbiguousTokens where !existingTombstones.contains(token) {
                // A compacted ambiguous journal is still a no-replay fence;
                // removing its payload must not make the transcript writable
                // again under the same handoff token.
                tombstoneCandidates.append(token)
            }
            for token in removedTokens where !existingTombstones.contains(token) {
                tombstoneCandidates.append(token)
            }
            var tombstoneDates = existingEnvelope?.consumedTokenDates ?? [:]
            guard let tombstones = appendTombstones(
                tombstoneCandidates,
                to: existingTombstones,
                datedBy: &tombstoneDates,
                now: now
            ) else { return false }
            let envelope = TranscriptEnvelope(
                records: records,
                consumedTokens: tombstones,
                consumedTokenDates: tombstoneDates,
                pendingDeliveries: pendingDeliveries,
                deliveryLeases: deliveryLeases
            )
            guard saveTranscriptEnvelope(envelope) else { return false }

            if envelopeURL == nil {
                // Keep compatibility keys for the UserDefaults-backed test
                // and migration path. App Group instances use only the
                // atomic envelope to avoid cfprefsd writes on the main actor.
                saveTokenIndex(tokens, forKey: Key.transcriptIndex)
                saveRecord(transcript, forToken: transcript.token)
                saveRecord(transcript, forToken: nil)
                removedTokens.forEach { defaults.removeObject(forKey: Key.transcriptRecordPrefix + $0) }
                if let lease = loadDeliveryLease(forToken: transcript.token), lease.transcriptToken != transcript.token {
                    defaults.removeObject(forKey: Key.deliveryLease)
                }
            }
            return true
        } ?? false
    }

    public func latestTranscript() -> SharedDictationTranscript? {
        withExclusiveAccess { loadLatestRecord() } ?? nil
    }

    public func latestTranscript(forSessionID sessionID: String) -> SharedDictationTranscript? {
        withExclusiveAccess { loadLatestRecord(forSessionID: sessionID) } ?? nil
    }

    /// Resolves the latest transcript without collapsing a storage read
    /// failure into "no transcript". Callers that may cancel or replace a
    /// command must fail closed on `.unavailable`.
    public func latestTranscriptResolution(
        forSessionID sessionID: String
    ) -> TranscriptLookupResolution {
        withExclusiveAccess {
            guard let transcript = loadLatestRecord(forSessionID: sessionID) else {
                return envelopeReadBlocked ? .unavailable : .missing
            }
            return .found(transcript)
        } ?? .unavailable
    }

    public func unconsumedTranscripts(now: Date = Date()) -> [SharedDictationTranscript] {
        switch unconsumedTranscriptsResolution(now: now) {
        case .available(let transcripts):
            return transcripts
        case .unavailable:
            return []
        }
    }

    public func unconsumedTranscriptsResolution(
        now: Date = Date()
    ) -> TranscriptResolution {
        withExclusiveAccess {
            let transcripts: [SharedDictationTranscript]
            if let envelope = loadTranscriptEnvelope() {
                transcripts = envelope.records.values.compactMap {
                    applyConsumption(to: $0, consumedTokens: envelope.consumedTokens)
                }
            } else {
                let consumedTokens = loadConsumedTokenIndex()
                var legacyTranscripts = loadTranscriptTokens().compactMap { loadLegacyRecord(forToken: $0) }
                if let singleton = loadLegacyRecord(forToken: nil),
                   !legacyTranscripts.contains(where: { $0.token == singleton.token }) {
                    legacyTranscripts.append(singleton)
                }
                transcripts = legacyTranscripts.compactMap {
                    applyConsumption(to: $0, consumedTokens: consumedTokens)
                }
            }
            guard !envelopeReadBlocked else { return .unavailable }
            return .available(transcripts
                .filter { !$0.isConsumed && !$0.isExpired(at: now) }
                .sorted { $0.createdAt < $1.createdAt })
        } ?? .unavailable
    }

    public func consumeLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            loadMatchingTranscript(forSessionID: nil, afterLastConsumedToken: lastConsumedToken, now: now)
        } ?? nil
    }

    public func consumeLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            loadMatchingTranscript(forSessionID: sessionID, afterLastConsumedToken: lastConsumedToken, now: now)
        } ?? nil
    }

    public func claimLatestTranscript(
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            claimMatchingTranscript(forSessionID: nil, afterLastConsumedToken: lastConsumedToken, now: now)
        } ?? nil
    }

    public func claimLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            claimMatchingTranscript(forSessionID: sessionID, afterLastConsumedToken: lastConsumedToken, now: now)
        } ?? nil
    }

    /// Compatibility API for callers that intentionally choose at-most-once
    /// delivery. New document-editing callers should use beginDelivery and
    /// markDelivered so a crash between claiming and proxy mutation is
    /// recoverable.
    public func claimAndMarkConsumedLatestTranscript(
        forSessionID sessionID: String,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date = Date()
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            guard let transcript = claimMatchingTranscript(
                forSessionID: sessionID,
                afterLastConsumedToken: lastConsumedToken,
                now: now
            ) else { return nil }
            guard markConsumedRecord(transcript) else { return nil }
            return transcript
        } ?? nil
    }

    @discardableResult
    public func beginDelivery(
        _ transcript: SharedDictationTranscript,
        beforeContext: SharedDictationDocumentContextFingerprint,
        afterContext: SharedDictationDocumentContextFingerprint,
        startedAt: Date = Date(),
        operations: [SharedDictationTranscriptDelivery.Operation] = [],
        stepContexts: [SharedDictationDocumentContextFingerprint] = [],
        localeIdentifier: String = "",
        ownerID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL == nil || ownerID != nil else { return false }
            let existingEnvelope = loadTranscriptEnvelope()
            var records = existingEnvelope?.records ?? loadLegacyRecords()
            guard let storedTranscript = records[transcript.token],
                  storedTranscript.sessionID == transcript.sessionID,
                  !storedTranscript.isConsumed,
                  !loadConsumedTokenIndex().contains(transcript.token),
                  SharedDictationTranscriptDelivery.isValidJournal(
                      operations: operations,
                      stepContexts: stepContexts,
                      beforeContext: beforeContext,
                      afterContext: afterContext
                  ) else { return false }
            if let existingDelivery = existingEnvelope?.pendingDeliveries[transcript.token] {
                guard !existingDelivery.mutationInFlight,
                      !existingDelivery.isQuarantined,
                      existingDelivery.appliedOperationCount == 0 else {
                    // A partially applied or quarantined journal is a
                    // durable no-replay fence. It must be resumed or repaired,
                    // never replaced with a fresh operation-zero journal.
                    return false
                }
            }
            if let lease = existingEnvelope?.deliveryLeases[transcript.token],
               now < lease.expiresAt,
               let leaseOwner = lease.ownerID,
               leaseOwner != ownerID {
                return false
            }
            records[transcript.token] = storedTranscript
            var pendingDeliveries = existingEnvelope?.pendingDeliveries ?? [:]
            var deliveryLeases = existingEnvelope?.deliveryLeases ?? [:]
            pendingDeliveries = pendingDeliveries.filter { token, delivery in
                guard records[token] != nil else {
                    deliveryLeases.removeValue(forKey: token)
                    return false
                }
                if delivery.mutationInFlight
                    || ((deliveryLeases[token]?.expiresAt ?? .distantPast) > now) {
                    return true
                }
                if delivery.isQuarantined || delivery.appliedOperationCount > 0 {
                    // Quarantined and partially applied journals are durable
                    // no-replay evidence. Normal delivery must retain them
                    // even after the transcript's user-facing TTL expires.
                    return true
                }
                return records[token]?.isExpired(at: now) == false
            }
            pruneExpiredDeliveryLeases(
                in: &deliveryLeases,
                records: records,
                pendingDeliveries: pendingDeliveries,
                now: now
            )
            guard pendingDeliveries[transcript.token] != nil
                || pendingDeliveries.count < Self.pendingDeliveryLimit else {
                return false
            }
            pendingDeliveries[transcript.token] = SharedDictationTranscriptDelivery(
                transcriptToken: transcript.token,
                sessionID: transcript.sessionID,
                beforeContext: beforeContext,
                afterContext: afterContext,
                startedAt: startedAt,
                ownerID: ownerID,
                localeIdentifier: localeIdentifier,
                operations: operations,
                stepContexts: stepContexts,
                planDigest: SharedDictationTranscriptDelivery.makePlanDigest(
                    transcript: storedTranscript,
                    localeIdentifier: localeIdentifier,
                    beforeContext: beforeContext,
                    afterContext: afterContext,
                    operations: operations,
                    stepContexts: stepContexts
                )
            )
            if let ownerID {
                deliveryLeases[transcript.token] = DeliveryLease(
                    transcriptToken: transcript.token,
                    expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                    ownerID: ownerID
                )
            }
            return saveTranscriptEnvelope(TranscriptEnvelope(
                records: records,
                consumedTokens: existingEnvelope?.consumedTokens ?? loadConsumedTokenIndex(),
                consumedTokenDates: existingEnvelope?.consumedTokenDates ?? [:],
                pendingDeliveries: pendingDeliveries,
                deliveryLeases: deliveryLeases
            ))
        } ?? false
    }

    @discardableResult
    public func markDeliveryProgress(
        transcriptToken: String,
        appliedOperationCount: Int,
        ownerID: String? = nil,
        observedContext: SharedDictationDocumentContextFingerprint? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  !pending.isQuarantined,
                  appliedOperationCount == pending.appliedOperationCount + 1,
                  appliedOperationCount <= pending.operations.count else { return false }
            if !pending.mutationInFlight {
                guard case .showUnsupportedCommand = pending.operations[pending.appliedOperationCount] else {
                    return false
                }
            }
            guard let lease = envelope.deliveryLeases[transcriptToken],
                  now < lease.expiresAt else {
                return false
            }
            if envelopeURL != nil {
                guard let ownerID, lease.ownerID == ownerID else { return false }
            } else {
                guard ownerID == nil || lease.ownerID == nil || lease.ownerID == ownerID else {
                    return false
                }
            }
            var updatedEnvelope = envelope
            updatedEnvelope.pendingDeliveries[transcriptToken] = pending
                .owned(by: ownerID ?? lease.ownerID)
                .progressed(to: appliedOperationCount, observedContext: observedContext)
            updatedEnvelope.deliveryLeases[transcriptToken] = DeliveryLease(
                transcriptToken: transcriptToken,
                expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                ownerID: ownerID ?? lease.ownerID
            )
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    /// Fences one host mutation before entering UITextDocumentProxy. If the
    /// extension is killed after this write, the next instance will observe
    /// `mutationInFlight` and fail closed instead of replaying an ambiguous
    /// insert/delete after the lease expires.
    public func beginDeliveryMutation(
        transcriptToken: String,
        operationIndex: Int,
        ownerID: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  operationIndex == pending.appliedOperationCount,
                  operationIndex < pending.operations.count,
                  !pending.mutationInFlight,
                  !pending.isQuarantined,
                  let lease = envelope.deliveryLeases[transcriptToken],
                  now < lease.expiresAt,
                  lease.ownerID == ownerID else { return false }
            var updatedEnvelope = envelope
            updatedEnvelope.pendingDeliveries[transcriptToken] = pending.owned(by: ownerID).withMutationInFlight()
            updatedEnvelope.deliveryLeases[transcriptToken] = DeliveryLease(
                transcriptToken: transcriptToken,
                expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                ownerID: ownerID
            )
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    /// Clears a mutation fence only when the owner proves that the host call
    /// has not started yet. This is used when lifecycle/context validation
    /// fails after the durable preflight but before entering
    /// UITextDocumentProxy.
    @discardableResult
    public func abortDeliveryMutation(
        transcriptToken: String,
        operationIndex: Int,
        ownerID: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  pending.mutationInFlight,
                  !pending.isQuarantined,
                  pending.ownerID == ownerID,
                  pending.appliedOperationCount == operationIndex,
                  let lease = envelope.deliveryLeases[transcriptToken],
                  lease.ownerID == ownerID,
                  now < lease.expiresAt else { return false }
            var updatedEnvelope = envelope
            updatedEnvelope.pendingDeliveries[transcriptToken] = pending.progressed(
                to: operationIndex
            )
            updatedEnvelope.deliveryLeases[transcriptToken] = DeliveryLease(
                transcriptToken: transcriptToken,
                expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                ownerID: ownerID
            )
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    /// Refreshes ownership immediately before a host mutation. Progress is
    /// persisted after the mutation; this preflight closes the window in
    /// which a long proxy operation starts after the previous lease expired.
    public func renewDeliveryLease(
        transcriptToken: String,
        ownerID: String,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope(),
                  envelope.pendingDeliveries[transcriptToken] != nil,
                  envelope.pendingDeliveries[transcriptToken]?.isQuarantined == false,
                  let lease = envelope.deliveryLeases[transcriptToken],
                  now < lease.expiresAt,
                  lease.ownerID == ownerID else { return false }
            var updatedEnvelope = envelope
            updatedEnvelope.deliveryLeases[transcriptToken] = DeliveryLease(
                transcriptToken: transcriptToken,
                expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                ownerID: ownerID
            )
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    public func pendingDelivery(forSessionID sessionID: String) -> SharedDictationTranscriptDelivery? {
        switch pendingDeliveryResolution(forSessionID: sessionID) {
        case .found(let delivery): return delivery
        case .missing, .unavailable: return nil
        }
    }

    /// Resolves a delivery journal without treating a damaged or unavailable
    /// App Group file as proof that no journal exists.
    public func pendingDeliveryResolution(
        forSessionID sessionID: String
    ) -> PendingDeliveryResolution {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope() else {
                return envelopeReadBlocked ? .unavailable : .missing
            }
            guard !envelopeReadBlocked else { return .unavailable }
            guard let delivery = envelope.pendingDeliveries.values
                .filter({ $0.sessionID == sessionID })
                .max(by: { lhs, rhs in lhs.startedAt < rhs.startedAt }) else {
                return .missing
            }
            return .found(delivery)
        } ?? .unavailable
    }

    /// Resolves a journal by its source command token. Recovery uses this
    /// identity instead of the bounded command history, because a terminal
    /// command may have been pruned while its no-replay journal is retained.
    public func pendingDeliveryResolution(
        forCommandToken commandToken: String
    ) -> PendingDeliveryResolution {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope() else {
                return envelopeReadBlocked ? .unavailable : .missing
            }
            guard !envelopeReadBlocked else { return .unavailable }
            let matches = envelope.pendingDeliveries.values.filter { delivery in
                envelope.records[delivery.transcriptToken]?.commandToken == commandToken
            }
            guard matches.count <= 1 else { return .unavailable }
            guard let delivery = matches.first else { return .missing }
            return .found(delivery)
        } ?? .unavailable
    }

    @discardableResult
    public func discardPendingDelivery(
        transcriptToken: String,
        ownerID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL == nil || ownerID != nil else { return false }
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  pending.appliedOperationCount == 0,
                  !pending.mutationInFlight,
                  !pending.isQuarantined else { return false }
            if let ownerID,
               let pendingOwnerID = pending.ownerID,
               pendingOwnerID != ownerID {
                guard let lease = envelope.deliveryLeases[transcriptToken],
                      now >= lease.expiresAt else {
                    return false
                }
            }
            if let ownerID,
               let lease = envelope.deliveryLeases[transcriptToken],
               now < lease.expiresAt,
               let leaseOwnerID = lease.ownerID,
               leaseOwnerID != ownerID {
                return false
            }
            var updatedEnvelope = envelope
            updatedEnvelope.pendingDeliveries.removeValue(forKey: transcriptToken)
            updatedEnvelope.deliveryLeases.removeValue(forKey: transcriptToken)
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    /// Converts an ambiguous host mutation into a durable no-replay fence.
    /// This is deliberately separate from `discardPendingDelivery`: deleting
    /// the journal before a failure status is persisted can make an already
    /// applied host edit look deliverable again after a process restart.
    @discardableResult
    public func quarantinePendingDelivery(
        transcriptToken: String,
        ownerID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL == nil || ownerID != nil else { return false }
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  !pending.isQuarantined else { return false }
            guard pending.mutationInFlight || pending.appliedOperationCount > 0 else {
                return false
            }
            if let lease = envelope.deliveryLeases[transcriptToken],
               now < lease.expiresAt,
               lease.ownerID != ownerID {
                return false
            }
            var updatedEnvelope = envelope
            updatedEnvelope.pendingDeliveries[transcriptToken] = pending.quarantined()
            if let transcript = updatedEnvelope.records[transcriptToken] {
                updatedEnvelope.records[transcriptToken] = SharedDictationTranscript(
                    sessionID: transcript.sessionID,
                    commandToken: transcript.commandToken,
                    text: SharedDictationTranscript.redactedText,
                    createdAt: transcript.createdAt,
                    expiresAt: transcript.expiresAt,
                    isConsumed: true
                )
                var tombstoneDates = updatedEnvelope.consumedTokenDates
                guard let consumedTokens = appendTombstones(
                    [transcriptToken],
                    to: updatedEnvelope.consumedTokens,
                    datedBy: &tombstoneDates,
                    now: now
                ) else { return false }
                updatedEnvelope.consumedTokens = consumedTokens
                updatedEnvelope.consumedTokenDates = tombstoneDates
            }
            // Remove the lease so the old owner cannot write progress after
            // the quarantine decision. The journal itself remains durable.
            updatedEnvelope.deliveryLeases.removeValue(forKey: transcriptToken)
            return saveTranscriptEnvelope(updatedEnvelope)
        } ?? false
    }

    /// Returns the transcript associated with a pending delivery without
    /// applying the short claim lease. This is used only after a recreated
    /// extension verifies that the host still matches the persisted
    /// pre-edit context.
    public func resumePendingDelivery(
        forSessionID sessionID: String,
        now: Date = Date(),
        ownerID: String? = nil
    ) -> SharedDictationTranscript? {
        withExclusiveAccess {
            guard envelopeURL == nil || ownerID != nil else { return nil }
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries.values
                      .filter({ $0.sessionID == sessionID })
                      .max(by: { lhs, rhs in lhs.startedAt < rhs.startedAt }),
                  let transcript = loadRecord(forToken: pending.transcriptToken),
                  !transcript.isConsumed,
                  !transcript.isExpired(at: now) else { return nil }
            guard !pending.mutationInFlight, !pending.isQuarantined else {
                // The previous owner may have completed the host call but
                // crashed before recording progress. Replaying is unsafe.
                return nil
            }
            if let ownerID,
               let lease = envelope.deliveryLeases[pending.transcriptToken],
               now < lease.expiresAt,
               let leaseOwner = lease.ownerID,
               leaseOwner != ownerID {
                return nil
            }
            if let ownerID {
                var updatedEnvelope = envelope
                updatedEnvelope.pendingDeliveries[pending.transcriptToken] = pending.owned(by: ownerID)
                updatedEnvelope.deliveryLeases[pending.transcriptToken] = DeliveryLease(
                    transcriptToken: pending.transcriptToken,
                    expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                    ownerID: ownerID
                )
                guard saveTranscriptEnvelope(updatedEnvelope) else { return nil }
            }
            return transcript
        } ?? nil
    }

    @discardableResult
    public func markDelivered(
        transcriptToken: String,
        ownerID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        withExclusiveAccess {
            guard envelopeURL == nil || ownerID != nil else { return false }
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  !pending.mutationInFlight,
                  !pending.isQuarantined,
                  !pending.operations.isEmpty,
                  pending.appliedOperationCount >= pending.operations.count else {
                return false
            }
            guard let transcript = loadRecord(forToken: transcriptToken),
                  Self.isValidPlanDigest(
                      pending.planDigest,
                      delivery: pending,
                      transcript: transcript
                  ) else {
                return false
            }
            if let ownerID {
                guard let lease = envelope.deliveryLeases[transcriptToken],
                      now < lease.expiresAt,
                      lease.ownerID == ownerID else {
                    return false
                }
            } else if let lease = envelope.deliveryLeases[transcriptToken] {
                guard now < lease.expiresAt, lease.ownerID == nil else {
                    return false
                }
            }
            return markConsumedRecord(transcript)
        } ?? false
    }

    /// Reconciles a journal after a keyboard restart. The host proxy is not
    /// transactional: a process can be terminated after the proxy mutation
    /// succeeds but before progress clears `mutationInFlight`. A recreated
    /// keyboard may settle that ambiguity only with a stable document identity
    /// and a context matching the journal's final fingerprint.
    @discardableResult
    public func reconcileDelivered(
        transcriptToken: String,
        ownerID: String,
        observedContext: SharedDictationDocumentContextFingerprint,
        now: Date = Date()
    ) -> DeliveryReconciliationResult {
        withExclusiveAccess {
            guard let envelope = loadTranscriptEnvelope(),
                  let pending = envelope.pendingDeliveries[transcriptToken],
                  let transcript = loadRecord(forToken: transcriptToken),
                  !transcript.isConsumed,
                  !pending.isQuarantined,
                  !pending.operations.isEmpty,
                  Self.isValidPlanDigest(
                      pending.planDigest,
                      delivery: pending,
                      transcript: transcript
                  ),
                  pending.mutationInFlight,
                  observedContext.hasDocumentIdentifier,
                  SharedDictationTranscriptDelivery.isValidJournal(
                      operations: pending.operations,
                      stepContexts: pending.stepContexts,
                      appliedOperationCount: pending.appliedOperationCount,
                      beforeContext: pending.beforeContext,
                      afterContext: pending.afterContext
                  ) else { return .failed }
            let operationIndex = pending.appliedOperationCount
            guard pending.stepContexts.count == pending.operations.count + 1,
                  operationIndex < pending.operations.count,
                  pending.stepContexts[operationIndex + 1].matches(observedContext) else {
                return .failed
            }
            if let lease = envelope.deliveryLeases[transcriptToken],
               now < lease.expiresAt,
               lease.ownerID != ownerID {
                return .failed
            }
            var updatedEnvelope = envelope
            let progressedDelivery = pending
                .owned(by: ownerID)
                .progressed(
                    to: operationIndex + 1,
                    observedContext: observedContext
                )
            updatedEnvelope.pendingDeliveries[transcriptToken] = progressedDelivery
            updatedEnvelope.deliveryLeases[transcriptToken] = DeliveryLease(
                transcriptToken: transcriptToken,
                expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval),
                ownerID: ownerID
            )
            guard operationIndex + 1 == pending.operations.count else {
                return saveTranscriptEnvelope(updatedEnvelope) ? .progressed : .failed
            }
            return markConsumedRecord(transcript, in: updatedEnvelope) ? .completed : .failed
        } ?? .failed
    }

    public func markConsumed(_ transcript: SharedDictationTranscript) {
        guard envelopeURL == nil else { return }
        _ = withExclusiveAccess { markConsumedRecord(transcript) }
    }

    /// Redacts a transcript when a delivery failure is proven before a
    /// delivery journal exists. This closes the no-journal recovery gap while
    /// keeping the write-once consumed fence durable.
    @discardableResult
    public func markConsumed(token: String) -> Bool {
        withExclusiveAccess {
            guard let transcript = loadRecord(forToken: token) else { return false }
            return markConsumedRecord(transcript)
        } ?? false
    }

    public func lastConsumedToken() -> String? {
        withExclusiveAccess {
            if let consumedToken = loadTranscriptEnvelope()?.consumedTokens.last {
                return consumedToken
            }
            if let consumedToken = defaults.string(forKey: Key.consumedToken) {
                return consumedToken
            }
            guard let transcript = loadLatestRecord(), transcript.isConsumed else { return nil }
            return transcript.token
        } ?? nil
    }

    private func loadMatchingTranscript(
        forSessionID sessionID: String?,
        afterLastConsumedToken lastConsumedToken: String?,
        now: Date
    ) -> SharedDictationTranscript? {
        guard let transcript = sessionID.flatMap({ loadLatestRecord(forSessionID: $0) }) ?? loadLatestRecord(),
              sessionID == nil || transcript.sessionID == sessionID,
              !transcript.isConsumed,
              !transcript.isExpired(at: now),
              transcript.token != lastConsumedToken else { return nil }
        return transcript
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
        if loadTranscriptEnvelope()?.pendingDeliveries[transcript.token].map({
            $0.mutationInFlight || $0.isQuarantined
        }) == true {
            return nil
        }
        let existingLease = loadDeliveryLease(forToken: transcript.token)
        guard !envelopeReadBlocked else { return nil }
        if let lease = existingLease,
           lease.transcriptToken == transcript.token,
           now < lease.expiresAt {
            return nil
        }
        guard saveDeliveryLease(DeliveryLease(
            transcriptToken: transcript.token,
            expiresAt: now.addingTimeInterval(Self.deliveryLeaseInterval)
        )) else { return nil }
        return transcript
    }

    private func saveRecord(_ transcript: SharedDictationTranscript, forToken token: String?) {
        guard let data = try? encoder.encode(transcript) else { return }
        defaults.set(
            data,
            forKey: token.map { Key.transcriptRecordPrefix + $0 } ?? Key.transcriptRecord
        )
    }

    private func saveDeliveryLease(_ lease: DeliveryLease) -> Bool {
        guard !envelopeReadBlocked else { return false }
        if envelopeURL != nil {
            var envelope = loadTranscriptEnvelope() ?? TranscriptEnvelope(
                records: loadLegacyRecords(),
                consumedTokens: loadConsumedTokenIndex()
            )
            envelope.deliveryLeases[lease.transcriptToken] = lease
            return saveTranscriptEnvelope(envelope)
        }
        guard let data = try? encoder.encode(lease) else { return false }
        defaults.set(data, forKey: Key.deliveryLeasePrefix + lease.transcriptToken)
        defaults.set(data, forKey: Key.deliveryLease)
        return defaults.data(forKey: Key.deliveryLeasePrefix + lease.transcriptToken) == data
    }

    private func loadDeliveryLease(forToken token: String) -> DeliveryLease? {
        if envelopeURL != nil {
            return loadTranscriptEnvelope()?.deliveryLeases[token]
        }
        switch loadLegacyDeliveryLease(forToken: token) {
        case .missing:
            return nil
        case .found(let lease):
            return lease
        case .unavailable:
            envelopeReadBlocked = true
            return nil
        }
    }

    private func loadLegacyDeliveryLease(forToken token: String) -> LegacyLeaseResolution {
        let tokenKey = Key.deliveryLeasePrefix + token
        let key: String
        if defaults.object(forKey: tokenKey) != nil {
            key = tokenKey
        } else if defaults.object(forKey: Key.deliveryLease) != nil {
            key = Key.deliveryLease
        } else {
            return .missing
        }
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEnvelopeByteCount,
              let lease = try? decoder.decode(DeliveryLease.self, from: data),
              key == Key.deliveryLease || lease.transcriptToken == token,
              lease.transcriptToken.utf8.count <= SharedDictationTranscript.maximumIdentifierByteCount,
              !lease.transcriptToken.contains("\0"),
              lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              lease.expiresAt <= Date().addingTimeInterval(Self.maximumDeliveryLeaseHorizon),
              lease.ownerID.map(Self.isBoundedIdentifier) ?? true else {
            return .unavailable
        }
        return .found(lease)
    }

    private func loadRecord(forToken token: String?) -> SharedDictationTranscript? {
        if let envelope = loadTranscriptEnvelope(), let token {
            return applyConsumption(
                to: envelope.records[token],
                consumedTokens: envelope.consumedTokens
            )
        }
        guard loadTranscriptEnvelope() == nil else { return nil }
        return loadLegacyRecord(forToken: token)
    }

    private func loadLegacyRecord(forToken token: String?) -> SharedDictationTranscript? {
        guard let transcript = loadRawLegacyRecord(forToken: token) else { return nil }
        return applyConsumption(to: transcript, consumedTokens: loadConsumedTokenIndex())
    }

    private func loadRawLegacyRecord(forToken token: String?) -> SharedDictationTranscript? {
        let key = token.map { Key.transcriptRecordPrefix + $0 } ?? Key.transcriptRecord
        guard let data = defaults.data(forKey: key) else {
            if defaults.object(forKey: key) != nil {
                envelopeReadBlocked = true
            }
            return nil
        }
        guard data.count <= Self.maximumEnvelopeByteCount,
              let transcript = try? decoder.decode(SharedDictationTranscript.self, from: data) else {
            // A present but malformed legacy record is a storage failure, not
            // proof that no transcript exists. Callers must fail closed.
            envelopeReadBlocked = true
            return nil
        }
        return transcript
    }

    private func loadLatestRecord(forSessionID sessionID: String? = nil) -> SharedDictationTranscript? {
        if let envelope = loadTranscriptEnvelope() {
            return envelope.records.values
                .compactMap { applyConsumption(to: $0, consumedTokens: envelope.consumedTokens) }
                .filter { sessionID == nil || $0.sessionID == sessionID }
                .max { lhs, rhs in lhs.createdAt < rhs.createdAt }
        }
        let indexedRecords = loadTranscriptTokens().compactMap { loadRecord(forToken: $0) }
            .filter { sessionID == nil || $0.sessionID == sessionID }
        let legacyRecord = loadRecord(forToken: nil)
            .flatMap { sessionID == nil || $0.sessionID == sessionID ? $0 : nil }
        return (indexedRecords + (legacyRecord.map { [$0] } ?? []))
            .max { lhs, rhs in lhs.createdAt < rhs.createdAt }
    }

    private func loadTranscriptIndex() -> [String] {
        let data: Data
        switch loadLegacyData(forKey: Key.transcriptIndex) {
        case .missing:
            return []
        case .found(let value):
            data = value
        case .unavailable:
            envelopeReadBlocked = true
            return []
        }
        guard data.count <= Self.maximumEnvelopeByteCount,
              let tokens = try? decoder.decode([String].self, from: data) else {
            // A present but malformed index must not be interpreted as an
            // empty mailbox; doing so can hide an unconsumed transcript or
            // replay one after a cold restart.
            envelopeReadBlocked = true
            return []
        }
        guard tokens.count <= Self.transcriptIndexLimit else {
            // Never silently discard legacy records during migration. A
            // caller can surface the storage failure and retry after the
            // mailbox is repaired or consumed explicitly.
            envelopeReadBlocked = true
            return []
        }
        return tokens
    }

    private func loadTranscriptEnvelope() -> TranscriptEnvelope? {
        if let envelopeURL {
            let primaryEnvelope = decodeEnvelope(at: envelopeURL)
            let backupEnvelope = backupEnvelopeURL.flatMap { decodeEnvelope(at: $0) }
            if let primaryEnvelope,
               backupEnvelope.map({ $0.revision <= primaryEnvelope.revision }) ?? true {
                envelopeReadBlocked = false
                return normalizedConsumedRecords(in: primaryEnvelope)
            }
            if let backupEnvelopeURL,
               let backupEnvelope {
                // Restore a validated backup when the primary is corrupt or
                // missing. This also prevents a later save from copying a
                // damaged primary over the only known-good backup.
                if let backupData = try? Data(contentsOf: backupEnvelopeURL) {
                    try? backupData.write(to: envelopeURL, options: [.atomic])
                }
                envelopeReadBlocked = false
                return normalizedConsumedRecords(in: backupEnvelope)
            }
            if FileManager.default.fileExists(atPath: envelopeURL.path)
                || defaults.bool(forKey: Key.envelopeMigrationMarker) {
                envelopeReadBlocked = true
                return TranscriptEnvelope(records: [:], consumedTokens: [])
            }
        }
        guard !defaults.bool(forKey: Key.envelopeMigrationMarker) else {
            return TranscriptEnvelope(records: [:], consumedTokens: [])
        }
        let data: Data
        switch loadLegacyData(forKey: Key.transcriptEnvelope) {
        case .missing:
            return nil
        case .found(let value):
            data = value
        case .unavailable:
            envelopeReadBlocked = true
            return TranscriptEnvelope(records: [:], consumedTokens: [])
        }
        guard data.count <= Self.maximumEnvelopeByteCount,
              let envelope = try? decoder.decode(TranscriptEnvelope.self, from: data) else {
            envelopeReadBlocked = true
            return TranscriptEnvelope(records: [:], consumedTokens: [])
        }
        envelopeReadBlocked = false
        return normalizedConsumedRecords(in: envelope)
    }

    private var hasFileBackedEnvelope: Bool {
        guard let envelopeURL else { return false }
        return FileManager.default.fileExists(atPath: envelopeURL.path)
            || (backupEnvelopeURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false)
    }

    /// Materializes legacy UserDefaults data before removing the old keys.
    /// A file-backed store must never treat an in-memory legacy read as an
    /// already-completed migration: a live transcript would otherwise be
    /// deleted by the cleanup pass without a durable replacement.
    private func migrateLegacyTranscriptPayloadsIfNeeded(
        _ loadedEnvelope: TranscriptEnvelope?
    ) -> Bool {
        guard envelopeURL != nil,
              !hasFileBackedEnvelope,
              !defaults.bool(forKey: Key.envelopeMigrationMarker) else {
            return true
        }

        if let loadedEnvelope {
            return saveTranscriptEnvelope(loadedEnvelope)
        }

        let records = loadRawLegacyRecords()
        let consumedTokens = loadConsumedTokenIndex()
        guard !envelopeReadBlocked else { return false }
        var deliveryLeases: [String: DeliveryLease] = [:]
        for token in records.keys {
            switch loadLegacyDeliveryLease(forToken: token) {
            case .missing:
                continue
            case .found(let lease):
                deliveryLeases[token] = lease
            case .unavailable:
                envelopeReadBlocked = true
                return false
            }
        }
        guard !records.isEmpty || !consumedTokens.isEmpty || !deliveryLeases.isEmpty else {
            return true
        }
        return saveTranscriptEnvelope(TranscriptEnvelope(
            records: records,
            consumedTokens: consumedTokens,
            deliveryLeases: deliveryLeases
        ))
    }

    private func loadRawTranscriptEnvelope() -> TranscriptEnvelope? {
        if let envelopeURL {
            let primaryEnvelope = decodeEnvelope(at: envelopeURL)
            let backupEnvelope = backupEnvelopeURL.flatMap { decodeEnvelope(at: $0) }
            if let primaryEnvelope,
               backupEnvelope.map({ $0.revision <= primaryEnvelope.revision }) ?? true {
                return primaryEnvelope
            }
            if let backupEnvelope { return backupEnvelope }
            if hasFileBackedEnvelope || defaults.bool(forKey: Key.envelopeMigrationMarker) {
                return nil
            }
        }
        guard !defaults.bool(forKey: Key.envelopeMigrationMarker) else { return nil }
        guard case .found(let data) = loadLegacyData(forKey: Key.transcriptEnvelope),
              data.count <= Self.maximumEnvelopeByteCount,
              let envelope = try? decoder.decode(TranscriptEnvelope.self, from: data) else {
            return nil
        }
        return envelope
    }

    private func saveTranscriptEnvelope(_ envelope: TranscriptEnvelope) -> Bool {
        var envelope = envelope
        pruneExpiredDeliveryLeases(
            in: &envelope.deliveryLeases,
            records: envelope.records,
            pendingDeliveries: envelope.pendingDeliveries,
            now: Date()
        )
        guard !envelopeReadBlocked,
              Self.isValidEnvelope(
                  records: envelope.records,
                  consumedTokens: envelope.consumedTokens,
                  consumedTokenDates: envelope.consumedTokenDates,
                  pendingDeliveries: envelope.pendingDeliveries,
                  deliveryLeases: envelope.deliveryLeases
              ) else { return false }
        if let envelopeURL {
            do {
                let currentRevision = max(
                    decodeEnvelope(at: envelopeURL)?.revision ?? 0,
                    backupEnvelopeURL.flatMap { decodeEnvelope(at: $0)?.revision } ?? 0
                )
                guard currentRevision < UInt64.max - 1 else { return false }
                envelope.revision = currentRevision + 1
                let data = try encoder.encode(envelope)
                guard data.count <= Self.maximumEnvelopeByteCount else { return false }
                var didWriteBackup = false
                if let backupEnvelopeURL {
                    // Commit the recovery copy first. If it cannot be
                    // written, leave the primary at its previous revision;
                    // otherwise a newer primary paired with an older backup
                    // could replay an already-applied journal after primary
                    // corruption.
                    try data.write(to: backupEnvelopeURL, options: [.atomic])
                    didWriteBackup = true
                }
                do {
                    try data.write(to: envelopeURL, options: [.atomic])
                } catch {
                    // The backup is the authoritative recovery copy on the
                    // next open. Report success when it committed so callers
                    // do not perform a host mutation while believing the
                    // journal was lost.
                    guard didWriteBackup else { return false }
                }
                defaults.set(true, forKey: Key.envelopeMigrationMarker)
                cleanupLegacyTranscriptPayloads()
                return true
            } catch {
                return false
            }
        }
        guard let data = try? encoder.encode(envelope),
              data.count <= Self.maximumEnvelopeByteCount else { return false }
        defaults.set(data, forKey: Key.transcriptEnvelope)
        return defaults.data(forKey: Key.transcriptEnvelope) == data
    }

    private var backupEnvelopeURL: URL? {
        envelopeURL?.appendingPathExtension("backup")
    }

    private func decodeEnvelope(at url: URL) -> TranscriptEnvelope? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue <= Self.maximumEnvelopeByteCount,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumEnvelopeByteCount else {
            return nil
        }
        guard let envelope = try? decoder.decode(TranscriptEnvelope.self, from: data),
              Self.isValidEnvelope(
                  records: envelope.records,
                  consumedTokens: envelope.consumedTokens,
                  consumedTokenDates: envelope.consumedTokenDates,
                  pendingDeliveries: envelope.pendingDeliveries,
                  deliveryLeases: envelope.deliveryLeases
              ) else {
            return nil
        }
        return envelope
    }

    private func pruneExpiredDeliveryLeases(
        in leases: inout [String: DeliveryLease],
        records: [String: SharedDictationTranscript],
        pendingDeliveries: [String: SharedDictationTranscriptDelivery],
        now: Date
    ) {
        leases = leases.filter { token, lease in
            guard records[token] != nil else { return false }
            if lease.expiresAt > now { return true }
            // Keep a lease while the journal still has an owner. The owner
            // may be between mutation/progress callbacks, and dropping the
            // lease would make the envelope invalid or let another process
            // steal a partially applied journal. A pending ownerless journal
            // has no lease to preserve; it can be reclaimed by normal
            // pending-delivery rules.
            return pendingDeliveries[token]?.ownerID != nil
        }
    }

    private func loadLegacyRecords() -> [String: SharedDictationTranscript] {
        var records: [String: SharedDictationTranscript] = [:]
        for token in Set(loadTranscriptTokens()) {
            if let transcript = loadLegacyRecord(forToken: token) {
                records[token] = transcript
            }
        }
        if let transcript = loadLegacyRecord(forToken: nil) {
            records[transcript.token] = transcript
        }
        return records
    }

    private func loadRawLegacyRecords() -> [String: SharedDictationTranscript] {
        var records: [String: SharedDictationTranscript] = [:]
        for token in Set(loadTranscriptTokens()) {
            if let transcript = loadRawLegacyRecord(forToken: token) {
                records[token] = transcript
            }
        }
        if let transcript = loadRawLegacyRecord(forToken: nil) {
            records[transcript.token] = transcript
        }
        return records
    }

    private func applyConsumption(
        to transcript: SharedDictationTranscript?,
        consumedTokens: [String]
    ) -> SharedDictationTranscript? {
        guard let transcript else { return nil }
        guard transcript.isConsumed || consumedTokens.contains(transcript.token) else { return transcript }
        return SharedDictationTranscript(
            sessionID: transcript.sessionID,
            commandToken: transcript.commandToken,
            text: SharedDictationTranscript.redactedText,
            createdAt: transcript.createdAt,
            expiresAt: transcript.expiresAt,
            isConsumed: true
        )
    }

    private func normalizedConsumedRecords(
        in envelope: TranscriptEnvelope
    ) -> TranscriptEnvelope {
        var normalized = envelope
        normalized.records = envelope.records.compactMapValues {
            applyConsumption(to: $0, consumedTokens: envelope.consumedTokens)
        }
        return normalized
    }

    private func loadTranscriptTokens() -> [String] {
        var tokens = loadTranscriptIndex()
        guard !envelopeReadBlocked else { return [] }
        for token in tokens {
            let recordKey = Key.transcriptRecordPrefix + token
            guard defaults.object(forKey: recordKey) != nil else {
                // An index entry without a record is corruption, not an
                // empty slot. Refuse migration so a transcript cannot be
                // silently discarded or replayed after the marker is set.
                envelopeReadBlocked = true
                return []
            }
        }
        if let legacyTranscript = loadLegacyRecord(forToken: nil),
           !tokens.contains(legacyTranscript.token) {
            tokens = Array(tokens.suffix(max(0, Self.transcriptIndexLimit - 1)))
            tokens.append(legacyTranscript.token)
        }
        return tokens
    }

    private func loadConsumedTokenIndex() -> [String] {
        if let consumedTokens = loadTranscriptEnvelope()?.consumedTokens { return consumedTokens }
        switch loadLegacyData(forKey: Key.consumedTokenIndex) {
        case .missing:
            if defaults.object(forKey: Key.consumedToken) != nil,
               defaults.string(forKey: Key.consumedToken) == nil {
                envelopeReadBlocked = true
                return []
            }
            guard let token = defaults.string(forKey: Key.consumedToken) else { return [] }
            guard Self.isBoundedIdentifier(token) else {
                envelopeReadBlocked = true
                return []
            }
            return [token]
        case .unavailable:
            envelopeReadBlocked = true
            return []
        case .found(let data):
            guard data.count <= Self.maximumEnvelopeByteCount,
                  let tokens = try? decoder.decode([String].self, from: data) else {
                envelopeReadBlocked = true
                return []
            }
            guard tokens.count <= Self.consumedTokenIndexLimit,
                  tokens.count == Set(tokens).count,
                  tokens.allSatisfy(Self.isBoundedIdentifier) else {
                envelopeReadBlocked = true
                return []
            }
            return tokens
        }
    }

    private func loadLegacyData(forKey key: String) -> LegacyDataResolution {
        guard defaults.object(forKey: key) != nil else { return .missing }
        guard let data = defaults.data(forKey: key) else { return .unavailable }
        return .found(data)
    }

    private func saveTokenIndex(_ tokens: [String], forKey key: String) {
        guard let data = try? encoder.encode(tokens) else { return }
        defaults.set(data, forKey: key)
    }

    private func appendTombstones(
        _ candidates: [String],
        to existing: [String],
        datedBy dates: inout [String: Date],
        now: Date
    ) -> [String]? {
        for token in existing where dates[token] == nil {
            dates[token] = now
        }
        let cutoff = now.addingTimeInterval(-Self.consumedTokenRetention)
        let retained = existing.filter { token in
            guard let date = dates[token] else { return true }
            guard date >= cutoff else {
                dates.removeValue(forKey: token)
                return false
            }
            return true
        }
        var result = retained
        for token in candidates where !result.contains(token) {
            guard Self.isBoundedIdentifier(token) else {
                return nil
            }
            if result.count >= Self.consumedTokenIndexLimit {
                // A tombstone is a replay fence, but refusing every future
                // delivery once the bounded index is full would leave the
                // already-applied host edit permanently pending. Evict the
                // oldest fence; transcript records and the random handoff
                // token still prevent ordinary duplicate publication.
                guard let oldest = result.min(by: {
                    (dates[$0] ?? .distantPast) < (dates[$1] ?? .distantPast)
                }) else { return nil }
                result.removeAll { $0 == oldest }
                dates.removeValue(forKey: oldest)
            }
            result.append(token)
            dates[token] = now
        }
        dates = dates.filter { result.contains($0.key) }
        return result
    }

    @discardableResult
    private func markConsumedRecord(
        _ transcript: SharedDictationTranscript,
        in suppliedEnvelope: TranscriptEnvelope? = nil
    ) -> Bool {
        let existingEnvelope = suppliedEnvelope ?? loadTranscriptEnvelope()
        let existingConsumedTokens = existingEnvelope?.consumedTokens ?? loadConsumedTokenIndex()
        var consumedTokenDates = existingEnvelope?.consumedTokenDates ?? [:]
        let now = Date()
        guard let consumedTokens = appendTombstones(
            [transcript.token],
            to: existingConsumedTokens,
            datedBy: &consumedTokenDates,
            now: now
        ) else { return false }
        var records = existingEnvelope?.records ?? loadLegacyRecords()
        records[transcript.token] = SharedDictationTranscript(
            sessionID: transcript.sessionID,
            commandToken: transcript.commandToken,
            text: SharedDictationTranscript.redactedText,
            createdAt: transcript.createdAt,
            expiresAt: transcript.expiresAt,
            isConsumed: true
        )
        var pendingDeliveries = existingEnvelope?.pendingDeliveries ?? [:]
        if let pendingDelivery = pendingDeliveries[transcript.token],
           pendingDelivery.isQuarantined
               || pendingDelivery.mutationInFlight
               || pendingDelivery.appliedOperationCount < pendingDelivery.operations.count {
            // Expiry/redaction must not erase evidence of a non-transactional
            // host edit. Retain a bounded quarantine journal so recovery can
            // never mistake a partial insertion for a clean completion.
            pendingDeliveries[transcript.token] = pendingDelivery.isQuarantined
                ? pendingDelivery
                : pendingDelivery.quarantined()
        } else {
            pendingDeliveries.removeValue(forKey: transcript.token)
        }
        var deliveryLeases = existingEnvelope?.deliveryLeases ?? [:]
        deliveryLeases.removeValue(forKey: transcript.token)
        guard saveTranscriptEnvelope(TranscriptEnvelope(
            records: records,
            consumedTokens: consumedTokens,
            consumedTokenDates: consumedTokenDates,
            pendingDeliveries: pendingDeliveries,
            deliveryLeases: deliveryLeases
        )) else { return false }
        if envelopeURL == nil {
            saveTokenIndex(
                consumedTokens,
                forKey: Key.consumedTokenIndex
            )
            defaults.set(transcript.token, forKey: Key.consumedToken)
            defaults.removeObject(forKey: Key.transcriptRecordPrefix + transcript.token)
            if loadLegacyRecord(forToken: nil)?.token == transcript.token {
                defaults.removeObject(forKey: Key.transcriptRecord)
            }
            if loadDeliveryLease(forToken: transcript.token)?.transcriptToken == transcript.token {
                defaults.removeObject(forKey: Key.deliveryLeasePrefix + transcript.token)
                defaults.removeObject(forKey: Key.deliveryLease)
            }
        }
        return true
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

    /// Expiry is a privacy boundary, not only a read filter. Redact every
    /// expired or already-consumed record while the store lock is held so
    /// plaintext cannot remain in the App Group envelope or legacy defaults.
    private func redactExpiredAndConsumedPayloads(now: Date = Date()) -> Bool {
        let envelope = loadRawTranscriptEnvelope()
        let records = envelope?.records ?? loadRawLegacyRecords()
        let consumedTokens = envelope?.consumedTokens ?? loadConsumedTokenIndex()
        guard !envelopeReadBlocked else { return false }
        for transcript in records.values where
            (transcript.isConsumed
                || consumedTokens.contains(transcript.token)
                || transcript.isExpired(at: now))
                && transcript.text != SharedDictationTranscript.redactedText {
            guard markConsumedRecord(transcript) else { return false }
        }
        return !envelopeReadBlocked
    }

    /// Once the atomic file envelope is authoritative, remove the old
    /// UserDefaults payloads. Keeping them would allow a rollback or an older
    /// process to rediscover plaintext that was already consumed/redacted.
    private func cleanupLegacyTranscriptPayloads() {
        guard envelopeURL != nil else { return }
        for key in defaults.dictionaryRepresentation().keys where
            key == Key.transcriptEnvelope
                || key == Key.transcriptRecord
                || key.hasPrefix(Key.transcriptRecordPrefix)
                || key == Key.transcriptIndex
                || key == Key.consumedToken
                || key == Key.consumedTokenIndex
                || key == Key.deliveryLease
                || key.hasPrefix(Key.deliveryLeasePrefix) {
            defaults.removeObject(forKey: key)
        }
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

    private func acquireProcessLock() -> Bool {
        Self.inProcessLock.lock()
        return true
    }
}

extension SharedDictationTranscriptStore: @unchecked Sendable {}
