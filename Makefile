PROJECT := Captylo.xcodeproj
SCHEME := Captylo
DERIVED := $(CURDIR)/.local-build
APP_NAME := Captylo.app
EXECUTABLE := Captylo
BUNDLE_ID := com.captylo.app
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath "$(DERIVED)" -skipPackagePluginValidation -skipMacroValidation
XCPRETTY := grep -E 'error:|warning: .*Captylo(Tests)?/|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|✘|Test run with'
# Stable local signing identity (see scripts/setup-signing.sh). Without it builds stay ad-hoc.
SIGN_NAME := Captylo Dev
SIGN_KEYCHAIN := $(HOME)/Library/Keychains/captylo-dev.keychain-db
SIGN_PASSWORD_FILE := $(HOME)/.claude/secrets/captylo-dev-keychain.key

.PHONY: gen build test release sign install run clean reset-tcc check help

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug CODE_SIGN_IDENTITY="-" build 2>&1 | $(XCPRETTY)

test: gen
	$(XCODEBUILD) -configuration Debug CODE_SIGN_IDENTITY="-" test 2>&1 | $(XCPRETTY)

release: gen
	$(XCODEBUILD) -configuration Release CODE_SIGN_IDENTITY="-" build 2>&1 | $(XCPRETTY)
	@rm -rf "$(HOME)/Downloads/$(APP_NAME)"
	@ditto "$(DERIVED)/Build/Products/Release/$(APP_NAME)" "$(HOME)/Downloads/$(APP_NAME)"
	@xattr -cr "$(HOME)/Downloads/$(APP_NAME)"
	@$(MAKE) --no-print-directory sign APP_PATH="$(HOME)/Downloads/$(APP_NAME)"
	@echo "Release build copied to ~/Downloads/$(APP_NAME)"

# Re-sign with the stable "Captylo Dev" identity so Microphone/Accessibility grants survive rebuilds.
# codesign only finds the identity through the keychain search list, so the signing keychain joins
# the list for this one call and the previous list comes back right after (also on failure or
# Ctrl-C): a keychain left in the list shows up as a client certificate in VPN and browser prompts.
sign:
	@if security find-identity -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q '"$(SIGN_NAME)"'; then \
		security unlock-keychain -p "$$(cat "$(SIGN_PASSWORD_FILE)")" "$(SIGN_KEYCHAIN)"; \
		ORIGINAL="$$(security list-keychains -d user | tr -d '"' | xargs)"; \
		trap 'security list-keychains -d user -s $$ORIGINAL' EXIT; \
		security list-keychains -d user -s $$ORIGINAL "$(SIGN_KEYCHAIN)"; \
		codesign --force --options runtime --timestamp=none --entitlements "$(CURDIR)/Captylo/Captylo.entitlements" \
			--sign "$(SIGN_NAME)" --keychain "$(SIGN_KEYCHAIN)" "$(APP_PATH)" && \
		echo "Signed with $(SIGN_NAME)"; \
	else \
		echo "No '$(SIGN_NAME)' identity (run scripts/setup-signing.sh); keeping the ad-hoc signature"; \
	fi

install: release
	@rm -rf "/Applications/$(APP_NAME)"
	@ditto "$(HOME)/Downloads/$(APP_NAME)" "/Applications/$(APP_NAME)"
	@echo "Installed to /Applications/$(APP_NAME)"

run:
	@if [ -d "/Applications/$(APP_NAME)" ]; then open "/Applications/$(APP_NAME)"; \
	elif [ -d "$(DERIVED)/Build/Products/Release/$(APP_NAME)" ]; then open "$(DERIVED)/Build/Products/Release/$(APP_NAME)"; \
	else open "$(DERIVED)/Build/Products/Debug/$(APP_NAME)"; fi

check:
	@"$(DERIVED)/Build/Products/Debug/$(APP_NAME)/Contents/MacOS/$(EXECUTABLE)" --check

# Ad-hoc signed builds change their code hash on every build, so macOS may drop
# Microphone / Accessibility grants. Run this, then re-grant in System Settings.
reset-tcc:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)

clean:
	rm -rf "$(DERIVED)" $(PROJECT)

help:
	@echo "gen build test release install run check reset-tcc clean"
