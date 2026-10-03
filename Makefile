# Build/launch driver for Redraft (macOS).
#
# When xcode-build-server is installed, builds are piped through it so
# `.compile` stays fresh for sourcekit-lsp.

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME      := Redraft
PROJECT     := Redraft.xcodeproj
DESTINATION := platform=macOS
DD          := build
APP         := $(DD)/Build/Products/Debug/$(SCHEME).app
RELEASE_APP := $(DD)/Build/Products/Release/$(SCHEME).app
PARSE       := $(if $(shell command -v xcode-build-server),| xcode-build-server parse -av,)

.PHONY: all gen build run launch install install-cli dmg release clean refresh-lsp lsp-config

all: run

gen:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  build \
	  $(PARSE)

launch:
	@pkill -x $(SCHEME) >/dev/null 2>&1 || true
	@sleep 0.3
	open $(APP)

run: build launch

# Release build (no debug hooks), copied to /Applications.
install: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Release \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  build
	@pkill -x $(SCHEME) >/dev/null 2>&1 || true
	rm -rf /Applications/$(SCHEME).app
	cp -R $(RELEASE_APP) /Applications/
	@echo "Installed /Applications/$(SCHEME).app"

# The `redraft` shell command, linked into ~/.local/bin.
CLI_DIR ?= $(HOME)/.local/bin
install-cli:
	@mkdir -p $(CLI_DIR)
	ln -sf $(CURDIR)/Tools/redraft $(CLI_DIR)/redraft
	@echo "Installed $(CLI_DIR)/redraft"

lsp-config:
	xcode-build-server config -scheme $(SCHEME) -project $(PROJECT)

refresh-lsp:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  clean build \
	  $(PARSE)

clean:
	rm -rf $(DD) .compile .bsp

# A signed, notarized disk image for sharing: dist/Redraft-<version>.dmg
# Needs a "Developer ID Application" certificate (Xcode → Settings → Accounts →
# Manage Certificates) and notarization credentials saved once with:
#   xcrun notarytool store-credentials MyWriter --apple-id <email> --team-id KFY97BH6J8
# (the profile name is just where the Apple ID login is kept; it predates the rename)
VERSION      = $(shell grep MARKETING_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG          = dist/$(SCHEME)-$(VERSION).dmg
NOTARY       ?= MyWriter
DEVELOPER_ID := Developer ID Application
# dmgbuild lays out the disk image window (installed into build/ on first use).
DMGBUILD     := $(DD)/venv/bin/dmgbuild

dmg: gen
	@security find-identity -v -p codesigning | grep -q "$(DEVELOPER_ID)" || \
	  { echo "No '$(DEVELOPER_ID)' certificate. Create one in Xcode → Settings → Accounts → Manage Certificates."; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination "$(DESTINATION)" -derivedDataPath $(DD) \
	  CODE_SIGN_IDENTITY="$(DEVELOPER_ID)" OTHER_CODE_SIGN_FLAGS="--timestamp" \
	  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
	  build $(PARSE)
	@# Sparkle's helpers come signed ad hoc; sign them (inside out) with our
	@# Developer ID so the whole app notarizes.
	@F="$(RELEASE_APP)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	for item in "$$F/XPCServices/Installer.xpc" "$$F/XPCServices/Downloader.xpc" "$$F/Autoupdate" "$$F/Updater.app" "$(RELEASE_APP)/Contents/Frameworks/Sparkle.framework"; do \
	  codesign --force --sign "$(DEVELOPER_ID)" --options runtime --timestamp --preserve-metadata=entitlements "$$item" || exit 1; \
	done; \
	codesign --force --sign "$(DEVELOPER_ID)" --options runtime --timestamp "$(RELEASE_APP)"
	codesign --verify --deep --strict "$(RELEASE_APP)"
	@[ -x $(DMGBUILD) ] || { /usr/bin/python3 -m venv $(DD)/venv && $(DD)/venv/bin/pip install -q dmgbuild; }
	mkdir -p dist && rm -f $(DMG)
	$(DMGBUILD) -s Tools/dmg_settings.py -D app="$(RELEASE_APP)" -D background=Design/dmg-background.tiff "$(SCHEME) $(VERSION)" $(DMG)
	codesign --sign "$(DEVELOPER_ID)" --timestamp $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY) --wait
	xcrun stapler staple $(DMG)
	@spctl --assess --type open --context context:primary-signature -v $(DMG)
	@echo "Ready to share: $(DMG)"

# Ship a version: set it, build + notarize the dmg, publish a GitHub Release,
# and install that official copy into /Applications. Usage: make release V=0.1.1
release:
	@Tools/release.sh "$(V)"
