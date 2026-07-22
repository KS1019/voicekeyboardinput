import Foundation

public enum ContainingAppRoute: Equatable, Sendable {
    case startDictation
    case startDictationForKeyboardSession(sessionID: String)

    public static let scheme = "voicekeyboard"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        guard url.path.isEmpty, url.fragment == nil else { return nil }

        switch url.host {
        case "start-dictation":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            guard queryItems.allSatisfy({ $0.name == "sessionID" }), queryItems.count <= 1 else {
                return nil
            }
            let sessionID = queryItems.first?.value
            guard sessionID?.isEmpty != true else { return nil }
            if let sessionID {
                self = .startDictationForKeyboardSession(sessionID: sessionID)
            } else {
                self = .startDictation
            }
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .startDictation:
            components.host = "start-dictation"
        case let .startDictationForKeyboardSession(sessionID):
            components.host = "start-dictation"
            components.queryItems = [URLQueryItem(name: "sessionID", value: sessionID)]
        }

        guard let url = components.url else {
            preconditionFailure("Invalid containing app route")
        }
        return url
    }
}
