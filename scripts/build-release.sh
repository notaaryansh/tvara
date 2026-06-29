#!/usr/bin/env bash
#
# Release build → sign → notarize → DMG. Designed to run unattended from
# CI (.github/workflows/release.yml). All credentials come from env vars;
# nothing is interactive.
#
# Required env vars:
#   SIGNING_IDENTITY     SHA-1 of the "Developer ID Application" cert in
#                        the active keychain. CI computes this with
#                        `security find-identity` after importing the
#                        .p12. Locally:
#                          security find-identity -v -p codesigning \
#                            | grep "Developer ID Application"
#   APPLE_ID             Apple ID of the developer account
#                        (sahayaaryansh2001@gmail.com).
#   APPLE_TEAM_ID        10-char Team ID matching the cert above
#                        (A5CY2872LP for the personal account).
#   APPLE_APP_PASSWORD   App-specific password from appleid.apple.com
#                        (NOT the Apple ID login password).
#
# Produces:
#   tvara.app/        — final signed + notarized + stapled bundle
#   tvara-<ver>.dmg   — signed + notarized DMG ready for distribution
#
set -euo pipefail

APP_NAME="tvara"
BUNDLE_ID="com.aaryansh.tvara"

# ---- 0. Validate env ----
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY must be set (cert SHA-1 hash)}"
: "${APPLE_ID:?APPLE_ID must be set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID must be set}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD must be set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${ROOT}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
ENTITLEMENTS="${ROOT}/${APP_NAME}.entitlements"

[[ -f "${ENTITLEMENTS}" ]] || {
    echo "Missing ${ENTITLEMENTS} — required for hardened-runtime signing"
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${ROOT}/Info.plist")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${ROOT}/${DMG_NAME}"

echo "==> Building ${APP_NAME} ${VERSION} (bundle id ${BUNDLE_ID})"

# ---- 1. Build release binary, arm64-only ----
echo "==> swift build -c release --arch arm64"
cd "${ROOT}"
swift build -c release --arch arm64

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BINARY="${BIN_DIR}/${APP_NAME}"
[[ -f "${BINARY}" ]] || { echo "build failed: ${BINARY} missing"; exit 1; }

# ---- 2. Assemble .app bundle ----
echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"
cp "${ROOT}/Info.plist" "${CONTENTS}/Info.plist"

# Copy SPM-generated resource bundles (CLIP tokenizer + MobileCLIP models).
# Bundle.module looks for *.bundle next to the executable.
for b in "${BIN_DIR}"/*.bundle; do
    [[ -d "$b" ]] || continue
    cp -R "$b" "${MACOS_DIR}/"
done

# ---- 3. Restructure SPM resource bundles for codesign ----
# SPM emits each resource bundle as a flat directory — resources at the
# root, no Info.plist, no Contents/ wrapper. macOS codesign only accepts
# Cocoa-shaped bundles, so we restructure each one to:
#   bundle/
#     └── Contents/
#         ├── Info.plist          (synthesized)
#         └── Resources/<files>
# Bundle.url(forResource:subdirectory:) still finds files because
# Foundation auto-detects the layout. Each nested bundle is then signed
# individually with hardened runtime + entitlements before we seal the
# outer app. (build-app.sh does the same thing for dev builds; missing it
# from release builds was a latent bug.)
for nested in "${MACOS_DIR}"/*.bundle; do
    [[ -d "$nested" ]] || continue
    if [[ -f "${nested}/Contents/Info.plist" ]]; then
        continue
    fi
    bundle_name="$(basename "$nested" .bundle)"
    tmp_dir="${nested}.tmp_restructure"
    mkdir -p "${tmp_dir}/Contents/Resources"
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
    <string>${BUNDLE_ID}.resources.${bundle_name}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleName</key>
    <string>${bundle_name}</string>
</dict>
</plist>
EOF
    rmdir "${nested}"
    mv "${tmp_dir}" "${nested}"
done

# ---- 4. Code-sign nested bundles, then the parent app ----
# Sign nested .bundles first with hardened runtime + entitlements;
# --deep on the parent then verifies their hashes against the parent's
# CodeResources file.
echo "==> codesign nested resource bundles"
for nested in "${MACOS_DIR}"/*.bundle; do
    [[ -d "$nested" ]] || continue
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${SIGNING_IDENTITY}" \
        "$nested"
done

echo "==> codesign ${APP_DIR}"
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGNING_IDENTITY}" \
    "${APP_DIR}"

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

# ---- 5. Notarize the .app ----
ZIP_FOR_NOTARY="${ROOT}/${APP_NAME}-notary.zip"
echo "==> Zipping for notarization"
rm -f "${ZIP_FOR_NOTARY}"
/usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_FOR_NOTARY}"

echo "==> Submitting .app to notary service (2-10 min)"
xcrun notarytool submit "${ZIP_FOR_NOTARY}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait

echo "==> Stapling ticket"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"
rm -f "${ZIP_FOR_NOTARY}"

# ---- 6. Build DMG ----
echo "==> Building ${DMG_NAME}"
rm -f "${DMG_PATH}"
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 175 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 425 190 \
    "${DMG_PATH}" \
    "${APP_DIR}"

# ---- 7. Sign + notarize the DMG itself ----
# Gatekeeper runs a separate check on the DMG when the user mounts it,
# independent of the .app inside.
echo "==> codesign DMG"
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

echo "==> Notarizing DMG"
xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "==> Done. Release artifact:"
echo "    ${DMG_PATH}"
