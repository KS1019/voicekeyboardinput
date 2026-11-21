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
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var showsOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.completed")

    var body: some View {
        ContentView(voiceInputLaunchModel: voiceInputLaunchModel) {
            showsOnboarding = true
        }
            .fullScreenCover(isPresented: $showsOnboarding) {
                OnboardingView {
                    onboardingCompleted = true
                    showsOnboarding = false
                } later: {
                    showsOnboarding = false
                }
            }
            .onOpenURL { url in
                showsOnboarding = false
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
