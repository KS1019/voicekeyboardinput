# Voice Keyboard Privacy Policy

Last updated: 2026-11-25

Voice Keyboard is designed to process voice input only when you explicitly
start voice input.

## Audio and speech recognition

After microphone and Speech permissions have been granted in the containing
app and Full Access is enabled, the keyboard can attempt experimental WebKit
microphone capture without opening the app. Capture begins only when you tap
the microphone control. Preloading the recording page does not activate the
microphone. The keyboard displays capture and processing states; stopping
capture drains the final audio segment through on-device Apple Speech recognition.
Finalized segments can be recognized and inserted while recording continues. Leaving the
keyboard or cancelling discards the attempt. Recordings are limited to one
minute. Temporary audio files are deleted when the attempt finishes or is
cancelled; no audio history is maintained.

If capture cannot start, the keyboard falls back to the containing Voice
Keyboard app. The app configures the current audio route, including supported
Bluetooth microphones, and uses Apple speech-recognition frameworks. WebKit
capture in a keyboard is not guaranteed to work on every iOS version or device.
Both recognition paths require on-device recognition and reject unsupported local
recognizers. There is no fallback to Apple server recognition or a third-party
transcription provider. Required speech assets must already be available; voice
input does not download models. Voice Keyboard does not operate a speech server.

## Temporary transcript handoff

For containing-app dictation, recognized text is temporarily stored in the shared App Group container so
the keyboard extension can insert it into the text field that initiated the
request. A normal transcript handoff expires after five minutes; recovery
keeps a handoff eligible for at most six minutes, and command history is
bounded separately. Handoff records are marked as consumed and redacted after
successful insertion. Records that cannot be safely inserted are quarantined
as a no-replay fence and are retained only in a small bounded local cleanup
queue. The app and keyboard extension do not use this handoff storage for
advertising or profiling.

A successful in-keyboard result is inserted into the originating text field after
checking that the field has not changed. Partial recognition results are not
inserted into the document.

## Deletion and consent withdrawal

To delete local Voice Keyboard data, stop any active dictation and uninstall
both the Voice Keyboard app and its keyboard extension from the device. To
withdraw permission without uninstalling, turn off Microphone and Speech
Recognition access in Settings, or stop voice input; no new recording is
started without an explicit user action and the required permission.

Voice Keyboard does not provide an account or an independent speech server, so
it has no server-side user profile or transcript store to delete. If a privacy
request concerns a diagnostic build or a copy of this source repository, open
an issue using the contact link below.

## Analytics and tracking

Voice Keyboard does not include advertising SDKs, cross-app tracking, or an
analytics service.

## Changes and contact

This policy may be updated when Voice Keyboard’s data practices change. For
questions or privacy requests, please open an issue in the project repository:

<https://github.com/KS1019/voicekeyboardinput/issues>
