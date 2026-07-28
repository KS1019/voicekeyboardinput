DERIVED_DATA := .build/XcodeDerivedData
PACKAGE_DIR := Packages/VoiceKeyboardPackage
PACKAGE_SWIFT_DIRS := $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests
MAC_APP_SWIFT_DIRS := VoiceKeyboardMenuBar
MAC_APP_BUNDLE := $(DERIVED_DATA)/Build/Products/Debug/VoiceKeyboardMenuBar.app
MAC_SECURITY_DERIVED_DATA := $(DERIVED_DATA)/mac-security
MAC_SECURITY_APP_BUNDLE := $(MAC_SECURITY_DERIVED_DATA)/Build/Products/Release/VoiceKeyboardMenuBar.app
MAC_PROJECT := VoiceKeyboardMenuBar.xcodeproj
MAC_SPEC := project-mac.yml
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
PREVIEW_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
SIMULATOR_DEVICE ?= booted
APP_BUNDLE_ID := com.ks1019.voicekeyboardinput
KEYBOARD_BUNDLE_ID := com.ks1019.voicekeyboardinput.keyboard
SNAPSHOT_DIR ?= .build/snapshot-previews/$(shell date +%Y%m%d-%H%M%S)
SCHEME := VoiceKeyboardInput
IOS_PROJECT := VoiceKeyboardInput.xcodeproj
MAC_SCHEME := VoiceKeyboardMenuBar
DOCC_SCHEMES := VoiceKeyboardModels VoiceKeyboardPresentation VoiceKeyboardInterfaces VoiceKeyboardCore
KEYBOARD_MANUAL_QA_DOC := docs/qa/keyboard-extension-manual-qa.md
GENERATED_CHECK_PATHS := VoiceKeyboardInputApp/Info.plist VoiceKeyboardExtension/Info.plist VoiceKeyboardMenuBar/Info.plist VoiceKeyboardMenuBar/VoiceKeyboardMenuBar.entitlements VoiceKeyboardInput.xcodeproj/project.pbxproj VoiceKeyboardInput.xcodeproj/project.xcworkspace/contents.xcworkspacedata VoiceKeyboardInput.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved VoiceKeyboardInput.xcodeproj/xcshareddata/xcschemes/VoiceKeyboardInput.xcscheme project-mac.yml VoiceKeyboardMenuBar.xcodeproj/project.pbxproj VoiceKeyboardMenuBar.xcodeproj/project.xcworkspace/contents.xcworkspacedata VoiceKeyboardMenuBar.xcodeproj/xcshareddata/xcschemes/VoiceKeyboardMenuBar.xcscheme
SWIFT_PM := env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache swift
XCODEBUILD := env CLANG_MODULE_CACHE_PATH=/private/tmp/voicekeyboard-clang-cache SWIFTPM_CACHE_PATH=/private/tmp/voicekeyboard-swiftpm-cache xcodebuild
XCODEGEN ?= $(or $(shell command -v xcodegen 2>/dev/null),$(wildcard /opt/homebrew/bin/xcodegen),$(wildcard /usr/local/bin/xcodegen),xcodegen)
DEPENDENCY_POLICY_PATHS := project.yml project-mac.yml VoiceKeyboardInput.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Packages/VoiceKeyboardPackage VoiceKeyboardInputApp VoiceKeyboardExtension VoiceKeyboardUIKit
FORBIDDEN_PACKAGE_IMPORTS := '^[[:space:]]*import[[:space:]]+(AuralKit|UIKit|AVFAudio|AVFoundation|Speech|FoundationModels)\b'
FORBIDDEN_MAC_APP_IMPORTS := '^[[:space:]]*import[[:space:]]+(AVFAudio|AVFoundation|Speech|UIKit|FoundationModels)\b'
EXTENSION_SAFE_PATHS := VoiceKeyboardExtension VoiceKeyboardUIKit
FORBIDDEN_EXTENSION_APIS := 'UIApplication[.]shared|^[[:space:]]*import[[:space:]]+FoundationModels\b'
APP_GROUP_ID := group.com.ks1019.voicekeyboardinput
MENU_BAR_ALLOWED_PACKAGE_PRODUCTS := VoiceKeyboardCommandPipeline VoiceKeyboardModels
MENU_BAR_FORBIDDEN_PROJECT_BLOCK_TOKENS := 'VoiceKeyboard(Core|SharedStorage|Presentation|Interfaces)|group[.]com[.]ks1019[.]voicekeyboardinput|com[.]apple[.]security[.]application-groups|NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription|AVFAudio|AVFoundation|Speech|FoundationModels|UIKit'

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
		-project $(IOS_PROJECT) \
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

.PHONY: mac-generate
mac-generate:
	$(XCODEGEN) generate --spec $(MAC_SPEC)

.PHONY: mac-build
mac-build: mac-generate
	set -o pipefail; \
	status=0; \
	cleanup() { $(LSREGISTER) -u "$(MAC_APP_BUNDLE)" >/dev/null 2>&1 || true; }; \
	handle_signal() { status=$$1; trap - EXIT INT TERM; cleanup; exit $$status; }; \
	trap cleanup EXIT; \
	trap 'handle_signal 130' INT; \
	trap 'handle_signal 143' TERM; \
	$(XCODEBUILD) build \
		-project $(MAC_PROJECT) \
		-scheme $(MAC_SCHEME) \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO || status=$$?; \
	exit $$status

.PHONY: mac-test
mac-test: mac-generate
	set -o pipefail; \
	status=0; \
	cleanup() { $(LSREGISTER) -u "$(MAC_APP_BUNDLE)" >/dev/null 2>&1 || true; }; \
	handle_signal() { status=$$1; trap - EXIT INT TERM; cleanup; exit $$status; }; \
	trap cleanup EXIT; \
	trap 'handle_signal 130' INT; \
	trap 'handle_signal 143' TERM; \
	$(XCODEBUILD) test \
		-project $(MAC_PROJECT) \
		-scheme $(MAC_SCHEME) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO || status=$$?; \
	exit $$status

.PHONY: mac-security-check
mac-security-check: mac-generate
	set -e; \
	trap '$(LSREGISTER) -u "$(MAC_SECURITY_APP_BUNDLE)" >/dev/null 2>&1 || true' EXIT; \
	$(XCODEBUILD) build \
		-project $(MAC_PROJECT) \
		-scheme $(MAC_SCHEME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(MAC_SECURITY_DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO; \
	$(XCODEBUILD) -showBuildSettings \
		-project $(MAC_PROJECT) \
		-scheme $(MAC_SCHEME) \
		-configuration Release | rg --quiet '^    ENABLE_HARDENED_RUNTIME = YES$$'; \
	$(XCODEBUILD) -showBuildSettings \
		-project $(MAC_PROJECT) \
		-scheme $(MAC_SCHEME) \
		-configuration Release | rg --quiet '^    CODE_SIGN_ENTITLEMENTS = VoiceKeyboardMenuBar/VoiceKeyboardMenuBar.entitlements$$'; \
	codesign --verify --deep --strict "$(MAC_SECURITY_APP_BUNDLE)"; \
	codesign -d --xml --entitlements :- "$(MAC_SECURITY_APP_BUNDLE)" 2>/dev/null > "$(MAC_SECURITY_DERIVED_DATA)/entitlements.plist"; \
	test "$$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$(MAC_SECURITY_DERIVED_DATA)/entitlements.plist")" = "true"; \
	if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$(MAC_SECURITY_DERIVED_DATA)/entitlements.plist" >/dev/null 2>&1; then \
		echo 'get-task-allow must not be present in the release app' >&2; exit 1; \
	fi; \
	codesign -dvv "$(MAC_SECURITY_APP_BUNDLE)" 2>&1 | rg --quiet 'flags=.*runtime'

.PHONY: preview-layout-test
preview-layout-test: generate
	$(XCODEBUILD) test \
		-project $(IOS_PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardInputPreviewTests/VoiceKeyboardInputPreviewLayoutTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: ui-kit-test
ui-kit-test: generate
	$(XCODEBUILD) test \
		-project $(IOS_PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardUIKitTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: app-ui-test
app-ui-test: generate
	$(XCODEBUILD) test \
		-project $(IOS_PROJECT) \
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
		-project $(IOS_PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(PREVIEW_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:VoiceKeyboardInputPreviewTests/VoiceKeyboardInputPreviewSnapshotTests \
		CODE_SIGNING_ALLOWED=NO

.PHONY: docc
docc: generate
	for scheme in $(DOCC_SCHEMES); do \
		$(XCODEBUILD) docbuild \
			-project $(IOS_PROJECT) \
			-scheme $$scheme \
			-destination 'generic/platform=iOS Simulator' \
			-derivedDataPath $(DERIVED_DATA) \
			CODE_SIGNING_ALLOWED=NO || exit $$?; \
	done

.PHONY: generated-check
generated-check: generate mac-generate
	@for path in $(GENERATED_CHECK_PATHS); do test -f "$$path"; done
	@untracked="$$(git ls-files --others --exclude-standard -- $(GENERATED_CHECK_PATHS))"; \
		test -z "$$untracked" || { printf '%s\n' "$$untracked"; exit 1; }
	git diff --exit-code -- $(GENERATED_CHECK_PATHS)

.PHONY: dependency-policy-check
dependency-policy-check:
	status=0; rg --quiet 'AuralKit' $(DEPENDENCY_POLICY_PATHS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(FORBIDDEN_PACKAGE_IMPORTS) $(PACKAGE_SWIFT_DIRS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(FORBIDDEN_EXTENSION_APIS) $(EXTENSION_SAFE_PATHS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(FORBIDDEN_MAC_APP_IMPORTS) $(MAC_APP_SWIFT_DIRS) || status=$$?; test $$status -eq 1
	status=0; rg --quiet 'VoiceKeyboardMenuBar' project.yml || status=$$?; test $$status -eq 1
	status=0; rg --quiet $(MENU_BAR_FORBIDDEN_PROJECT_BLOCK_TOKENS) project-mac.yml || status=$$?; test $$status -eq 1
	test "$$(rg -o 'product: [A-Za-z0-9]+' project-mac.yml | sed 's/product: //' | sort | tr '\n' ' ' | sed 's/ $$//')" = "$$(printf '%s\n' $(MENU_BAR_ALLOWED_PACKAGE_PRODUCTS) | sort | tr '\n' ' ' | sed 's/ $$//')"
	status=0; rg --quiet 'DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE|CODE_SIGN_ENTITLEMENTS' project-mac.yml || status=$$?; test $$status -eq 1
	test "$$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' VoiceKeyboardMenuBar/VoiceKeyboardMenuBar.entitlements)" = "true"
	test "$$(plutil -p VoiceKeyboardMenuBar/VoiceKeyboardMenuBar.entitlements | rg -o '"com[.]apple[.]security[^\"]+"' | sort | tr '\n' ' ' | sed 's/ $$//')" = '"com.apple.security.app-sandbox"'

.PHONY: keyboard-permission-policy-check
keyboard-permission-policy-check:
	rg --quiet 'RequestsOpenAccess:[[:space:]]*true' project.yml
	test "$$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' VoiceKeyboardExtension/Info.plist)" = "true"
	rg --quiet '$(APP_GROUP_ID)' project.yml
	rg --quiet '$(APP_GROUP_ID)' VoiceKeyboardInputApp/VoiceKeyboardInput.entitlements
	rg --quiet '$(APP_GROUP_ID)' VoiceKeyboardExtension/VoiceKeyboardExtension.entitlements

.PHONY: verify
verify:
	$(MAKE) package-strict-test
	$(MAKE) dependency-policy-check
	$(MAKE) keyboard-permission-policy-check
	$(MAKE) generated-check
	$(MAKE) build
	$(MAKE) mac-build
	$(MAKE) mac-test
	$(MAKE) mac-security-check
	$(MAKE) ui-kit-test
	$(MAKE) app-ui-test
	$(MAKE) preview-layout-test
	$(MAKE) docc
