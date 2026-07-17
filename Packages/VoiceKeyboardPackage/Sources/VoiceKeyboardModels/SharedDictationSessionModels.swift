import Foundation

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

    public init(
        token: String,
        kind: Kind,
        source: Source,
        requestedAt: Date,
        expiresAt: Date,
        sessionID: String? = nil
    ) {
        self.sessionID = sessionID ?? UUID().uuidString
        self.token = token
        self.kind = kind
        self.source = source
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }

    public static func start(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10,
        sessionID: String = UUID().uuidString
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .start,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID
        )
    }

    public static func stop(
        sessionID: String,
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .stop,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID
        )
    }

    public static func stop(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10
    ) -> SharedDictationSessionCommand {
        stop(
            sessionID: UUID().uuidString,
            source: source,
            requestedAt: requestedAt,
            expiryInterval: expiryInterval
        )
    }

    public static func cancel(
        sessionID: String,
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10
    ) -> SharedDictationSessionCommand {
        SharedDictationSessionCommand(
            token: UUID().uuidString,
            kind: .cancel,
            source: source,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(expiryInterval),
            sessionID: sessionID
        )
    }

    public static func cancel(
        source: Source,
        requestedAt: Date = Date(),
        expiryInterval: TimeInterval = 10
    ) -> SharedDictationSessionCommand {
        cancel(
            sessionID: UUID().uuidString,
            source: source,
            requestedAt: requestedAt,
            expiryInterval: expiryInterval
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case token
        case kind
        case source
        case requestedAt
        case expiresAt
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
    public let lastSeenAt: Date
    public let sessionState: SessionState

    public init(
        token: String,
        lastSeenAt: Date,
        sessionState: SessionState
    ) {
        self.token = token
        self.lastSeenAt = lastSeenAt
        self.sessionState = sessionState
    }

    public func isFresh(at date: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard sessionState != .unavailable else { return false }
        return date.timeIntervalSince(lastSeenAt) <= maxAge
    }
}
