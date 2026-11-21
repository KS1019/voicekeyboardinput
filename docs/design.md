# Voice Keyboard design

Voice Keyboard provides an iOS 26+ custom keyboard and a containing app for
permission onboarding, dictation, and manual QA. In-keyboard WebKit capture is
experimental: automated tests do not establish microphone support on a real iPhone.

## Architecture

- `VoiceKeyboardExtension` owns keyboard lifecycle, direct capture, and guarded
  text insertion. `KeyboardSpeechCaptureCoordinator` connects WebKit recording
  to Apple file recognition and the command pipeline.
- `VoiceKeyboardInputApp` owns microphone/Speech permission onboarding and the
  containing-app dictation fallback. Shared App Group records correlate requests,
  session state, and final transcript delivery across process lifetimes.
- The Swift package keeps models, command parsing, presentation, service
  interfaces, core workflows, and shared storage separate from platform UI.
  `VoiceKeyboardCommandPipeline` exposes the literal-transcript preview API;
  parser and planner implementation types remain package-scoped.
- `VoiceKeyboardMenuBar` is a macOS 13+ literal-transcript tester, generated from
  `project-mac.yml`. It depends only on Models and CommandPipeline, accepts text
  and document context, and previews operations. It does not capture audio,
  share iOS handoffs, or insert into other apps.

The portable package supports iOS 16/macOS 13. App and extension requirements
are enforced separately by their Xcode targets. The package's generic
`SpeechRecognitionService` and `KeyboardSpeechRecognitionSession` remain
independently tested abstractions; the live app and WebKit adapters use their
own lifecycle APIs rather than implementing that generic service.

## Onboarding

On first launch, the containing app offers microphone and Speech authorization
without starting a recording. It refreshes permission status when returning from
Settings and explains denied or restricted access. Keyboard installation and Full
Access remain manual Settings steps; the app does not claim to verify them.
Continue saves completion, Later defers until the next launch, and setup can be
reopened from the main screen. Keyboard deep links dismiss onboarding to preserve
the existing recording handoff.

## Dictation and insertion

1. Showing the keyboard preloads a local, noninteractive WebKit document without
   requesting microphone access. Capture requires an explicit tap, Full Access,
   and microphone/Speech authorization previously granted in the containing app.
   Navigation and microphone requests are restricted to the recording document.
2. JavaScript resamples input to mono 16 kHz Int16 PCM. Native message validation
   bounds chunk size and caps the recording at 60 seconds. Capture counts as
   started only after PCM arrives. Startup failure, including no PCM within two
   seconds, tears down capture and attempts the containing-app handoff.
3. Stop finishes capture. Audio is normalized, encoded to a temporary m4a file,
   and submitted with `SFSpeechURLRecognitionRequest`. A 20-second deadline
   includes encoding. Recognition requests on-device processing when supported;
   otherwise Apple service availability applies. Recognition failure displays
   an error rather than automatically starting another recording.
4. Only a final transcript enters the existing command pipeline. Insertion
   checks the session, document identity, surrounding context, selection, and
   mutation generation. Partial results never edit the host field. Cancellation,
   keyboard dismissal, document changes, and memory warnings discard the direct
   attempt; stale callbacks cannot complete a newer session.

Temporary audio is removed on completion/cancellation. Later encoding attempts
also sweep crash leftovers older than five minutes. Shared handoffs use durable
claims, expiration, consumption/redaction, and quarantine for ambiguous edits to
prevent replay into another field. A temporarily hidden keyboard can recover a
containing-app result only when the document checks still pass. See the
[privacy policy](../PRIVACY.md) for storage and processing details.

## Interface

The keyboard has two compact rows: transcript/status/meter preview and input
keys. Its root, preview, and control containers are transparent and non-opaque;
material and tint belong to individual keys. The system host supplies the
surrounding keyboard background. Semantic colors, Dynamic Type, symbols, and
accessibility labels communicate state without relying on color alone.

Speak/Stop is the primary action. Next, Delete, and Return remain ordinary input
controls. The containing app provides the voice console and Keyboard Extension
QA field, with setup and diagnostics under Developer Details. Keep technical
explanations there rather than adding them to the keyboard's limited space.

## Validation

Use `make verify-unsigned` for local validation without signing. It includes the
bundled recording-page tests (`make webkit-test`) alongside package, app, UI,
build, policy, and generated-project checks. `make verify` adds the signed macOS
security check and remains the CI entry point; use it when signing is intended.

Synthetic WebKit input verifies the bridge and lifecycle, not actual microphone
capture in an extension. Live Apple recognition, external microphone routes,
and final insertion in third-party hosts still need device validation. In
particular, delayed native Speech completion after a host document change is
protected in code but is not established by automated controller tests.
Follow the [manual QA checklist](qa/keyboard-extension-manual-qa.md) before
claiming real-device support.
