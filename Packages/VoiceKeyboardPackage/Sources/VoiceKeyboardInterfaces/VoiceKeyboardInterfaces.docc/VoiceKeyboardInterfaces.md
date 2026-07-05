# ``VoiceKeyboardInterfaces``

Service boundaries for platform-specific audio, speech, capability, and cleanup adapters.

## Overview

`VoiceKeyboardInterfaces` defines protocols that isolate platform-specific implementations from domain and presentation code. App and extension targets can provide AVFoundation, SpeechAnalyzer, or other concrete adapters while the package remains portable.

Prefer adding a protocol here before introducing framework-specific behavior into core package modules.

## Topics

### Audio and Capability Probes

- ``CapabilityChecking``
- ``AudioCaptureProbing``

### Speech Recognition

- ``SpeechRecognitionService``

### Text Cleanup

- ``TextCleanupService``
