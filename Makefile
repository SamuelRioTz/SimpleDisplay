APP_NAME = SimpleDisplay
BUILD_DIR = .build/apple/Products/Release
OUT_DIR = .build
APP_BUNDLE = $(OUT_DIR)/$(APP_NAME).app
BINARY = $(BUILD_DIR)/$(APP_NAME)
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources
INFO_PLIST = Info.plist
DMG_NAME = $(OUT_DIR)/$(APP_NAME).dmg
DMG_STAGING = $(OUT_DIR)/dmg-staging
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "1.0.0")

.PHONY: all build bundle run clean debug sign dmg

all: bundle

debug:
	swift build
	@rm -rf $(OUT_DIR)/$(APP_NAME)-debug.app
	@mkdir -p $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/MacOS $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Resources
	@cp .build/debug/$(APP_NAME) $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/MacOS/$(APP_NAME)
	@cp $(INFO_PLIST) $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Info.plist
	@cp branding/assets/AppIcon.icns $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Resources/AppIcon.icns
	@echo "Built $(OUT_DIR)/$(APP_NAME)-debug.app ($(VERSION))"

build:
	swift build -c release --arch arm64 --arch x86_64

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	@cp $(BINARY) $(MACOS_DIR)/$(APP_NAME)
	@cp $(INFO_PLIST) $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(CONTENTS)/Info.plist
	@cp branding/assets/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	@-cp -R $(BUILD_DIR)/SimpleDisplay_SimpleDisplay.bundle $(RESOURCES_DIR)/ 2>/dev/null || true
	@echo "Built $(APP_BUNDLE) ($(VERSION))"

run: debug
	@open $(OUT_DIR)/$(APP_NAME)-debug.app

run-release: bundle
	@open $(APP_BUNDLE)

sign: bundle
	@codesign --sign - \
		--options runtime \
		--entitlements Entitlements.plist \
		--force \
		$(APP_BUNDLE)
	@echo "Signed $(APP_BUNDLE) (Hardened Runtime)"

dmg: sign
	@rm -f $(DMG_NAME)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP_BUNDLE) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	@mkdir -p $(DMG_STAGING)/.background
	@cp branding/assets/dmg-background.png $(DMG_STAGING)/.background/background.png
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_STAGING) \
		-ov -format UDRW \
		/tmp/$(APP_NAME)_rw.dmg
	@hdiutil attach /tmp/$(APP_NAME)_rw.dmg -mountpoint /tmp/$(APP_NAME)_mount
	@cp branding/assets/AppIcon.icns /tmp/$(APP_NAME)_mount/.VolumeIcon.icns
	@-SetFile -a C /tmp/$(APP_NAME)_mount 2>/dev/null || true
	@osascript -e '\
		tell application "Finder" \n\
			tell disk "$(APP_NAME)" \n\
				open \n\
				set current view of container window to icon view \n\
				set toolbar visible of container window to false \n\
				set statusbar visible of container window to false \n\
				set bounds of container window to {200, 120, 860, 520} \n\
				set opts to icon view options of container window \n\
				set icon size of opts to 80 \n\
				set arrangement of opts to not arranged \n\
				set background picture of opts to file ".background:background.png" \n\
				set position of item "$(APP_NAME).app" of container window to {165, 168} \n\
				set position of item "Applications" of container window to {495, 168} \n\
				close \n\
				open \n\
			end tell \n\
		end tell' || true
	@sync
	@hdiutil detach /tmp/$(APP_NAME)_mount
	@hdiutil convert /tmp/$(APP_NAME)_rw.dmg -format UDZO -o $(DMG_NAME)
	@rm -f /tmp/$(APP_NAME)_rw.dmg
	@rm -rf $(DMG_STAGING)
	@echo "Created $(DMG_NAME)"

clean:
	@rm -rf .build
