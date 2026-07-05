---
name: voicekeyboard-speech-audio
description: Use when working on VoiceKeyboard iOS microphone capture, AVAudioSession, AVAudioEngine, SpeechAnalyzer, SpeechTranscriber, speech-to-text, keyboard-extension voice UI, or audio permission behavior.
---

# VoiceKeyboard Speech Audio

## Core Rule

Treat keyboard-extension microphone capture as an experiment, not a product assumption. Apple’s archived Custom Keyboard guide says custom keyboards have no microphone access, while real apps show voice-keyboard UX exists through unclear implementation routes.

## Architecture Bias

- Keep shared speech/audio models, value objects, interfaces, and presentation snapshots in `Packages/VoiceKeyboardPackage`.
- Keep UIKit rendering in `VoiceKeyboardUIKit`; exclude previews from the extension target.
- Put permission onboarding, long-running audio work, SpeechAnalyzer validation, and Foundation Models work in the containing app unless a real-device probe proves extension stability.
- Do not add fake fallback implementations. If a path is unavailable, model it explicitly as unavailable or unvalidated.

## External Speech Dependencies

- Do not add AuralKit to `VoiceKeyboardPackage` or `VoiceKeyboardExtension`.
- Treat AuralKit as a reference implementation for SpeechAnalyzer/SpeechTranscriber adapters, not as a default dependency.
- If containing-app STT acceleration becomes necessary, depend on external wrappers only from an iOS-only adapter target pinned to an exact version.
- Keep `SpeechRecognitionService` as the ownership boundary so third-party speech code remains removable.

## Keyboard Extension Constraints

- Assume low memory, short lifetime, and aggressive termination.
- Avoid WhisperKit, Foundation Models, long recordings, large caches, and model warmup inside the extension.
- Keep extension UI responsive and extension-safe under `APPLICATION_EXTENSION_API_ONLY`.
- Use `textDocumentProxy` for insertion only after the capture/STT path has a verified result.

## Validation Ladder

1. Probe `AVAudioSession` / `AVAudioEngine` in the keyboard extension on a real iOS 26+ device for 1-3 seconds.
2. Track success, failure reason, duration, peak/input level, memory, repeated use, and host app.
3. Only after stable capture, test SpeechAnalyzer/SpeechTranscriber in the extension.
4. Keep Foundation Models in the containing app until there is evidence extension use is safe and rate limits are understood.

## Modeling Pattern

- Prefer small `Sendable` value objects with failable initializers for invalid numeric input.
- Prefer actors for mutable async services such as readiness/probe state.
- Prefer protocols in `VoiceKeyboardInterfaces` for AV/Speech adapters so domain and presentation code stay platform-portable.
- Prefer presentation snapshots over UIKit-specific state in package modules.

## Verification

Use the narrowest check first, then broaden:

```bash
make package-strict-test
make build
make preview-layout-test
make -j verify
```

When generated files are involved, run `make generated-check`. After initial files are tracked, consider hardening it to catch untracked generated outputs.

## References

- Apple Custom Keyboard guide: `https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html`
- Apple App Extension creation guide: `https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html`
- Speech framework: `https://developer.apple.com/documentation/speech`
- SpeechAnalyzer: `https://developer.apple.com/documentation/speech/speechanalyzer`
- AVAudioSession: `https://developer.apple.com/documentation/avfaudio/avaudiosession`
