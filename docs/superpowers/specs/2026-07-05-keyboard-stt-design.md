# Keyboard Extension STT Design

## Goal

Build toward real speech-to-text inside the keyboard extension. The first implementation should create the keyboard-side STT architecture and runtime path, even if iOS blocks some devices or hosts at runtime. Failures must be explicit and diagnosable rather than hidden behind a generic unavailable state.

## Decision

Use the recommended approach: add a keyboard-side `SpeechRecognitionService` adapter and wire the keyboard microphone button into recognition. Keep the app-side microphone probe as a secondary validation surface, but do not make it the primary dictation path.

This accepts the platform risk around microphone access in custom keyboard extensions. The implementation must therefore separate product flow from platform evidence: the UI can attempt keyboard STT, while the diagnostics record whether permission, audio session activation, engine startup, or speech recognition failed.

## Scope

In scope:

- Extend shared speech models so keyboard STT can report distinct failure reasons.
- Add a concrete speech adapter in `VoiceKeyboardExtension`.
- Start recognition from the keyboard microphone button.
- Insert final recognized text through `textDocumentProxy.insertText`.
- Show listening, transcribing, failure, and unavailable states in the existing keyboard UI.
- Preserve detailed runtime diagnostics for manual real-device validation.
- Keep extension code safe under `APPLICATION_EXTENSION_API_ONLY`.

Out of scope for the first implementation:

- Network recognition.
- Foundation Models in the keyboard extension.
- WhisperKit or any large model in the keyboard extension.
- App-to-extension transcription relay.
- A polished long-form dictation editor.

## Architecture

Shared package modules remain the ownership boundary for portable models, interfaces, state machines, and presentation snapshots.

`VoiceKeyboardInterfaces` continues to own `SpeechRecognitionService`. `VoiceKeyboardModels` owns speech update and error values. `VoiceKeyboardCore` owns recognition state transitions and transcript handling that can be tested without UIKit, AVFoundation, or Speech framework dependencies.

`VoiceKeyboardExtension` owns the concrete keyboard adapter. It may import `AVFAudio` and Speech APIs, but those imports must not leak into package modules. The adapter is responsible for:

- checking microphone permission,
- activating `AVAudioSession`,
- starting `AVAudioEngine`,
- starting the speech recognizer,
- streaming partial/final updates,
- stopping and cleaning up resources,
- mapping platform failures to shared error values.

`KeyboardViewController` remains the UIKit integration point. It should coordinate button taps, render snapshots, and insert final text. It should not contain speech recognition implementation details.

## Runtime Flow

1. User taps the keyboard microphone button.
2. The controller asks a keyboard speech coordinator to start recognition for the current locale.
3. The coordinator renders a listening state immediately.
4. The keyboard speech adapter validates microphone permission and platform availability.
5. The adapter activates audio and starts speech recognition.
6. Partial updates render as transcribing state with live transcript text and input level when available.
7. Final update is passed through `VoiceInputPipeline.operations(for:documentContextBeforeInput:)`; plain insertion operations are inserted with `textDocumentProxy.insertText`, and unsupported operations are ignored for the first implementation.
8. Stop, cancellation, or final completion releases the audio session and engine.
9. Any failure renders a state-specific message and records diagnostics.

## Error Model

`SpeechRecognitionError` must be expanded beyond `unavailableInCurrentProcess`.

Required cases:

- `microphonePermissionDenied`
- `microphonePermissionUndetermined`
- `audioSessionActivationFailed`
- `audioInputUnavailable`
- `audioEngineStartFailed`
- `speechRecognizerUnavailable`
- `speechAuthorizationDenied`
- `recognitionStartFailed`
- `recognitionFailed`
- `cancelled`

Errors should carry a short diagnostic string only where the underlying platform error is useful. UI copy should be derived in presentation code, not embedded in the adapter.

## Diagnostics

The keyboard adapter must record one compact diagnostic event for each major boundary:

- permission state before recognition,
- full-access state when observable,
- selected locale,
- `AVAudioSession` category/mode activation result,
- input route availability,
- input format sample rate and channel count,
- audio engine start result,
- speech recognizer availability,
- recognition stream start result,
- final stop reason.

Diagnostics may initially use `os.Logger`. They should avoid transcript content unless needed for local debugging, because dictated text can be sensitive.

## UI Behavior

The keyboard should not claim dictation is ready solely because the audio probe passed.

Required visible states:

- Idle: microphone is available to try.
- Listening: audio capture is starting or active.
- Transcribing: partial transcript is available.
- Inserted: final text was inserted.
- Unavailable: platform or permission prevents recognition.
- Failed: a start-time or stream-time error occurred.

The existing app screen remains outside this first implementation. A separate follow-up should rename app-side microphone-probe copy so it no longer implies app-side dictation is the main path.

## Full Access

`RequestsOpenAccess` may be changed only if the implementation needs a capability that requires full access, such as an app group handoff or network access. It should not be treated as the microphone permission switch.

For the keyboard-first STT path, the initial implementation should not depend on full access. If a future physical-device QA run shows that full access changes microphone behavior, that observation should be captured as a diagnostic result and documented separately.

## Testing Strategy

Unit tests should cover the shared state and presentation layers with fake recognition services:

- start recognition renders listening,
- partial update renders transcribing,
- final update prepares text for insertion,
- permission denial renders unavailable,
- audio/session/recognition failures render failed states,
- cancellation cleans up without insertion.

UIKit tests should verify `KeyboardRootView` rendering for the new states.

Integration with real `AVAudioSession`, `AVAudioEngine`, and Speech APIs remains manual/device validation. The manual QA checklist must be updated with keyboard STT steps and expected diagnostics.

## Verification Commands

Use the existing narrow-to-broad verification ladder:

```bash
make package-strict-test
make build
make ui-kit-test
make app-ui-test
make preview-layout-test
make generated-check
```

Before claiming real keyboard STT works, run manual QA on a physical iOS 26+ device and capture the diagnostic result. Simulator success alone is not sufficient.

## Risks

- iOS may deny microphone capture inside the custom keyboard extension regardless of Info.plist usage strings.
- Speech APIs may be unavailable or unstable in the extension process.
- Host apps may terminate the extension aggressively during audio capture.
- Memory pressure may interrupt recognition.
- `textDocumentProxy` insertion is only possible after the extension receives a final transcript while still active.

The design handles these risks by making every boundary explicit, keeping heavy work out of shared packages, and ensuring failures are visible rather than silently falling back to app-side behavior.
