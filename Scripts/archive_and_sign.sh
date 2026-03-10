#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${PROJECT_ROOT}/build/ReleaseArchive/YouTubeDownloader.xcarchive"
EXPORT_DIR="${PROJECT_ROOT}/build/ReleaseSigned"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "DEVELOPMENT_TEAM environment variable is required."
  exit 1
fi

mkdir -p "${PROJECT_ROOT}/build/ReleaseArchive" "${EXPORT_DIR}"

xcodebuild \
  -project "${PROJECT_ROOT}/YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  archive

cat > "${PROJECT_ROOT}/build/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${PROJECT_ROOT}/build/exportOptions.plist"

echo "Signed app exported to: ${EXPORT_DIR}"
