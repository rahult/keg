BINARY     := Keg
RELEASE_DIR := release
APP_NAME   := $(RELEASE_DIR)/Keg.app
BUNDLE_ID  := dev.rahult.keg

# The tag is the single source of truth for the version. A checkout sitting on
# v0.2.0 builds 0.2.0; anywhere else you get the last tag, which is honest
# enough for a local build and never ends up in a release.
VERSION    ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
ifeq ($(strip $(VERSION)),)
VERSION    := 0.0.0-dev
endif

# Sparkle compares CFBundleVersion, not the marketing version, so it has to
# increase with every published build. CI passes the workflow run number.
BUILD      ?= 1

BUILD_DIR  := .build/release
MACOS_DIR  := $(APP_NAME)/Contents/MacOS
RES_DIR    := $(APP_NAME)/Contents/Resources
FRAMEWORKS_DIR := $(APP_NAME)/Contents/Frameworks
PLIST      := $(APP_NAME)/Contents/Info.plist
ICON_FILE  := Resources/Keg.icns
MENU_BAR_ICON_FILE := Resources/KegMenuBarTemplate.png
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CODESIGN   := /usr/bin/codesign

# Any identity will do for a local build you only run yourself.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:|Developer ID Application:/ { print $$2; exit }')
# Distribution is stricter: only a Developer ID can be notarized.
RELEASE_IDENTITY  ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ { print $$2; exit }')

# Sparkle's public EdDSA key. Public by design — it ships inside the app so it
# can verify the signature on a downloaded update. Its private half lives only
# in the SPARKLE_PRIVATE_KEY CI secret.
SPARKLE_PUBLIC_KEY ?= $(shell cat Resources/sparkle-public-key.txt 2>/dev/null)
APPCAST_URL := https://keg.rahultrikha.com/appcast.xml
SPARKLE_FRAMEWORK := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

DMG_NAME   := $(RELEASE_DIR)/Keg-$(VERSION).dmg
DMG_TEMP   := .build/dmg-temp
DMG_RW     := .build/Keg-rw.dmg
ZIP_NAME   := $(RELEASE_DIR)/Keg-$(VERSION).zip
# Un-versioned so the site can point at a permanent
# /releases/latest/download/Keg.dmg URL that never needs regenerating.
DMG_LATEST := $(RELEASE_DIR)/Keg.dmg

.PHONY: all build bundle sign app open run test qa qa-live qa-agents dmg install clean \
        release-app notarize zip dmg-only release version

all: app

version:
	@echo "$(VERSION)"

build:
	swift build -c release

# Lay out the .app. Signing is deliberately a separate step because local
# builds and release builds sign the same bundle very differently.
bundle: build
	@rm -rf $(APP_NAME)
	@mkdir -p $(MACOS_DIR) $(RES_DIR) $(FRAMEWORKS_DIR)
	@cp $(BUILD_DIR)/$(BINARY) $(MACOS_DIR)/$(BINARY)
	@cp $(ICON_FILE) $(RES_DIR)/Keg.icns
	@cp $(MENU_BAR_ICON_FILE) $(RES_DIR)/KegMenuBarTemplate.png
	@test -d $(SPARKLE_FRAMEWORK) || { echo "❌ Sparkle.framework not found. Run 'swift package resolve' first."; exit 1; }
	@cp -R $(SPARKLE_FRAMEWORK) $(FRAMEWORKS_DIR)/
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
	@echo '  <key>CFBundleShortVersionString</key>    <string>$(VERSION)</string>'          >> $(PLIST)
	@echo '  <key>CFBundleVersion</key>               <string>$(BUILD)</string>'            >> $(PLIST)
	@echo '  <key>LSMinimumSystemVersion</key>        <string>26.0</string>'                >> $(PLIST)
	@echo '  <key>NSHighResolutionCapable</key>       <true/>'                              >> $(PLIST)
	@echo '  <key>SUFeedURL</key>                     <string>$(APPCAST_URL)</string>'      >> $(PLIST)
	@echo '  <key>SUPublicEDKey</key>                 <string>$(SPARKLE_PUBLIC_KEY)</string>' >> $(PLIST)
	@echo '</dict></plist>'                                                                >> $(PLIST)

# Sign everything Sparkle ships from the inside out. Signing the outer app
# first and the nested helpers afterwards invalidates the outer signature,
# which is the usual reason a Sparkle app launches fine locally and is then
# rejected by Gatekeeper on someone else's Mac.
#
# $(1) is the identity, $(2) any extra codesign flags (hardened runtime and a
# secure timestamp for release builds; neither is wanted locally because the
# timestamp server makes every build a network round trip).
define sign_bundle
	@fw="$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B"; \
	for nested in "$$fw/XPCServices/Downloader.xpc" "$$fw/XPCServices/Installer.xpc" "$$fw/Updater.app" "$$fw/Autoupdate"; do \
		$(CODESIGN) --force --sign "$(1)" $(2) --preserve-metadata=entitlements "$$nested" || exit 1; \
	done; \
	$(CODESIGN) --force --sign "$(1)" $(2) "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B" || exit 1
	@$(CODESIGN) --force --sign "$(1)" $(2) $(APP_NAME)
	@$(CODESIGN) --verify --deep --strict --verbose=2 $(APP_NAME)
endef

sign: bundle
	@test -n "$(CODESIGN_IDENTITY)" || { echo "❌ No Apple code signing identity found. Set CODESIGN_IDENTITY or install Apple Development cert."; exit 1; }
	$(call sign_bundle,$(CODESIGN_IDENTITY),--timestamp=none)
	@echo "✅ Signed $(APP_NAME) with $(CODESIGN_IDENTITY)"

app: sign
	@echo "✅ Built $(APP_NAME) ($(VERSION) build $(BUILD))"

# The distribution build: Developer ID, hardened runtime, secure timestamp.
# Notarization rejects a bundle missing any of the three.
release-app: bundle
	@test -n "$(RELEASE_IDENTITY)" || { echo "❌ No 'Developer ID Application' identity found. Release builds cannot be notarized without one."; exit 1; }
	@test -n "$(SPARKLE_PUBLIC_KEY)" || { echo "❌ Resources/sparkle-public-key.txt is missing or empty — shipping without it would leave updates unverifiable. Run ./Scripts/setup-release.sh"; exit 1; }
	$(call sign_bundle,$(RELEASE_IDENTITY),--options runtime --timestamp)
	@echo "✅ Signed $(APP_NAME) for distribution with $(RELEASE_IDENTITY)"

# notarytool only accepts an archive, but the ticket is stapled to the .app
# itself, so the zip here is a throwaway submission vehicle — the shipping
# archives are built afterwards from the stapled bundle.
notarize:
	@test -n "$$APPLE_ID" && test -n "$$APPLE_PASSWORD" && test -n "$$APPLE_TEAM_ID" \
		|| { echo "❌ Set APPLE_ID, APPLE_PASSWORD (app-specific) and APPLE_TEAM_ID."; exit 1; }
	@echo "📤 Submitting $(APP_NAME) to Apple…"
	@rm -f .build/notarize.zip
	@ditto -c -k --sequesterRsrc --keepParent $(APP_NAME) .build/notarize.zip
	@xcrun notarytool submit .build/notarize.zip \
		--apple-id "$$APPLE_ID" --password "$$APPLE_PASSWORD" --team-id "$$APPLE_TEAM_ID" --wait
	@xcrun stapler staple $(APP_NAME)
	@rm -f .build/notarize.zip
	@echo "✅ Notarized and stapled $(APP_NAME)"

# Sparkle's update artifact. ditto rather than `zip` because it is the only
# archiver that reliably preserves the symlinks in a versioned framework.
zip:
	@rm -f $(ZIP_NAME)
	@ditto -c -k --sequesterRsrc --keepParent $(APP_NAME) $(ZIP_NAME)
	@echo "✅ $(ZIP_NAME) ($$(du -h $(ZIP_NAME) | cut -f1))"

dmg: app
	@$(MAKE) dmg-only

dmg-only:
	@echo "📦 Creating DMG..."
	@rm -rf $(DMG_TEMP) $(DMG_RW) $(DMG_NAME) $(DMG_LATEST)
	@mkdir -p $(DMG_TEMP)
	@cp -R $(APP_NAME) $(DMG_TEMP)/
	@ln -s /Applications $(DMG_TEMP)/Applications
	@hdiutil create -srcfolder $(DMG_TEMP) -volname "Keg" -fs HFS+ \
		-format UDRW -size 200m $(DMG_RW) >/dev/null
	@hdiutil convert $(DMG_RW) -format UDZO -imagekey zlib-level=9 \
		-o $(DMG_NAME) >/dev/null
	@rm -rf $(DMG_TEMP) $(DMG_RW)
	@cp $(DMG_NAME) $(DMG_LATEST)
	@echo "✅ $(DMG_NAME) ($$(du -h $(DMG_NAME) | cut -f1))"

# Everything a published release needs, in the order the artifacts depend on
# each other: sign → notarize + staple the app → archive the stapled app.
# The DMG is notarized separately because the ticket is stapled to the disk
# image, not to the app inside it.
release: release-app notarize zip dmg-only
	@$(CODESIGN) --force --sign "$(RELEASE_IDENTITY)" --options runtime --timestamp $(DMG_NAME)
	@xcrun notarytool submit $(DMG_NAME) \
		--apple-id "$$APPLE_ID" --password "$$APPLE_PASSWORD" --team-id "$$APPLE_TEAM_ID" --wait
	@xcrun stapler staple $(DMG_NAME)
	@cp $(DMG_NAME) $(DMG_LATEST)
	@echo "✅ Release artifacts ready: $(DMG_NAME), $(DMG_LATEST), $(ZIP_NAME)"

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

install: app
	@echo "🚚 Installing to /Applications/Keg.app..."
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@rm -rf /Applications/Keg.app
	@cp -R $(APP_NAME) /Applications/Keg.app
	@$(LSREGISTER) -f /Applications/Keg.app >/dev/null 2>&1 || true
	@echo "✅ Installed /Applications/Keg.app"

clean:
	swift package clean
	@rm -rf $(RELEASE_DIR) $(DMG_RW) $(DMG_TEMP)
	@echo "✅ Cleaned"
