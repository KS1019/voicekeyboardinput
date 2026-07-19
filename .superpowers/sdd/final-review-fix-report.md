# Final Review Fix Report

Date: 2026-07-19
Base HEAD: `d1b0280569c6f0245fe9cd2cdeb2ae322e939900`

## Changed files

- `Makefile`
- `project.yml`
- `VoiceKeyboardInput.xcodeproj/project.pbxproj`
- `Packages/VoiceKeyboardPackage/Sources/VoiceKeyboardCommands/TextInsertionPlanner.swift`
- `Packages/VoiceKeyboardPackage/Tests/VoiceKeyboardCommandsTests/TextInsertionPlannerTests.swift`
- `.superpowers/sdd/final-review-fix-report.md`

## Fix summary

1. `TextInsertionPlanner.deleteSentenceCount` now treats trailing closing delimiters as part of the current sentence tail before scanning backward through stacked terminators and sentence body.
2. Added `make mac-test` for the `VoiceKeyboardMenuBar` scheme test action and wired it into `make verify` immediately after `mac-build`.
3. Extended dependency policy verification to cover the macOS menu bar target by:
   - rejecting `AVFAudio`, `AVFoundation`, `Speech`, `UIKit`, and `FoundationModels` imports in `VoiceKeyboardMenuBar/`
   - asserting the `VoiceKeyboardMenuBar` target block in `project.yml` contains exactly `VoiceKeyboardCommandPipeline` and `VoiceKeyboardModels`
   - rejecting Core/SharedStorage/Presentation/Interfaces, App Group, microphone, and speech-related entries in that target block
4. Added root `MARKETING_VERSION: "1.0"` and `CURRENT_PROJECT_VERSION: "1"` settings to `project.yml` and regenerated the Xcode project.

## Red / green evidence

### Planner TDD red

Command:

`env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache swift test --filter TextInsertionPlannerTests/testPlansDeleteSentenceIncludingTrailingClosingDelimiters`

Result:

- Failed in `TextInsertionPlannerTests.testPlansDeleteSentenceIncludingTrailingClosingDelimiters`
- Observed deletes were `count: 1`
- Expected deletes were `count: 7`, `count: 7`, and `count: 4`

### Planner TDD green

Same command after the planner change:

- Passed `TextInsertionPlannerTests.testPlansDeleteSentenceIncludingTrailingClosingDelimiters`

### Generated project stability

First `make generated-check` run after adding root version settings surfaced the expected tracked `project.pbxproj` diff from regeneration.

After staging the intended tracked changes, rerunning `make generated-check` passed with no additional generated drift.

## Verification commands and results

- `make dependency-policy-check` — passed
- `make package-strict-test` — passed
- `make mac-build` — passed
- `make mac-test` — passed (`VoiceKeyboardMenuBarTests`, 3 tests, 0 failures)
- `make build` — passed
- `make ui-kit-test` — passed (`VoiceKeyboardUIKitTests`, 28 tests, 0 failures)
- `make generated-check` — passed after staging tracked generated files

## Commit hash

The final commit hash is recorded in the final handoff message after commit creation. It cannot be embedded inside this committed report without changing the commit hash itself.

## Remaining concerns

- `make mac-test` emitted platform/service warnings from the local macOS test environment (`com.apple.linkd.autoShortcut` connection failures), but the scheme test action completed successfully.
- `make ui-kit-test` emitted simulator/runtime duplicate-class and plugin warnings during startup, but all targeted UIKit tests passed.
- Existing unrelated workspace noise was intentionally left untouched and unstaged:
  - `.superpowers/sdd/task-1-report.md`
  - `Packages/VoiceKeyboardPackage/build/`
  - `build/`
