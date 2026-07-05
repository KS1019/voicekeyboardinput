# ``VoiceKeyboardCore``

Core orchestration for speech capture readiness and voice input processing.

## Overview

`VoiceKeyboardCore` coordinates package-level workflows using `VoiceKeyboardModels` and `VoiceKeyboardInterfaces`. It should remain UI-free and platform-neutral.

Containing app and keyboard extension code should call core services rather than duplicating readiness rules, probe handling, or text-preparation flow.

## Topics

### Voice Input

- ``VoiceInputPipeline``
- ``VoiceInputPipelineError``

### Keyboard Speech Capture

- ``KeyboardSpeechCaptureReadinessService``
