# macOS Menu Bar Transcript Tester Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS 13+ SwiftUI menu bar utility that previews literal transcript parsing and text operations through the same shared command pipeline used by the iOS keyboard.

**Architecture:** Keep `VoiceKeyboardCommands` as the package-internal parser/planner implementation, add a small public `VoiceKeyboardCommandPipeline` product with literal-transcript preview value types, and keep `VoiceKeyboardCore` focused on speech-session orchestration. The macOS target depends only on the command pipeline and models; it never links the iOS audio, speech, containing-app, or keyboard-extension targets.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI `MenuBarExtra`, XcodeGen, XCTest, xcodebuild.

## Global Constraints

- Package support is limited to `iOS 16` and `macOS 13`.
- The iOS application and keyboard extension continue to target iOS 26.
- The macOS target must not import AVFAudio, AVFoundation, Speech, UIKit, or FoundationModels.
- The macOS target must not use App Group entitlements or keyboard-extension handoff.
- Parser and planner implementation types remain package-internal.
- No new third-party dependency may be added.
- Commits use the Codex identity through environment variables and `--no-gpg-sign`.

---

### Task 1: Add the public literal-transcript command pipeline

**Files:**

- Modify: `Packages/VoiceKeyboardPackage/Package.swift`
- Create: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCommandPipeline/LiteralTranscriptCommandPipeline.swift`
- Create: `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCommandPipelineTests/LiteralTranscriptCommandPipelineTests.swift`
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCommands/VoiceCommand.swift` only if package access is needed by the new target

**Interfaces:**

- Produces package product `VoiceKeyboardCommandPipeline`.
- Produces public `LiteralTranscriptCommandPipeline`.
- Produces public `LiteralTranscriptPreview`, `LiteralTranscriptElement`, and `LiteralTranscriptCommand`.
- Keeps `VoiceCommandParser`, `TextInsertionPlanner`, `ParsedTranscript`, and `VoiceCommand` internal to the package implementation.

- [ ] **Step 1: Add the new test target and write the failing test**

Add these manifest entries before creating production source:

~~~swift
.library(
    name: "VoiceKeyboardCommandPipeline",
    targets: ["VoiceKeyboardCommandPipeline"]
),
~~~

~~~swift
.target(
    name: "VoiceKeyboardCommandPipeline",
    dependencies: [
        "VoiceKeyboardModels",
        "VoiceKeyboardCommands"
    ]
),
~~~

~~~swift
.testTarget(
    name: "VoiceKeyboardCommandPipelineTests",
    dependencies: [
        "VoiceKeyboardCommandPipeline",
        "VoiceKeyboardModels"
    ]
),
~~~

Create `LiteralTranscriptCommandPipelineTests.swift`:

~~~swift
import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels
import XCTest

final class LiteralTranscriptCommandPipelineTests: XCTestCase {
    func testPreviewExposesParsedElementsAndPlannedOperations() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )

        let preview = pipeline.preview(
            for: "hello comma world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("hello"),
            .command(.insertText(",")),
            .text("world")
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("hello"),
            .insertText(","),
            .insertText(" world")
        ])
    }

    func testJapanesePreviewUsesLocaleSpecificUnspacedAliases() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "ja-JP")
        )

        let preview = pipeline.preview(
            for: "こんにちは読点世界改行",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("こんにちは"),
            .insertText("、"),
            .insertText("世界"),
            .insertText("\n")
        ])
    }
}
~~~

- [ ] **Step 2: Run the new test and verify the missing-source failure**

Run:

~~~bash
cd Packages/VoiceKeyboardPackage
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    swift test --filter LiteralTranscriptCommandPipelineTests \
    --scratch-path /private/tmp/voicekeyboard-command-pipeline-red
~~~

Expected: FAIL because the declared target has no production source and the public types do not exist.

- [ ] **Step 3: Implement the public facade**

Create `LiteralTranscriptCommandPipeline.swift` with this complete public surface and package-internal mapping:

~~~swift
import VoiceKeyboardCommands
import VoiceKeyboardModels

public enum LiteralTranscriptCommand: Equatable, Sendable {
    case insertText(String)
    case deleteWord
    case deleteSentence
    case unsupportedShortcut(String)
}

public enum LiteralTranscriptElement: Equatable, Sendable {
    case text(String)
    case command(LiteralTranscriptCommand)
}

public struct LiteralTranscriptPreview: Equatable, Sendable {
    public let elements: [LiteralTranscriptElement]
    public let operations: [TextOperation]

    public init(
        elements: [LiteralTranscriptElement],
        operations: [TextOperation]
    ) {
        self.elements = elements
        self.operations = operations
    }
}

public struct LiteralTranscriptCommandPipeline: Sendable {
    private let parser: VoiceCommandParser
    private let planner: TextInsertionPlanner

    public init(locale: VoiceKeyboardLocale) {
        parser = VoiceCommandParser(locale: locale)
        planner = TextInsertionPlanner()
    }

    public func preview(
        for transcript: String,
        documentContextBeforeInput: String?
    ) -> LiteralTranscriptPreview {
        let parsed = parser.parse(transcript)
        let elements = parsed.elements.map(Self.mapElement)
        return LiteralTranscriptPreview(
            elements: elements,
            operations: planner.plan(
                parsed,
                documentContextBeforeInput: documentContextBeforeInput
            )
        )
    }

    private static func mapElement(
        _ element: TranscriptElement
    ) -> LiteralTranscriptElement {
        switch element {
        case .text(let value):
            .text(value)
        case .command(let command):
            .command(mapCommand(command))
        }
    }

    private static func mapCommand(
        _ command: VoiceCommand
    ) -> LiteralTranscriptCommand {
        switch command {
        case .insertText(let value):
            .insertText(value)
        case .deleteWord:
            .deleteWord
        case .deleteSentence:
            .deleteSentence
        case .unsupportedShortcut(let phrase):
            .unsupportedShortcut(phrase)
        }
    }
}
~~~

If Swift's package access checker rejects the new target's access to the
existing implementation types, change only the required declarations from
`package` to `internal` and keep them out of the product's public signatures.
Do not make the parser or planner public.

- [ ] **Step 4: Run the focused test and the strict full package suite**

Run:

~~~bash
cd Packages/VoiceKeyboardPackage
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    swift test --filter LiteralTranscriptCommandPipelineTests \
    --scratch-path /private/tmp/voicekeyboard-command-pipeline-green

env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    swift test -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors \
    --scratch-path /private/tmp/voicekeyboard-package-strict-command-pipeline
~~~

Expected: both commands exit 0 and all existing parser/planner/core tests remain green.

- [ ] **Step 5: Commit the new public product**

~~~bash
git add Packages/VoiceKeyboardPackage/Package.swift \
        Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCommandPipeline \
        Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCommandPipelineTests
GIT_AUTHOR_NAME='Codex' GIT_AUTHOR_EMAIL='codex@openai.com' \
GIT_COMMITTER_NAME='Codex' GIT_COMMITTER_EMAIL='codex@openai.com' \
git commit --no-gpg-sign -m "feat(package): add literal transcript command pipeline"
~~~

### Task 2: Route the iOS core and app through the narrow pipeline

**Files:**

- Modify: `Packages/VoiceKeyboardPackage/Package.swift`
- Modify: `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/VoiceInputPipeline.swift`
- Modify: `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/VoiceInputPipelineTests.swift`
- Modify: `project.yml`
- Modify: `VoiceKeyboardInputApp/ContentView.swift`

**Interfaces:**

- `VoiceKeyboardCore` depends on `VoiceKeyboardCommandPipeline`, not directly on `VoiceKeyboardCommands`.
- Existing `VoiceInputPipeline` behavior and public methods remain source-compatible.
- The iOS containing app uses `LiteralTranscriptCommandPipeline` for its command preview and no longer depends on the broad `VoiceKeyboardCore` product solely for that preview.

- [ ] **Step 1: Add a failing compatibility test for the core wrapper**

Add this test to `VoiceInputPipelineTests.swift`:

~~~swift
func testCorePipelineOperationsMatchLiteralCommandPipelinePreview() {
    let pipeline = VoiceInputPipeline(
        locale: VoiceKeyboardLocale(identifier: "en-US")
    )

    XCTAssertEqual(
        pipeline.operations(
            for: "hello comma world",
            documentContextBeforeInput: "prefix"
        ),
        [
            .insertText(" hello"),
            .insertText(","),
            .insertText(" world")
        ]
    )
}
~~~

Run the existing Core test target with the strict command from Task 1. Expected:
the test remains green before the dependency swap, proving the behavior is the
compatibility contract that must be preserved.

- [ ] **Step 2: Change the package dependency graph**

In `Package.swift`, change the `VoiceKeyboardCore` dependency list from:

~~~swift
"VoiceKeyboardModels",
"VoiceKeyboardCommands",
"VoiceKeyboardInterfaces"
~~~

to:

~~~swift
"VoiceKeyboardModels",
"VoiceKeyboardCommandPipeline",
"VoiceKeyboardInterfaces"
~~~

Keep `VoiceKeyboardCommands` as a dependency of
`VoiceKeyboardCommandPipeline`.

- [ ] **Step 3: Route VoiceInputPipeline through the facade**

In `VoiceInputPipeline.swift`, replace the parser/planner imports and stored properties with:

~~~swift
import VoiceKeyboardCommandPipeline
import VoiceKeyboardInterfaces
import VoiceKeyboardModels

public struct VoiceInputPipeline: Sendable {
    private let commandPipeline: LiteralTranscriptCommandPipeline
    private let cleanupService: (any TextCleanupService)?
    private let locale: VoiceKeyboardLocale

    public init(
        locale: VoiceKeyboardLocale,
        cleanupService: (any TextCleanupService)? = nil
    ) {
        self.locale = locale
        self.commandPipeline = LiteralTranscriptCommandPipeline(locale: locale)
        self.cleanupService = cleanupService
    }

    public func operations(
        for transcript: String,
        documentContextBeforeInput: String?
    ) -> [TextOperation] {
        commandPipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContextBeforeInput
        ).operations
    }
~~~

Keep `prepareInsertedText`, boundary whitespace restoration, and
`VoiceInputPipelineError` unchanged.

- [ ] **Step 4: Narrow the iOS app dependency and command preview**

In `project.yml`, add `VoiceKeyboardCommandPipeline` to the iOS app's package
dependencies and remove `VoiceKeyboardCore` from that app target. Keep
`VoiceKeyboardCore` in the extension target.

In `ContentView.swift`, replace:

~~~swift
import VoiceKeyboardCore
~~~

with:

~~~swift
import VoiceKeyboardCommandPipeline
~~~

Replace the stored pipeline with:

~~~swift
private let pipeline = LiteralTranscriptCommandPipeline(
    locale: VoiceKeyboardLocale(identifier: Locale.current.identifier)
)
~~~

Replace the preview assignment with:

~~~swift
let preview = pipeline.preview(
    for: sampleTranscript,
    documentContextBeforeInput: ""
)
commandPreview = CommandPreviewPresentationSnapshot(
    operations: preview.operations
)
~~~

- [ ] **Step 5: Run iOS package and app tests**

Run:

~~~bash
make package-strict-test
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    xcodebuild -quiet -project VoiceKeyboardInput.xcodeproj \
    -scheme VoiceKeyboardInput \
    -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/voicekeyboard-ios-derived-data \
    CODE_SIGNING_ALLOWED=NO build-for-testing
~~~

Expected: exit code 0, with no source or dependency errors.

- [ ] **Step 6: Commit the narrow dependency integration**

~~~bash
git add Packages/VoiceKeyboardPackage/Package.swift \
        Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/VoiceInputPipeline.swift \
        Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/VoiceInputPipelineTests.swift \
        project.yml VoiceKeyboardInputApp/ContentView.swift
GIT_AUTHOR_NAME='Codex' GIT_AUTHOR_EMAIL='codex@openai.com' \
GIT_COMMITTER_NAME='Codex' GIT_COMMITTER_EMAIL='codex@openai.com' \
git commit --no-gpg-sign -m "refactor: isolate command pipeline from speech core"
~~~

### Task 3: Add the independent macOS target

**Files:**

- Modify: `project.yml`
- Create: `VoiceKeyboardMenuBar/Info.plist`

**Interfaces:**

- Produces `VoiceKeyboardMenuBar`, a macOS application target.
- Produces a separate `VoiceKeyboardMenuBar` scheme.
- The target depends only on `VoiceKeyboardCommandPipeline` and
  `VoiceKeyboardModels`.
- The target has no entitlements and no dependency on the iOS app, extension,
  UIKit source, audio adapters, or speech adapters.

- [ ] **Step 1: Add macOS deployment settings**

Update the root settings in `project.yml`:

~~~yaml
deploymentTarget:
  iOS: "26.0"
  macOS: "13.0"
settings:
  base:
    SWIFT_VERSION: 6.0
    IPHONEOS_DEPLOYMENT_TARGET: 26.0
    MACOSX_DEPLOYMENT_TARGET: 13.0
~~~

Change only the package platform declarations in `Package.swift` to retain
`iOS(.v16)` and `macOS(.v13)`; remove the unverified visionOS, tvOS, and
watchOS declarations.

- [ ] **Step 2: Add the target and scheme to XcodeGen**

Add under `targets`:

~~~yaml
  VoiceKeyboardMenuBar:
    type: application
    platform: macOS
    sources:
      - VoiceKeyboardMenuBar
    dependencies:
      - package: VoiceKeyboardPackage
        product: VoiceKeyboardCommandPipeline
      - package: VoiceKeyboardPackage
        product: VoiceKeyboardModels
    info:
      path: VoiceKeyboardMenuBar/Info.plist
      properties:
        CFBundleDisplayName: Voice Keyboard Menu Bar
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
        LSUIElement: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ks1019.voicekeyboardinput.menubar
~~~

Add under `schemes`:

~~~yaml
  VoiceKeyboardMenuBar:
    build:
      targets:
        VoiceKeyboardMenuBar: all
    run:
      config: Debug
      executable: VoiceKeyboardMenuBar
~~~

- [ ] **Step 3: Add the menu bar Info.plist and regenerate**

Create `VoiceKeyboardMenuBar/Info.plist`:

~~~xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
~~~

Run:

~~~bash
xcodegen generate
xcodebuild -list -project VoiceKeyboardInput.xcodeproj
~~~

Expected: the generated project lists `VoiceKeyboardMenuBar` as a target and
scheme, while the existing iOS targets remain unchanged.

- [ ] **Step 4: Build the target before adding UI source**

~~~bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    xcodebuild -quiet -project VoiceKeyboardInput.xcodeproj \
    -scheme VoiceKeyboardMenuBar \
    -destination 'generic/platform=macOS' \
    -derivedDataPath /private/tmp/voicekeyboard-macos-derived-data \
    CODE_SIGNING_ALLOWED=NO build
~~~

Expected: the command reaches the new target and fails only because its Swift
source directory has no app source yet.

- [ ] **Step 5: Commit the target configuration**

~~~bash
git add project.yml Packages/VoiceKeyboardPackage/Package.swift \
        VoiceKeyboardMenuBar/Info.plist VoiceKeyboardInput.xcodeproj
GIT_AUTHOR_NAME='Codex' GIT_AUTHOR_EMAIL='codex@openai.com' \
GIT_COMMITTER_NAME='Codex' GIT_COMMITTER_EMAIL='codex@openai.com' \
git commit --no-gpg-sign -m "build(mac): add independent menu bar target"
~~~

### Task 4: Implement the SwiftUI menu bar transcript tester

**Files:**

- Create: `VoiceKeyboardMenuBar/VoiceKeyboardMenuBarApp.swift`
- Create: `VoiceKeyboardMenuBar/MenuBarContentView.swift`

**Interfaces:**

- The app presents one `MenuBarExtra` scene with `.menuBarExtraStyle(.window)`.
- The view calls `LiteralTranscriptCommandPipeline.preview`.
- The view displays parsed elements and text operations with no audio, permission,
  notification, or shared-storage side effects.

- [ ] **Step 1: Add the app entry point**

Create `VoiceKeyboardMenuBar/VoiceKeyboardMenuBarApp.swift`:

~~~swift
import SwiftUI

@main
struct VoiceKeyboardMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Voice Keyboard", systemImage: "waveform") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
~~~

- [ ] **Step 2: Add the deterministic preview view**

Create `MenuBarContentView.swift`:

~~~swift
import SwiftUI
import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels

struct MenuBarContentView: View {
    private enum PreviewLocale: String, CaseIterable, Identifiable {
        case english = "en-US"
        case japanese = "ja-JP"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .english:
                "English"
            case .japanese:
                "日本語"
            }
        }
    }

    @State private var transcript = "hello comma world newline"
    @State private var documentContext = ""
    @State private var selectedLocale: PreviewLocale = .english
    @State private var preview = LiteralTranscriptPreview(
        elements: [],
        operations: []
    )

    private var pipeline: LiteralTranscriptCommandPipeline {
        LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: selectedLocale.rawValue)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcript Tester", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Button("Preview", action: previewTranscript)
                    .keyboardShortcut(.return, modifiers: [.command])
            }

            Text("Literal transcript")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $transcript)
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )

            TextField(
                "Text immediately before insertion",
                text: $documentContext
            )
            .textFieldStyle(.roundedBorder)

            Picker("Locale", selection: $selectedLocale) {
                ForEach(PreviewLocale.allCases) { locale in
                    Text(locale.title).tag(locale)
                }
            }
            .pickerStyle(.segmented)

            Divider()
            previewSection
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: previewTranscript)
    }

    private var previewSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parsed Elements")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.elements.enumerated()),
                    id: \.offset
                ) { index, element in
                    Text("\(index + 1). \(elementDescription(element))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if preview.elements.isEmpty {
                    Text("No elements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Planned Operations")
                    .font(.subheadline.weight(.semibold))

                ForEach(
                    Array(preview.operations.enumerated()),
                    id: \.offset
                ) { index, operation in
                    Text("\(index + 1). \(operationDescription(operation))")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if preview.operations.isEmpty {
                    Text("No operations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func previewTranscript() {
        preview = pipeline.preview(
            for: transcript,
            documentContextBeforeInput: documentContext
        )
    }

    private func elementDescription(
        _ element: LiteralTranscriptElement
    ) -> String {
        switch element {
        case .text(let value):
            "text(\"\(value)\")"
        case .command(let command):
            "command(\(commandDescription(command)))"
        }
    }

    private func commandDescription(
        _ command: LiteralTranscriptCommand
    ) -> String {
        switch command {
        case .insertText(let value):
            "insertText(\"\(value)\")"
        case .deleteWord:
            "deleteWord"
        case .deleteSentence:
            "deleteSentence"
        case .unsupportedShortcut(let phrase):
            "unsupportedShortcut(\"\(phrase)\")"
        }
    }

    private func operationDescription(_ operation: TextOperation) -> String {
        switch operation {
        case .insertText(let value):
            "insertText(\"\(value)\")"
        case .deleteBackward(let count):
            "deleteBackward(count: \(count.value))"
        case .showUnsupportedCommand(let phrase):
            "showUnsupportedCommand(\"\(phrase)\")"
        }
    }
}
~~~

- [ ] **Step 3: Build the macOS target**

Run:

~~~bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    xcodebuild -quiet -project VoiceKeyboardInput.xcodeproj \
    -scheme VoiceKeyboardMenuBar \
    -destination 'generic/platform=macOS' \
    -derivedDataPath /private/tmp/voicekeyboard-macos-derived-data \
    CODE_SIGNING_ALLOWED=NO build
~~~

Expected: exit code 0. Any compile error mentioning UIKit, AVFAudio,
AVFoundation, Speech, FoundationModels, App Group settings, or an iOS-only
source file is a module-boundary failure and must be fixed.

- [ ] **Step 4: Commit the menu bar UI**

~~~bash
git add VoiceKeyboardMenuBar
GIT_AUTHOR_NAME='Codex' GIT_AUTHOR_EMAIL='codex@openai.com' \
GIT_COMMITTER_NAME='Codex' GIT_COMMITTER_EMAIL='codex@openai.com' \
git commit --no-gpg-sign -m "feat(mac): add transcript tester menu bar UI"
~~~

### Task 5: Add verification tooling and complete multi-persona review

**Files:**

- Modify: `Makefile`
- Modify: `GENERATED_CHECK_PATHS` in `Makefile`
- Modify: any source/config file only when a reviewer identifies an actionable defect

**Interfaces:**

- Produces `make mac-build` for a reproducible generic macOS build.
- Extends `make verify` to include the macOS build and generated-file checks.
- Leaves no unresolved P1/P2 review finding in the new cross-platform path.

- [ ] **Step 1: Add macOS build and generated-file checks**

Add:

~~~make
MAC_SCHEME := VoiceKeyboardMenuBar
GENERATED_CHECK_PATHS := VoiceKeyboardInputApp/Info.plist VoiceKeyboardExtension/Info.plist VoiceKeyboardMenuBar/Info.plist VoiceKeyboardInput.xcodeproj/project.pbxproj VoiceKeyboardInput.xcodeproj/project.xcworkspace/contents.xcworkspacedata VoiceKeyboardInput.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved VoiceKeyboardInput.xcodeproj/xcshareddata/xcschemes/VoiceKeyboardInput.xcscheme VoiceKeyboardInput.xcodeproj/xcshareddata/xcschemes/VoiceKeyboardMenuBar.xcscheme

.PHONY: mac-build
mac-build: generate
	$(XCODEBUILD) build \
		-scheme $(MAC_SCHEME) \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO
~~~

Add `$(MAKE) mac-build` to `verify` after the existing iOS `build` step.
Retain all existing generated paths while adding the macOS Info.plist and
scheme.

- [ ] **Step 2: Run static boundary checks**

Run:

~~~bash
make dependency-policy-check
if rg -n 'AVFAudio|AVFoundation|Speech|UIKit|FoundationModels|application-groups' VoiceKeyboardMenuBar; then
    exit 1
fi
~~~

Expected: exit code 0 and no output from the second command.

- [ ] **Step 3: Run package, iOS, and macOS verification**

Run each command separately:

~~~bash
make package-strict-test
make generate
make build
make mac-build
~~~

Expected: every command exits 0. Read the full output and record the actual
test/build summaries; do not infer macOS success from SwiftPM success.

- [ ] **Step 4: Dispatch the multi-persona review**

Dispatch four read-only reviewers with distinct scopes:

1. Package/API boundary and source compatibility.
2. SwiftUI `MenuBarExtra` and XcodeGen/macOS target configuration.
3. Literal parsing/planning semantics and test coverage.
4. AVFAudio/Speech/Bluetooth isolation and cross-platform compilation hazards.

Review every finding against the current worktree. Fix all actionable issues,
then rerun the focused affected test, `make package-strict-test`, the iOS build,
and `make mac-build`. Do not treat an agent's success message as verification.

- [ ] **Step 5: Commit verification tooling and final fixes**

~~~bash
git add Makefile project.yml VoiceKeyboardInput.xcodeproj \
        Packages/VoiceKeyboardPackage VoiceKeyboardInputApp VoiceKeyboardMenuBar
GIT_AUTHOR_NAME='Codex' GIT_AUTHOR_EMAIL='codex@openai.com' \
GIT_COMMITTER_NAME='Codex' GIT_COMMITTER_EMAIL='codex@openai.com' \
git commit --no-gpg-sign -m "test: verify macOS transcript tester build"
~~~


