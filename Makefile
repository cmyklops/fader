XCODEGEN    := /tmp/xcodegen_bin/xcodegen/bin/xcodegen
SCHEME      := Fader
PROJECT_YML := /Users/mattwesdock/Code/Fader/project.yml
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Fader/Info.plist 2>/dev/null || echo 0.1.0)
DMG_NAME    := Fader-$(VERSION).dmg
DMG_STAGING := /tmp/fader-dmg-staging

# Resolve the Release and Debug build output directories once at parse time.
RELEASE_DIR := $(shell xcodebuild -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR =/{print $$3; exit}')
DEBUG_DIR   := $(shell xcodebuild -scheme $(SCHEME) -configuration Debug  -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR =/{print $$3; exit}')

.PHONY: build install uninstall run clean dev dmg

# Generate the Xcode project and build a Release binary.
build:
	$(XCODEGEN) generate --spec $(PROJECT_YML)
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

# Generate the project, build Debug, and open the app directly from DerivedData.
dev:
	$(XCODEGEN) generate --spec $(PROJECT_YML)
	xcodebuild -scheme $(SCHEME) -configuration Debug build
	open "$(DEBUG_DIR)/Fader.app"
