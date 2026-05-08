XCODEGEN    ?= xcodegen
SCHEME      := Fader
PROJECT_YML := /Users/mattwesdock/Code/Fader/project.yml
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Fader/Info.plist 2>/dev/null || echo 0.1.0)
DMG_NAME    := Fader-$(VERSION).dmg
DMG_STAGING := /tmp/fader-dmg-staging
SIGN_IDENTITY ?= Developer ID Application
APPLE_ID ?=
TEAM_ID ?=
APP_SPECIFIC_PASSWORD ?=

# Resolve the Release and Debug build output directories once at parse time.
RELEASE_DIR := $(shell xcodebuild -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR =/{print $$3; exit}')
DEBUG_DIR   := $(shell xcodebuild -scheme $(SCHEME) -configuration Debug  -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR =/{print $$3; exit}')

.PHONY: build install uninstall run clean dev dmg test ci release-dmg verify-signature notarize

# Generate the Xcode project and build a Release binary.
build:
	@if command -v $(XCODEGEN) >/dev/null 2>&1; then $(XCODEGEN) generate --spec $(PROJECT_YML); else echo "xcodegen not found; using existing Fader.xcodeproj"; fi
	xcodebuild -scheme $(SCHEME) -configuration Release build

# Copy the Release app to /Applications and re-register it with Launch Services.
install: build
	cp -R "$(RELEASE_DIR)/Fader.app" /Applications/Fader.app
	xattr -cr /Applications/Fader.app
	touch /Applications/Fader.app

# DESTRUCTIVE: permanently deletes /Applications/Fader.app.
uninstall:
	rm -rf /Applications/Fader.app

# Install the Release build and open it.
run: install
	open /Applications/Fader.app

# Remove Xcode build artifacts for this scheme.
clean:
	xcodebuild -scheme $(SCHEME) clean

# Run unit tests on the local Mac destination.
test:
	xcodebuild test -scheme $(SCHEME) -destination 'platform=macOS'

# CI entrypoint: generate when xcodegen is available, then build and test.
ci:
	@if command -v $(XCODEGEN) >/dev/null 2>&1; then $(XCODEGEN) generate --spec $(PROJECT_YML); else echo "xcodegen not found; using existing Fader.xcodeproj"; fi
	xcodebuild -scheme $(SCHEME) -configuration Debug build
	xcodebuild test -scheme $(SCHEME) -destination 'platform=macOS'

# Build a DMG with Fader.app and an Applications symlink for drag-to-install.
dmg: build
	rm -rf "$(DMG_STAGING)" "$(DMG_NAME)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(RELEASE_DIR)/Fader.app" "$(DMG_STAGING)/Fader.app"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "Fader $(VERSION)" \
		-srcfolder "$(DMG_STAGING)" \
		-ov -format UDZO \
		"$(DMG_NAME)"
	rm -rf "$(DMG_STAGING)"
	@echo "Created $(DMG_NAME)"

# Build and verify a direct-distribution DMG.
release-dmg: dmg verify-signature

# Verify Developer ID signatures before notarization.
verify-signature:
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_DIR)/Fader.app"
	spctl -a -vv --type execute "$(RELEASE_DIR)/Fader.app"

# Submit and staple the already-built DMG. Requires APPLE_ID, TEAM_ID, and APP_SPECIFIC_PASSWORD.
notarize:
	test -n "$(APPLE_ID)"
	test -n "$(TEAM_ID)"
	test -n "$(APP_SPECIFIC_PASSWORD)"
	xcrun notarytool submit "$(DMG_NAME)" --apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)" --password "$(APP_SPECIFIC_PASSWORD)" --wait
	xcrun stapler staple "$(DMG_NAME)"

# Generate the project, build Debug, and open the app directly from DerivedData.
dev:
	@if command -v $(XCODEGEN) >/dev/null 2>&1; then $(XCODEGEN) generate --spec $(PROJECT_YML); else echo "xcodegen not found; using existing Fader.xcodeproj"; fi
	xcodebuild -scheme $(SCHEME) -configuration Debug build
	open "$(DEBUG_DIR)/Fader.app"
