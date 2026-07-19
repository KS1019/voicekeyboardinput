import SwiftUI

@main
struct VoiceKeyboardMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Voice Keyboard", systemImage: "waveform") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
