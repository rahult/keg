BINARY     := Keg
APP_NAME   := Keg.app
BUNDLE_ID  := dev.rahult.keg
VERSION    := 1.0
BUILD_DIR  := .build/release
MACOS_DIR  := $(APP_NAME)/Contents/MacOS
RES_DIR    := $(APP_NAME)/Contents/Resources
PLIST      := $(APP_NAME)/Contents/Info.plist
ICON_FILE  := Resources/Keg.icns
MENU_BAR_ICON_FILE := Resources/KegMenuBarTemplate.png
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CODESIGN   := /usr/bin/codesign
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:|Developer ID Application:/ { print $$2; exit }')

.PHONY: all build sign app open run test qa qa-live qa-agents clean

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
	@cp $(ICON_FILE) $(RES_DIR)/Keg.icns
	@cp $(MENU_BAR_ICON_FILE) $(RES_DIR)/KegMenuBarTemplate.png
	@echo '<?xml version="1.0" encoding="UTF-8"?>'                                         > $(PLIST)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'                           >> $(PLIST)
	@echo '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'                            >> $(PLIST)
	@echo '<plist version="1.0"><dict>'                                                    >> $(PLIST)
	@echo '  <key>CFBundleExecutable</key>            <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleIdentifier</key>            <string>$(BUNDLE_ID)</string>'        >> $(PLIST)
	@echo '  <key>CFBundleName</key>                  <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleDisplayName</key>           <string>$(BINARY)</string>'           >> $(PLIST)
	@echo '  <key>CFBundleIconFile</key>              <string>Keg.icns</string>'            >> $(PLIST)
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
	KEG_RUN_CONTAINER_E2E=1 KEG_RUN_MANAGED_AGENTS=1 ./Scripts/qa.sh

qa-agents:
	KEG_RUN_MANAGED_AGENTS=1 ./Scripts/qa.sh

clean:
	swift package clean
	@rm -rf $(APP_NAME)
	@echo "✅ Cleaned"
