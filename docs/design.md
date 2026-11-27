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

On first launch, the containing app presents three native swipeable pages for
microphone, Speech recognition, and keyboard setup. Each page pairs a short benefit
with an illustrative waveform, transcript, or keyboard preview. These demos do
not record audio. A primary permission/Settings action and secondary navigation
remain visible while the content scrolls for larger text. Permission requests
require an explicit tap; paging neither grants access nor starts a recording.
It refreshes permission status when returning from
Settings and explains denied or restricted access. Keyboard installation and Full
Access remain manual Settings steps; the app does not claim to verify them.
Done saves completion, Later defers until the next launch, and setup can be
reopened from the main screen. Keyboard deep links dismiss onboarding to preserve
the existing recording handoff.

## Dictation and insertion

1. Showing the keyboard preloads a local, noninteractive WebKit document without
   requesting microphone access. Capture requires an explicit tap, Full Access,
   and microphone/Speech authorization previously granted in the containing app.
   Navigation and microphone requests are restricted to the recording document.
2. JavaScript resamples input to mono 16 kHz Int16 PCM and segments it at pauses
   or eight seconds. Native capture validates and bounds each chunk; continuous
   delivery keeps recording active until Stop. Startup failure (no PCM within
   two seconds) attempts the app handoff; a three-second PCM stall after startup
   reports capture failure. Silent PCM counts as delivery.
3. Each segment is normalized, encoded to a temporary m4a file, and submitted
   sequentially with `SFSpeechURLRecognitionRequest`, requiring on-device Apple
   recognition. A 20-second segment deadline includes encoding. Stop drains the
   remaining audio and queued recognition. Backlog is bounded to 60 seconds of
   PCM; overload fails explicitly rather than silently discarding segments.
4. Only final segment transcripts enter the existing command pipeline. Insertion
   checks the session, document identity, surrounding context, selection, and
   mutation generation. Partial results never edit the host field. Cancellation,
   keyboard dismissal, document changes, and memory warnings discard the direct
   attempt; stale callbacks cannot complete a newer session.

Long direct sessions compact already-inserted transcript context. At rollover,
pending command wording is inserted literally and the remaining session uses
plain text, avoiding destructive interpretation of truncated command context.

The app fallback keeps its audio engine active until Stop, renewing on-device
recognition requests at 45-second boundaries or natural finals. A bounded PCM
history transfers unprocessed audio across natural-final boundaries; an uncovered
boundary fails explicitly. Stop drains admitted callbacks and pending audio before
publishing the aggregate transcript. Shared-transcript size limits still apply.

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
