# Offline composition and command experiment

## Try the prototype

Open the containing app → **Developer Details → Composition Lab**. Type or paste
a transcript, select **Preview draft**, and then **Commit utterance**. This is a
recognition-output simulator: it does not record audio or edit another app.

Literal mode preserves every phrase, including `改行して` and `ここから日本語`.
Explicit Command mode recognizes only whole-utterance newline and future-language
commands. `new line item`, quotations, negation, deletion requests, and unknown
instructions remain literal. After each commit the mode returns to Literal.
The language indicator is a proposed future recognizer setting, not an actual
change to the app's existing microphone locale.

Cumulative hypotheses replace the draft instead of appending duplicates. Drafts
are capped at 512 characters without silently truncating; a 160-character draft
offers review/commit. The experiment does not auto-commit partial hypotheses.
Cancel/destination change invalidates the generation so late results cannot commit.
The actual host-document identifier, selection and revision checks must remain in
the existing keyboard controller if this is integrated later. Generation alone is
not a substitute for those checks.

## Research and design comparison

| Approach | Benefit | Constraint / choice here |
| --- | --- | --- |
| Host marked text | Shows an editable composition in the destination | Host behavior and selection changes require real-device validation; not used by the lab |
| Local draft then explicit commit | Can inspect long text before any host edit | Extra action; chosen for the first experiment |
| Exact rules + explicit command mode | Predictable, offline, easily tested | Limited vocabulary; chosen for execution in the lab |
| On-device language model | Can propose paraphrased intentions and formatting | Stochastic; proposals must pass deterministic validation and cannot delete text directly |
| Always interpret natural language | Fewer mode switches | Cannot reliably distinguish literal quotation from intent; rejected as the default |

[Apple's custom-keyboard documentation](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
documents `UITextDocumentProxy.setMarkedText(_:selectedRange:)` and `unmarkText()`.
The installed SDK marks these available since iOS 13. Repeated updates replace the
marked range; unmarking leaves its text. Ranges use UTF-16 offsets, including emoji.
The proxy exposes surrounding text and document identity, but is not unrestricted
access to the host editor. A UIKit test covers replacement and unmarking with emoji;
it does not prove behavior through a third-party host's extension proxy. Never clear
or unmark a different destination after focus changes.

[Apple Voice Control](https://support.apple.com/en-ca/guide/iphone/-iph2c21a3c88/ios)
offers dictation, command and spelling modes and works offline after language assets
are prepared. This is precedent for explicit modes, not a public API to embed its
command engine. Its command mode ignores unknown utterances; our prototype retains
unknown phrases literally so the user's words are not silently lost.

[Wispr Flow Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)
uses a separate shortcut and selected-text context for spoken transformations. Its
documented desktop/iOS behavior differs; it is a UX reference, not our offline
implementation dependency. [Superwhisper](https://superwhisper.com/offline-transcription)
documents local speech models and offline transcription after model preparation.
Its product also offers cloud options; this does not establish that every mode is
offline or suitable for an iOS keyboard extension's memory/lifecycle limits.

[Tap&Say (CHI 2025)](https://doi.org/10.1145/3706598.3713376) directly studies the
dictation-versus-edit-command ambiguity and ambiguous edit locations. It combines a
touch location with spoken correction to constrain an LLM's target. Its trained
model and evaluation results are not reproduced here. The applicable design lesson
is to make edit intent and target explicit, rather than trusting voice-only intent
classification. In a keyboard extension this should mean a user-selected target
plus a bounded preview, not giving a model unrestricted document operations.

## Foundation Models probe

[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
is explicitly the on-device model. The newer Foundation Models framework also has
cloud providers, so the framework name alone is not an offline guarantee. The probe
uses only `SystemLanguageModel.default`, checks availability, supplies no tools, and
generates a closed intent enum. No model download or cloud fallback is implemented.

```sh
xcrun swiftc -parse-as-library Tests/OfflineCommandModelProbe.swift -o /tmp/OfflineCommandModelProbe
/tmp/OfflineCommandModelProbe
```

The six examples include negation, quotation, ambiguous wording and deletion. Model
output is logged as a **proposal**, never executed. Even a well-formed generated enum
does not prove correct intent. A production model-assisted path would need separate
user activation, stale-result rejection, supported-language/availability checks,
bounded draft input, and a deterministic allowlist; destructive transformations
would require reviewing the exact replacement. Rule-only/literal behavior remains
available when the model is missing or fails.

On the development Mac, the compiled probe returned `unavailable(modelNotReady)`.
It exited without generation or a cloud fallback. Foundation Models intent accuracy
is therefore **not measured** here; the rule-based lab remains usable independently.

## Integration boundary

The existing direct keyboard continues ordered segment insertion and its current
whole-transcript command handling. The lab does not reinterpret already inserted
text. A future integration should accumulate uncertain text locally, retain the
original audio until its language is resolved, and commit only finalized utterances
against the original field/selection/revision. A language command affects the next
utterance, never silently retranscribes committed text. Missing recognition segments
must continue disabling risky command interpretation as the existing path does.

Not verified: microphone-to-lab integration, third-party host marked-text behavior,
real-device Foundation Models performance/memory, mixed-language accuracy, and
airplane-mode device operation. No production automatic language switching or LLM
editing is claimed by this prototype.

## Verification on 2026-11-25

- Signed iOS simulator build succeeded. UIKit suite: 76 tests passed, including 8
  new draft/marked-text checks; the 8 new checks were also rerun successfully.
- Start Voice Input and QA focus responsiveness UI tests passed. The new lab UI test
  passed after correcting offscreen-element scrolling and dismissing the keyboard
  on preview/commit. It opens the app's Developer Details entry, previews without
  insertion, commits literal `new line`, then changes the lab language to `ja-JP`
  in Command mode without changing the previously committed text.
- Language-context executable compiled; 17 checks passed. Incremental recognition
  ran with preinstalled assets and no model-installation path.
- WebKit, dependency and keyboard-permission policy checks passed. Generated project
  and Info.plists were unchanged by a second generation pass; `git diff --check`
  passed. Read-only independent review found no actionable defect in this scope.
- Foundation Models executable compiled but reported `modelNotReady`; no model
  inference accuracy or latency result is claimed.

Local logs: `/tmp/voice-composition-tests.log`, `/tmp/voice-composition-final.log`,
`/tmp/voice-composition-ui-verified.log`, `/tmp/voice-language-context.log`,
`/tmp/voice-language-context-checks.log`, `/tmp/voice-command-model.log`, and
`/tmp/voice-offline-policy.log`. The first two test logs include earlier UI failures;
the final UI log records the corrected successful test, not a claimed all-green
initial run.
