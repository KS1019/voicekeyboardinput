# In-keyboard WebKit dictation

Approved direction: WebKit capture with existing Apple Speech. The user authorized recommended decisions without further review and unsigned builds only.

## Baseline

Existing changes were verified by strict Swift package tests, unsigned iOS build, and dependency/permission policy checks, committed as b270635 and pushed to origin/main. Build output directories remain untracked and untouched. Existing production capture runs in the containing app; extension direct adapters are excluded.

## Behavior

Preload a local inline HTML document in a noninteractive 2×2 pt WKWebView at alpha 0.02 in viewDidAppear. Enable inline playback and remove media user-action requirement. Use a fixed synthetic HTTPS origin and permit only this main frame's microphone request, only during a user-started capture with previously granted microphone permission and Full Access. Preloading must never request capture.

On explicit microphone tap, getUserMedia requests mono audio with automatic gain control. ScriptProcessor converts source-rate samples into continuous 16 kHz little-endian Int16 base64 chunks. Validate messages, bound chunk size, recording duration and memory. Declare capture started only after receiving real PCM; after 2 seconds without PCM stop/dispose capture and use the existing containing-app handoff. Late completions must not restart a canceled capture. Block navigation to external documents.

Use Apple Speech through a separate adapter, without AVAudioEngine microphone capture. Prefer final-file recognition: accumulate at most 60 seconds, normalize conservatively, encode m4a, recognize with SFSpeechURLRecognitionRequest, clean up temporary audio on every terminal path. Speech authorization must already be granted in the app; no extension permission onboarding. Keep partial hypotheses out of the host document. Insert only a final result using the existing guarded text insertion path. Preserve Japanese locale support and existing command parsing. No external STT provider or secret configuration is added.

Stop button finalizes capture and recognizes; cancellation, focus/document changes, keyboard dismissal, memory warnings and deallocation discard capture and results. Separate finish from cancel. Processing has a bounded timeout. All callbacks carry a session identity to reject stale results. Display recording/processing/error states using existing keyboard presentation. Do not automatically start recording in the app after a transcription failure; offer retry/error instead. Startup failures may use the existing handoff.

## Validation and limits

Test PCM validation/normalization, sample-rate conversion, startup timeout/late message handling, finish vs cancel, permissions/origin gating, and final-only insertion with session identity. Run strict package tests, unsigned simulator build and relevant UIKit tests; inspect generated project drift. Add real-device QA for repeated use, denial, multiple hosts, interruptions and disappearance. WebKit keyboard capture remains an explicitly unvalidated experiment until real iPhone testing: public WebKit API availability is not proof of keyboard microphone support.

The unclear phrase “GTテキスト / Inup” is not treated as authorization to choose an unidentified third-party service. Existing text pipeline and Apple Speech remain replaceable. No Foundation Models or heavy model initialization in extension.
