# Keyboard Extension Manual QA

Use this checklist for behavior XCTest cannot reliably automate yet: enabling the custom keyboard in Settings, switching to it from a host text field, and observing the extension UI inside the keyboard host process.

## Preconditions

- Build and install `VoiceKeyboardInput` on an iOS 26+ simulator or device.
- Run `make verify-unsigned` for local package, WebKit, UIKit, app UI, build, layout, policy, and generated-file checks without signing. Full `make verify` also runs the signed macOS security check and is the CI entry point.
- Run `make keyboard-permission-policy-check` if `Allow Full Access` is missing in Settings or App Group handoff fails.
- Turn `Allow Full Access` on for `Voice Keyboard` when validating the keyboard UI and App Group handoff. The containing app owns microphone and Speech authorization; grant both there before testing experimental WebKit capture.
- The signed app and keyboard extension must both have the `group.com.ks1019.voicekeyboardinput` App Group entitlement. For physical devices, also enable that App Group for both bundle identifiers in the Apple Developer portal before signing.
- On Simulator, grant microphone access for both the containing app and keyboard extension before probing if you want to bypass the permission prompt:
  `make simulator-grant-microphone`
- The experimental WebKit path uses Apple file recognition (`SFSpeechURLRecognitionRequest`), with a 20-second deadline including audio encoding.

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

- Loading/focusing the keyboard does not initialize WebKit. Tapping Mic loads the local capture document.
- With Full Access and previously granted microphone/Speech permissions, tapping Mic attempts WebKit capture inside the keyboard. Pauses of roughly 0.7 seconds commit audio for Apple Speech transcription while capture continues (uninterrupted audio is split at eight seconds). A second tap drains the remaining audio, then waits for queued recognition.
- The keyboard inserts a final result only if the originating document context is still valid. Partial results never change the host field.
- If no PCM arrives within two seconds, capture is torn down and the existing containing-app handoff is attempted. Missing permissions also use the app onboarding path.
- The containing app can record and publish a transcript through the shared App Group. Return to the host and show the keyboard to insert that result once.
- If App Group storage is unavailable, the fallback displays an unavailable state rather than losing a handoff.
- A segment without a recognition result must not discard later segments or the Stop tail. Permission/startup failures remain terminal, but already-recognized pending text is preserved literally. Missing audio must be reported; commands must not execute after a recognition gap in that recording.
- Audio chunks are not command boundaries: ordinary text is inserted live, while potential command wording waits for Stop. Check `new line` + `item` and `command delete` + `word`, including preceding prose.
- Nonempty quiet PCM must reach recognition. After Stop, the latest result must remain visible without “Continue speaking.” Delayed self-insertion callbacks must not cancel recording when the expected field/context still matches; a real field/context change must cancel it.
- Dismissing/switching the keyboard, changing the host field, Delete/Return, and memory cancellation must discard the active direct recording/result.
- Delete removes the previous character; Return inserts a newline; Next switches keyboard when iOS exposes the input-mode switch key.
- Simulator and build success are not proof of real-device WebKit microphone support.

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

## Physical Device WebKit Validation (not yet verified)

Record device model, iOS version, host app, permission state, startup time,
input level, recording duration, memory, transcription result, and fallback
outcome. A build/test pass alone must never change this section to verified.
Device installation requires a separately signed build. Unsigned local
validation does not install or provision a physical device.

1. Grant microphone and Speech permissions in the app, enable the keyboard and Full Access.
2. Open a text field in Notes, Safari, and a third-party host in turn. Show the keyboard and wait: the microphone must stay inactive before tapping Mic.
3. Tap Mic. Confirm the recording indicator and audible input, without switching apps. Speak a phrase, pause, and verify insertion before Stop. Repeat with a second phrase, then speak a short tail and Stop. Verify all three appear once, in order. Repeat in Japanese and English, including punctuation/delete commands that depend on the previous segment.
4. Repeat at least ten times, including immediate start/stop and a 60-second recording. Confirm bounded memory, no retained audio files, and usable subsequent attempts.
5. Deny microphone, deny Speech, and disable Full Access separately. Confirm controlled onboarding/fallback and no unauthorized recording. Re-enable permissions and retry.
6. Reproduce startup failure (including WebKit process failure if available): after two seconds without PCM the existing app handoff must work, and late WebKit completion must not leave a second microphone capture running.
7. During both recording and transcription: hide keyboard, switch keyboards, select another field, move caret, edit text from the host, press Delete/Return, background the host, and interrupt with a call. Confirm microphone release and no stale or duplicate insertion.
8. Test silence, very quiet/loud speech, offline Apple recognition, unsupported locale, and recognition timeout. Confirm errors are visible and temporary files removed.
9. Stop during startup and rapidly retry. Confirm canceled callbacks never insert text into the next session.
10. Compare direct WebKit and containing-app fallback for each external microphone route below; browser audio routing may differ from the app's AVAudioSession route.

## External Microphone Route Matrix

Run the containing-app handoff flow for each route below. Record the route
shown by the audio diagnostics, whether the transcript is inserted exactly
once, and whether Stop/Cancel leaves the next attempt usable.

| Route | Connect/disconnect cases |
| --- | --- |
| AirPods or another Bluetooth HFP headset | Connected before Start; connected during Start; disconnected during recording; reconnected before the next attempt |
| USB microphone/interface | Connected before Start; connected while the app is opening; removed during recording |
| Wired headset microphone | Plugged in before Start; unplugged during recording |
| Built-in microphone fallback | No external route; external route removed before the next attempt |

Also repeat one case while the device is locked, while the app moves to the
background, and after rapidly pressing Start/Stop twice. A2DP-only Bluetooth
output is not an input route and must fall back to a microphone-capable route
or report a controlled unavailable state.

## Known Automation Boundary

XCTest covers the stable layers:

- `make ui-kit-test` verifies `KeyboardRootView` state rendering.
- `make app-ui-test` verifies the app exposes the QA surface.
- `make preview-layout-test` verifies SwiftUI preview layout rendering.

Do not treat those as proof that iOS accepted the custom keyboard in Settings. That remains manual or future device-lab automation.

## Responsiveness regression checks

- Focus the app's Keyboard Extension QA field, type text, scroll, and reopen onboarding.
- Tap Start Voice Input and immediately focus/type in the QA field. Verify scrolling and Stop remain usable while audio initializes.
- Repeat with Voice Keyboard selected (not only the system keyboard), and while connecting/disconnecting Bluetooth audio. Record a hang stack if the device still freezes.
- The simulator tests cover UI interactions, real local WebKit message delivery with synthetic PCM, and ordered recognition with a test recognizer. They do not establish real-device microphone access, Apple Speech accuracy at chunk boundaries, or signed App Group handoff behavior.
