# Apple-only speech language investigation

## Status (2026-11-25)

Automatic spoken-language selection is **not enabled** in the app or keyboard.
The experiment in `Tests/AppleSpeechLanguageProbe.swift` runs Japanese and English
transcription sequentially on the same audio using Apple's on-device
SpeechAnalyzer/SpeechTranscriber. It is an executable feasibility probe, not a
production language classifier. Existing uncommitted dictation fixes are preserved.

## Public API findings

- [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
  takes one explicit locale. The existing app and keyboard adapters use this API
  with the current locale; they do not perform language identification.
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
  also takes an explicit locale. The installed iOS 27.2 SDK exposes no audio
  language-identification module. SpeechDetector detects speech activity.
- [NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer)
  identifies **text**, so applying it to a transcript already decoded with the wrong
  locale does not establish the original spoken language.
- Recognition confidence is not a documented, calibrated probability for choosing
  between locale models. Comparing it is a heuristic, not Apple's language-ID API.

No third-party service or library was used. SpeechTranscriber processes audio on
device. Apple English speech assets were downloaded onto the development Mac for
this probe; Japanese assets were already installed. Following the explicit offline
requirement, the checked-in probe now refuses missing assets and contains no download
path. The previous `--install-models` option has been removed.
On a later process launch, asset status returned `supported` again; the explicit
installation request restored readiness. Production code must recheck readiness
instead of treating a previous successful download as permanent installation.
Legacy SFSpeechRecognizer reported Japanese on-device recognition unavailable on
this Mac, while SpeechTranscriber supported it. One API's model availability must
not be used as evidence of availability in the other API or on an iPhone.

## Reproduce on macOS 26+ with the Speech SDK

```sh
xcrun swiftc -parse-as-library Tests/AppleSpeechLanguageProbe.swift Tests/AppleSpeechLanguageContext.swift -o /tmp/AppleSpeechLanguageProbe
say -v Kyoko -o /tmp/language-ja.aiff '今日は天気が良いので、午後から公園を散歩しようと思います。'
say -v Samantha -o /tmp/language-en.aiff 'The weather is beautiful today, so I am going for a walk in the park this afternoon.'
say -v Kyoko -o /tmp/language-ja-short.aiff 'はい。'
say -v Samantha -o /tmp/language-en-short.aiff 'Hi.'
say -v Kyoko -o /tmp/language-ja-command.aiff '改行'
say -v Samantha -o /tmp/language-en-command.aiff 'Delete word.'
/tmp/AppleSpeechLanguageProbe --self-test --windows /tmp/language-ja.aiff /tmp/language-en.aiff /tmp/language-ja-short.aiff /tmp/language-en-short.aiff /tmp/language-ja-command.aiff /tmp/language-en-command.aiff
```

The output includes raw confidence runs, transcripts, and elapsed time for each
file/locale pair. The context experiment additionally averages confidence runs as
an explicitly uncalibrated ASR ranking heuristic, not a language probability.
Do not pass private recordings if you intend to share
the terminal output, which contains their transcripts. No input audio is modified.

## Observed results on the development Mac

Apple synthetic voices, quiet files; these are six examples, not an accuracy study.

| Spoken input | Japanese model | English model |
| --- | --- | --- |
| Long Japanese sentence above | Correct sentence; confidence runs 0.711–1.0 | Incorrect English/romanized fragments; 0.036–0.528 |
| Long English sentence above | Mostly English with several missing letters; 0.488–0.965 | Correct sentence; 0.896–1.0 |
| Japanese はい | はい; 0.997 | Hi.; 0.86 |
| English Hi | はい; 0.608–0.696 | Hi.; 0.743 |
| Japanese 改行 | 開業; 0.57–0.612 | Kaiyo.; 0.482 |
| English Delete word | ジェリーワード; 0.113–0.514 | Delete word.; 0.621–0.633 |

Warm sequential runs took approximately 0.07–0.35 seconds per file/model, excluding
asset installation. These timings say nothing about iPhone startup, peak memory,
concurrent capture, or extension termination.

The long examples support further experimentation with a bounded Japanese/English
candidate set. The short examples expose ambiguity and a command recognition error
even with the correct language. A high transcript confidence alone is insufficient
to decide whether to change language or execute an edit command.

## Integration requirements and unverified behavior

A viable next implementation would need an explicit automatic mode with an
uncertain outcome and manual language choice, installed-model readiness before
recording, bounded candidate work, and a detected locale carried through to command
interpretation. It must retain the existing ordering, stop-tail drain, cancellation,
and external-document-change protections. Language decisions should not switch on
each tiny segment or cause ambiguous audio to execute destructive commands.

The project speech/audio skill requires containing-app SpeechAnalyzer validation
and real-device evidence before adding it to the keyboard extension. Replacing the
existing extension adapter with this probe would bypass that validation. Falling
back silently to server recognition would also invalidate an on-device claim.

Not verified: real microphone multilingual accuracy; mixed languages, accents and
noise; repeated iPhone use and memory pressure; automatic selection through the
keyboard Mic or app Start Voice Input entry points. Those entry points still use
their existing fixed locale. The probe is intentionally not wired to text insertion.
Existing UI regression tests can verify responsiveness, but cannot establish an
automatic-language feature that has not been integrated.

## Context and incremental-window follow-up

[Improving Language Identification for Multilingual Speakers](https://arxiv.org/html/2001.11019v1)
combines a trained acoustic LID model with interaction context and limits candidates
to installed locales. It retries with longer speech when confidence is insufficient.
Its trained model, internal dataset, and reported accuracy are not reproduced here.
The paper does not establish that ASR transcript confidence can replace LID posteriors.
Using surrounding text and last-confirmed language is our experimental extension,
not an API or implementation supplied by the paper.

`AppleSpeechLanguageContext` obtains text-language hypotheses using on-device
NLLanguageRecognizer from at most 256 characters on each side of a simulated cursor.
Missing, very short, numeric-only, or unsupported-language context is ignored. The
actual UITextDocumentProxy is not yet connected. The Japanese/English candidate set
is explicit; all models must already be ready. Historical language is an explicit
scenario input, never inferred from an unconfirmed suggestion.

The probe compares 1, 2, 4 seconds and the full file, bounded to 60 seconds. These
are file-start windows, not VAD-measured speech durations. Context weights are capped;
stronger sustained ASR differences override stale text/history. An unresolved prefix
waits; ambiguous final audio remains unresolved or a non-executable suggestion.
These hand-picked thresholds need a multilingual corpus before product use.

Observed in the four-file incremental run (Japanese/English long and short examples):

- Japanese long phrase became a heuristic Japanese candidate at 2 seconds, even
  with English text/history. English remained undecided at 2 seconds, then became an
  English candidate at 4 seconds despite Japanese text/history.
- English “Hi” was suggested as English with English context/history and as Japanese
  with Japanese context/history. This demonstrates **both usefulness and a genuine
  language switch missed because of stale context**, not a general accuracy improvement.
- Conflicting text/history or no context left the short English example unresolved.
- All 17 context/policy checks passed, including stale context, empty evidence,
  nonfinite values, unsupported text, and short/final utterances.

Both existing SFSpeechRecognizer adapters now require on-device support and set
`requiresOnDeviceRecognition = true` unconditionally. Unsupported locales fail
instead of sending audio to Apple servers. This can reduce availability on devices
without the required local model. Airplane-mode iPhone behavior and system-service
network traces remain unverified; API enforcement and simulator tests are distinct
from that real-device check.
