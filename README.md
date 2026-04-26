# Video Simple Toolkit

macOS Apple Silicon 전용 SwiftUI 영상 유틸리티입니다. `yt-dlp`와 `ffmpeg`를 앱 내부 `Process`로 실행해서 다운로드, 스트리밍 녹화, 영상 병합, 자막 하드코딩 영상을 처리합니다.

## 주요 기능
- YouTube / 직접 URL / `m3u8` 다운로드
- 직접 `m3u8` 및 플레이어에서 열리는 스트리밍 URL 녹화
- 다중 다운로드 작업 동시 실행
- `yt-dlp --newline` 기반 진행률 표시
- 네트워크 끊김 시 자동 재접속 옵션
- `ffmpeg` 기반 로컬 영상 병합, 2개 이상 파일 지원
- 원본 유지 우선 병합:
  - 같은 영상 조건이면 비디오 무열화 병합
  - 오디오만 다르면 오디오만 변환 후 병합
- 오디오 파일 + 자막 파일로 HD 검은 화면 자막 영상 생성
- 자막 미리보기 및 폰트 크기 조절
- 앱 내부에서 Homebrew / `yt-dlp` / `ffmpeg` 설치와 제거 실행
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
- `YouTubeDownloader.xcodeproj` 열기
- `YouTubeDownloader` 스킴 실행

참고:
- Xcode 프로젝트/스킴 이름은 기존 호환성을 위해 `YouTubeDownloader`로 유지합니다.
- 빌드 결과 앱 이름은 `Video Simple Toolkit`입니다.

CLI:
```bash
xcodebuild -project "YouTubeDownloader.xcodeproj" \
  -scheme "YouTubeDownloader" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

## 테스트
```bash
xcodebuild test -project "YouTubeDownloader.xcodeproj" \
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

산출물:
- `Video Simple Toolkit.app`

DMG:
```bash
./Scripts/create_dmg.sh
```

산출물:
- `Video Simple Toolkit-AppleSilicon.dmg`

GitHub Releases 업로드 흐름은 `RELEASING.md` 참고.

## 저장소
- `https://github.com/change-7/video-simple-toolkit`

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
