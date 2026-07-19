# Task 2 Implementation Report

Date: 2026-07-19
Branch: `codex/task-2-command-pipeline`
Task brief: `.superpowers/sdd/task-2-brief.md`

## Scope completed

Implemented only Task 2: routed `VoiceKeyboardCore` through the narrow `VoiceKeyboardCommandPipeline` facade and narrowed the iOS app command-preview dependency from `VoiceKeyboardCore` to `VoiceKeyboardCommandPipeline`, while preserving existing behavior.

I did not modify any macOS target or any UI file under `VoiceKeyboardMenuBar`.

## Changed files

- `Packages/VoiceKeyboardPackage/Package.swift`
- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCore/VoiceInputPipeline.swift`
- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCoreTests/VoiceInputPipelineTests.swift`
- `project.yml`
- `VoiceKeyboardInputApp/ContentView.swift`
- `VoiceKeyboardInput.xcodeproj/project.pbxproj`
- `.superpowers/sdd/task-2-report.md`

## Implementation details

1. Added a compatibility guard test in `VoiceInputPipelineTests` that asserts `VoiceInputPipeline.operations(...)` matches the literal command-pipeline preview behavior for a contextual insertion case.
2. Changed the `VoiceKeyboardCore` package target to depend on `VoiceKeyboardCommandPipeline` instead of `VoiceKeyboardCommands`.
3. Reworked `VoiceInputPipeline` to hold `LiteralTranscriptCommandPipeline` and source its `operations(...)` result from `preview(...).operations`, while leaving cleanup behavior, whitespace restoration, and `VoiceInputPipelineError` unchanged.
4. Narrowed the containing iOS app target dependency in `project.yml` from `VoiceKeyboardCore` to `VoiceKeyboardCommandPipeline`.
5. Updated `VoiceKeyboardInputApp/ContentView.swift` to preview commands through `LiteralTranscriptCommandPipeline` and feed `preview.operations` into `CommandPreviewPresentationSnapshot`.
6. Regenerated the Xcode project and then manually trimmed unrelated generated signing/default churn so the committed `.pbxproj` change stayed focused on the package-product swap.

## Red/green evidence

### Compatibility-contract baseline (green before dependency swap)

The brief’s Step 1 is a compatibility guard that should remain green before the dependency reroute rather than a newly failing red test.

Command:

```bash
cd Packages/VoiceKeyboardPackage
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    swift test -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors \
    --filter VoiceInputPipelineTests/testCorePipelineOperationsMatchLiteralCommandPipelinePreview \
    --scratch-path /private/tmp/voicekeyboard-task2-core-baseline
```

Result:

- Exit code: `0`
- Key output:
  - `Test Case '-[VoiceKeyboardCoreTests.VoiceInputPipelineTests testCorePipelineOperationsMatchLiteralCommandPipelinePreview]' passed`

### Full package verification after implementation (green)

Command:

```bash
make package-strict-test
```

Result:

- Exit code: `0`
- Key output:
  - `Test Suite 'VoiceInputPipelineTests' passed`
  - `Executed 14 tests, with 0 failures`
  - `Test Suite 'VoiceKeyboardCoreTests.xctest' passed`
  - `Executed 37 tests, with 0 failures`

### iOS build-for-testing verification

Initial sandboxed run of the required build command failed for environment access reasons, not source errors:

- `CoreSimulatorService connection became invalid`
- `Error opening log file ... CoreSimulator.com.apple.dt.xcodebuild.log: Operation not permitted`

Reran the exact required command outside the sandbox and it succeeded.

Command:

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache \
    SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache \
    xcodebuild -quiet -project VoiceKeyboardInput.xcodeproj \
    -scheme VoiceKeyboardInput \
    -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/voicekeyboard-ios-derived-data \
    CODE_SIGNING_ALLOWED=NO build-for-testing
```

Final result:

- Exit code: `0`
- Final output after the narrowed `.pbxproj` cleanup:
  - `warning: All interface orientations must be supported unless the app requires full screen. (in target 'VoiceKeyboardInput' from project 'VoiceKeyboardInput')`

## Commands run and output summary

1. Added the compatibility guard test and ran the focused strict package test.
2. Regenerated the Xcode project with:

```bash
make generate
```

Output excerpt:

- `/opt/homebrew/bin/xcodegen generate`
- `Created project at /Users/kotaro.suto/ghq/github.com/KS1019/voicekeyboardinput/VoiceKeyboardInput.xcodeproj`

3. Ran the required package strict suite:

```bash
make package-strict-test
```

Output excerpt:

- `Build complete!`
- `Test Suite 'All tests' passed`

4. Ran the required iOS build-for-testing command twice:
   - first in the sandbox, which failed because of CoreSimulator/log path access
   - then with escalated access, which passed
   - then once more after narrowing the `.pbxproj` diff, which also passed

## Self-review

- Confirmed `VoiceInputPipeline` public surface remains source-compatible.
- Confirmed cleanup behavior and boundary-whitespace restoration code stayed unchanged.
- Confirmed the containing app now imports and uses `VoiceKeyboardCommandPipeline` directly for preview generation.
- Confirmed `VoiceKeyboardCore` remains on the extension target and was removed only from the containing app target.
- Confirmed no `VoiceKeyboardMenuBar` files or macOS-target files were touched.
- Confirmed build directories remained unstaged and preserved:
  - `Packages/VoiceKeyboardPackage/build/`
  - `build/`
- Preserved the user’s unrelated modification to `.superpowers/sdd/task-1-report.md`.

## Commit

Commit hash at report-authoring time (pre-final-amend): `8fc8d8b`

Note: a checked-in report cannot stably contain the final hash of the same amended commit, because updating the report changes the commit object ID. Use `git rev-parse HEAD` after the last amend for the canonical final hash.

Commit message:

```text
refactor: isolate command pipeline from speech core
```

## Concerns

1. The required `xcodebuild -quiet ... build-for-testing` command emits an existing warning about supported interface orientations, but still exits `0`.
2. The required iOS build command cannot complete inside the sandbox in this environment because `xcodebuild` needs CoreSimulator/Xcode user-path access; verification required an escalated rerun.
