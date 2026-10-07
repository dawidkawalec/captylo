#!/bin/bash
# The remote commands expand their arguments on this Mac on purpose.
# shellcheck disable=SC2029
# Publishes a release that scripts/release.sh built: the DMG to the downloads folder on the
# server, the appcast and release notes (site/updates/) to captylo.com, then a GitHub release
# with the DMG attached. The website itself has its own repository and reads the version from
# the appcast. Owner-facing steps: docs/release.md.
#
#   scripts/publish-release.sh <version>            local checks, one question, then publishes
#   scripts/publish-release.sh <version> --check    local checks only, nothing leaves this Mac
#   scripts/publish-release.sh <version> --yes      no question (only when the owner said yes)
#
# Order: DMG upload -> Captylo.dmg points at it -> the DMG answers over HTTPS -> appcast sync
# (the appcast never points at a file that is not there yet) -> appcast check -> GitHub release.
# Running it again for the same version is safe: rsync skips what is there, the symlink is
# replaced, an existing GitHub release is left alone.
#
# Needs: PUBLISH_HOST, PUBLISH_SITE_ROOT (the folder that holds updates/) and PUBLISH_DOWNLOADS
# (the environment or the owner-only deploy/local.env, not in this repo), ssh access to that host with the
# downloads folder created and served by Caddy (/download/*.dmg), gh logged in with
# access to the public repo, and the release commit (site/updates included) pushed to origin/main.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# deploy/local.env (git-ignored) names the server; an environment variable of the same name wins.
if [ -f deploy/local.env ]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    [ -n "${!key:-}" ] || export "$key=$value"
  done < deploy/local.env
fi
HOST="${PUBLISH_HOST:?set PUBLISH_HOST in deploy/local.env or the environment}"
SITE_ROOT="${PUBLISH_SITE_ROOT:?set PUBLISH_SITE_ROOT in deploy/local.env or the environment}"
DOWNLOADS="${PUBLISH_DOWNLOADS:?set PUBLISH_DOWNLOADS in deploy/local.env or the environment}"
BASE_URL="https://captylo.com"
REPO="dawidkawalec/captylo"

usage() {
  echo "usage: $0 <version> [--check | --yes]" >&2
  exit 2
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\npublish-release.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || usage
VERSION="$1"
shift
MODE="ask"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --yes) MODE="yes"; shift ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "The version must look like 1.2.3, got \"$VERSION\""

OUT="$ROOT/dist/$VERSION"
APP="$OUT/Captylo.app"
DMG_NAME="Captylo-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
NOTES_MD="$OUT/notes.md"
APPCAST="$ROOT/site/updates/appcast.xml"
NOTES_HTML="$ROOT/site/updates/notes/$VERSION.html"

# 1. Local checks: every problem is listed, then a real publish stops before anything leaves.

PROBLEMS=0
problem() { note "NOT READY: $*"; PROBLEMS=$((PROBLEMS + 1)); }

step "Checking Captylo $VERSION before publishing"

BUILD=""
LENGTH=""
if [ ! -f "$DMG" ]; then
  problem "No ${DMG#"$ROOT"/} (make dist VERSION=$VERSION first)"
else
  LENGTH="$(stat -f%z "$DMG")"
  note "DMG: ${DMG#"$ROOT"/} ($LENGTH bytes)"
  # Local look at the signature first; the stapler check only makes sense on a Developer ID DMG.
  DMG_SIGNATURE="$(codesign -dvv "$DMG" 2>&1 || true)"
  if grep -q '^Authority=Developer ID Application' <<<"$DMG_SIGNATURE"; then
    note "DMG signature: Developer ID"
    if xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
      note "DMG ticket: stapled"
    else
      problem "The DMG has no stapled notarization ticket (a dry run DMG, or notarization did not finish)"
    fi
  else
    problem "The DMG is not signed with Developer ID (a dry run DMG? make dist VERSION=$VERSION)"
  fi
fi

if [ -f "$APP/Contents/Info.plist" ]; then
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  if [ "$BUILT_VERSION" = "$VERSION" ]; then
    note "App: version $BUILT_VERSION, build $BUILD"
  else
    problem "${APP#"$ROOT"/} is version $BUILT_VERSION, not $VERSION"
  fi
else
  problem "No ${APP#"$ROOT"/} (the build number comes from it)"
fi

if [ ! -f "$APPCAST" ]; then
  problem "No ${APPCAST#"$ROOT"/} (a real make dist writes it; commit it afterwards)"
elif [ -n "$BUILD" ] && [ -n "$LENGTH" ]; then
  if CHECK="$(python3 "$ROOT/scripts/appcast.py" check "$APPCAST" --version "$VERSION" --build "$BUILD" --length "$LENGTH" 2>&1)"; then
    note "Appcast: build $BUILD is there, signed, newest, $LENGTH bytes"
  else
    problem "${CHECK#appcast.py: }"
  fi
fi

if [ -f "$NOTES_HTML" ]; then
  note "Release notes page: ${NOTES_HTML#"$ROOT"/}"
else
  problem "No ${NOTES_HTML#"$ROOT"/} (make dist writes it from ${NOTES_MD#"$ROOT"/})"
fi
if [ -s "$NOTES_MD" ]; then
  note "GitHub release notes: ${NOTES_MD#"$ROOT"/}"
else
  problem "No ${NOTES_MD#"$ROOT"/} (the GitHub release uses it)"
fi

if [ -n "$(git status --porcelain -- site/updates)" ]; then
  problem "site/updates/ has uncommitted changes: commit them, the appcast goes live exactly as committed"
else
  note "site/updates/: committed"
fi

COMMIT="$(git rev-parse HEAD)"
if git rev-parse --verify -q origin/main >/dev/null && git merge-base --is-ancestor "$COMMIT" origin/main; then
  note "Commit ${COMMIT:0:9}: on origin/main (as of the last fetch)"
else
  problem "Commit ${COMMIT:0:9} is not on origin/main: push the release commit first (the GitHub release tags it)"
fi

for tool in rsync ssh curl gh; do
  command -v "$tool" >/dev/null || problem "$tool is not installed"
done

if [ "$PROBLEMS" -gt 0 ]; then
  die "$PROBLEMS problem(s) above, nothing was published"
fi

# 2. What happens next

step "Plan"
note "1. rsync $DMG_NAME to $HOST:$DOWNLOADS/"
note "2. $DOWNLOADS/Captylo.dmg -> $DMG_NAME"
note "3. check $BASE_URL/download/$DMG_NAME and $BASE_URL/download/Captylo.dmg ($LENGTH bytes)"
note "4. rsync site/updates/ to $HOST:$SITE_ROOT/updates/ (--delete)"
note "5. check $BASE_URL/updates/appcast.xml for build $BUILD"
note "6. gh release create v$VERSION on $REPO at ${COMMIT:0:9} with $DMG_NAME"

if [ "$MODE" = "check" ]; then
  printf '\nReady to publish Captylo %s (build %s). --check: nothing was sent.\n' "$VERSION" "$BUILD"
  exit 0
fi
if [ "$MODE" = "ask" ]; then
  printf '\nPublish Captylo %s to captylo.com and GitHub? Type "publish" to continue: ' "$VERSION"
  read -r answer
  [ "$answer" = "publish" ] || { echo "Cancelled."; exit 1; }
fi

# 3. The DMG

# remote_length URL: Content-Length of the final answer for URL (empty when it is not 200).
remote_length() {
  curl -sfIL "$1" | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }'
}

step "Uploading the DMG"
ssh "$HOST" "test -d '$DOWNLOADS'" ||
  die "No $DOWNLOADS on $HOST: create it and mount it into the Caddy container first (docs/release.md)"
rsync -a --progress "$DMG" "$HOST:$DOWNLOADS/"
ssh "$HOST" "cd '$DOWNLOADS' && ln -sfn '$DMG_NAME' Captylo.dmg"
note "$DOWNLOADS/Captylo.dmg -> $DMG_NAME"

for name in "$DMG_NAME" Captylo.dmg; do
  SERVED="$(remote_length "$BASE_URL/download/$name" || true)"
  [ "$SERVED" = "$LENGTH" ] ||
    die "$BASE_URL/download/$name answers with ${SERVED:-no file} bytes, expected $LENGTH (check the /download/*.dmg route in the captylo.com Caddy block)"
  note "$BASE_URL/download/$name: 200, $SERVED bytes"
done

# 4. The appcast and release notes (the rest of captylo.com is the website's own repository)

step "Syncing the appcast"
rsync -az --delete --exclude .DS_Store "$ROOT/site/updates/" "$HOST:$SITE_ROOT/updates/"
# Into a variable first: grep -q closing the pipe early would fail curl under pipefail.
LIVE_APPCAST="$(curl -sf "$BASE_URL/updates/appcast.xml" || true)"
grep -q "<sparkle:version>$BUILD</sparkle:version>" <<<"$LIVE_APPCAST" ||
  die "$BASE_URL/updates/appcast.xml does not list build $BUILD"
note "$BASE_URL/updates/appcast.xml: lists build $BUILD"
# The website reads the version from the appcast and caches it for 5 minutes.
LIVE_HOME="$(curl -sf "$BASE_URL/" || true)"
if grep -q "data-version>$VERSION<" <<<"$LIVE_HOME"; then
  note "$BASE_URL/: shows $VERSION"
else
  note "$BASE_URL/ shows $VERSION within about 10 minutes (it reads the appcast)"
fi

# 5. GitHub

step "GitHub release"
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  note "v$VERSION exists already, left as it is"
else
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$COMMIT" \
    --title "Captylo $VERSION" --notes-file "$NOTES_MD"
fi

step "Done"
note "Captylo $VERSION (build $BUILD) is on $BASE_URL/download/Captylo.dmg and in the appcast."
note "Installed copies see it at their next update check (Check for Updates... shows it at once)."
