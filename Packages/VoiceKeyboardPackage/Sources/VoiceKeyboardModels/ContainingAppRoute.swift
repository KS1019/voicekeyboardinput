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
            guard let sessionID = queryItems.first?.value,
                  !sessionID.isEmpty else { return nil }
            self = .startDictationForKeyboardSession(sessionID: sessionID)
        default:
            return nil
        }
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .startDictation:
            // A bare custom URL cannot authenticate a keyboard handoff and
            // must never trigger microphone capture.
            return nil
        case let .startDictationForKeyboardSession(sessionID):
            components.host = "start-dictation"
            components.queryItems = [URLQueryItem(name: "sessionID", value: sessionID)]
        }

        return components.url
    }
}
