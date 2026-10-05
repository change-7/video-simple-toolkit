import SwiftUI

@main
struct YouTubeDownloaderApp: App {
    @StateObject private var toolManager = ToolManager()
    @AppStorage(SettingsKeys.ytDlpCheckUpdateOnLaunch) private var ytDlpCheckUpdateOnLaunch: Bool = true

    var body: some Scene {
        WindowGroup {
            MainView()
            .environmentObject(toolManager)
            .frame(width: 700, height: 760)
            .onAppear {
                toolManager.refresh()
                if ytDlpCheckUpdateOnLaunch {
                    toolManager.checkYtDlpUpdateAvailability()
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

/*
 테스트 시나리오
 1) 도구 미설치 상태에서 앱 실행
    - 설정 버튼을 눌러 설치 안내/복사 버튼이 노출되고 상태가 ❌로 보이는지 확인
 2) 도구 설치 후 다시 검사
    - 설정 팝업의 "다시 검사"로 설치 상태가 ✅로 갱신되는지 확인
 3) 유효하지 않은 URL 입력
    - 다운로드 버튼이 비활성화되는지 확인
 4) 다운로드 시작
    - ProgressView, 상태 텍스트(퍼센트/속도/ETA), 로그 스트리밍이 갱신되는지 확인
 5) 취소 동작
    - 취소 버튼 클릭 시 프로세스 종료 후 UI가 복구되는지 확인
 6) 완료 동작
    - 완료 후 "폴더 열기", "경로 복사" 버튼이 정상 동작하는지 확인
 7) 영상 붙이기 파일 추가
    - Finder에서 로컬 영상 여러 개를 드래그하면 목록에 순서대로 추가되는지 확인
 8) 영상 붙이기 실행
    - ffmpeg 설치 상태에서 파일 2개 이상 추가 후 "영상 합치기" 실행 시 merged-YYYYMMDD-HHMMSS.mp4 파일이 생성되는지 확인
 9) 영상 붙이기 중지
    - 병합 중 "중지" 클릭 시 프로세스가 종료되고 상태가 취소됨으로 바뀌는지 확인
*/
