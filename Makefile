# Recipes run under bash with pipefail so a failing xcodebuild can never be
# masked by the grep/tail that prettify its output.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: gen build run test cli fixtures selftest dmg icon clean cert install

APP := dist/Blurt.app

gen:
	xcodegen generate

build: gen
	@Scripts/build.sh

run: build
	open $(APP)

cli: gen
	@Scripts/build.sh --cli-only

test: gen
	xcodebuild test -project Blurt.xcodeproj -scheme Blurt \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build \
		2>&1 | grep -Ev '^\s*$$' | tail -40

fixtures:
	@Scripts/make_fixtures.sh

selftest: cli fixtures
	@build/Build/Products/Debug/blurt-cli selftest

icon:
	@Scripts/make_icon.sh

cert:
	@Scripts/make_signing_cert.sh

dmg: build
	@Scripts/make_dmg.sh

install: build
	@rm -rf /Applications/Blurt.app
	@cp -R $(APP) /Applications/
	@echo "Installed to /Applications/Blurt.app"

clean:
	rm -rf build dist Blurt.xcodeproj Generated
