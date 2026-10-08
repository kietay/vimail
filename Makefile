# The Command Line Tools ship the macOS 27 SDK, where SwiftUI's @State is a macro whose plugin
# only ships with Xcode. Build against the 26.5 SDK instead. With full Xcode installed, run
# `make SDKROOT=` to use the default SDK.
CLT := /Library/Developer/CommandLineTools
SDKROOT ?= $(CLT)/SDKs/MacOSX26.5.sdk
export SDKROOT

# Swift Testing's macro plugin is not on the default plugin path with the Command Line Tools.
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing

APP := build/app.noindex/vimail.app

.PHONY: build release test app run dev install uninstall icon clean reset-data

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

# Release build packaged as a signed (ad-hoc) .app bundle.
app: release
	scripts/bundle.sh release

# Debug build packaged as an .app (faster to compile).
dev: build
	scripts/bundle.sh debug

run: app
	open $(APP)

# Release build installed to /Applications (launch it from Spotlight, Launchpad or the Dock).
install: app
	scripts/install.sh

uninstall:
	rm -rf /Applications/vimail.app "$$HOME/Applications/vimail.app"
	@echo "Removed the app. Mail data stays in ~/Library/Application Support/vimail (make reset-data removes it)."

# Regenerates Resources/AppIcon.icns.
icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build build

# Deletes all local state (mail cache, drafts, settings, dummy server). Asks first.
reset-data:
	@read -p "Delete ~/Library/Application Support/vimail? [y/N] " ans; \
	if [ "$$ans" = "y" ]; then rm -rf "$$HOME/Library/Application Support/vimail" "$$HOME/Library/Caches/vimail"; echo "Deleted."; fi
