import Foundation
import VoiceKeyboardModels

@MainActor
protocol ContainingAppOpening {
    func openContainingAppForDictation(
        sessionID: String?,
        completion: @escaping @Sendable (Bool) -> Void
    )
}

@MainActor
extension ContainingAppOpening {
    func openContainingAppForDictation(completion: @escaping @Sendable (Bool) -> Void) {
        openContainingAppForDictation(sessionID: nil, completion: completion)
    }
}

@MainActor
struct ExtensionContextContainingAppOpener: ContainingAppOpening {
    private let extensionContextProvider: () -> NSExtensionContext?

    init(extensionContextProvider: @escaping () -> NSExtensionContext?) {
        self.extensionContextProvider = extensionContextProvider
    }

    func openContainingAppForDictation(
        sessionID: String?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let extensionContext = extensionContextProvider() else {
            completion(false)
            return
        }

        extensionContext.open(
            (sessionID.map(ContainingAppRoute.startDictationForKeyboardSession)
                ?? .startDictation).url,
            completionHandler: completion
        )
    }
}
