import AppKit
import SwiftUI

@main
struct VoiceKeyboardMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Voice Keyboard", systemImage: "waveform") {
            MenuBarContentView()
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
