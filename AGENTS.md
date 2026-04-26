## Project goal
- Build `Video Simple Toolkit`, a macOS Apple Silicon-only SwiftUI app for YouTube/direct downloads, stream recording, video merging, and subtitle video generation through `yt-dlp` and `ffmpeg`.
- The app must not open Terminal for downloads. It runs tools internally with `Process` and streams output into the UI.
- Distribution target is direct `.app` / `.dmg`, not the App Store.

## Tech stack
- Swift 5
- SwiftUI + AppKit interop (`NSOpenPanel`, `NSWorkspace`, `NSPasteboard`)
- `Process` / `Pipe` based tool execution
- Xcode project: `YouTubeDownloader.xcodeproj`
- External runtime dependency: `/opt/homebrew/bin/yt-dlp`, `/opt/homebrew/bin/ffmpeg`, optional `/opt/homebrew/bin/ffprobe`

## Run
- Open `YouTubeDownloader.xcodeproj` in Xcode and run the `YouTubeDownloader` scheme.
- The internal project/scheme names remain `YouTubeDownloader`; the built app product is `Video Simple Toolkit`.
- CLI build:
```bash
xcodebuild -project "YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

## Test
- CLI test:
```bash
xcodebuild test -project "YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -destination 'platform=macOS,arch=arm64'
```
- Note: in this environment, `xcodebuild test` may fail or hang because macOS test runner communication can be blocked by sandbox / helper restrictions.

## Constraints
- Apple Silicon only. Keep `/opt/homebrew` as the default tool path base.
- Do not add automatic install/update logic that silently runs brew for regular downloads.
- Do not open Terminal UI. Use `Process` only.
- Keep download arguments as arrays, never one shell string.
- Do not add cookie/login/proxy MVP features beyond guidance text.
- Do not reintroduce noisy tool path/version UI unless explicitly requested.

## Coding rules
- Keep managers separated: `ToolManager`, `DownloadManager`, `ProcessRunner`, models, views.
- Keep UI updates on the main thread. Run process execution and file validation off the main thread.
- Prefer deterministic output tracking from `yt-dlp` output over folder-wide guessing.
- Treat invalid `ffprobe` validation as failure, not success.
- Keep settings in `UserDefaults` / `@AppStorage`.
- Prefer small, focused edits and keep the main UI compact.
