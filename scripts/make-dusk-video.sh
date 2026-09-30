#!/usr/bin/env bash
# Renders the living "Zmierzch" window background (Captylo/Resources/Video/dusk-loop.mp4) from our
# own blurred dusk photo (docs/design/backdrops/dusk-wallpaper.jpg). No stock footage.
#
#   scripts/make-dusk-video.sh [out.mp4]
#
# Every motion is a whole number of cycles per loop, so the frame after the last one is the
# first one again and AVPlayerLooper plays it without a seam:
#   - Ken Burns breathe: scale 1.02 -> 1.07 -> 1.02 (one cycle) with a slow elliptic drift,
#   - lake ripple: two travelling sine waves of horizontal displacement (their phase bends along
#     x, so the lines break up like real water) plus a small vertical one and faint broken glints,
#     only below the horizon (smooth ramp from ~57 % of the height),
#   - sunset warmth: a warm glow over the sun and its reflection that breathes twice per loop.
# Everything is sampled with bilinear interpolation (sub-pixel, no integer crop jitter) in one
# `geq` pass at a working size, then upscaled; the photo is so blurred that nothing is lost.
# Encoded as 10-bit HEVC (hvc1 tag for AVFoundation), no audio, with I, P and B frames at the same
# quality so the last frame (end of a GOP) still matches the first (an I frame) at the loop point.
#
# Environment: FFMPEG (default /opt/homebrew/bin/ffmpeg or ffmpeg on PATH), LOOP (seconds, 24),
# FPS (30), CRF (x265, 17), PREVIEW=1 renders 2 s only (quick look), STILL=<png> [STILL_T=<s>]
# writes one unencoded 8-bit frame at that time instead (tuning the look).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/design/backdrops/dusk-wallpaper.jpg"
OUT="${1:-$ROOT/Captylo/Resources/Video/dusk-loop.mp4}"
FFMPEG="${FFMPEG:-$(command -v /opt/homebrew/bin/ffmpeg || command -v ffmpeg)}"
LOOP="${LOOP:-24}"
FPS="${FPS:-30}"
CRF="${CRF:-17}"
FRAMES=$((LOOP * FPS))
[[ "${PREVIEW:-0}" == 1 ]] && FRAMES=$((2 * FPS))

# Working size of the geq pass and the delivered size.
WW=960
WH=600
OW=1920
OH=1200

# Phase of one loop cycle at time T.
P="(2*PI*T/$LOOP)"

# Registers: 0 scale, 1/2 source x/y, 3 water mask, 4/7 ripple dx/dy, 5 glow shape,
# 6 glow breathe, 8 glint factor. Pixel units are the working size (960 x 600).
GEOM="st(0,1.02+0.025*(1-cos($P)));\
st(1,W/2+(X-W/2)/ld(0)+7*sin($P+0.7));\
st(2,H/2+(Y-H/2)/ld(0)+4*sin($P+2.3));\
st(3,clip((ld(2)/H-0.575)/0.16,0,1));\
st(3,ld(3)*ld(3)*(3-2*ld(3)));\
st(4,ld(3)*(3.0*sin(2*PI*ld(2)/21-3*$P+1.6*sin(ld(1)/71+$P))+1.2*sin(2*PI*ld(2)/10+5*$P+ld(1)/43)));\
st(7,ld(3)*0.5*sin(2*PI*ld(2)/17-4*$P+ld(1)/59));\
st(5,exp(-(pow((ld(1)/W-0.40)/0.17,2)+pow((ld(2)/H-0.58)/0.21,2))));\
st(6,0.5-0.5*cos(2*$P));\
st(8,1+0.012*ld(3)*sin(2*PI*ld(2)/23-2*$P+2.2*sin(ld(1)/47-2*$P))*sin(ld(1)/31+3*$P))"

channel() { # $1 plane function (r/g/b), $2 glow strength in 8-bit levels
    echo "$GEOM;clip($1(ld(1)+ld(4),ld(2)+ld(7))*ld(8)+$2*257*ld(5)*ld(6),0,65535)"
}

GRAPH="scale=${WW}:${WH}:force_original_aspect_ratio=increase:flags=lanczos,crop=${WW}:${WH},\
format=gbrp16le,\
geq=r='$(channel r 18)':g='$(channel g 9)':b='$(channel b 1)',\
scale=${OW}:${OH}:flags=lanczos,format=yuv420p10le"

if [[ -n "${STILL:-}" ]]; then
    # One frame at STILL_T seconds straight from the graph, no encoding (tuning the look).
    "$FFMPEG" -hide_banner -loglevel error -y -loop 1 -framerate "$FPS" -i "$SRC" \
        -vf "trim=start=${STILL_T:-0},$GRAPH,format=rgb24" -frames:v 1 "$STILL"
    echo "$STILL"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
"$FFMPEG" -hide_banner -loglevel error -stats -y \
    -loop 1 -framerate "$FPS" -i "$SRC" \
    -vf "$GRAPH" \
    -frames:v "$FRAMES" -r "$FPS" -an \
    -c:v libx265 -preset slow -crf "$CRF" -pix_fmt yuv420p10le \
    -x265-params "log-level=error:keyint=$((FPS * 4)):min-keyint=$((FPS * 4)):scenecut=0:no-open-gop=1:ipratio=1.0:pbratio=1.0:aq-mode=3" \
    -tag:v hvc1 -movflags +faststart \
    "$OUT"

echo "$OUT"
