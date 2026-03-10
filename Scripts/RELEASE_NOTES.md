# Release Packaging Notes

## Signing / Notarization (Developer ID)
- `Scripts/archive_and_sign.sh`
- `Scripts/create_dmg.sh`
- `Scripts/notarize_dmg.sh`

## Required Environment Variables
- `DEVELOPMENT_TEAM`: Apple Developer Team ID (for archive/export)
- `NOTARY_PROFILE`: `xcrun notarytool store-credentials` 로 저장한 keychain profile 이름

## Typical Flow
1. `xcodegen generate` (if project settings changed)
2. `Scripts/archive_and_sign.sh`
3. `Scripts/create_dmg.sh /path/to/signed/YouTubeDownloader.app`
4. `Scripts/notarize_dmg.sh`

## Notes
- Hardened Runtime is enabled in `project.yml`.
- The app is unsandboxed DMG distribution (non-App Store).
