import Foundation
import CryptoKit

public struct SharedDictationDocumentContextFingerprint: Codable, Equatable, Sendable {
    private let beforeInput: String
    private let beforeInputSuffix: String?
    private let beforeInputLength: Int?
    private let afterInput: String
    private let documentIdentifier: String?
    private let selectedText: String

    public init(
        beforeInput: String?,
        afterInput: String?,
        documentIdentifier: UUID? = nil,
        selectedText: String? = nil
    ) {
        self.beforeInput = Self.fingerprint(beforeInput)
        self.beforeInputSuffix = beforeInput.map { Self.fingerprintSuffix($0) }
        self.beforeInputLength = beforeInput?.count
        self.afterInput = Self.fingerprint(afterInput)
        self.documentIdentifier = documentIdentifier?.uuidString
        self.selectedText = Self.fingerprint(selectedText)
    }

    public func matches(
        beforeInput: String?,
        afterInput: String?,
        documentIdentifier: UUID? = nil,
        selectedText: String? = nil
    ) -> Bool {
        self.beforeInputMatches(beforeInput)
            && self.afterInput == Self.fingerprint(afterInput)
            && self.documentIdentifier == documentIdentifier?.uuidString
            && self.selectedText == Self.fingerprint(selectedText)
    }

    /// Compares two already-fingerprinted contexts without exposing the
    /// document text or identifier hash to storage clients.
    public func matches(_ other: SharedDictationDocumentContextFingerprint) -> Bool {
        beforeInputMatches(other)
            && afterInput == other.afterInput
            && documentIdentifier == other.documentIdentifier
            && selectedText == other.selectedText
    }

    /// `UITextDocumentProxy.documentIdentifier` is optional on some hosts.
    /// A fingerprint without it must not be used to automatically replay a
    /// destructive edit after a new keyboard controller is created.
    public var hasDocumentIdentifier: Bool {
        documentIdentifier != nil
    }

    /// A host that exposes neither a stable field identity nor any context
    /// cannot prove that a later document callback belongs to our own edit.
    /// Such a fingerprint must fail closed instead of suppressing an external
    /// focus change as if it were a self-generated callback.
    public var hasStableMutationIdentity: Bool {
        hasDocumentIdentifier
            && (beforeInput != Self.fingerprint(nil)
                || afterInput != Self.fingerprint(nil)
                || selectedText != Self.fingerprint(nil))
    }

    private enum CodingKeys: String, CodingKey {
        case beforeInput
        case beforeInputSuffix
        case beforeInputLength
        case afterInput
        case documentIdentifier
        case selectedText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beforeInput = try container.decode(String.self, forKey: .beforeInput)
        beforeInputSuffix = try container.decodeIfPresent(String.self, forKey: .beforeInputSuffix)
        beforeInputLength = try container.decodeIfPresent(Int.self, forKey: .beforeInputLength)
        afterInput = try container.decode(String.self, forKey: .afterInput)
        documentIdentifier = try container.decodeIfPresent(String.self, forKey: .documentIdentifier)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
            ?? Self.fingerprint(nil)
    }

    private static func fingerprint(_ context: String?) -> String {
        let value = context.map { "value:\($0)" } ?? "nil"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let suffixCharacterLimit = 256

    private static func fingerprintSuffix(_ context: String) -> String {
        fingerprint(String(context.suffix(suffixCharacterLimit)))
    }

    private func beforeInputMatches(_ rawContext: String?) -> Bool {
        guard let rawContext else {
            return beforeInput == Self.fingerprint(nil)
        }
        guard beforeInput == Self.fingerprint(rawContext) else {
            guard let beforeInputSuffix,
                  let beforeInputLength,
                  beforeInputLength >= rawContext.count else {
                return false
            }
            return beforeInputSuffix == Self.fingerprintSuffix(rawContext)
        }
        return true
    }

    private func beforeInputMatches(_ other: SharedDictationDocumentContextFingerprint) -> Bool {
        guard beforeInput != other.beforeInput else { return true }
        guard let beforeInputSuffix,
              let beforeInputLength,
              let otherSuffix = other.beforeInputSuffix,
              let otherLength = other.beforeInputLength,
              beforeInputLength >= otherLength else {
            return false
        }
        return beforeInputSuffix == otherSuffix
    }
}

public struct SharedDictationSessionCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case start
        case stop
        case cancel
    }

    public enum Source: String, Codable, Sendable {
        case keyboard
        case containingApp
    }

    public let sessionID: String
    public let token: String
    public let kind: Kind
    public let source: Source
    public let requestedAt: Date
    public let expiresAt: Date
    public let replacesCommandToken: String?
    public let documentContextFingerprint: SharedDictationDocumentContextFingerprint?

    public init(
        token: String,
        kind: Kind,
        source: Source,
        requestedAt: Date,
        expiresAt: Date,
        sessionID: String? = nil,
        replacesCommandToken: String? = nil,
        documentContextFingerprint: SharedDictationDocumentContextFingerprint? = nil
    ) {
        self.sessionID = sessionID ?? UUID().uuidString
        self.token = token
        self.kind = kind
        self.source = source
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.replacesCommandToken = replacesCommandToken
        self.documentContextFingerprint = documentContextFingerprint
    }

    public static func start(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        sessionID: String = UUID().uuidString,
        documentContextFingerprint: SharedDictationDocumentContextFingerprint? = nil
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .start,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID,
            documentContextFingerprint: documentContextFingerprint
        )
    }

    public static func stop(
        sessionID: String,
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        replacingCommandToken: String? = nil
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .stop,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID,
            replacesCommandToken: replacingCommandToken
        )
    }

    public static func stop(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        replacingCommandToken: String? = nil
    ) -> SharedDictationSessionCommand {
        stop(
            sessionID: UUID().uuidString,
            source: source,
            requestedAt: requestedAt,
            expiryInterval: expiryInterval,
            replacingCommandToken: replacingCommandToken
        )
    }

    public static func cancel(
        sessionID: String,
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        replacingCommandToken: String? = nil
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .cancel,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID,
            replacesCommandToken: replacingCommandToken
        )
    }

    public static func cancel(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        replacingCommandToken: String? = nil
    ) -> SharedDictationSessionCommand {
        cancel(
            sessionID: UUID().uuidString,
            source: source,
            requestedAt: requestedAt,
            expiryInterval: expiryInterval,
            replacingCommandToken: replacingCommandToken
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case token
        case kind
        case source
        case requestedAt
        case expiresAt
        case replacesCommandToken
        case documentContextFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decode(String.self, forKey: .token)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? token
        self.token = token
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.source = try container.decode(Source.self, forKey: .source)
        self.requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        self.replacesCommandToken = try container.decodeIfPresent(String.self, forKey: .replacesCommandToken)
        self.documentContextFingerprint = try container.decodeIfPresent(
            SharedDictationDocumentContextFingerprint.self,
            forKey: .documentContextFingerprint
        )
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }
}

public enum SharedDictationSessionStatus: Codable, Equatable, Sendable {
    case idle
    case commandPending(token: String, requestedAt: Date)
    case commandAcknowledged(token: String, acknowledgedAt: Date)
    case recording(token: String, startedAt: Date, timeoutSeconds: Double)
    case transcribing(token: String)
    case transcriptReady(token: String)
    case failed(token: String?, message: String)
    case cancelled(token: String?)
}

public extension SharedDictationSessionStatus {
    var acceptsKeyboardStopCommand: Bool {
        switch self {
        case .commandPending,
             .commandAcknowledged,
             .recording,
             .transcribing:
            true
        case .idle,
             .transcriptReady,
             .failed,
             .cancelled:
            false
        }
    }
}

public struct SharedDictationAppHeartbeat: Codable, Equatable, Sendable {
    public enum SessionState: String, Codable, Sendable {
        case unavailable
        case foreground
        case armed
        case recording
        case transcribing
    }

    public let token: String
    public let sessionID: String?
    public let lastSeenAt: Date
    public let sessionState: SessionState

    public init(
        token: String,
        sessionID: String? = nil,
        lastSeenAt: Date,
        sessionState: SessionState
    ) {
        self.token = token
        self.sessionID = sessionID
        self.lastSeenAt = lastSeenAt
        self.sessionState = sessionState
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case sessionID
        case lastSeenAt
        case sessionState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        sessionState = try container.decode(SessionState.self, forKey: .sessionState)
    }

    public func isFresh(at date: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard sessionState != .unavailable else { return false }
        let age = date.timeIntervalSince(lastSeenAt)
        return age >= 0 && age <= maxAge
    }
}
