# ``VoiceKeyboardCore``

Core orchestration for speech capture readiness and voice input processing.

## Overview

`VoiceKeyboardCore` coordinates package-level workflows using `VoiceKeyboardModels` and `VoiceKeyboardInterfaces`. It should remain UI-free and platform-neutral.

The keyboard uses `VoiceInputPipeline` to prepare final transcript operations through the shared command pipeline.

`KeyboardSpeechRecognitionSession` turns a `SpeechRecognitionService` stream into keyboard presentation states and insertion actions without platform framework dependencies. This portable abstraction is tested independently; the live containing-app and WebKit adapters use their own lifecycle APIs.

## Topics

### Voice Input

- ``VoiceInputPipeline``
- ``VoiceInputPipelineError``

### Keyboard Speech Capture

- ``KeyboardSpeechCaptureReadinessService``
