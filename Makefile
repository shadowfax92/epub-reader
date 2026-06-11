# Apple Silicon Macs run iphoneos arm64 bundles natively ("Designed for iPad"),
# so the Mac app is the regular iOS build — no Catalyst, no separate target.
# Launchability requires dev signing + the App Store wrapper layout; that lives
# in scripts/install-mac.sh.

APP        := EPUBReader
PROJECT    := EPUBReader.xcodeproj
SCHEME     := EPUBReader
CONFIG     := Release
DERIVED    := DerivedData
APP_BUNDLE := $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/$(APP).app

# hw.optional.arm64 stays 1 under Rosetta, where uname -m lies (x86_64)
IS_ARM64 ?= $(shell sysctl -n hw.optional.arm64 2>/dev/null)
XCODEGEN ?= xcodegen

INSTALL_DIR ?= /Applications

REQUIRE_XCODEGEN = @command -v $(XCODEGEN) >/dev/null 2>&1 || { echo "error: xcodegen not found — brew install xcodegen"; exit 1; }

.PHONY: generate build-mac install-mac clean check-arch

generate:
	$(REQUIRE_XCODEGEN)
	$(XCODEGEN) generate

# regen only when the spec changed, so a signing team set in Xcode (stored in
# the pbxproj, wiped by xcodegen) survives make install-mac
$(PROJECT)/project.pbxproj: project.yml
	$(REQUIRE_XCODEGEN)
	$(XCODEGEN) generate

build-mac: check-arch $(PROJECT)/project.pbxproj
	@command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found — install Xcode"; exit 1; }
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO
	@echo "Built: $(APP_BUNDLE)"

install-mac: build-mac
	bash scripts/install-mac.sh "$(APP_BUNDLE)" "$(INSTALL_DIR)"

check-arch:
	@[ "$(IS_ARM64)" = "1" ] || { echo "error: Mac install needs Apple Silicon (iOS apps only run on arm64 Macs)"; exit 1; }

clean:
	rm -rf $(DERIVED)
