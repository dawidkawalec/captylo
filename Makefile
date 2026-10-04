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
# Public releases (scripts/release.sh): codesign matches this as a prefix of the certificate
# name, so one Developer ID Application certificate in the login Keychain is enough.
DIST_IDENTITY ?= Developer ID Application

.PHONY: gen build test release sign install run clean reset-tcc check help dist dist-dry publish publish-check

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
# Signing goes inside-out (scripts/sign-app.sh) so the embedded Sparkle.framework and its helpers
# carry the same identity. That alone is not enough here: hardened runtime library validation
# matches Team IDs, and neither the self-signed certificate nor an ad-hoc signature has one, so
# dyld would refuse Sparkle and the app would die at launch (Xcode's own ad-hoc Release product
# does exactly that). Development signatures therefore add
# com.apple.security.cs.disable-library-validation to a copy of the app's entitlements made at
# sign time. The Developer ID release signs with Captylo.entitlements as is, never with this.
DEV_ENTITLEMENTS := $(DERIVED)/CaptyloDev.entitlements

sign:
	@mkdir -p "$(DERIVED)"
	@cp "$(CURDIR)/Captylo/Captylo.entitlements" "$(DEV_ENTITLEMENTS)"
	@/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$(DEV_ENTITLEMENTS)"
	@if security find-identity -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q '"$(SIGN_NAME)"'; then \
		security unlock-keychain -p "$$(cat "$(SIGN_PASSWORD_FILE)")" "$(SIGN_KEYCHAIN)"; \
		ORIGINAL="$$(security list-keychains -d user | tr -d '"' | xargs)"; \
		trap 'security list-keychains -d user -s $$ORIGINAL' EXIT; \
		security list-keychains -d user -s $$ORIGINAL "$(SIGN_KEYCHAIN)"; \
		"$(CURDIR)/scripts/sign-app.sh" "$(APP_PATH)" "$(SIGN_NAME)" --no-timestamp \
			--entitlements "$(DEV_ENTITLEMENTS)" --keychain "$(SIGN_KEYCHAIN)" && \
		echo "Signed with $(SIGN_NAME)"; \
	else \
		echo "No '$(SIGN_NAME)' identity (run scripts/setup-signing.sh); signing ad-hoc"; \
		"$(CURDIR)/scripts/sign-app.sh" "$(APP_PATH)" - --no-timestamp --entitlements "$(DEV_ENTITLEMENTS)"; \
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

# Public release into dist/<version>/: Developer ID signature, notarization, stapled DMG,
# appcast item (scripts/release.sh, docs/release.md). dist-dry signs with "Captylo Dev",
# skips notarization and writes the appcast into dist/ only. publish uploads the DMG and the
# site and creates the GitHub release (owner only, asks first); publish-check only looks.
dist:
	@test -n "$(VERSION)" || { echo "usage: make dist VERSION=1.0.0"; exit 2; }
	@DIST_IDENTITY="$(DIST_IDENTITY)" "$(CURDIR)/scripts/release.sh" "$(VERSION)"

dist-dry:
	@test -n "$(VERSION)" || { echo "usage: make dist-dry VERSION=1.0.0"; exit 2; }
	@DRY_RUN=1 DIST_IDENTITY="$(DIST_IDENTITY)" "$(CURDIR)/scripts/release.sh" "$(VERSION)" --allow-branch

publish:
	@test -n "$(VERSION)" || { echo "usage: make publish VERSION=1.0.0"; exit 2; }
	@"$(CURDIR)/scripts/publish-release.sh" "$(VERSION)"

publish-check:
	@test -n "$(VERSION)" || { echo "usage: make publish-check VERSION=1.0.0"; exit 2; }
	@"$(CURDIR)/scripts/publish-release.sh" "$(VERSION)" --check

clean:
	rm -rf "$(DERIVED)" $(PROJECT)

help:
	@echo "gen build test release install run check reset-tcc clean"
	@echo "dist VERSION=x.y.z      Developer ID release into dist/ (sign, notarize, DMG, appcast)"
	@echo "dist-dry VERSION=x.y.z  the same with Captylo Dev, no notarization, nothing leaves the Mac"
	@echo "publish VERSION=x.y.z   upload the DMG and the site (appcast), GitHub release; asks first"
	@echo "publish-check VERSION=x.y.z  the same checks, nothing leaves the Mac"
