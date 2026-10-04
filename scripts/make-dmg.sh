#!/bin/bash
# Packages a signed Captylo.app into a compressed DMG with an Applications shortcut.
#
#   scripts/make-dmg.sh <app> <out.dmg> <volume name> [--sign IDENTITY] [--keychain FILE]
#
# The volume holds the app and a symlink Applications -> /Applications, so installing is one
# drag. Only hdiutil (no create-dmg). `--sign` signs the DMG itself with a secure timestamp
# (Developer ID releases); a dry run leaves the DMG unsigned. Prints the size and SHA-256.
set -euo pipefail

usage() {
  echo "usage: $0 <app> <out.dmg> <volume name> [--sign IDENTITY] [--keychain FILE]" >&2
  exit 2
}

[ $# -ge 3 ] || usage
APP="${1%/}"
OUT="$2"
VOLNAME="$3"
shift 3
IDENTITY=""
KEYCHAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) [ $# -ge 2 ] || usage; IDENTITY="$2"; shift 2 ;;
    --keychain) [ $# -ge 2 ] || usage; KEYCHAIN="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$APP/Contents" ] || { echo "Not an app bundle: $APP" >&2; exit 1; }
case "$OUT" in *.dmg) ;; *) echo "The output must end in .dmg: $OUT" >&2; exit 1 ;; esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/captylo-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "Staging $(basename "$APP") and an Applications shortcut"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
echo "Creating $OUT (UDZO, HFS+, volume \"$VOLNAME\")"
# hdiutil now and then fails with "Resource busy" right after a previous image detached.
for attempt in 1 2 3; do
  if hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null; then
    break
  fi
  [ "$attempt" -lt 3 ] || { echo "hdiutil create failed" >&2; exit 1; }
  echo "hdiutil create failed, trying again ($attempt/3)"
  sleep 3
done

echo "Verifying the image checksum"
hdiutil verify "$OUT" >/dev/null

if [ -n "$IDENTITY" ]; then
  echo "Signing the DMG with $IDENTITY"
  SIGN=(codesign --force --timestamp --sign "$IDENTITY")
  [ -z "$KEYCHAIN" ] || SIGN+=(--keychain "$KEYCHAIN")
  "${SIGN[@]}" "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
else
  echo "DMG left unsigned (no --sign)"
fi

BYTES="$(stat -f%z "$OUT")"
echo "Size: $BYTES bytes ($(du -h "$OUT" | cut -f1 | xargs))"
echo "SHA-256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
