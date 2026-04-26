#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${PROJECT_ROOT}/build/ReleaseCheck"
APP_NAME="Video Simple Toolkit"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/VideoSimpleToolkit.app"
OUTPUT_APP="${PROJECT_ROOT}/${APP_NAME}.app"

xcodebuild \
  -project "${PROJECT_ROOT}/YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "platform=macOS,arch=arm64" \
  build

rm -rf "${OUTPUT_APP}"
cp -R "${BUILT_APP}" "${OUTPUT_APP}"

echo "Release app ready: ${OUTPUT_APP}"
