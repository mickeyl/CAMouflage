prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin

# Mock app
MOCK_CODESIGN_MATCH ?= Developer ID Application
MOCK_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(MOCK_CODESIGN_MATCH)/ {print $$2; exit}')
MOCK_CODESIGN_FLAGS ?= --options runtime --timestamp
MOCK_SRCS = $(shell find Sources/CAMouflage-Mock -name '*.swift' 2>/dev/null)
MOCK_PLIST = Sources/CAMouflage-Mock/Resources/Info.plist
MOCK_ENTITLEMENTS = Sources/CAMouflage-Mock/Resources/entitlements.plist
MOCK_ICON = Sources/CAMouflage-Mock/Resources/CAMouflage.icns
MOCK_BUNDLE = CAMouflage-Mock.app
MOCK_BIN = $(MOCK_BUNDLE)/Contents/MacOS/CAMouflage-Mock
MOCK_BIN_NAME = CAMouflage-Mock
INSTALLED_MOCK_APP = $(INSTALL_DIR)/$(MOCK_BUNDLE)
MOCK_DIST_ZIP = CAMouflage-Mock.zip
NOTARY_PROFILE ?=

# Monotonic build number derived from commit count; falls back to the
# value already in the source Info.plist when the tree is not a git
# checkout (e.g. a tarball).
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null)

SWIFTPM_FLAGS ?= --disable-sandbox

.DEFAULT_GOAL := help

.PHONY: help lib mock mock-debug mock-dev mock-relaunch mock-install mock-run mock-stop mock-assess mock-notarize mock-clean \
        install uninstall clean status log

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Library (simulator-side):"
	@echo "  lib         Build the CAMouflage library for the iOS Simulator"
	@echo ""
	@echo "Mock (virtual camera devices):"
	@echo "  mock        Build the mock menubar app (release)"
	@echo "  mock-debug  Build with debug symbols"
	@echo "  mock-dev    Stop, debug-build, and run in foreground"
	@echo "  mock-relaunch  Quick debug rebuild and background relaunch"
	@echo "  mock-run    Install and start the mock app"
	@echo "  mock-stop   Stop the running mock app"
	@echo "  mock-assess Verify signing and Gatekeeper assessment"
	@echo "  mock-notarize Notarize the mock app (requires NOTARY_PROFILE)"
	@echo "  mock-clean  Remove mock build artifacts"
	@echo ""
	@echo "General:"
	@echo "  install     Build and install the mock app to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo "  status      Show whether the mock app is running"
	@echo "  log         Tail system log output from the mock app"
	@echo "  clean       Remove all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  prefix               Install prefix        [$(prefix)]"
	@echo "  MOCK_CODESIGN_MATCH  Mock signing identity [$(MOCK_CODESIGN_MATCH)]"
	@echo "  NOTARY_PROFILE       notarytool profile    [$(NOTARY_PROFILE)]"

lib:
	xcodebuild -scheme CAMouflage -destination 'generic/platform=iOS Simulator' build -quiet | xcbeautify -qq || true
	@echo "Library build finished"

mock: $(MOCK_BIN)

mock-debug: SWIFTBUILD_CONFIG = debug
mock-debug: mock-build-debug

mock-dev: mock-clean mock-build-debug
	@pkill -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(MOCK_BIN)

.PHONY: mock-build-debug
mock-build-debug:
	@mkdir -p $(MOCK_BUNDLE)/Contents/MacOS $(MOCK_BUNDLE)/Contents/Resources
	@cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	@cp $(MOCK_ICON) $(MOCK_BUNDLE)/Contents/Resources/CAMouflage.icns
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MOCK_BUNDLE)/Contents/Info.plist; fi
	@cd Sources/CAMouflage-Mock && swift build $(SWIFTPM_FLAGS) 2>&1 | tail -3
	@cp Sources/CAMouflage-Mock/.build/debug/$(MOCK_BIN_NAME) $(MOCK_BIN)
	@codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE) >/dev/null
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true

mock-relaunch: mock-build-debug
	@pkill -f "$(MOCK_BIN_NAME)" 2>/dev/null && sleep 0.5 || true
	@open "$(MOCK_BUNDLE)"
	@echo "Mock app relaunched (debug build)"

$(MOCK_BIN): $(MOCK_SRCS) $(MOCK_PLIST) $(MOCK_ENTITLEMENTS) $(MOCK_ICON)
	mkdir -p $(MOCK_BUNDLE)/Contents/MacOS $(MOCK_BUNDLE)/Contents/Resources
	cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	cp $(MOCK_ICON) $(MOCK_BUNDLE)/Contents/Resources/CAMouflage.icns
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MOCK_BUNDLE)/Contents/Info.plist; fi
	cd Sources/CAMouflage-Mock && swift build $(SWIFTPM_FLAGS) -c release
	cp Sources/CAMouflage-Mock/.build/release/$(MOCK_BIN_NAME) $(MOCK_BIN)
	@if [ -z "$(MOCK_SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(MOCK_CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the mock app ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	else \
		echo "Codesigning mock app with: $(MOCK_SIGN_IDENTITY)"; \
		codesign --force --sign "$(MOCK_SIGN_IDENTITY)" $(MOCK_CODESIGN_FLAGS) --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	fi
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true

mock-install: mock
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_MOCK_APP)
	cp -R $(MOCK_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MOCK_APP) 2>/dev/null || true

install: mock-install

uninstall:
	rm -rf $(INSTALLED_MOCK_APP)
	@echo "Uninstalled from $(INSTALL_DIR)"

mock-run: mock-install
	@if ! pgrep -f $(MOCK_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_MOCK_APP)"; \
		echo "CAMouflage-Mock started"; \
	else \
		echo "CAMouflage-Mock already running"; \
	fi

mock-stop:
	@pid=$$(pgrep -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "CAMouflage-Mock stopped (was PID $$pid)"; \
	else \
		echo "CAMouflage-Mock is not running"; \
	fi

status:
	@pid=$$(pgrep -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "CAMouflage-Mock is running (PID $$pid)"; \
	else \
		echo "CAMouflage-Mock is not running"; \
	fi

log:
	@echo "Tailing logs for CAMouflage-Mock… (^C to stop)"
	@log stream --predicate 'process == "CAMouflage-Mock"' --style compact

mock-assess: mock
	codesign --verify --deep --strict --verbose=4 $(MOCK_BUNDLE)
	spctl -a -vvv -t exec $(MOCK_BUNDLE)

mock-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials camouflage-notary"; \
		exit 1; \
	fi
	$(MAKE) mock-clean
	$(MAKE) mock
	rm -f $(MOCK_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)
	xcrun notarytool submit $(MOCK_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(MOCK_BUNDLE)
	$(MAKE) mock-assess

mock-clean:
	rm -rf $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)

clean: mock-clean
	rm -rf .build Sources/CAMouflage-Mock/.build
