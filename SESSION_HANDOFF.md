## Done
- Renamed the user-facing app to `Video Simple Toolkit`.
- Built the macOS SwiftUI video toolkit and kept downloads/ffmpeg work inside the app via `Process`.
- Added multi-download task UI with per-task progress, pause/resume, cancel, and cleanup.
- Added direct URL / m3u8 / streaming URL handling with reconnect options.
- Added local video merge tooling for 2+ files with original-preserving mode and audio-only normalization when possible.
- Added HD black-screen video generation from audio + subtitles, including drag-and-drop and subtitle font preview.
- Simplified settings UI into sidebar sections and merged tool/install management.
- Fixed output tracking so downloads use printed `yt-dlp` file paths instead of scanning the folder for the newest file.
- Moved success validation work off the main thread.
- Changed `ffprobe` validation failure to fail the download instead of marking it complete.
- Reduced wasted state and log buffering overhead in `DownloadManager` and `ToolManager`.
- Release build succeeded and root app bundle was refreshed: `Video Simple Toolkit.app`
- GitHub repository was renamed and made public: `https://github.com/change-7/video-simple-toolkit`

## In progress
- Test execution is not fully verified in this environment.

## Problems
- `xcodebuild test` inside sandbox fails because `testmanagerd` communication is restricted.
- `xcodebuild test` outside sandbox started but did not finish cleanly in this session, so there is no trustworthy green test result yet.
- A hanging escalated `xcodebuild` process was manually terminated after investigation.

## Next steps
1. Re-run `xcodebuild test` in a stable local environment and confirm `DownloadLineHeuristicsTests` passes.
2. Manually verify concurrent downloads save the correct final file when two jobs target the same folder.
3. Manually verify direct streaming URL recording with a fresh expiring URL.
4. Rebuild and upload `Video Simple Toolkit-AppleSilicon.dmg` when a release is needed.

## Related files
- `Managers/DownloadManager.swift`
- `Managers/ToolManager.swift`
- `Utilities/DownloadLineHeuristics.swift`
- `Views/MainView.swift`
- `Views/ToolsView.swift`
- `Views/CopyButton.swift`
- `Models/ToolModels.swift`
- `Tests/YouTubeDownloaderTests/DownloadLineHeuristicsTests.swift`
