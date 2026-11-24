.DEFAULT_GOAL := help
.PHONY: help build test app run install uninstall dist release release-dry-run brand clean

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)

help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Compile everything in debug
	swift build

test: ## Run the tests (the real trackpad check stays off; TAPTONE_MOTOR_CHECK=1 turns it on)
	swift test

app: ## Build .build/Taptone.app in release
	scripts/build-app.sh release

run: ## Build a debug app and open it with diagnostics logging
	scripts/build-app.sh debug >/dev/null
	open .build/Taptone.app --args --diagnostics

install: ## Build in release and install into /Applications (or ~/Applications)
	scripts/install.sh

uninstall: ## Quit and remove the installed app
	scripts/uninstall.sh

dist: app ## Zip the release app into dist/ for local sharing (nothing is uploaded)
	mkdir -p dist
	rm -f dist/Taptone-$(VERSION)-macos.zip
	ditto -c -k --keepParent .build/Taptone.app dist/Taptone-$(VERSION)-macos.zip
	@shasum -a 256 dist/Taptone-$(VERSION)-macos.zip

release: ## Release VERSION=X.Y.Z: notarize, tag, push, publish, update the cask
	@test "$(origin VERSION)" = "command line" || { echo "usage: make release VERSION=X.Y.Z" >&2; exit 2; }
	scripts/release.sh $(VERSION)

release-dry-run: ## Build, sign and check a release locally, publishing nothing (VERSION=X.Y.Z optional)
	scripts/release.sh --dry-run $(VERSION)

brand: ## Redraw the app icon, logo, and README banners
	swift scripts/make-brand.swift

clean: ## Remove build products
	swift package clean
	rm -rf .build/Taptone.app dist
