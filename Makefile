BINARY     := Keg
APP_NAME   := Keg.app
BUNDLE_ID  := dev.keg.app
VERSION    := 1.0
BUILD_DIR  := .build/release
MACOS_DIR  := $(APP_NAME)/Contents/MacOS
RES_DIR    := $(APP_NAME)/Contents/Resources
PLIST      := $(APP_NAME)/Contents/Info.plist
ICON_FILE  := Resources/Keg.icns

.PHONY: all build app open run test clean

all: app

build:
	swift build -c release

app: build
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	@cp $(BUILD_DIR)/$(BINARY) $(MACOS_DIR)/$(BINARY)
	@cp $(ICON_FILE) $(RES_DIR)/Keg.icns
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
	@echo "✅ Built $(APP_NAME)"

open: app
	open $(APP_NAME)

run: app
	@$(BUILD_DIR)/$(BINARY) &
	@echo "✅ Running $(BINARY) (PID: $$!)"

test:
	swift test --filter KegTests

clean:
	swift package clean
	@rm -rf $(APP_NAME)
	@echo "✅ Cleaned"
