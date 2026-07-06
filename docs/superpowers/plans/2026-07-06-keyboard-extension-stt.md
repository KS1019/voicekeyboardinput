# Keyboard Extension STT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first keyboard-extension speech-to-text path, with explicit failure reasons and diagnostics, so the keyboard microphone button attempts real STT and inserts final recognized text.

**Architecture:** Shared package modules define speech errors, keyboard recognition states, presentation snapshots, and fake-service test coverage. `VoiceKeyboardExtension` owns the concrete AVFAudio + Speech adapter and UIKit integration. Runtime failures are reported as typed `SpeechRecognitionError` values and logged through `os.Logger`.

**Tech Stack:** Swift 6, iOS 26+ deployment target, UIKit keyboard extension, AVFAudio, Speech framework `SpeechAnalyzer`, `SpeechTranscriber`, `AnalyzerInputConverter`, XcodeGen project generation, XCTest.

## Global Constraints

- Keep shared speech/audio models, value objects, interfaces, and presentation snapshots in `Packages/VoiceKeyboardPackage`.
- Keep UIKit rendering in `VoiceKeyboardUIKit`; exclude previews from the extension target.
- Keep extension code safe under `APPLICATION_EXTENSION_API_ONLY`.
- Do not add AuralKit, WhisperKit, Foundation Models, network recognition, or app-to-extension transcription relay.
- Do not make the first keyboard STT path depend on `RequestsOpenAccess`.
- Do not claim real keyboard STT works until manual QA passes on a physical iOS 26+ device.
- Preserve transcript privacy in diagnostics; do not log dictated text.
- Run narrow-to-broad verification: `make package-strict-test`, `make build`, `make ui-kit-test`, `make app-ui-test`, `make preview-layout-test`, `make generated-check`.

---

## File Structure

- Modify `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/SpeechModels.swift`: expand `SpeechRecognitionError`.
- Modify `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/KeyboardSpeechCaptureState.swift`: add STT runtime states while preserving existing probe states.
- Modify `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardPresentation/SpeechCapturePresentationSnapshot+KeyboardState.swift`: map STT states to UI copy.
- Modify `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardInterfaces/SpeechRecognitionService.swift`: keep the protocol boundary and document typed failure behavior.
- Add `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/KeyboardSpeechRecognitionSession.swift`: fake-testable coordinator from `SpeechRecognitionService` updates to presentation states and text operations.
- Add `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/KeyboardSpeechRecognitionSessionTests.swift`: package-level fake service tests.
- Modify `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift`: error value tests.
- Modify `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardPresentationTests/SpeechCapturePresentationSnapshotKeyboardStateTests.swift`: STT presentation tests.
- Modify `VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift`: rendering tests for listening/transcribing/inserted/failed.
- Add `VoiceKeyboardExtension/KeyboardSpeechRecognitionDiagnostics.swift`: compact `os.Logger` diagnostic wrapper.
- Add `VoiceKeyboardExtension/KeyboardSpeechRecognitionService.swift`: real keyboard adapter using AVFAudio and Speech.
- Modify `VoiceKeyboardExtension/KeyboardSpeechCaptureCoordinator.swift`: start/stop recognition and stream snapshots.
- Modify `VoiceKeyboardExtension/KeyboardViewController.swift`: call recognition path, insert final text operations through `textDocumentProxy`.
- Modify `Makefile`: allow `import Speech` in the extension now that keyboard-side STT is the product direction; keep `UIApplication.shared` and `FoundationModels` forbidden.
- Modify `VoiceKeyboardExtension/Info.plist` and `project.yml`: add extension `NSSpeechRecognitionUsageDescription`.
- Modify `docs/qa/keyboard-extension-manual-qa.md`: add keyboard STT manual QA and diagnostic expectations.

## Task 1: Shared STT State And Presentation

**Files:**
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/SpeechModels.swift`
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/KeyboardSpeechCaptureState.swift`
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardPresentation/SpeechCapturePresentationSnapshot+KeyboardState.swift`
- Test: `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift`
- Test: `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardPresentationTests/SpeechCapturePresentationSnapshotKeyboardStateTests.swift`
- Test: `VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift`

**Interfaces:**
- Consumes: existing `SpeechRecognitionUpdate`, `KeyboardSpeechCaptureState`, `SpeechCapturePresentationSnapshot.keyboardSpeechCapture(_:)`.
- Produces: expanded `SpeechRecognitionError`, STT states in `KeyboardSpeechCaptureState`, and UI snapshots consumed by Tasks 2-4.

- [ ] **Step 1: Write failing model tests for expanded speech errors**

Add to `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift`:

```swift
func testSpeechRecognitionErrorsCompareByValue() {
    XCTAssertEqual(
        SpeechRecognitionError.audioSessionActivationFailed("setActive failed"),
        .audioSessionActivationFailed("setActive failed")
    )
    XCTAssertNotEqual(
        SpeechRecognitionError.audioSessionActivationFailed("setActive failed"),
        .audioEngineStartFailed("engine failed")
    )
    XCTAssertEqual(SpeechRecognitionError.microphonePermissionDenied, .microphonePermissionDenied)
    XCTAssertEqual(SpeechRecognitionError.cancelled, .cancelled)
}
```

- [ ] **Step 2: Write failing presentation tests for STT states**

Add to `SpeechCapturePresentationSnapshotKeyboardStateTests`:

```swift
func testListeningStateMapsToActiveCapture() {
    let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.listening)

    XCTAssertEqual(snapshot.transcriptText, "Listening...")
    XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
    XCTAssertEqual(snapshot.microphoneTitle, "Stop")
    XCTAssertEqual(snapshot.microphoneTone, .positive)
    XCTAssertEqual(snapshot.activeMicrophoneBars, .ready)
    XCTAssertEqual(snapshot.voiceActivityState, .listening(level: nil))
}

func testTranscribingStateShowsPartialTranscript() {
    let update = SpeechRecognitionUpdate(transcript: "hello wor", isFinal: false, inputLevel: 0.6)
    let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.transcribing(update))

    XCTAssertEqual(snapshot.transcriptText, "hello wor")
    XCTAssertEqual(snapshot.statusText, "Transcribing...")
    XCTAssertEqual(snapshot.microphoneTitle, "Stop")
    XCTAssertEqual(snapshot.microphoneTone, .positive)
    XCTAssertEqual(snapshot.voiceActivityState, .listening(level: update.inputLevel))
}

func testInsertedStateShowsInsertedText() {
    let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(.inserted("hello world"))

    XCTAssertEqual(snapshot.transcriptText, "hello world")
    XCTAssertEqual(snapshot.statusText, "Inserted.")
    XCTAssertEqual(snapshot.microphoneTitle, "Speak")
    XCTAssertEqual(snapshot.microphoneTone, .positive)
    XCTAssertEqual(snapshot.voiceActivityState, .idle)
}

func testRecognitionFailedStateShowsSpecificUnavailableReason() {
    let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
        .recognitionFailed(.speechRecognizerUnavailable)
    )

    XCTAssertEqual(snapshot.transcriptText, "Speech recognition is unavailable in this keyboard.")
    XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
    XCTAssertEqual(snapshot.microphoneTitle, "Speech unavailable")
    XCTAssertEqual(snapshot.microphoneTone, .critical)
    XCTAssertEqual(snapshot.voiceActivityState, .unavailable)
}

func testRecognitionFailedStateShowsRetryableFailure() {
    let snapshot = SpeechCapturePresentationSnapshot.keyboardSpeechCapture(
        .recognitionFailed(.audioEngineStartFailed("engine failed"))
    )

    XCTAssertEqual(snapshot.transcriptText, "Voice input failed in this keyboard.")
    XCTAssertEqual(snapshot.statusText, snapshot.transcriptText)
    XCTAssertEqual(snapshot.microphoneTitle, "Retry")
    XCTAssertEqual(snapshot.microphoneTone, .critical)
    XCTAssertEqual(snapshot.voiceActivityState, .idle)
}
```

- [ ] **Step 3: Write failing UIKit rendering tests**

Add to `VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift`:

```swift
func testListeningSpeechCaptureKeepsMicrophoneEnabledAsStopButton() throws {
    let view = KeyboardRootView()

    view.render(speechCapture: .keyboardSpeechCapture(.listening))
    let button = try microphoneButton(in: view)

    XCTAssertTrue(button.isEnabled)
    XCTAssertEqual(button.configuration?.title, "Stop")
}

func testRecognitionUnavailableDisablesMicrophoneButton() throws {
    let view = KeyboardRootView()

    view.render(speechCapture: .keyboardSpeechCapture(.recognitionFailed(.speechRecognizerUnavailable)))

    XCTAssertFalse(try microphoneButton(in: view).isEnabled)
}
```

- [ ] **Step 4: Run tests and verify they fail**

Run:

```bash
make package-strict-test
make ui-kit-test
```

Expected: failures because `KeyboardSpeechCaptureState.listening`, `.transcribing`, `.inserted`, `.recognitionFailed`, and expanded `SpeechRecognitionError` cases do not exist yet.

- [ ] **Step 5: Expand speech error and keyboard state models**

Replace `SpeechRecognitionError` in `SpeechModels.swift` with:

```swift
public enum SpeechRecognitionError: Error, Equatable, Sendable {
    case unavailableInCurrentProcess
    case microphonePermissionDenied
    case microphonePermissionUndetermined
    case audioSessionActivationFailed(String)
    case audioInputUnavailable
    case audioEngineStartFailed(String)
    case speechRecognizerUnavailable
    case speechAuthorizationDenied
    case recognitionStartFailed(String)
    case recognitionFailed(String)
    case cancelled
}
```

Extend `KeyboardSpeechCaptureState` in `KeyboardSpeechCaptureState.swift`:

```swift
public enum KeyboardSpeechCaptureState: Equatable, Sendable {
    case containingAppLaunchRequired
    case unavailable(KeyboardSpeechCaptureUnavailableReason)
    case probeNeeded
    case probing
    case ready
    case probeFailed(AudioCaptureProbeError)
    case listening
    case transcribing(SpeechRecognitionUpdate)
    case inserted(String)
    case recognitionFailed(SpeechRecognitionError)
}
```

- [ ] **Step 6: Map new STT states to presentation snapshots**

Add cases to `SpeechCapturePresentationSnapshot.keyboardSpeechCapture(_:)`:

```swift
case .listening:
    return SpeechCapturePresentationSnapshot(
        transcriptText: "Listening...",
        statusText: "Listening...",
        microphoneTitle: "Stop",
        microphoneTone: .positive,
        activeMicrophoneBars: .ready,
        voiceActivityState: .listening(level: nil)
    )

case let .transcribing(update):
    return SpeechCapturePresentationSnapshot(
        transcriptText: update.transcript.isEmpty ? "Listening..." : update.transcript,
        statusText: "Transcribing...",
        microphoneTitle: "Stop",
        microphoneTone: .positive,
        activeMicrophoneBars: .ready,
        voiceActivityState: .listening(level: update.inputLevel)
    )

case let .inserted(text):
    return SpeechCapturePresentationSnapshot(
        transcriptText: text,
        statusText: "Inserted.",
        microphoneTitle: "Speak",
        microphoneTone: .positive,
        activeMicrophoneBars: .ready,
        voiceActivityState: .idle
    )

case let .recognitionFailed(error):
    return failedKeyboardSpeechCapture(error)
```

Add helper:

```swift
private static func failedKeyboardSpeechCapture(
    _ error: SpeechRecognitionError
) -> SpeechCapturePresentationSnapshot {
    let message: String
    let title: String
    let isUnavailable: Bool

    switch error {
    case .microphonePermissionDenied:
        message = "Microphone permission is denied for this keyboard."
        title = "Mic denied"
        isUnavailable = true
    case .microphonePermissionUndetermined:
        message = "Microphone permission is not decided for this keyboard."
        title = "Mic setup"
        isUnavailable = true
    case .audioInputUnavailable:
        message = "Microphone input is unavailable in this keyboard."
        title = "Mic unavailable"
        isUnavailable = true
    case .speechRecognizerUnavailable:
        message = "Speech recognition is unavailable in this keyboard."
        title = "Speech unavailable"
        isUnavailable = true
    case .speechAuthorizationDenied:
        message = "Speech recognition permission is denied."
        title = "Speech denied"
        isUnavailable = true
    case .cancelled:
        message = "Voice input stopped."
        title = "Speak"
        isUnavailable = false
    case .unavailableInCurrentProcess,
         .audioSessionActivationFailed,
         .audioEngineStartFailed,
         .recognitionStartFailed,
         .recognitionFailed:
        message = "Voice input failed in this keyboard."
        title = "Retry"
        isUnavailable = false
    }

    return SpeechCapturePresentationSnapshot(
        transcriptText: message,
        statusText: message,
        microphoneTitle: title,
        microphoneTone: .critical,
        activeMicrophoneBars: .inactive,
        voiceActivityState: isUnavailable ? .unavailable : .idle
    )
}
```

- [ ] **Step 7: Run tests and verify they pass**

Run:

```bash
make package-strict-test
make ui-kit-test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/SpeechModels.swift \
  Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/KeyboardSpeechCaptureState.swift \
  Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardPresentation/SpeechCapturePresentationSnapshot+KeyboardState.swift \
  Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardModelsTests/SpeechRecognitionUpdateTests.swift \
  Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardPresentationTests/SpeechCapturePresentationSnapshotKeyboardStateTests.swift \
  VoiceKeyboardUIKitTests/KeyboardRootViewTests.swift
git commit -m "feat: model keyboard speech recognition states"
```

## Task 2: Fake-Tested Recognition Session Core

**Files:**
- Add: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/KeyboardSpeechRecognitionSession.swift`
- Test: `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/KeyboardSpeechRecognitionSessionTests.swift`
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/VoiceKeyboardCore.docc/VoiceKeyboardCore.md`

**Interfaces:**
- Consumes: `SpeechRecognitionService.start(locale:)`, `SpeechRecognitionUpdate`, `VoiceInputPipeline.operations(for:documentContextBeforeInput:)`.
- Produces: `KeyboardSpeechRecognitionSession`, `KeyboardSpeechRecognitionEvent`, and `KeyboardTextInsertionAction` for extension integration.

- [ ] **Step 1: Write failing tests with a fake speech service**

Create `KeyboardSpeechRecognitionSessionTests.swift`:

```swift
import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import XCTest

final class KeyboardSpeechRecognitionSessionTests: XCTestCase {
    func testStartEmitsListeningThenTranscribingThenInsertion() async {
        let service = FakeSpeechRecognitionService(updates: [
            SpeechRecognitionUpdate(transcript: "hello", isFinal: false, inputLevel: 0.4),
            SpeechRecognitionUpdate(transcript: "hello world", isFinal: true, inputLevel: 0.8)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.map(\.state), [
            .listening,
            .transcribing(SpeechRecognitionUpdate(transcript: "hello", isFinal: false, inputLevel: 0.4)),
            .inserted("hello world")
        ])
        XCTAssertEqual(events.last?.actions, [.insertText("hello world")])
    }

    func testFinalCommandTranscriptProducesDeleteAction() async {
        let service = FakeSpeechRecognitionService(updates: [
            SpeechRecognitionUpdate(transcript: "delete word", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: "hello world"
        ))

        XCTAssertEqual(events.last?.actions, [.deleteBackward(count: TextDeletionCount(5)! )])
    }

    func testStartFailureEmitsRecognitionFailed() async {
        let service = FakeSpeechRecognitionService(startError: .microphonePermissionDenied)
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: nil
        ))

        XCTAssertEqual(events.map(\.state), [.listening, .recognitionFailed(.microphonePermissionDenied)])
        XCTAssertEqual(events.last?.actions, [])
    }
}

private struct FakeSpeechRecognitionService: SpeechRecognitionService {
    var updates: [SpeechRecognitionUpdate] = []
    var startError: SpeechRecognitionError?

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        if let startError { throw startError }
        return SpeechRecognitionUpdateStream { continuation in
            for update in updates {
                continuation.yield(update)
            }
            continuation.finish()
        }
    }

    func stop() async {}
}

private func collect(
    _ stream: AsyncStream<KeyboardSpeechRecognitionEvent>
) async -> [KeyboardSpeechRecognitionEvent] {
    var events: [KeyboardSpeechRecognitionEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
cd Packages/VoiceKeyboardPackage && env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache swift test --filter KeyboardSpeechRecognitionSessionTests
```

Expected: FAIL because `KeyboardSpeechRecognitionSession`, `KeyboardSpeechRecognitionEvent`, and `KeyboardTextInsertionAction` do not exist.

- [ ] **Step 3: Implement the session and action types**

Create `KeyboardSpeechRecognitionSession.swift`:

```swift
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

public struct KeyboardSpeechRecognitionEvent: Equatable, Sendable {
    public let state: KeyboardSpeechCaptureState
    public let actions: [KeyboardTextInsertionAction]

    public init(
        state: KeyboardSpeechCaptureState,
        actions: [KeyboardTextInsertionAction] = []
    ) {
        self.state = state
        self.actions = actions
    }
}

public enum KeyboardTextInsertionAction: Equatable, Sendable {
    case insertText(String)
    case deleteBackward(count: TextDeletionCount)
}

public struct KeyboardSpeechRecognitionSession: Sendable {
    private let speechService: any SpeechRecognitionService
    private let pipeline: VoiceInputPipeline

    public init(
        speechService: any SpeechRecognitionService,
        pipeline: VoiceInputPipeline
    ) {
        self.speechService = speechService
        self.pipeline = pipeline
    }

    public func events(
        locale: VoiceKeyboardLocale,
        documentContextBeforeInput: String?
    ) -> AsyncStream<KeyboardSpeechRecognitionEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(KeyboardSpeechRecognitionEvent(state: .listening))
                do {
                    let updates = try await speechService.start(locale: locale)
                    for try await update in updates {
                        guard !Task.isCancelled else { break }
                        if update.isFinal {
                            let actions = actions(
                                transcript: update.transcript,
                                documentContextBeforeInput: documentContextBeforeInput
                            )
                            continuation.yield(
                                KeyboardSpeechRecognitionEvent(
                                    state: .inserted(insertedText(from: actions, fallback: update.transcript)),
                                    actions: actions
                                )
                            )
                        } else {
                            continuation.yield(KeyboardSpeechRecognitionEvent(state: .transcribing(update)))
                        }
                    }
                    await speechService.stop()
                    continuation.finish()
                } catch let error as SpeechRecognitionError {
                    await speechService.stop()
                    continuation.yield(KeyboardSpeechRecognitionEvent(state: .recognitionFailed(error)))
                    continuation.finish()
                } catch is CancellationError {
                    await speechService.stop()
                    continuation.yield(KeyboardSpeechRecognitionEvent(state: .recognitionFailed(.cancelled)))
                    continuation.finish()
                } catch {
                    await speechService.stop()
                    continuation.yield(
                        KeyboardSpeechRecognitionEvent(state: .recognitionFailed(.recognitionFailed(String(describing: error))))
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func actions(
        transcript: String,
        documentContextBeforeInput: String?
    ) -> [KeyboardTextInsertionAction] {
        pipeline.operations(for: transcript, documentContextBeforeInput: documentContextBeforeInput).compactMap { operation in
            switch operation {
            case let .insertText(value):
                return .insertText(value)
            case let .deleteBackward(count):
                return .deleteBackward(count: count)
            case .showUnsupportedCommand:
                return nil
            }
        }
    }

    private func insertedText(
        from actions: [KeyboardTextInsertionAction],
        fallback: String
    ) -> String {
        let text = actions.reduce(into: "") { result, action in
            if case let .insertText(value) = action {
                result.append(value)
            }
        }
        return text.isEmpty ? fallback : text
    }
}
```

- [ ] **Step 4: Update package docs**

Append one sentence to `VoiceKeyboardCore.docc/VoiceKeyboardCore.md`:

```markdown
`KeyboardSpeechRecognitionSession` turns a platform `SpeechRecognitionService` stream into keyboard presentation states and insertion actions without depending on UIKit, AVFAudio, or Speech framework APIs.
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
make package-strict-test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/KeyboardSpeechRecognitionSession.swift \
  Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/VoiceKeyboardCore.docc/VoiceKeyboardCore.md \
  Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/KeyboardSpeechRecognitionSessionTests.swift
git commit -m "feat: add keyboard recognition session core"
```

## Task 3: Keyboard Speech Adapter And Diagnostics

**Files:**
- Add: `VoiceKeyboardExtension/KeyboardSpeechRecognitionDiagnostics.swift`
- Add: `VoiceKeyboardExtension/KeyboardSpeechRecognitionService.swift`
- Modify: `VoiceKeyboardExtension/Info.plist`
- Modify: `project.yml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `SpeechRecognitionService`, `SpeechRecognitionUpdateStream`, expanded `SpeechRecognitionError`.
- Produces: `KeyboardSpeechRecognitionService` concrete adapter for the extension.

- [ ] **Step 1: Add extension speech usage description**

In `project.yml`, add under `VoiceKeyboardExtension.info.properties`:

```yaml
NSSpeechRecognitionUsageDescription: Voice Keyboard uses speech recognition only when you explicitly start keyboard voice input.
```

In `VoiceKeyboardExtension/Info.plist`, add:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Voice Keyboard uses speech recognition only when you explicitly start keyboard voice input.</string>
```

- [ ] **Step 2: Update extension dependency policy**

In `Makefile`, change:

```make
FORBIDDEN_EXTENSION_APIS := 'UIApplication[.]shared|^[[:space:]]*import[[:space:]]+(Speech|FoundationModels)\b'
```

to:

```make
FORBIDDEN_EXTENSION_APIS := 'UIApplication[.]shared|^[[:space:]]*import[[:space:]]+FoundationModels\b'
```

This keeps app-only UI and Foundation Models out of the extension while allowing the planned keyboard-side Speech adapter.

- [ ] **Step 3: Add diagnostics wrapper**

Create `KeyboardSpeechRecognitionDiagnostics.swift`:

```swift
import Foundation
import os
import VoiceKeyboardModels

struct KeyboardSpeechRecognitionDiagnostics: Sendable {
    private let logger = Logger(
        subsystem: "com.ks1019.voicekeyboardinput.keyboard",
        category: "KeyboardSpeechRecognition"
    )

    func event(_ name: String, metadata: [String: String] = [:]) {
        let details = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("\(name, privacy: .public) \(details, privacy: .public)")
    }

    func failure(_ name: String, error: SpeechRecognitionError) {
        logger.error("\(name, privacy: .public) \(String(describing: error), privacy: .public)")
    }
}
```

- [ ] **Step 4: Add real keyboard speech service**

Create `KeyboardSpeechRecognitionService.swift` with this structure. Use the Xcode 27 SDK symbols verified in `Speech.swiftinterface`: `SpeechAnalyzer`, `SpeechTranscriber`, `AnalyzerInputConverter`, and `AnalyzerInput`.

```swift
import AVFAudio
import Foundation
import Speech
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

actor KeyboardSpeechRecognitionService: SpeechRecognitionService {
    private let diagnostics: KeyboardSpeechRecognitionDiagnostics
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var recognitionTask: Task<Void, Never>?

    init(diagnostics: KeyboardSpeechRecognitionDiagnostics = KeyboardSpeechRecognitionDiagnostics()) {
        self.diagnostics = diagnostics
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        diagnostics.event("start", metadata: ["locale": locale.identifier])
        guard AVAudioApplication.shared.recordPermission == .granted else {
            let error: SpeechRecognitionError = AVAudioApplication.shared.recordPermission == .denied
                ? .microphonePermissionDenied
                : .microphonePermissionUndetermined
            diagnostics.failure("permission", error: error)
            throw error
        }

        guard SpeechTranscriber.isAvailable else {
            diagnostics.failure("availability", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: locale.identifier)
        ) else {
            diagnostics.failure("locale", error: .speechRecognizerUnavailable)
            throw .speechRecognizerUnavailable
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            diagnostics.event("audio-session-active")
        } catch {
            let mapped = SpeechRecognitionError.audioSessionActivationFailed(String(describing: error))
            diagnostics.failure("audio-session", error: mapped)
            throw mapped
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            diagnostics.failure("audio-input", error: .audioInputUnavailable)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw .audioInputUnavailable
        }

        diagnostics.event("audio-format", metadata: [
            "channels": "\(naturalFormat.channelCount)",
            "sampleRate": "\(naturalFormat.sampleRate)"
        ])

        do {
            try await analyzer.prepareToAnalyze(in: naturalFormat)
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("prepare", error: mapped)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw mapped
        }

        let inputStream = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
            self.inputContinuation = continuation
        }
        let converter: AnalyzerInputConverter
        do {
            converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        } catch {
            let mapped = SpeechRecognitionError.recognitionStartFailed(String(describing: error))
            diagnostics.failure("converter", error: mapped)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw mapped
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { [weak self] buffer, time in
            guard let self else { return }
            Task {
                do {
                    let inputs = try converter.convert(buffer, at: time)
                    for input in inputs {
                        await self.yield(input)
                    }
                } catch {
                    await self.finishInput(throwing: error)
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            diagnostics.event("audio-engine-started")
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            let mapped = SpeechRecognitionError.audioEngineStartFailed(String(describing: error))
            diagnostics.failure("audio-engine", error: mapped)
            throw mapped
        }

        self.engine = engine
        recognitionTask = Task {
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                await self.finishInput(throwing: error)
            }
        }

        return SpeechRecognitionUpdateStream { continuation in
            Task {
                do {
                    for try await result in transcriber.results {
                        let transcript = String(result.text.characters)
                        continuation.yield(
                            SpeechRecognitionUpdate(
                                transcript: transcript,
                                isFinal: result.isFinal,
                                inputLevel: nil
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SpeechRecognitionError.recognitionFailed(String(describing: error)))
                }
            }
        }
    }

    func stop() async {
        diagnostics.event("stop")
        recognitionTask?.cancel()
        recognitionTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        inputContinuation?.finish()
        inputContinuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func yield(_ input: AnalyzerInput) {
        inputContinuation?.yield(input)
    }

    private func finishInput(throwing error: Error) {
        inputContinuation?.finish(throwing: error)
    }
}
```

- [ ] **Step 5: Run build and fix adapter-local compiler issues**

Run:

```bash
make build
```

Expected: PASS. If the adapter has compiler errors, keep fixes inside `VoiceKeyboardExtension/KeyboardSpeechRecognitionService.swift` or `VoiceKeyboardExtension/KeyboardSpeechRecognitionDiagnostics.swift`.

- [ ] **Step 6: Regenerate project if needed**

Run:

```bash
make generate
make generated-check
```

Expected: generated `Info.plist` and `project.pbxproj` match `project.yml`.

- [ ] **Step 7: Commit**

```bash
git add VoiceKeyboardExtension/KeyboardSpeechRecognitionDiagnostics.swift \
  VoiceKeyboardExtension/KeyboardSpeechRecognitionService.swift \
  VoiceKeyboardExtension/Info.plist \
  VoiceKeyboardInput.xcodeproj/project.pbxproj \
  project.yml \
  Makefile
git commit -m "feat: add keyboard speech recognition adapter"
```

## Task 4: Wire Keyboard Button To Recognition And Text Insertion

**Files:**
- Modify: `VoiceKeyboardExtension/KeyboardSpeechCaptureCoordinator.swift`
- Modify: `VoiceKeyboardExtension/KeyboardViewController.swift`

**Interfaces:**
- Consumes: `KeyboardSpeechRecognitionSession.events(locale:documentContextBeforeInput:)`, `KeyboardTextInsertionAction`, `SpeechCapturePresentationSnapshot.keyboardSpeechCapture(_:)`.
- Produces: keyboard microphone tap starts/stops recognition and inserts final text actions.

- [ ] **Step 1: Update coordinator to own recognition session**

Change `KeyboardSpeechCaptureCoordinator` initializer to accept a speech service:

```swift
private let recognitionSession: KeyboardSpeechRecognitionSession

init(
    capabilityChecker: any CapabilityChecking = KeyboardAudioCapabilityChecker(),
    audioProbe: (any AudioCaptureProbing)? = KeyboardAudioInputProbe(),
    speechService: any SpeechRecognitionService = KeyboardSpeechRecognitionService(),
    stateMachine: KeyboardSpeechCaptureStateMachine = KeyboardSpeechCaptureStateMachine()
) {
    self.capabilityChecker = capabilityChecker
    readinessService = KeyboardSpeechCaptureReadinessService(
        capabilityChecker: capabilityChecker,
        audioProbe: audioProbe,
        stateMachine: stateMachine
    )
    recognitionSession = KeyboardSpeechRecognitionSession(
        speechService: speechService,
        pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: Locale.current.identifier))
    )
}
```

Add:

```swift
func recognitionEvents(
    locale: VoiceKeyboardLocale,
    documentContextBeforeInput: String?
) -> AsyncStream<KeyboardSpeechRecognitionEvent> {
    recognitionSession.events(
        locale: locale,
        documentContextBeforeInput: documentContextBeforeInput
    )
}
```

- [ ] **Step 2: Update microphone action in controller**

Replace the probe/open-app behavior in `KeyboardViewController.microphoneTapped()` with recognition streaming:

```swift
@objc private func microphoneTapped() {
    renderTask?.cancel()

    let speechCaptureCoordinator = speechCaptureCoordinator
    let locale = VoiceKeyboardLocale(identifier: Locale.current.identifier)
    let context = textDocumentProxy.documentContextBeforeInput

    renderTask = Task { [weak self] in
        for await event in speechCaptureCoordinator.recognitionEvents(
            locale: locale,
            documentContextBeforeInput: context
        ) {
            guard !Task.isCancelled else { return }
            guard let self else { return }
            keyboardRootView.render(
                speechCapture: .keyboardSpeechCapture(event.state),
                announce: true
            )
            apply(event.actions)
        }
    }
}
```

Add:

```swift
private func apply(_ actions: [KeyboardTextInsertionAction]) {
    for action in actions {
        switch action {
        case let .insertText(value):
            textDocumentProxy.insertText(value)
        case let .deleteBackward(count):
            for _ in 0..<count.value {
                textDocumentProxy.deleteBackward()
            }
        }
    }
}
```

`TextDeletionCount.value` already exists in `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardModels/VoiceCommand.swift`, so no model change is required for deletion.

- [ ] **Step 3: Keep current snapshot fallback on load**

Leave `renderCurrentSpeechCapture()` calling `currentSnapshot()` so the keyboard still renders a non-STT idle/unavailable state before the user taps the microphone.

- [ ] **Step 4: Run focused build**

Run:

```bash
make build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VoiceKeyboardExtension/KeyboardSpeechCaptureCoordinator.swift \
  VoiceKeyboardExtension/KeyboardViewController.swift
git commit -m "feat: start keyboard recognition from mic button"
```

## Task 5: QA Documentation And Full Verification

**Files:**
- Modify: `docs/qa/keyboard-extension-manual-qa.md`

**Interfaces:**
- Consumes: keyboard STT runtime path and diagnostic logger from previous tasks.
- Produces: manual QA checklist for physical-device validation.

- [ ] **Step 1: Update manual QA expectations**

Replace the old microphone-probe expected behavior section with:

```markdown
## Expected Keyboard STT Behavior

- Tapping Mic in `Voice Keyboard` starts the keyboard-process STT path.
- The keyboard first shows `Listening...`.
- Partial recognition shows the live transcript and a Stop microphone button.
- A final transcript is inserted into the host text field.
- If iOS blocks microphone capture in the keyboard process, the keyboard shows a specific unavailable or failed message.
- The diagnostic log should include permission state, locale, audio session activation, input format, audio engine start, speech recognizer availability, recognition start, and stop reason.
- Do not treat Simulator success as proof that real-device keyboard STT works.
```

Add a physical-device diagnostic checklist:

```markdown
## Physical Device STT Validation

1. Install a signed build on an iOS 26+ physical device.
2. Enable `Voice Keyboard` in Settings.
3. Leave `Allow Full Access` off for the first run.
4. Open a host text field and switch to `Voice Keyboard`.
5. Tap Mic and speak a short phrase.
6. Confirm whether text is inserted.
7. Capture the `KeyboardSpeechRecognition` logs.
8. Repeat with `Allow Full Access` on only to record whether behavior changes; do not make full access a product dependency without a separate design update.
```

- [ ] **Step 2: Run full verification**

Run:

```bash
make package-strict-test
make build
make ui-kit-test
make app-ui-test
make preview-layout-test
make generated-check
```

Expected: PASS. If any command fails, fix the current task's files only unless the failure clearly belongs to an earlier task.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/keyboard-extension-manual-qa.md
git commit -m "docs: update keyboard stt manual qa"
```

## Self-Review Checklist

- Spec coverage: Tasks 1-5 cover shared errors, keyboard adapter, microphone button recognition, final text insertion, UI states, diagnostics, Info.plist speech usage, and manual QA.
- Placeholders: No task contains TBD/TODO or an unbounded instruction without expected files and commands.
- Type consistency: `SpeechRecognitionError`, `KeyboardSpeechRecognitionSession`, `KeyboardSpeechRecognitionEvent`, and `KeyboardTextInsertionAction` are introduced before later tasks consume them.
- Risk note: The plan uses Xcode 27 SDK `SpeechModuleResult.isFinal` for transcriber result finality and keeps the adapter boundary and error mapping fixed.
