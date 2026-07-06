DERIVED_DATA := .build/XcodeDerivedData
PACKAGE_DIR := Packages/VoiceKeyboardPackage
PACKAGE_SWIFT_DIRS := $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests
PREVIEW_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
SIMULATOR_DEVICE ?= booted
APP_BUNDLE_ID := com.ks1019.voicekeyboardinput
KEYBOARD_BUNDLE_ID := com.ks1019.voicekeyboardinput.keyboard
SNAPSHOT_DIR ?= .build/snapshot-previews/$(shell date +%Y%m%d-%H%M%S)
SCHEME := VoiceKeyboardInput
DOCC_SCHEMES := VoiceKeyboardModels VoiceKeyboardPresentation VoiceKeyboardInterfaces VoiceKeyboardCore
KEYBOARD_MANUAL_QA_DOC := docs/qa/keyboard-extension-manual-qa.md
GENERATED_CHECK_PATHS := VoiceKeyboardInputApp/Info.plist VoiceKeyboardExtension/Info.plist VoiceKeyboardInput.xcodeproj/project.pbxproj VoiceKeyboardInput.xcodeproj/project.xcworkspace/contents.xcworkspacedata VoiceKeyboardInput.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved VoiceKeyboardInput.xcodeproj/xcshareddata/xcschemes/VoiceKeyboardInput.xcscheme
SWIFT_PM := env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache swift
XCODEBUILD := env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache xcodebuild
XCODEGEN ?= $(or $(shell command -v xcodegen 2>/dev/null),$(wildcard /opt/homebrew/bin/xcodegen),$(wildcard /usr/local/bin/xcodegen),xcodegen)
DEPENDENCY_POLICY_PATHS := project.yml VoiceKeyboardInput.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Packages/VoiceKeyboardPackage VoiceKeyboardInputApp VoiceKeyboardExtension VoiceKeyboardUIKit
FORBIDDEN_PACKAGE_IMPORTS := '^[[:space:]]*import[[:space:]]+(AuralKit|UIKit|AVFoundation|Speech|FoundationModels)\b'
EXTENSION_SAFE_PATHS := VoiceKeyboardExtension VoiceKeyboardUIKit
FORBIDDEN_EXTENSION_APIS := 'UIApplication[.]shared|^[[:space:]]*import[[:space:]]+FoundationModels\b'

.PHONY: generate
generate:
	$(XCODEGEN) generate

.PHONY: package-test
package-test:
	cd $(PACKAGE_DIR) && $(SWIFT_PM) test

.PHONY: package-strict-test
package-strict-test:
	cd $(PACKAGE_DIR) && $(SWIFT_PM) test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.PHONY: build
build: generate
	$(XCODEBUILD) build \
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

.PHONY: preview-layout-test
preview-layout-test: generate
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardInputPreviewTests/VoiceKeyboardInputPreviewLayoutTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: ui-kit-test
ui-kit-test: generate
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardUIKitTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: app-ui-test
app-ui-test: generate
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardInputUITests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: simulator-grant-microphone
simulator-grant-microphone:
	xcrun simctl privacy $(SIMULATOR_DEVICE) grant microphone $(APP_BUNDLE_ID)
	xcrun simctl privacy $(SIMULATOR_DEVICE) grant microphone $(KEYBOARD_BUNDLE_ID)

.PHONY: simulator-reset-microphone
simulator-reset-microphone:
	xcrun simctl privacy $(SIMULATOR_DEVICE) reset microphone $(APP_BUNDLE_ID)
	xcrun simctl privacy $(SIMULATOR_DEVICE) reset microphone $(KEYBOARD_BUNDLE_ID)

.PHONY: keyboard-manual-qa
keyboard-manual-qa:
	sed -n '1,220p' $(KEYBOARD_MANUAL_QA_DOC)

.PHONY: preview-snapshots
preview-snapshots: generate
	mkdir -p $(SNAPSHOT_DIR)
	TEST_RUNNER_SNAPSHOTS_EXPORT_DIR=$(abspath $(SNAPSHOT_DIR)) $(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardInputPreviewTests/VoiceKeyboardInputPreviewSnapshotTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: docc
docc: generate
	for scheme in $(DOCC_SCHEMES); do \
		$(XCODEBUILD) docbuild \
			-scheme $$scheme \
			-destination 'generic/platform=iOS Simulator' \
			-derivedDataPath $(DERIVED_DATA) \
			CODE_SIGNING_ALLOWED=NO || exit $$?; \
	done

.PHONY: generated-check
generated-check: generate
	@for path in $(GENERATED_CHECK_PATHS); do test -f "$$path"; done
	@untracked="$$(git ls-files --others --exclude-standard -- $(GENERATED_CHECK_PATHS))"; \
		test -z "$$untracked" || { printf '%s\n' "$$untracked"; exit 1; }
	git diff --exit-code -- $(GENERATED_CHECK_PATHS)

.PHONY: dependency-policy-check
dependency-policy-check:
	status=0; rg --quiet 'AuralKit' $(DEPENDENCY_POLICY_PATHS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(FORBIDDEN_PACKAGE_IMPORTS) $(PACKAGE_SWIFT_DIRS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(FORBIDDEN_EXTENSION_APIS) $(EXTENSION_SAFE_PATHS) || status=$$?; test $$status -eq 1

.PHONY: verify
verify:
	$(MAKE) package-strict-test
	$(MAKE) dependency-policy-check
	$(MAKE) generated-check
	$(MAKE) build
	$(MAKE) ui-kit-test
	$(MAKE) app-ui-test
	$(MAKE) preview-layout-test
	$(MAKE) docc
