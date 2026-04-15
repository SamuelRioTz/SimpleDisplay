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
VERSION = 1.0.0

.PHONY: all build bundle run clean debug sign dmg

all: bundle

debug:
	swift build
	@rm -rf $(OUT_DIR)/$(APP_NAME)-debug.app
	@mkdir -p $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/MacOS $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Resources
	@cp .build/debug/$(APP_NAME) $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/MacOS/$(APP_NAME)
	@cp $(INFO_PLIST) $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Info.plist
	@cp branding/assets/AppIcon.icns $(OUT_DIR)/$(APP_NAME)-debug.app/Contents/Resources/AppIcon.icns
	@echo "Built $(OUT_DIR)/$(APP_NAME)-debug.app"

build:
	swift build -c release --arch arm64 --arch x86_64

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	@cp $(BINARY) $(MACOS_DIR)/$(APP_NAME)
	@cp $(INFO_PLIST) $(CONTENTS)/Info.plist
	@cp branding/assets/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	@echo "Built $(APP_BUNDLE)"

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
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_STAGING) \
		-ov -format UDRW \
		/tmp/$(APP_NAME)_rw.dmg
	@hdiutil attach /tmp/$(APP_NAME)_rw.dmg -mountpoint /tmp/$(APP_NAME)_mount
	@cp branding/assets/AppIcon.icns /tmp/$(APP_NAME)_mount/.VolumeIcon.icns
	@-SetFile -a C /tmp/$(APP_NAME)_mount 2>/dev/null || true
	@hdiutil detach /tmp/$(APP_NAME)_mount
	@hdiutil convert /tmp/$(APP_NAME)_rw.dmg -format UDZO -o $(DMG_NAME)
	@rm -f /tmp/$(APP_NAME)_rw.dmg
	@rm -rf $(DMG_STAGING)
	@echo "Created $(DMG_NAME)"

clean:
	@rm -rf .build
