## Done
- Built the macOS SwiftUI downloader app and kept downloads inside the app via `Process`.
- Added multi-download task UI with per-task progress, pause/resume, cancel, and cleanup.
- Added direct m3u8 handling with reconnect options.
- Simplified settings UI into sidebar sections and merged tool/install management.
- Fixed output tracking so downloads use printed `yt-dlp` file paths instead of scanning the folder for the newest file.
- Moved success validation work off the main thread.
- Changed `ffprobe` validation failure to fail the download instead of marking it complete.
- Reduced wasted state and log buffering overhead in `DownloadManager` and `ToolManager`.
- Release build succeeded and root app bundle was refreshed: `/Users/pdg/Documents/유튜브 다운로더/YouTubeDownloader.app`

## In progress
- Test execution is not fully verified in this environment.
- The code-side fixes are in place, but automated confirmation is limited by the local test runner environment.

## Problems
- `xcodebuild test` inside sandbox fails because `testmanagerd` communication is restricted.
- `xcodebuild test` outside sandbox started but did not finish cleanly in this session, so there is no trustworthy green test result yet.
- A hanging escalated `xcodebuild` process was manually terminated after investigation.

## Next steps
1. Re-run `xcodebuild test` in a stable local environment and confirm `DownloadLineHeuristicsTests` passes.
2. Manually verify concurrent downloads save the correct final file when two jobs target the same folder.
3. Manually verify QuickTime-compatible MP4 playback on a few real downloads.
4. If requested, refresh `/Applications/YouTubeDownloader.app` and rebuild the DMG.

## Related files
- `/Users/pdg/Documents/유튜브 다운로더/Managers/DownloadManager.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Managers/ToolManager.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Utilities/DownloadLineHeuristics.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Views/MainView.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Views/ToolsView.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Models/ToolModels.swift`
- `/Users/pdg/Documents/유튜브 다운로더/Tests/YouTubeDownloaderTests/DownloadLineHeuristicsTests.swift`
