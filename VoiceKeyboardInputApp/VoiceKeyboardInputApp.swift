import SwiftUI

@main
struct VoiceKeyboardInputApp: App {
    var body: some Scene {
        WindowGroup {
            VoiceKeyboardAppRootView()
        }
    }
}

private struct VoiceKeyboardAppRootView: View {
    @State private var voiceInputLaunchModel = VoiceInputLaunchModel()

    var body: some View {
        ContentView(voiceInputLaunchModel: voiceInputLaunchModel)
            .onOpenURL { url in
                voiceInputLaunchModel.handleOpenURL(url)
            }
            .task {
                await voiceInputLaunchModel.prepareSession()
            }
    }
}
