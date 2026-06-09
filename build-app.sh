#!/usr/bin/env bash
set -euo pipefail

APP_NAME="tvara"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${ROOT}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "==> swift build -c ${BUILD_CONFIG}"
cd "${ROOT}"
swift build -c "${BUILD_CONFIG}"

BINARY="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BINARY}" ]]; then
    echo "Build did not produce ${BINARY}"
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"
cp "${ROOT}/Info.plist" "${CONTENTS}/Info.plist"

# Copy SPM-generated resource bundles (CLIP tokenizer + MobileCLIP models).
# Bundle.module looks for *.bundle next to the executable.
BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)"
for b in "${BIN_DIR}"/*.bundle; do
    if [[ -d "$b" ]]; then
        cp -R "$b" "${MACOS_DIR}/"
    fi
done

# Sign with a stable identity so macOS' TCC subsystem recognizes the
# bundle as the same app across rebuilds — that's what lets Accessibility
# / Contacts / Calendar / Full Disk Access grants persist instead of
# re-prompting every launch.
#
# Pinned to the Apple Development cert for aaryansh@pally.com (team
# 2G7H5Z94U8). If/when this cert is rotated or revoked, list current
# valid identities with:
#     security find-identity -v -p codesigning
# and update the SHA-1 below.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-4F64A755DFB135BE69E1995968180971D2FC13BC}"

# SPM emits each resource bundle in a flat layout — resources sit at the
# bundle root with no Info.plist, no Contents/ wrapper. macOS codesign
# only accepts Cocoa-shaped bundles, so we restructure each one:
#   bundle/
#     ├── Contents/
#     │   ├── Info.plist               (synthesized)
#     │   └── Resources/<original tree>
# Bundle.url(forResource:subdirectory:) still finds files under Resources/
# at runtime because Foundation auto-detects the layout. Then we sign
# each nested bundle, and finally the outer app.
for nested in "${MACOS_DIR}"/*.bundle; do
    [[ -d "$nested" ]] || continue
    # Skip if already restructured (idempotent rebuilds).
    if [[ -f "${nested}/Contents/Info.plist" ]]; then
        codesign --force --sign "${SIGNING_IDENTITY}" "$nested"
        continue
    fi
    bundle_name="$(basename "$nested" .bundle)"
    tmp_dir="${nested}.tmp_restructure"
    mkdir -p "${tmp_dir}/Contents/Resources"
    # Move every top-level entry into Contents/Resources/.
    for child in "${nested}"/*; do
        [[ -e "$child" ]] || continue
        mv "$child" "${tmp_dir}/Contents/Resources/"
    done
    cat > "${tmp_dir}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.aaryanshsahay.tvara.resources.${bundle_name}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleName</key>
    <string>${bundle_name}</string>
</dict>
</plist>
EOF
    rmdir "${nested}"
    mv "${tmp_dir}" "${nested}"
    codesign --force --sign "${SIGNING_IDENTITY}" "$nested"
done

# Seal the parent app. --deep walks the now-signed nested bundles and
# verifies their hashes against the parent's CodeResources file.
codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_DIR}"

echo "==> Built ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
