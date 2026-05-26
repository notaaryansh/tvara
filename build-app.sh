#!/usr/bin/env bash
set -euo pipefail

APP_NAME="spotlight++"
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

# Ad-hoc sign so the global hotkey registration is allowed on modern macOS.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> Built ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
