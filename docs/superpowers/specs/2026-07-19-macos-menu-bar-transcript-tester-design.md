# macOS Menu Bar Transcript Tester Design

## Goal

Add a macOS SwiftUI menu bar utility that makes literal speech transcripts easy to
run through the same transcript-to-command pipeline used by Voice Keyboard. The
utility must build independently from the iOS containing app and keyboard
extension while sharing the platform-neutral package modules.

## Scope

### Included

- A macOS 13 or newer application target generated from `project.yml`.
- A menu bar-only SwiftUI scene using `MenuBarExtra` with the window style.
- A transcript editor, document-context editor, locale selector, and preview action.
- A preview showing both parsed transcript elements and planned text operations.
- A public `VoiceKeyboardCommandPipeline` package product that exposes only the
  literal-transcript preview facade; parser and planner implementation types
  remain internal to `VoiceKeyboardCommands`.
- Package tests covering the public command API and the existing iOS pipeline.
- Build and test commands for both the package and the macOS target.

### Excluded

- Microphone capture, AVAudioSession, AVAudioEngine, Speech, SpeechAnalyzer, and
  Bluetooth route management in the macOS target.
- App Group storage, keyboard-extension handoff, or text insertion into another
  macOS application.
- A second command language or a macOS-specific parser.
- New third-party dependencies.

The macOS target is deliberately a deterministic test surface for literal
transcripts. Audio capture remains owned by the existing iOS app/extension
adapters until a separate macOS audio requirement is established.

## Architecture

### Package boundary

`VoiceKeyboardModels` remains platform-neutral and contains value types such as
`TextOperation` and `VoiceKeyboardLocale`. `VoiceKeyboardCommands` owns the
transcript language and keeps `VoiceCommand`, `TranscriptElement`,
`ParsedTranscript`, `VoiceCommandParser`, and `TextInsertionPlanner` as package
implementation types. `VoiceKeyboardCommandPipeline` is the small public
cross-platform facade for literal transcript previews. `VoiceKeyboardCore`
remains the iOS speech-session orchestration layer and uses the command pipeline
internally for keyboard actions.

The public facade is intentionally small:

```swift
public struct LiteralTranscriptCommandPipeline: Sendable {
    public init(locale: VoiceKeyboardLocale)
    public func preview(
        for transcript: String,
        documentContextBeforeInput: String?
    ) -> LiteralTranscriptPreview
}

public struct LiteralTranscriptPreview: Equatable, Sendable {
    public let elements: [LiteralTranscriptElement]
    public let operations: [TextOperation]
}
```

The facade maps the internal parser representation to public
`LiteralTranscriptElement` and `LiteralTranscriptCommand` values. This lets the
menu bar UI display parsed commands without making the parser's implementation
types part of the package's external contract.

The package keeps its existing iOS and macOS minimums (`iOS 16`, `macOS 13`),
but removes platform declarations for surfaces that this product does not build
or verify. The actual iOS app and extension continue to enforce iOS 26 in
`project.yml`; the package remains reusable by both products.

### macOS target

The new `VoiceKeyboardMenuBar` target contains only SwiftUI/AppKit-free UI and
the menu bar app entry point. It depends on:

- `VoiceKeyboardCommandPipeline` for the literal transcript preview facade.
- `VoiceKeyboardModels` for locale and text-operation value types.

It does not depend on `VoiceKeyboardCore`, `VoiceKeyboardCommands`, the iOS
containing app, or the keyboard extension. It has no entitlements, no App Group,
no iOS frameworks, and no audio or speech adapter. `LSUIElement` keeps the
utility in the menu bar without a Dock icon.

## User flow

1. The user clicks the waveform icon in the menu bar.
2. The popover-like window opens with a sample transcript prefilled.
3. The user edits the transcript, optional text immediately before insertion, and
   the language (`English` or `日本語`).
4. The user clicks `Preview`.
5. The app parses the literal transcript with
   `LiteralTranscriptCommandPipeline` and displays both parsed elements and
   planned text operations.
6. The user can revise the literal transcript and repeat without recording audio.

The UI treats empty input as a valid no-op preview. It displays delete counts and
unsupported shortcut feedback explicitly, so an operation preview cannot be
mistaken for text that will be inserted.

## Error and lifecycle behavior

- The preview action is synchronous and deterministic; it does not create a
  task, audio session, notification observer, or shared-state writer.
- The selected locale is passed to the same command facade used by
  `VoiceInputPipeline`.
- The document context is passed to the planner so spacing and deletion behavior
  matches keyboard insertion semantics.
- The menu bar scene is the only scene. There is no hidden long-running service
  or microphone permission prompt.

## Testing and verification

- Add/adjust package tests so public command types can be constructed and
  inspected from the test target.
- Add a focused package test for the complete literal-transcript preview path,
  including parsed command elements and planned operations.
- Run the full Swift Package test suite with strict concurrency and warnings as
  errors.
- Run `xcodegen generate` and build the existing iOS scheme.
- Build the new macOS scheme for a generic macOS destination with code signing
  disabled.
- Run multi-persona review covering package boundaries, SwiftUI/macOS target
  configuration, command semantics, and audio/framework isolation. Resolve all
  actionable findings before completion.

## Apple API reference

- `MenuBarExtra`: https://developer.apple.com/documentation/swiftui/menubarextra
- `MenuBarExtraStyle.window`:
  https://developer.apple.com/documentation/swiftui/menubarextrastyle/window
