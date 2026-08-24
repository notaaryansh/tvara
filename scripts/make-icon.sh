#!/usr/bin/env bash
#
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.svg.
# Rasterizes the SVG at 1024 via QuickLook (renders the Georgia-italic "t"
# correctly), downsamples to the 10 iconset slots with sips, then iconutil.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="${ROOT}/Resources"
SVG="${RES}/AppIcon.svg"

[[ -f "${SVG}" ]] || { echo "Missing ${SVG}"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

qlmanage -t -s 1024 -o "${TMP}" "${SVG}" >/dev/null 2>&1
SRC="${TMP}/AppIcon.svg.png"
[[ -f "${SRC}" ]] || { echo "QuickLook failed to rasterize ${SVG}"; exit 1; }

SET="${TMP}/AppIcon.iconset"
mkdir -p "${SET}"
gen() { sips -z "$1" "$1" "${SRC}" --out "${SET}/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "${SET}" -o "${RES}/AppIcon.icns"
echo "Wrote ${RES}/AppIcon.icns"
