import Foundation

public enum ContainingAppRoute: Equatable, Sendable {
    case startDictation

    public static let scheme = "voicekeyboard"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        guard url.path.isEmpty, url.query == nil, url.fragment == nil else { return nil }

        switch url.host {
        case "start-dictation":
            self = .startDictation
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
        }

        guard let url = components.url else {
            preconditionFailure("Invalid containing app route")
        }
        return url
    }
}
