# YouTubeDownloader

macOS Apple Silicon 전용 SwiftUI 앱입니다. `yt-dlp`와 `ffmpeg`를 앱 내부 `Process`로 실행해서 YouTube, 직접 `m3u8`, 실시간 `m3u8` 녹화를 처리합니다.

## 주요 기능
- YouTube / 직접 `m3u8` URL 다운로드
- 직접 `m3u8` 라이브 스트림 녹화
- 다중 다운로드 작업 동시 실행
- `yt-dlp --newline` 기반 진행률 표시
- `ffmpeg` 기반 로컬 영상 병합
- 원본 유지 우선 병합
  - 같은 영상 조건이면 비디오 무열화 병합
  - 오디오만 다르면 오디오만 변환 후 병합
- 설정 화면에서 Homebrew / `yt-dlp` / `ffmpeg` 설치 상태 확인 및 설치 안내

## 요구 사항
- macOS
- Apple Silicon
- Xcode
- Homebrew 경로 기준 도구
  - `/opt/homebrew/bin/yt-dlp`
  - `/opt/homebrew/bin/ffmpeg`
  - `/opt/homebrew/bin/ffprobe` (선택)

## 실행
Xcode:
- `/Users/pdg/Documents/유튜브 다운로더/YouTubeDownloader.xcodeproj` 열기
- `YouTubeDownloader` 스킴 실행

CLI:
```bash
xcodebuild -project "/Users/pdg/Documents/유튜브 다운로더/YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

## 테스트
```bash
xcodebuild test -project "/Users/pdg/Documents/유튜브 다운로더/YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -destination 'platform=macOS,arch=arm64'
```

주의:
- 이 환경에서는 macOS 테스트 러너 제약 때문에 `xcodebuild test`가 실패하거나 멈출 수 있습니다.

## 배포
Release 앱:
```bash
./Scripts/build_release_app.sh
```

DMG:
```bash
./Scripts/create_dmg.sh
```

GitHub Releases 업로드 흐름은 `/Users/pdg/Documents/유튜브 다운로더/RELEASING.md` 참고.

## 구조
- `Managers/ToolManager.swift`
- `Managers/DownloadManager.swift`
- `Utilities/ProcessRunner.swift`
- `Views/MainView.swift`
- `Views/ToolsView.swift`
- `Models/ToolModels.swift`

## 제약
- App Store 배포 대상 아님
- 다운로드 시 Terminal 창 직접 실행 안 함
- 기본 경로는 `/opt/homebrew`만 사용
- 쿠키/로그인/프록시 등 고급 기능은 MVP 범위 밖
