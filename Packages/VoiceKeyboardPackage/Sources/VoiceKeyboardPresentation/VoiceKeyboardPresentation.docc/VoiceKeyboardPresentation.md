# ``VoiceKeyboardPresentation``

Presentation snapshots for rendering Voice Keyboard state without coupling package code to UIKit or SwiftUI.

## Overview

`VoiceKeyboardPresentation` translates domain state from `VoiceKeyboardModels` into small value objects that UI targets can render. UIKit and SwiftUI code should depend on these snapshots instead of duplicating state-to-copy, state-to-tone, and meter calculations.

This boundary keeps the keyboard extension UI simple and testable while preserving portability across platforms.

## Topics

### Speech Capture

- ``SpeechCapturePresentationSnapshot``
- ``PresentationTone``
- ``ActiveMicrophoneBarCount``

### Voice Activity

- ``VoiceActivityPresentationSnapshot``
- ``VoiceActivityMeterSnapshot``
- ``VoiceActivityMeterBarCount``
- ``VoiceActivityInputIntensity``

### Command Preview

- ``CommandPreviewPresentationSnapshot``
