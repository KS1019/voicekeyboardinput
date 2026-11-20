# Voice Keyboard Privacy Policy

Last updated: 2026-08-02

Voice Keyboard is designed to process voice input only when you explicitly
start voice input.

## Audio and speech recognition

The keyboard opens the containing Voice Keyboard app for microphone capture.
The app configures the current audio route, including supported Bluetooth
microphones, and uses Apple speech-recognition frameworks to transcribe the
recording. Depending on Apple’s speech-recognition availability and settings,
audio may be processed by Apple’s services. Voice Keyboard does not operate an
independent speech server.

## Temporary transcript handoff

The recognized text is temporarily stored in the shared App Group container so
the keyboard extension can insert it into the text field that initiated the
request. A normal transcript handoff expires after five minutes; recovery
keeps a handoff eligible for at most six minutes, and command history is
bounded separately. Handoff records are marked as consumed and redacted after
successful insertion. Records that cannot be safely inserted are quarantined
as a no-replay fence and are retained only in a small bounded local cleanup
queue. The app and keyboard extension do not use this handoff storage for
advertising or profiling.

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
