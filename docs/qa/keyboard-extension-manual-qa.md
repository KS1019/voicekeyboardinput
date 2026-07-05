# Keyboard Extension Manual QA

Use this checklist for behavior XCTest cannot reliably automate yet: enabling the custom keyboard in Settings, switching to it from a host text field, and observing the extension UI inside the keyboard host process.

## Preconditions

- Build and install `VoiceKeyboardInput` on an iOS 26+ simulator or device.
- Run `make verify` first so package, UIKit, app UI, build, preview layout, and generated-file checks are green.
- Keep `Allow Full Access` off for the baseline keyboard. The current extension does not require network or shared-container access.
- On Simulator, grant microphone access for both the containing app and keyboard extension before probing if you want to bypass the permission prompt:
  `make simulator-grant-microphone`

## Enable The Keyboard

1. Open the app and confirm the `Keyboard Extension QA` section is visible.
2. Open Settings.
3. Go to General, Keyboard, Keyboards.
4. Choose Add New Keyboard.
5. Add `Voice Keyboard`.
6. Open the `Voice Keyboard` entry and confirm `Allow Full Access` is off.

## Load The Extension

1. Return to `VoiceKeyboardInput`.
2. Tap the text field in `Keyboard Extension QA`.
3. Use the system keyboard switcher to select `Voice Keyboard`.
4. Confirm the keyboard extension appears without crashing.

## Expected Baseline Behavior

- Without microphone permission, the keyboard shows `Open the app to start voice input.` and tapping Mic opens `VoiceKeyboardInput` through `voicekeyboard://start-dictation`.
- With microphone permission granted to the keyboard extension, tapping Mic runs a short keyboard-process `AVAudioSession`/`AVAudioEngine` input probe.
- A successful keyboard-side probe shows `Microphone probe passed.`.
- The app-side `Start Voice Input` button still runs the containing-app probe and shows `Microphone Active` with a peak input value when non-silent audio was observed.
- Delete removes the previous character from the host text field.
- Return inserts a newline into the host text field.
- Next switches to another enabled keyboard when iOS exposes the input-mode switch key.

## Simulator Audio Input Probe

1. Boot the target Simulator and install the app.
2. Run `make simulator-grant-microphone`.
3. Open the app and tap `Start Voice Input`.
4. Speak into the Mac microphone during the short probe.
5. Confirm the app reports `Microphone Active`.
6. Load `Voice Keyboard` in the app text field.
7. Tap Mic in the keyboard and confirm it reports `Microphone probe passed.`.

If the probe fails on Simulator, check macOS microphone permission for Simulator/Xcode and the Mac input device in System Settings. `simctl io` does not provide an audio injection operation in the current local Xcode help output; microphone permission is controlled through `simctl privacy`.

## Known Automation Boundary

XCTest covers the stable layers:

- `make ui-kit-test` verifies `KeyboardRootView` state rendering.
- `make app-ui-test` verifies the app exposes the QA surface.
- `make preview-layout-test` verifies SwiftUI preview layout rendering.

Do not treat those as proof that iOS accepted the custom keyboard in Settings. That remains manual or future device-lab automation.
