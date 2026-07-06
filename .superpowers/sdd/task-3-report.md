# Task 3 Report: Keyboard Speech Adapter And Diagnostics

## Status

DONE_WITH_CONCERNS

## Summary

Implemented the keyboard extension speech-recognition adapter and diagnostics requested by Task 3.

Changes made:
- Added `VoiceKeyboardExtension/KeyboardSpeechRecognitionDiagnostics.swift`.
- Added `VoiceKeyboardExtension/KeyboardSpeechRecognitionService.swift`.
- Added `NSSpeechRecognitionUsageDescription` to `VoiceKeyboardExtension/Info.plist`.
- Added the same speech usage description to `project.yml` under `VoiceKeyboardExtension.info.properties`.
- Updated `Makefile` extension dependency policy to allow `import Speech` while continuing to block `FoundationModels`.
- Regenerated `VoiceKeyboardInput.xcodeproj/project.pbxproj`.

Adapter-local build fixes after the initial brief implementation:
- Added an iOS 27 runtime availability guard before using `AnalyzerInputConverter`, because Xcode 27 beta 2 marks it iOS 27-only while the project deployment target is iOS 26. On iOS 26, `start(locale:)` reports `.speechRecognizerUnavailable`.
- Moved `converter.convert(_:at:)` out of the spawned `Task` in the audio tap so non-Sendable AVAudio buffers are not captured across a sending closure. Only converted analyzer inputs are yielded back to the actor.

## Privacy

Diagnostics do not log dictated transcript text. They log event names, locale identifier, audio format metadata, and mapped error descriptions only.

## Verification

Commands run:

```bash
make dependency-policy-check
make build
make generate
make generated-check
```

Results:
- `make dependency-policy-check`: PASS.
- First `make build`: FAIL in `KeyboardSpeechRecognitionService.swift` due to `AnalyzerInputConverter` iOS 27 availability.
- Second `make build`: FAIL in `KeyboardSpeechRecognitionService.swift` due to Swift 6 sendability risk from capturing the audio buffer in a `Task`.
- Final `make build`: PASS.
- `make generate`: PASS.
- First `make generated-check`: FAIL because generated outputs were intentionally modified but not staged; after staging the generated plist and pbxproj, the check was rerun.
- Final `make generated-check`: PASS.

## Concerns

- Real keyboard STT is still unvalidated. This adapter compiles, but Task 3 does not wire the keyboard button and no claim is made that real keyboard STT works before physical iOS 26+ device QA.
- The first compiled adapter path depends on `AnalyzerInputConverter`, which is iOS 27-only in the local Xcode 27 beta 2 SDK. The adapter therefore fails closed with `.speechRecognizerUnavailable` on iOS 26.
