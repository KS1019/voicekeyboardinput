# Keyboard Extension Manual QA

Use this checklist for behavior XCTest cannot reliably automate yet: enabling the custom keyboard in Settings, switching to it from a host text field, and observing the extension UI inside the keyboard host process.

## Preconditions

- Build and install `VoiceKeyboardInput` on an iOS 26+ simulator or device.
- Run `make verify` first so package, UIKit, app UI, build, preview layout, and generated-file checks are green.
- Run `make keyboard-permission-policy-check` if `Allow Full Access` is missing in Settings or App Group handoff fails.
- Turn `Allow Full Access` on for `Voice Keyboard` when validating keyboard-side STT. The extension requests open access so Settings exposes the switch; the first STT path still records diagnostics if the platform blocks microphone or Speech access.
- The signed app and keyboard extension must both have the `group.com.ks1019.voicekeyboardinput` App Group entitlement. For physical devices, also enable that App Group for both bundle identifiers in the Apple Developer portal before signing.
- On Simulator, grant microphone access for both the containing app and keyboard extension before probing if you want to bypass the permission prompt:
  `make simulator-grant-microphone`
- On iOS 26, the keyboard speech adapter uses the legacy `SFSpeechRecognizer` audio-buffer path. On iOS 27+, it can use the `SpeechAnalyzer` path when available.

## Enable The Keyboard

1. Open the app and confirm the `Keyboard Extension QA` section is visible.
2. Open Settings.
3. Go to General, Keyboard, Keyboards.
4. Choose Add New Keyboard.
5. Add `Voice Keyboard`.
6. Open the `Voice Keyboard` entry and turn `Allow Full Access` on.

## Load The Extension

1. Return to `VoiceKeyboardInput`.
2. Tap the text field in `Keyboard Extension QA`.
3. Use the system keyboard switcher to select `Voice Keyboard`.
4. Confirm the keyboard extension appears without crashing.

## Expected Keyboard STT Behavior

- Tapping Mic in `Voice Keyboard` starts the keyboard-process STT path.
- The keyboard first shows `Listening...`.
- Partial recognition shows the live transcript and a Stop microphone button.
- A final transcript is inserted into the host text field.
- If iOS blocks microphone capture in the keyboard process, tapping Mic opens the containing app through the dictation URL route.
- The containing app requests microphone and Speech permission, records a short utterance, transcribes it, and saves the transcript to the shared App Group.
- Return to the host app and show `Voice Keyboard` again; the keyboard consumes the latest shared transcript once and inserts it into the host text field.
- If App Group signing is missing or mismatched, the keyboard shows `Shared App Group storage is unavailable.` instead of opening the app into a handoff path that cannot return text.
- If the current OS cannot start either the legacy Speech path or the SpeechAnalyzer path, the keyboard shows speech unavailable rather than falling back silently.
- The diagnostic log should include permission state, locale, audio session activation, input format, audio engine start, speech recognizer availability, recognition start, and stop reason.
- Do not treat Simulator success as proof that real-device keyboard STT works.
- The app-side `Start Voice Input` button runs the containing-app dictation flow and shows `Transcript Ready` after a non-empty transcript is saved for the keyboard.
- Delete removes the previous character from the host text field.
- Return inserts a newline into the host text field.
- Next switches to another enabled keyboard when iOS exposes the input-mode switch key.

## Simulator Keyboard STT Probe

1. Boot the target Simulator and install the app.
2. Run `make simulator-grant-microphone`.
3. Open the app and tap `Start Voice Input`.
4. Speak into the Mac microphone during the short dictation window.
5. Confirm the app reports `Transcript Ready`.
6. Load `Voice Keyboard` in the app text field.
7. Tap Mic in the keyboard and speak a short phrase.
8. Confirm either that recognized text is inserted or that the keyboard reports a specific Speech/microphone unavailable state.

If the probe fails on Simulator, check macOS microphone permission for Simulator/Xcode and the Mac input device in System Settings. `simctl io` does not provide an audio injection operation in the current local Xcode help output; microphone permission is controlled through `simctl privacy`.

## Physical Device STT Validation

1. Install a signed build on an iOS 26+ physical device.
2. Enable `Voice Keyboard` in Settings.
3. Turn `Allow Full Access` on.
4. Open a host text field and switch to `Voice Keyboard`.
5. Tap Mic and speak a short phrase.
6. If the containing app opens, speak a short phrase, then return to the host app and show `Voice Keyboard` again.
7. Confirm whether text is inserted exactly once.
8. Capture the `KeyboardSpeechRecognition` logs.
9. Repeat with `Allow Full Access` off only to record whether behavior changes; do not ship an off-state requirement without a separate design update.
10. On iOS 26, confirm logs show the legacy audio-buffer strategy before classifying any recognition failure as a platform limitation.

## Known Automation Boundary

XCTest covers the stable layers:

- `make ui-kit-test` verifies `KeyboardRootView` state rendering.
- `make app-ui-test` verifies the app exposes the QA surface.
- `make preview-layout-test` verifies SwiftUI preview layout rendering.

Do not treat those as proof that iOS accepted the custom keyboard in Settings. That remains manual or future device-lab automation.
