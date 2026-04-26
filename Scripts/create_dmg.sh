#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Video Simple Toolkit"
APP_PATH="${1:-${PROJECT_ROOT}/${APP_NAME}.app}"
DMG_PATH="${2:-${PROJECT_ROOT}/${APP_NAME}-AppleSilicon.dmg}"
STAGE_DIR="${PROJECT_ROOT}/dist/dmg-root"
VOL_NAME="${APP_NAME}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found: ${APP_PATH}"
  exit 1
fi

PLIST_PATH="${APP_PATH}/Contents/Info.plist"
if [[ ! -f "${PLIST_PATH}" ]]; then
  echo "Invalid app bundle: missing Info.plist"
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${PLIST_PATH}" 2>/dev/null || true)"
if [[ -z "${EXECUTABLE_NAME}" ]]; then
  echo "Invalid app bundle: missing CFBundleExecutable"
  exit 1
fi

EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "Invalid app bundle: executable not found at ${EXECUTABLE_PATH}"
  exit 1
fi

# Guard rail: prevent packaging Debug app bundles.
if [[ -f "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}.debug.dylib" ]]; then
  echo "Refusing to package Debug app bundle."
  echo "Please build Release first, then retry."
  exit 1
fi

if otool -L "${EXECUTABLE_PATH}" | grep -q "\.debug\.dylib"; then
  echo "Refusing to package Debug-linked executable."
  echo "Please build Release first, then retry."
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "${VOL_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO "${DMG_PATH}"

echo "DMG created: ${DMG_PATH}"
echo "Tip: For polished layout/background, mount the DMG and run AppleScript Finder positioning before final conversion."
