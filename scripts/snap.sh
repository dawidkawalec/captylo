#!/usr/bin/env bash
# Screenshot one Captylo screen from the design preview (docs/design/dusk-glass.md).
#
#   scripts/snap.sh <target> <out.png>
#   scripts/snap.sh --list
#
# Launches the Debug binary with `--design-preview <target>` (fake data, no services: no hotkey
# tap, no audio, no model, nothing written to the real defaults or data folder), waits for the
# `WINDOW_ID=<n>` line (up to 20 s), lets the animations settle for 2.5 s, captures the screen,
# then kills exactly that process. Run `make build` first.
#
# Windows are frosted glass over whatever is behind them, so they are captured as a screen
# region (`screencapture -R`, the `WINDOW_FRAME` the preview prints): a window capture (`-l`)
# has no backdrop and shows no blur. Widget targets are captured with `-l` (transparent around
# the widget, window shadow kept) unless a backdrop is set.
#
# Environment:
#   CAPTYLO_BIN=<path>        binary to launch (default: this checkout's Debug build)
#   SNAP_SETTLE=<seconds>     wait after the window appears (default 2.5)
#   SNAP_BACKDROP=<b>         put a known backdrop right behind the target and capture the region:
#                             `white`, `dark`, `dusk` (docs/design/backdrops/dusk-wallpaper.jpg) or
#                             an image path. Without it windows show the real desktop behind them.
#                             The backdrop and the target float above other apps' windows while
#                             the preview runs, so the region capture is not covered.
#   CAPTYLO_WINDOW_BG=<s>     passed through: window background `glass`, `aurora` or `dusk`
#                             ("Tło okna"; default: the app default)
#   CAPTYLO_GLASS_FALLBACK=1  passed through: draws the macOS 14/15 fallbacks on macOS 26
#                             (material glass, aurora glows instead of the mesh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CAPTYLO_BIN:-$ROOT/.local-build/Build/Products/Debug/Captylo.app/Contents/MacOS/Captylo}"
SETTLE="${SNAP_SETTLE:-2.5}"
DUSK="$ROOT/docs/design/backdrops/dusk-wallpaper.jpg"
TARGETS="widget-compact widget-compact-mode widget-expanded widget-transcribing widget-enhancing onboarding-welcome onboarding-permissions onboarding-model onboarding-shortcut onboarding-tryit main-pulpit main-historia main-plik main-slownik main-modele main-ustawienia glass-gallery"

if [[ "${1:-}" == "--list" ]]; then
    tr ' ' '\n' <<<"$TARGETS"
    exit 0
fi

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/snap.sh <target> <out.png>   (scripts/snap.sh --list for targets)" >&2
    exit 2
fi
target="$1"
out="$2"

if [[ " $TARGETS " != *" $target "* ]]; then
    echo "snap: unknown target '$target'; one of: $TARGETS" >&2
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "snap: no binary at $BIN (run make build)" >&2
    exit 1
fi

backdrop="${SNAP_BACKDROP:-}"
case "$backdrop" in
    "" | white | dark) ;;
    dusk | 1) backdrop="$DUSK" ;;
    *)
        if [[ ! -f "$backdrop" ]]; then
            echo "snap: SNAP_BACKDROP must be white, dark, dusk or an image file" >&2
            exit 2
        fi
        ;;
esac

log="$(mktemp -t captylo-snap)"
CAPTYLO_PREVIEW_BACKDROP="$backdrop" "$BIN" --design-preview "$target" >"$log" 2>/dev/null &
pid=$!

cleanup() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$log"
}
trap cleanup EXIT

window_id=""
for _ in $(seq 1 200); do
    window_id="$(sed -n 's/^WINDOW_ID=\([0-9][0-9]*\)$/\1/p' "$log" | head -n 1)"
    [[ -n "$window_id" ]] && break
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "snap: preview exited before showing a window:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ -z "$window_id" ]]; then
    echo "snap: no WINDOW_ID within 20 s" >&2
    exit 1
fi
frame="$(sed -n 's/^WINDOW_FRAME=\([0-9,-]*\)$/\1/p' "$log" | head -n 1)"

sleep "$SETTLE"

mkdir -p "$(dirname "$out")"
rm -f "$out"
if [[ "$target" == widget-* && -z "$backdrop" ]]; then
    screencapture -x -l"$window_id" "$out"
elif [[ -n "$frame" ]]; then
    screencapture -x -R"$frame" "$out"
else
    screencapture -x -o -l"$window_id" "$out"
fi
if [[ ! -s "$out" ]]; then
    echo "snap: screencapture wrote nothing (Screen Recording permission for this terminal?)" >&2
    exit 1
fi

echo "$out"
