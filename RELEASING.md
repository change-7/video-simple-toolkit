# Releasing

GitHub Releases에 올릴 DMG를 만드는 최소 흐름입니다.

## 1. Release 앱 빌드
```bash
./Scripts/build_release_app.sh
```

산출물:
- `YouTubeDownloader.app`

## 2. DMG 생성
```bash
./Scripts/create_dmg.sh
```

산출물:
- `YouTubeDownloader-AppleSilicon.dmg`

## 3. 선택: 서명 / 노타리제이션
Developer ID 인증서와 notarytool 프로필이 있으면:
```bash
./Scripts/archive_and_sign.sh
./Scripts/create_dmg.sh /path/to/signed/YouTubeDownloader.app
./Scripts/notarize_dmg.sh
```

필요 환경 변수:
- `DEVELOPMENT_TEAM`
- `NOTARY_PROFILE`

## 4. GitHub Releases 업로드
GitHub 저장소의 Releases 화면에서:
1. `Draft a new release`
2. 태그 입력 예: `v0.1.0`
3. 제목 입력
4. `YouTubeDownloader-AppleSilicon.dmg` 업로드
5. 릴리스 노트는 `Scripts/RELEASE_NOTES.md` 참고

## 체크
- Debug 앱이 아닌 Release 앱인지 확인
- DMG 안에 `Applications` 링크가 있는지 확인
- 다운로드 후 앱 실행이 되는지 다른 경로에서 한 번 확인
