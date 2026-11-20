# WebKit Dictation Implementation Plan

> Use superpowers:subagent-driven-development, then independent review.

**Goal:** Record and transcribe within the keyboard, falling back to existing app handoff on capture startup failure.

**Architecture:** A bounded PCM value type in the portable package; a WebKit capture bridge and Apple file speech adapter in the extension; coordinator/controller integration reusing existing final insertion guards.

**Tech Stack:** Swift 6, WebKit, Web Audio, AVFAudio file encoding, Speech, XCTest.

## Global constraints

- No code signing; all Xcode builds/tests use CODE_SIGNING_ALLOWED=NO.
- No third-party STT, heavy models, private API or Foundation Models in extension.
- Full Access and existing app-granted microphone/Speech permissions required.
- 2-second first-PCM timeout; 60-second bounded recording; cancel never inserts text.
- Commit identity is command-local Codex <codex@openai.com>; no global git settings.
- Real-device capture support remains unverified until explicitly tested.

## Task 1: Bounded WebKit capture and file transcription

- [x] Add failing package tests for PCM input: invalid base64/odd bytes/oversized chunks rejected; silence stays finite; normalized output cannot clip; total recording cannot exceed 960000 samples.
- [x] Run focused tests and record expected failure before implementing the PCM model.
- [x] Add a small portable PCM model under VoiceKeyboardModels; run focused tests.
- [x] Add extension WebKit bridge with preloaded inline HTML, continuous resampling, per-session IDs, strict message/origin checks, first-PCM timeout, stop acknowledgement and synchronous webview disposal on cancel. Test JavaScript resampling with a local JS runner if available.
- [x] Add Apple Speech file adapter: m4a encode, SFSpeechURLRecognitionRequest, timeout, cancellation and temporary file deletion; no AVAudioEngine.
- [x] Update KeyboardSpeechCaptureCoordinator and KeyboardViewController: preload in viewDidAppear, readiness gate, finish on second tap vs cancel on lifecycle/context mutations, final-only guarded insertion, startup fallback after capture teardown.
- [x] Update project.yml resources/permission strings and regenerate Xcode project.
- [x] Run make package-strict-test, make build, relevant UIKit tests with unsigned settings. Record failures and fix root causes.
- [x] Commit feature after self-review; independent reviewer checks lifecycle and fallback races before integration.

## Task 2: Documentation and integration

- [x] Update PRIVACY.md and device QA to describe experimental WebKit capture, Apple recognition and fallback; document unresolved real-device validation.
- [x] Review full feature diff independently; address important findings and rerun affected checks.
- [x] Verify generated files match project spec and git diff --check.
- [ ] Push normal fast-forward to origin/main with temporary Codex identity and report decisions, test evidence and limitations.
