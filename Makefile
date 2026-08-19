prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin

# Mac app
MAC_CODESIGN_MATCH ?= Developer ID Application
MAC_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(MAC_CODESIGN_MATCH)/ {print $$2; exit}')
MAC_CODESIGN_FLAGS ?= --options runtime --timestamp
MAC_SRCS = $(shell find Sources/CAMouflage-Mac -name '*.swift' 2>/dev/null)
MAC_PLIST = Sources/CAMouflage-Mac/Resources/Info.plist
MAC_ENTITLEMENTS = Sources/CAMouflage-Mac/Resources/entitlements.plist
MAC_ICON = Sources/CAMouflage-Mac/Resources/CAMouflage.icns
MAC_BUNDLE = CAMouflage-Mac.app
MAC_BIN = $(MAC_BUNDLE)/Contents/MacOS/CAMouflage-Mac
MAC_BIN_NAME = CAMouflage-Mac
INSTALLED_MAC_APP = $(INSTALL_DIR)/$(MAC_BUNDLE)
MAC_DIST_ZIP = CAMouflage-Mac.zip
NOTARY_PROFILE ?=

# Monotonic build number derived from commit count; falls back to the
# value already in the source Info.plist when the tree is not a git
# checkout (e.g. a tarball).
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null)

SWIFTPM_FLAGS ?= --disable-sandbox

.DEFAULT_GOAL := help

.PHONY: help lib mac mac-debug mac-dev mac-relaunch mac-install mac-run mac-stop mac-assess mac-notarize mac-clean \
        install uninstall clean status log

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Library (simulator-side):"
	@echo "  lib         Build the CAMouflage library for the iOS Simulator"
	@echo ""
	@echo "Mac (virtual camera devices):"
	@echo "  mac        Build the Mac menubar app (release)"
	@echo "  mac-debug  Build with debug symbols"
	@echo "  mac-dev    Stop, debug-build, and run in foreground"
	@echo "  mac-relaunch  Quick debug rebuild and background relaunch"
	@echo "  mac-run    Install and start the Mac app"
	@echo "  mac-stop   Stop the running Mac app"
	@echo "  mac-assess Verify signing and Gatekeeper assessment"
	@echo "  mac-notarize Notarize the Mac app (requires NOTARY_PROFILE)"
	@echo "  mac-clean  Remove mac build artifacts"
	@echo ""
	@echo "General:"
	@echo "  install     Build and install the Mac app to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo "  status      Show whether the Mac app is running"
	@echo "  log         Tail system log output from the Mac app"
	@echo "  clean       Remove all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  prefix               Install prefix        [$(prefix)]"
	@echo "  MAC_CODESIGN_MATCH  Mac signing identity [$(MAC_CODESIGN_MATCH)]"
	@echo "  NOTARY_PROFILE       notarytool profile    [$(NOTARY_PROFILE)]"

lib:
	xcodebuild -scheme CAMouflage -destination 'generic/platform=iOS Simulator' build -quiet | xcbeautify -qq || true
	@echo "Library build finished"

mac: $(MAC_BIN)

mac-debug: SWIFTBUILD_CONFIG = debug
mac-debug: mac-build-debug

mac-dev: mac-clean mac-build-debug
	@pkill -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(MAC_BIN)

.PHONY: mac-build-debug
mac-build-debug:
	@mkdir -p $(MAC_BUNDLE)/Contents/MacOS $(MAC_BUNDLE)/Contents/Resources
	@cp $(MAC_PLIST) $(MAC_BUNDLE)/Contents/Info.plist
	@cp $(MAC_ICON) $(MAC_BUNDLE)/Contents/Resources/CAMouflage.icns
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MAC_BUNDLE)/Contents/Info.plist; fi
	@cd Sources/CAMouflage-Mac && swift build $(SWIFTPM_FLAGS) 2>&1 | tail -3
	@cp Sources/CAMouflage-Mac/.build/debug/$(MAC_BIN_NAME) $(MAC_BIN)
	@codesign --force --sign - --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE) >/dev/null
	@xattr -cr $(MAC_BUNDLE) 2>/dev/null || true

mac-relaunch: mac-build-debug
	@pkill -f "$(MAC_BIN_NAME)" 2>/dev/null && sleep 0.5 || true
	@open "$(MAC_BUNDLE)"
	@echo "Mac app relaunched (debug build)"

$(MAC_BIN): $(MAC_SRCS) $(MAC_PLIST) $(MAC_ENTITLEMENTS) $(MAC_ICON)
	mkdir -p $(MAC_BUNDLE)/Contents/MacOS $(MAC_BUNDLE)/Contents/Resources
	cp $(MAC_PLIST) $(MAC_BUNDLE)/Contents/Info.plist
	cp $(MAC_ICON) $(MAC_BUNDLE)/Contents/Resources/CAMouflage.icns
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MAC_BUNDLE)/Contents/Info.plist; fi
	cd Sources/CAMouflage-Mac && swift build $(SWIFTPM_FLAGS) -c release
	cp Sources/CAMouflage-Mac/.build/release/$(MAC_BIN_NAME) $(MAC_BIN)
	@if [ -z "$(MAC_SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(MAC_CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the Mac app ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE); \
	else \
		echo "Codesigning Mac app with: $(MAC_SIGN_IDENTITY)"; \
		codesign --force --sign "$(MAC_SIGN_IDENTITY)" $(MAC_CODESIGN_FLAGS) --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE); \
	fi
	@xattr -cr $(MAC_BUNDLE) 2>/dev/null || true

mac-install: mac
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_MAC_APP)
	cp -R $(MAC_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MAC_APP) 2>/dev/null || true

install: mac-install

uninstall:
	rm -rf $(INSTALLED_MAC_APP)
	@echo "Uninstalled from $(INSTALL_DIR)"

mac-run: mac-install
	@if ! pgrep -f $(MAC_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_MAC_APP)"; \
		echo "CAMouflage-Mac started"; \
	else \
		echo "CAMouflage-Mac already running"; \
	fi

mac-stop:
	@pid=$$(pgrep -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "CAMouflage-Mac stopped (was PID $$pid)"; \
	else \
		echo "CAMouflage-Mac is not running"; \
	fi

status:
	@pid=$$(pgrep -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "CAMouflage-Mac is running (PID $$pid)"; \
	else \
		echo "CAMouflage-Mac is not running"; \
	fi

log:
	@echo "Tailing logs for CAMouflage-Mac… (^C to stop)"
	@log stream --predicate 'process == "CAMouflage-Mac"' --style compact

mac-assess: mac
	codesign --verify --deep --strict --verbose=4 $(MAC_BUNDLE)
	spctl -a -vvv -t exec $(MAC_BUNDLE)

mac-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials camouflage-notary"; \
		exit 1; \
	fi
	$(MAKE) mac-clean
	$(MAKE) mac
	rm -f $(MAC_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(MAC_BUNDLE) $(MAC_DIST_ZIP)
	xcrun notarytool submit $(MAC_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(MAC_BUNDLE)
	$(MAKE) mac-assess

mac-clean:
	rm -rf $(MAC_BUNDLE) $(MAC_DIST_ZIP)

clean: mac-clean
	rm -rf .build Sources/CAMouflage-Mac/.build
