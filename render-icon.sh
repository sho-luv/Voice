#!/usr/bin/env bash
# render-icon.sh — Regenerate every raster icon from icon.svg.
#
# Usage: ./render-icon.sh
#
# icon.svg is the only source of truth: a 1024 px canvas with the 824 px macOS
# squircle centred in it (Apple's Big Sur margin, so the Dock shadow lines up).
# Outputs: icon.png + Voice.icns (app/README), website/voice-icon.png (with margin),
# website/apple-touch-icon.png and favicons (full-bleed, as browsers expect).
# Needs: rsvg-convert, magick (Homebrew: librsvg imagemagick), iconutil (Xcode CLT).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

for TOOL in rsvg-convert magick iconutil; do
    command -v "${TOOL}" >/dev/null || { echo "error: ${TOOL} not found" >&2; exit 1; }
done

MASTER="$(mktemp -d)/master.png"
ICONSET="$(mktemp -d)/Voice.iconset"
mkdir -p "${ICONSET}"
trap 'rm -rf "$(dirname "${MASTER}")" "$(dirname "${ICONSET}")"' EXIT

# Render straight from vector at every size: no upscaling, no resampling blur.
render() { rsvg-convert -w "$1" -h "$1" icon.svg -o "$2"; }

render 1024 "${MASTER}"
render 256 icon.png
render 256 website/voice-icon.png

# macOS iconset. iconutil wants both 1x and 2x for each nominal size.
for SIZE in 16 32 128 256 512; do
    render "${SIZE}"        "${ICONSET}/icon_${SIZE}x${SIZE}.png"
    render "$((SIZE * 2))"  "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png"
done
iconutil -c icns "${ICONSET}" -o Voice.icns

# Web icons are full-bleed: crop the 824 px squircle out of the 1024 master.
BLEED="$(dirname "${MASTER}")/bleed.png"
magick "${MASTER}" -crop 824x824+100+100 +repage "${BLEED}"
magick "${BLEED}" -resize 180x180 website/apple-touch-icon.png
magick "${BLEED}" -resize 32x32   website/favicon-32x32.png
magick "${BLEED}" -resize 16x16   website/favicon-16x16.png

echo "Rendered icon.png, Voice.icns and website icons from icon.svg"
