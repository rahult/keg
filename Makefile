BINARY     := Meadow
RELEASE_DIR := release
APP_NAME   := $(RELEASE_DIR)/Meadow.app
BUNDLE_ID  := dev.rahult.meadow
VERSION    := 0.1.0-alpha
BUILD_DIR  := .build/release
MACOS_DIR  := $(APP_NAME)/Contents/MacOS
RES_DIR    := $(APP_NAME)/Contents/Resources
PLIST      := $(APP_NAME)/Contents/Info.plist
ICON_FILE  := Resources/Meadow.icns
MENU_BAR_ICON_FILE := Resources/MeadowMenuBarTemplate.png
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CODESIGN   := /usr/bin/codesign
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:|Developer ID Application:/ { print $$2; exit }')

DMG_NAME   := $(RELEASE_DIR)/Meadow-$(VERSION).dmg
DMG_TEMP   := .build/dmg-temp
DMG_RW     := .build/Meadow-rw.dmg

.PHONY: all build sign app open run test qa qa-live qa-agents dmg install clean

all: app

build:
	swift build -c release

app: build sign
	@echo "✅ Built $(APP_NAME)"

sign: build
	@test -n "$(CODESIGN_IDENTITY)" || { echo "❌ No Apple code signing identity found. Set CODESIGN_IDENTITY or install Apple Development cert."; exit 1; }
	@rm -rf $(APP_NAME)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	@cp $(BUILD_DIR)/$(BINARY) $(MACOS_DIR)/$(BINARY)
	@cp $(ICON_FILE) $(RES_DIR)/Meadow.icns
	@cp $(MENU_BAR_ICON_FILE) $(RES_DIR)/MeadowMenuBarTemplate.png
	@echo '<?xml version="1.0" encoding="UTF-8"?>'                                         > $(PLIST)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'                           >> $(PLIST)
	@echo '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'                            >> $(PLIST)
	@echo '<plist version="1.0"><dict>'                                                    >> $(PLIST)
	@echo '  <key>CFBundleExecutable</key>            <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleIdentifier</key>            <string>$(BUNDLE_ID)</string>'        >> $(PLIST)
	@echo '  <key>CFBundleName</key>                  <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleDisplayName</key>           <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleIconFile</key>              <string>Meadow.icns</string>'            >> $(PLIST)
	@echo '  <key>CFBundlePackageType</key>           <string>APPL</string>'                >> $(PLIST)
	@echo '  <key>CFBundleShortVersionString</key>   <string>$(VERSION)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleVersion</key>               <string>1</string>'                   >> $(PLIST)
	@echo '  <key>LSMinimumSystemVersion</key>        <string>26.0</string>'                >> $(PLIST)
	@echo '  <key>NSHighResolutionCapable</key>       <true/>'                              >> $(PLIST)
	@echo '</dict></plist>'                                                                >> $(PLIST)
	@$(CODESIGN) --force --sign "$(CODESIGN_IDENTITY)" --timestamp=none $(APP_NAME)
	@$(CODESIGN) --verify --deep --strict --verbose=2 $(APP_NAME)
	@echo "✅ Signed $(APP_NAME) with $(CODESIGN_IDENTITY)"

open: app
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@touch $(APP_NAME)
	@$(LSREGISTER) -f $(APP_NAME) >/dev/null 2>&1 || true
	open -n $(APP_NAME)

run: app
	@open -n $(APP_NAME)
	@echo "✅ Running signed $(APP_NAME)"

test:
	swift test

qa:
	./Scripts/qa.sh

qa-live:
	MEADOW_RUN_CONTAINER_E2E=1 MEADOW_RUN_MANAGED_AGENTS=1 ./Scripts/qa.sh

qa-agents:
	MEADOW_RUN_MANAGED_AGENTS=1 ./Scripts/qa.sh

dmg: app
	@echo "📦 Creating DMG..."
	@rm -rf $(DMG_TEMP) $(DMG_RW) $(DMG_NAME)
	@mkdir -p $(DMG_TEMP)
	@cp -R $(APP_NAME) $(DMG_TEMP)/
	@ln -s /Applications $(DMG_TEMP)/Applications
	@hdiutil create -srcfolder $(DMG_TEMP) -volname "Meadow" -fs HFS+ \
		-format UDRW -size 200m $(DMG_RW) >/dev/null
	@hdiutil convert $(DMG_RW) -format UDZO -imagekey zlib-level=9 \
		-o $(DMG_NAME) >/dev/null
	@rm -rf $(DMG_TEMP) $(DMG_RW)
	@echo "✅ $(DMG_NAME) ($$(du -h $(DMG_NAME) | cut -f1))"

install: app
	@echo "🚚 Installing to /Applications/Meadow.app..."
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@rm -rf /Applications/Meadow.app
	@cp -R $(APP_NAME) /Applications/Meadow.app
	@$(LSREGISTER) -f /Applications/Meadow.app >/dev/null 2>&1 || true
	@echo "✅ Installed /Applications/Meadow.app"

clean:
	swift package clean
	@rm -rf $(RELEASE_DIR) $(DMG_RW) $(DMG_TEMP)
	@echo "✅ Cleaned"
