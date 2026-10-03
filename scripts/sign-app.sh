#!/bin/bash
# Signs a built Captylo.app inside-out with one identity, hardened runtime on.
#
#   scripts/sign-app.sh <app> <identity> [--entitlements FILE] [--keychain FILE] [--no-timestamp]
#
# Under hardened runtime, library validation only lets the app load frameworks signed by
# the same team, so every nested piece has to carry the app's signature, not Xcode's ad-hoc
# one: an app re-signed only on the outside dies in dyld at launch ("different Team IDs").
# A nested item has to be signed before the bundle that contains it, so the order is:
#   1. inside each framework version: XPC services, helper apps, helper executables
#      (Sparkle's Downloader.xpc, Installer.xpc, Updater.app, Autoupdate)
#   2. each framework and dylib in Contents/Frameworks
#   3. the app itself, with the app's entitlements
# Helper entitlements are not carried over (Xcode's ad-hoc pass leaves an application
# identifier on Autoupdate that a Developer ID signature must not claim), except for the
# XPC services, which keep whatever Sparkle shipped them with.
#
# A secure timestamp is on by default (Developer ID and notarization need it); `--no-timestamp`
# or DRY_RUN=1 turns it off for the self-signed "Captylo Dev" identity, which cannot get one.
# `--keychain` points codesign at a keychain that is not in the search list (`make sign`).
set -euo pipefail

usage() {
  echo "usage: $0 <app> <identity> [--entitlements FILE] [--keychain FILE] [--no-timestamp]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
APP="${1%/}"
IDENTITY="$2"
shift 2
ENTITLEMENTS=""
KEYCHAIN=""
TIMESTAMP="--timestamp"
[ "${DRY_RUN:-0}" = "1" ] && TIMESTAMP="--timestamp=none"
while [ $# -gt 0 ]; do
  case "$1" in
    --entitlements) [ $# -ge 2 ] || usage; ENTITLEMENTS="$2"; shift 2 ;;
    --keychain) [ $# -ge 2 ] || usage; KEYCHAIN="$2"; shift 2 ;;
    --no-timestamp) TIMESTAMP="--timestamp=none"; shift ;;
    *) usage ;;
  esac
done

[ -d "$APP/Contents" ] || { echo "Not an app bundle: $APP" >&2; exit 1; }
[ -z "$ENTITLEMENTS" ] || [ -f "$ENTITLEMENTS" ] || { echo "No entitlements file: $ENTITLEMENTS" >&2; exit 1; }

CODESIGN=(codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY")
[ -z "$KEYCHAIN" ] || CODESIGN+=(--keychain "$KEYCHAIN")

# sign PATH [extra codesign options...]
sign() {
  local target="$1"
  shift
  if [ "$target" = "$APP" ]; then echo "Signing $(basename "$APP")"; else echo "Signing ${target#"$APP"/}"; fi
  "${CODESIGN[@]}" "$@" "$target"
}

is_macho() {
  [ -f "$1" ] && [ ! -L "$1" ] && file -b "$1" | grep -q 'Mach-O'
}

shopt -s nullglob
FRAMEWORKS="$APP/Contents/Frameworks"

for framework in "$FRAMEWORKS"/*.framework; do
  name="$(basename "$framework" .framework)"
  for version in "$framework"/Versions/*; do
    [ -L "$version" ] && continue
    for xpc in "$version"/XPCServices/*.xpc; do
      sign "$xpc" --preserve-metadata=entitlements
    done
    for helper in "$version"/*.app; do
      sign "$helper"
    done
    for item in "$version"/*; do
      [ "$(basename "$item")" = "$name" ] && continue
      if is_macho "$item"; then sign "$item"; fi
    done
  done
done

for library in "$FRAMEWORKS"/*.framework "$FRAMEWORKS"/*.dylib; do
  sign "$library"
done

if [ -n "$ENTITLEMENTS" ]; then
  sign "$APP" --entitlements "$ENTITLEMENTS"
else
  sign "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Designated requirement:"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => /  /p'
