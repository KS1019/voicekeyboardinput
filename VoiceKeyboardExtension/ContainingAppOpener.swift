import Foundation
import VoiceKeyboardModels

@MainActor
protocol ContainingAppOpening {
    func openContainingAppForDictation(completion: @escaping @Sendable (Bool) -> Void)
}

@MainActor
struct ExtensionContextContainingAppOpener: ContainingAppOpening {
    private let extensionContextProvider: () -> NSExtensionContext?

    init(extensionContextProvider: @escaping () -> NSExtensionContext?) {
        self.extensionContextProvider = extensionContextProvider
    }

    func openContainingAppForDictation(completion: @escaping @Sendable (Bool) -> Void) {
        guard let extensionContext = extensionContextProvider() else {
            completion(false)
            return
        }

        extensionContext.open(
            ContainingAppRoute.startDictation.url,
            completionHandler: completion
        )
    }
}
