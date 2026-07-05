# ``VoiceKeyboardModels``

Shared value types for the Voice Keyboard app, keyboard extension, and portable package code.

## Overview

`VoiceKeyboardModels` contains platform-neutral domain entities. Keep this module free of UIKit, AVFoundation, Speech, and Foundation Models dependencies so the same types can be reused by app, extension, tests, and future non-iOS surfaces.

Use this module for state, command, route, and speech-recognition data that has no UI rendering responsibility.

## Topics

### Runtime Capabilities

- ``RuntimeCapabilities``
- ``KeyboardSpeechCaptureState``
- ``KeyboardSpeechCaptureStateMachine``
- ``KeyboardSpeechCaptureUnavailableReason``

### Audio Probe

- ``AudioCaptureProbeDuration``
- ``AudioCaptureProbeResult``
- ``AudioCaptureProbeError``
- ``NormalizedInputLevel``

### Speech Input

- ``SpeechRecognitionUpdate``
- ``SpeechRecognitionError``
- ``VoiceActivityState``

### Text Commands

- ``VoiceKeyboardLocale``
- ``TextOperation``
- ``TextDeletionCount``
- ``InsertedTextPreparationResult``

### Containing App Routing

- ``ContainingAppRoute``
