#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="${1:-${PROJECT_ROOT}/Video Simple Toolkit-AppleSilicon.dmg}"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}"
  exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "NOTARY_PROFILE environment variable is required (notarytool keychain profile name)."
  exit 1
fi

xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"

echo "Notarization submitted and stapled: ${DMG_PATH}"
