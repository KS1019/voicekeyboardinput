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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentView(voiceInputLaunchModel: voiceInputLaunchModel)
            .onOpenURL { url in
                voiceInputLaunchModel.handleOpenURL(url)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                voiceInputLaunchModel.setAppAvailable(phase == .active)
            }
            .task {
                await voiceInputLaunchModel.prepareSession()
            }
    }
}
