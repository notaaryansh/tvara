#!/usr/bin/env bash
set -euo pipefail

# Release build + sign + notarize + DMG.
# Prereqs: see ../office-hours design doc Step 0.

APP_NAME="tvara"
BUNDLE_ID="com.aaryansh.tvara"
DEV_ID_APP="Developer ID Application: <YOUR NAME> (<TEAMID>)"  # CHANGE THIS
NOTARY_PROFILE="AC_NOTARY"                                     # set via notarytool store-credentials

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${ROOT}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
ENTITLEMENTS="${ROOT}/${APP_NAME}.entitlements"
DMG_NAME="${APP_NAME}-$(date +%Y%m%d).dmg"
DMG_PATH="${ROOT}/${DMG_NAME}"

# ---- 1. Build release binary ----
echo "==> swift build -c release"
cd "${ROOT}"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
[[ -f "${BINARY}" ]] || { echo "build failed: ${BINARY} missing"; exit 1; }

# ---- 2. Assemble .app bundle ----
echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"
cp "${ROOT}/Info.plist" "${CONTENTS}/Info.plist"

# ---- 3. Code-sign with hardened runtime ----
echo "==> codesign with Developer ID"
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${DEV_ID_APP}" \
    "${APP_DIR}"

# Verify the signature was applied correctly
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

# ---- 4. Notarize ----
# Notarization requires a zip, not the .app directly.
ZIP_FOR_NOTARY="${ROOT}/${APP_NAME}-notary.zip"
echo "==> Zipping for notarization"
rm -f "${ZIP_FOR_NOTARY}"
/usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_FOR_NOTARY}"

echo "==> Submitting to Apple notary service (this takes 2-10 minutes)"
xcrun notarytool submit "${ZIP_FOR_NOTARY}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the notarization ticket onto the .app so it works offline
echo "==> Stapling notarization ticket"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"

rm -f "${ZIP_FOR_NOTARY}"

# ---- 5. Build DMG ----
echo "==> Building DMG"
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

# Sign the DMG itself (required for distribution outside the App Store)
codesign --force --sign "${DEV_ID_APP}" --timestamp "${DMG_PATH}"

# Notarize the DMG too (so users don't get the "unidentified developer" prompt)
echo "==> Notarizing DMG"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "==> Done. Release artifact:"
echo "    ${DMG_PATH}"
echo ""
echo "Upload to GitHub Releases:"
echo "    gh release create v0.5.0 \"${DMG_PATH}\" --title \"v0.5\" --notes \"...\""
