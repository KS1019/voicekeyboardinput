# ``VoiceKeyboardInterfaces``

Service boundaries for platform-specific audio, speech, capability, and cleanup adapters.

## Overview

`VoiceKeyboardInterfaces` defines protocols that isolate platform-specific implementations from domain and presentation code. Concrete adapters can use platform frameworks while the package remains portable. The live containing-app and WebKit speech adapters currently use their own lifecycle APIs rather than implementing `SpeechRecognitionService`.

Prefer adding a protocol here before introducing framework-specific behavior into core package modules.

## Topics

### Audio and Capability Probes

- ``CapabilityChecking``
- ``AudioCaptureProbing``

### Speech Recognition

- ``SpeechRecognitionService``

### Text Cleanup

- ``TextCleanupService``
