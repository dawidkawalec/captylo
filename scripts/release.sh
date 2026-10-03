#!/bin/bash
# Builds a Captylo release: Release build, Developer ID signature, notarization, stapled DMG,
# Sparkle appcast item, release notes page and the version shown in the site's download
# block (site/index.html, <span data-version>). Publishing is a separate step
# (scripts/publish-release.sh). Owner-facing steps: docs/release.md.
#
#   scripts/release.sh <version> [--allow-branch]      (make dist VERSION=1.0.0)
#   DRY_RUN=1 scripts/release.sh <version> --allow-branch   (make dist-dry VERSION=1.0.0)
#
# Order: build -> sign the app inside-out -> notarize the app (zip) -> staple the app ->
# DMG -> sign the DMG -> notarize the DMG -> staple the DMG -> check -> appcast item.
# Both submissions, so the app inside the DMG carries its own ticket too.
#
# A dry run signs with the local "Captylo Dev" identity (make sign), leaves the DMG unsigned,
# skips notarization and stapling, writes the appcast and notes into dist/<version>/ instead
# of site/, and reports what a real run would refuse instead of stopping.
#
# Environment: DIST_IDENTITY (default "Developer ID Application", matched by codesign as a
# prefix of the certificate name), NOTARY_PROFILE (default captylo-notary, a notarytool
# Keychain profile), DRY_RUN=1. Secrets come only from the Keychain: the identity, the
# notary profile and Sparkle's EdDSA key; nothing is read from or written to the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_IDENTITY="${DIST_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-captylo-notary}"
DRY_RUN="${DRY_RUN:-0}"
SPARKLE_BIN="$ROOT/.local-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
DERIVED="$ROOT/.local-build"
PLACEHOLDER_KEY="REPLACE_ME"

usage() {
  echo "usage: [DRY_RUN=1] $0 <version> [--allow-branch]" >&2
  exit 2
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nrelease.sh: %s\n' "$*" >&2; exit 1; }
dry() { [ "$DRY_RUN" = "1" ]; }

# refuse MESSAGE: stops a real release, only reports in a dry run.
refuse() {
  if dry; then note "DRY RUN, a real release would stop here: $*"; else die "$*"; fi
}

[ $# -ge 1 ] || usage
VERSION="$1"
shift
ALLOW_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-branch) ALLOW_BRANCH=1; shift ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "The version must look like 1.2.3, got \"$VERSION\""

OUT="$ROOT/dist/$VERSION"
APP="$OUT/Captylo.app"
DMG="$OUT/Captylo-$VERSION.dmg"
NOTES_MD="$OUT/notes.md"
DOWNLOAD_URL="https://captylo.com/download/Captylo-$VERSION.dmg"
NOTES_URL="https://captylo.com/updates/notes/$VERSION.html"
if dry; then
  APPCAST="$OUT/appcast.xml"
  NOTES_HTML="$OUT/notes/$VERSION.html"
else
  APPCAST="$ROOT/site/updates/appcast.xml"
  NOTES_HTML="$ROOT/site/updates/notes/$VERSION.html"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/captylo-release.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if dry; then
  printf 'Captylo %s: DRY RUN (Captylo Dev signature, no notarization, nothing leaves this Mac)\n' "$VERSION"
else
  printf 'Captylo %s: release build\n' "$VERSION"
fi

# 1. Guards

step "Checking the repository and the release prerequisites"
BRANCH="$(git branch --show-current)"
if [ "$BRANCH" = "main" ]; then
  note "Branch: main"
elif [ "$ALLOW_BRANCH" = "1" ]; then
  note "Branch: $BRANCH (allowed with --allow-branch)"
else
  die "Releases are cut from main, this is \"$BRANCH\" (pass --allow-branch to override)"
fi

if [ -n "$(git status --porcelain)" ]; then
  refuse "The working tree has uncommitted changes (commit or stash them first)"
else
  note "Working tree: clean"
fi

MARKETING_VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ "$MARKETING_VERSION" = "$VERSION" ] ||
  die "project.yml says MARKETING_VERSION \"$MARKETING_VERSION\", not \"$VERSION\" (bump it by hand and commit first)"
note "MARKETING_VERSION: $MARKETING_VERSION"

PUBLIC_KEY="$(sed -n 's/^ *SPARKLE_PUBLIC_ED_KEY: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
SIGN_UPDATES=1
if [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = "$PLACEHOLDER_KEY" ]; then
  SIGN_UPDATES=0
  refuse "SPARKLE_PUBLIC_ED_KEY in project.yml is still the placeholder: run Sparkle's generate_keys once (docs/release.md), put the public key there and commit"
elif [ "$(printf '%s' "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != "32" ]; then
  # A malformed key makes Sparkle show "updater failed to start" at every launch, and 1.0.0
  # would ship unable to take any update.
  die "SPARKLE_PUBLIC_ED_KEY in project.yml is not a base64 Ed25519 public key (32 bytes); copy it again from generate_keys -p"
else
  note "Sparkle public key: set (32 bytes; compare it with generate_keys -p before the first release)"
fi

if [ -x "$SPARKLE_BIN/sign_update" ]; then
  note "Sparkle sign_update: found"
else
  SIGN_UPDATES=0
  refuse "No $SPARKLE_BIN/sign_update (run make build once so SwiftPM fetches Sparkle)"
fi

VALID_IDENTITIES="$(security find-identity -v -p codesigning | grep -cF "\"$DIST_IDENTITY" || true)"
if [ "$VALID_IDENTITIES" = "1" ]; then
  note "Signing identity: one valid \"$DIST_IDENTITY...\" in the Keychain"
elif [ "$VALID_IDENTITIES" = "0" ]; then
  refuse "No valid \"$DIST_IDENTITY\" signing identity in the Keychain (docs/release.md, Developer ID certificate)"
else
  refuse "$VALID_IDENTITIES identities match \"$DIST_IDENTITY\": set DIST_IDENTITY to the full certificate name"
fi

if dry; then
  # Local look only, no request to Apple: notarytool keeps saved profiles as a generic
  # password item named after the profile. The real run asks notarytool itself.
  if security find-generic-password -a "com.apple.gke.notary.tool.saved-creds.$NOTARY_PROFILE" >/dev/null 2>&1; then
    note "Notary profile \"$NOTARY_PROFILE\": looks present in the Keychain (not checked against Apple in a dry run)"
  else
    note "DRY RUN, a real release would stop here: no notarytool profile \"$NOTARY_PROFILE\" found in the Keychain (xcrun notarytool store-credentials $NOTARY_PROFILE ..., docs/release.md)"
  fi
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  note "Notary profile \"$NOTARY_PROFILE\": works"
else
  die "The notarytool profile \"$NOTARY_PROFILE\" is missing or rejected (xcrun notarytool store-credentials $NOTARY_PROFILE ..., docs/release.md)"
fi

HAVE_NOTES=1
if [ -s "$NOTES_MD" ]; then
  note "Release notes: ${NOTES_MD#"$ROOT"/}"
else
  HAVE_NOTES=0
  refuse "Write the release notes first: ${NOTES_MD#"$ROOT"/} (Markdown, Polish)"
fi

# 2. Build

BUILD="$(git rev-list --count HEAD)"
step "Building Captylo $VERSION (build $BUILD), Release"
mkdir -p "$OUT"
make --no-print-directory gen >/dev/null
BUILD_LOG="$OUT/build.log"
if ! xcodebuild -project Captylo.xcodeproj -scheme Captylo -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation -configuration Release \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGN_IDENTITY="-" build >"$BUILD_LOG" 2>&1; then
  grep -E 'error:' "$BUILD_LOG" | head -20 || tail -40 "$BUILD_LOG"
  die "xcodebuild failed, full log in ${BUILD_LOG#"$ROOT"/}"
fi
note "** BUILD SUCCEEDED ** (log in ${BUILD_LOG#"$ROOT"/})"

rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/Captylo.app" "$APP"
xattr -cr "$APP"
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[ "$BUILT_VERSION" = "$VERSION" ] || die "The built app says version $BUILT_VERSION, expected $VERSION"
[ "$BUILT_BUILD" = "$BUILD" ] || die "The built app says build $BUILT_BUILD, expected $BUILD"
note "Copied to ${APP#"$ROOT"/} (CFBundleShortVersionString $BUILT_VERSION, CFBundleVersion $BUILT_BUILD)"

# 3. Sign the app

if dry; then
  step "Signing the app with the development identity (make sign)"
  make --no-print-directory sign APP_PATH="$APP"
else
  step "Signing the app inside-out with \"$DIST_IDENTITY\""
  note "If macOS asks to let codesign use the Developer ID key, choose \"Always Allow\" (once)"
  "$ROOT/scripts/sign-app.sh" "$APP" "$DIST_IDENTITY" --entitlements "$ROOT/Captylo/Captylo.entitlements"
fi

# notarize FILE LABEL: submits to Apple and waits; anything but Accepted prints the log and stops.
notarize() {
  local file="$1" label="$2" result id status
  note "Submitting $label to Apple (this waits for the verdict, up to 30 min)"
  result="$WORK/notary-$label.json"
  if ! xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
    --output-format json >"$result"; then
    cat "$result" >&2 || true
  fi
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$result" 2>/dev/null || true)"
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$result" 2>/dev/null || true)"
  note "Notarization of $label: ${status:-no answer} (id ${id:-none})"
  if [ "$status" != "Accepted" ]; then
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Apple did not accept $label (see the log above; docs/release.md, \"Rejected\")"
  fi
}

# 4. Notarize and staple the app

if dry; then
  step "Notarizing the app: skipped (dry run)"
else
  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$WORK/Captylo-$VERSION.zip"
  notarize "$WORK/Captylo-$VERSION.zip" app
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# 5. DMG

step "Packaging ${DMG#"$ROOT"/}"
if dry; then
  "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "Captylo"
else
  "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "Captylo" --sign "$DIST_IDENTITY"
fi

# 6. Notarize and staple the DMG

if dry; then
  step "Notarizing the DMG: skipped (dry run)"
else
  step "Notarizing the DMG"
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# 7. Check what people will download

step "Checking the DMG"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
[ -d "$MOUNT/Captylo.app" ] || die "No Captylo.app in the DMG"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || die "No Applications shortcut in the DMG"
note "Mounted: Captylo.app and the Applications shortcut are there"
codesign --verify --deep --strict "$MOUNT/Captylo.app"
note "codesign --verify --deep --strict: valid"
# --mcp runs before AppKit (no UI, no services) and exits when stdin closes; it still makes
# dyld load every linked framework, so a signature mismatch with Sparkle fails right here.
"$MOUNT/Captylo.app/Contents/MacOS/Captylo" --mcp </dev/null >/dev/null 2>"$WORK/launch.log" ||
  { cat "$WORK/launch.log" >&2; die "The app from the DMG does not launch"; }
note "Launch check (--mcp, stdin closed): exit 0"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

if spctl --assess --type open --context context:primary-signature -v "$DMG" 2>"$WORK/spctl-dmg.log"; then
  note "spctl (DMG): $(tr '\n' ' ' <"$WORK/spctl-dmg.log")"
elif dry; then
  note "spctl (DMG): rejected, as expected without Developer ID and notarization"
else
  cat "$WORK/spctl-dmg.log" >&2
  die "Gatekeeper rejects the DMG"
fi
if spctl -a -vv "$APP" 2>"$WORK/spctl-app.log"; then
  note "spctl (app): $(tr '\n' ' ' <"$WORK/spctl-app.log")"
elif dry; then
  note "spctl (app): rejected, as expected without Developer ID and notarization"
else
  cat "$WORK/spctl-app.log" >&2
  die "Gatekeeper rejects the app"
fi

# 8. Appcast item and release notes

step "Writing the appcast item"
LENGTH="$(stat -f%z "$DMG")"
if [ "$SIGN_UPDATES" = "1" ] && SIGN_LINE="$("$SPARKLE_BIN/sign_update" "$DMG" 2>"$WORK/sign_update.log")"; then
  note "sign_update: signed with the EdDSA key from the Keychain"
  python3 "$ROOT/scripts/appcast.py" item "$APPCAST" --version "$VERSION" --build "$BUILD" \
    --url "$DOWNLOAD_URL" --sign-update "$SIGN_LINE" --notes "$NOTES_URL" --min-os 14.4
elif dry; then
  if [ "$SIGN_UPDATES" = "1" ]; then
    note "sign_update failed: $(tr '\n' ' ' <"$WORK/sign_update.log")"
  else
    note "sign_update skipped: no Sparkle EdDSA key yet (SPARKLE_PUBLIC_ED_KEY is the placeholder)"
  fi
  note "The dry-run item carries the signature DRY-RUN-UNSIGNED and is never published"
  [ -f "$APPCAST" ] || [ ! -f "$ROOT/site/updates/appcast.xml" ] || cp "$ROOT/site/updates/appcast.xml" "$APPCAST"
  python3 "$ROOT/scripts/appcast.py" item "$APPCAST" --version "$VERSION" --build "$BUILD" \
    --url "$DOWNLOAD_URL" --signature DRY-RUN-UNSIGNED --length "$LENGTH" --notes "$NOTES_URL" --min-os 14.4
else
  cat "$WORK/sign_update.log" >&2
  die "sign_update failed: is Sparkle's private key in the login Keychain? (docs/release.md)"
fi

if [ "$HAVE_NOTES" = "1" ]; then
  python3 "$ROOT/scripts/appcast.py" notes "$NOTES_MD" "$NOTES_HTML" --version "$VERSION"
else
  note "Release notes page skipped (no ${NOTES_MD#"$ROOT"/})"
fi

# The download block on captylo.com shows the version (<span data-version>); a dry run
# writes it into a copy so the marker is exercised without touching site/.
if dry; then
  SITE_INDEX="$OUT/site-index.html"
  cp "$ROOT/site/index.html" "$SITE_INDEX"
else
  SITE_INDEX="$ROOT/site/index.html"
fi
python3 "$ROOT/scripts/appcast.py" site-version "$SITE_INDEX" --version "$VERSION"

# 9. Next

step "Done"
note "DMG:     ${DMG#"$ROOT"/} ($LENGTH bytes)"
note "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
note "Appcast: ${APPCAST#"$ROOT"/}"
if dry; then
  note "Dry run: nothing was notarized, signed for distribution or published."
else
  note "Next: commit site/updates (appcast and notes) and site/index.html (the version), push,"
  note "then make publish VERSION=$VERSION (scripts/publish-release.sh; --check looks first)"
fi
