# Task 1 Report: Shared STT State And Presentation

## Scope

Implemented the shared keyboard STT state expansion, presentation mapping, and UIKit rendering coverage in the locations required by the brief:

- `Packages/VoiceKeyboardPackage`
- `VoiceKeyboardUIKitTests`

No real recognition session, adapter, network recognition, app-to-extension relay, AuralKit, WhisperKit, or Foundation Models work was added.

## TDD Record

### RED

Added failing tests first in:

- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift`
- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardPresentationTests/SpeechCapturePresentationSnapshotKeyboardStateTests.swift`
- `VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift`

Observed expected failures:

- `make package-strict-test` failed because expanded `SpeechRecognitionError` cases did not exist.
- `make ui-kit-test` failed because `KeyboardSpeechCaptureState.listening` and `.recognitionFailed` did not exist.

### GREEN

Implemented the minimum code to satisfy the new tests:

- Expanded `SpeechRecognitionError` in `SpeechModels.swift`
- Added `listening`, `transcribing`, `inserted`, and `recognitionFailed` to `KeyboardSpeechCaptureState.swift`
- Added snapshot mapping for the new states in `SpeechCapturePresentationSnapshot+KeyboardState.swift`
- Added a narrow `VoiceActivityState.listening(level: NormalizedInputLevel?)` overload so the new presentation tests can represent “listening with no measured level yet” and reuse normalized levels directly

Re-ran the same checks successfully:

- `make package-strict-test`
- `make ui-kit-test`

## Verification

Completed the required verification sequence:

1. `make package-strict-test`
2. `make build`
3. `make ui-kit-test`
4. `make app-ui-test`
5. `make preview-layout-test`
6. `make generated-check`

Notes:

- Parallel `make` verification is unsafe here because concurrent `xcodegen generate` invocations collide on the project bundle. Sequential runs passed.
- Transcript text was not added to diagnostics or logs.

## Files Changed

- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/SpeechModels.swift`
- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/KeyboardSpeechCaptureState.swift`
- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/VoiceActivityState.swift`
- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardPresentation/SpeechCapturePresentationSnapshot+KeyboardState.swift`
- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift`
- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardPresentationTests/SpeechCapturePresentationSnapshotKeyboardStateTests.swift`
- `VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift`

## Outcome

Task 1 is complete. Shared STT states and their presentation snapshots are in place, and UIKit rendering now covers the new listening and recognition-failure states. No claim is made that real keyboard STT works; that remains for later tasks and physical-device QA.
