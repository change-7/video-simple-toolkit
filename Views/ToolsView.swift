import SwiftUI

struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toolManager: ToolManager

    @AppStorage(SettingsKeys.defaultDownloadPreset) private var defaultDownloadPresetRaw: String = DownloadPreset.macCompatibleMP4.rawValue
    @AppStorage(SettingsKeys.defaultFilenameConflictPolicy) private var defaultFilenameConflictPolicyRaw: String = FilenameConflictPolicy.autoRename.rawValue
    @AppStorage(SettingsKeys.mergeBehavior) private var mergeBehaviorRaw: String = MergeBehavior.compatibilityPreferred.rawValue
    @AppStorage(SettingsKeys.ytDlpCheckUpdateOnLaunch) private var ytDlpCheckUpdateOnLaunch: Bool = true
    @AppStorage(SettingsKeys.hlsAutoReconnectEnabled) private var hlsAutoReconnectEnabled: Bool = true
    @AppStorage(SettingsKeys.hlsReconnectFailTimeoutSeconds) private var hlsReconnectFailTimeoutSeconds: Int = 90
    @AppStorage(SettingsKeys.hoverHelpEnabled) private var hoverHelpEnabled: Bool = true

    @State private var selectedSettingsSection: SettingsSection? = .download
    @State private var alertMessage: String = ""
    @State private var showAlert = false

    private let homebrewInstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    private let homebrewUninstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)\" -- --force"
    private let ytDlpUpgradeCommand = "brew upgrade yt-dlp"

    private var defaultPreset: Binding<DownloadPreset> {
        Binding(
            get: { DownloadPreset(rawValue: defaultDownloadPresetRaw) ?? .macCompatibleMP4 },
            set: { defaultDownloadPresetRaw = $0.rawValue }
        )
    }

    private var defaultConflictPolicy: Binding<FilenameConflictPolicy> {
        Binding(
            get: { FilenameConflictPolicy(rawValue: defaultFilenameConflictPolicyRaw) ?? .autoRename },
            set: { defaultFilenameConflictPolicyRaw = $0.rawValue }
        )
    }

    private var mergeBehavior: Binding<MergeBehavior> {
        Binding(
            get: { MergeBehavior(rawValue: mergeBehaviorRaw) ?? .compatibilityPreferred },
            set: { mergeBehaviorRaw = $0.rawValue }
        )
    }

    private var currentSettingsSection: SettingsSection {
        selectedSettingsSection ?? .download
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("설정")
                        .font(.title3.bold())
                    Text("도구 / 업데이트")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button("다시 검사") {
                        toolManager.refresh(force: true)
                    }

                    Button("닫기") {
                        dismiss()
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                settingsSidebar

                Divider()
                    .frame(maxHeight: .infinity)

                ScrollView {
                    activeSectionContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .controlSize(.regular)
        .onAppear {
            toolManager.refresh()
        }
        .alert("안내", isPresented: $showAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSettingsSection = section
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.iconName)
                                .frame(width: 14)
                            Text(section.title)
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(currentSettingsSection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
            }
            .padding(4)
        }
        .frame(width: 172)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var activeSectionContent: some View {
        switch currentSettingsSection {
        case .download:
            VStack(alignment: .leading, spacing: 10) {
                interfaceHelpCard
                downloadDefaultsCard
            }
        case .tools:
            toolsStatusSection
        case .update:
            updateTroubleshootingCard
        }
    }

    private var interfaceHelpCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                settingRow(title: "마우스 오버 설명") {
                    Toggle("사용", isOn: $hoverHelpEnabled)
                        .labelsHidden()
                }
            }
            .padding(.top, 4)
        } label: {
            Text("화면 도움말")
        }
    }

    private var downloadDefaultsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                settingRow(title: "포맷 프리셋") {
                    Picker("포맷 프리셋", selection: defaultPreset) {
                        ForEach(DownloadPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                settingRow(title: "동일 파일명 처리") {
                    Picker("동일 파일명 처리", selection: defaultConflictPolicy) {
                        ForEach(FilenameConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                settingRow(title: "영상 병합 모드") {
                    Picker("영상 병합 모드", selection: mergeBehavior) {
                        ForEach(MergeBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                settingRow(title: "m3u8 재접속") {
                    Toggle("자동 재접속", isOn: $hlsAutoReconnectEnabled)
                        .labelsHidden()
                }

                settingRow(title: "자동 중지(초)") {
                    Stepper(value: $hlsReconnectFailTimeoutSeconds, in: 15...1800, step: 15) {
                        Text("\(hlsReconnectFailTimeoutSeconds)초")
                            .font(.caption.monospacedDigit())
                    }
                    .disabled(!hlsAutoReconnectEnabled)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("다운로드 기본값")
        }
    }

    private var toolsStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    managedToolRow(
                        title: "Homebrew",
                        isInstalled: toolManager.homebrewInstalled,
                        onInstall: {
                            alertMessage = "Homebrew 설치는 Terminal.app에서 진행하는 방식이 가장 안정적입니다.\n\n설치 명령:\n\(homebrewInstallCommand)"
                            showAlert = true
                        },
                        onUninstall: {
                            alertMessage = "Homebrew 제거도 Terminal.app에서 진행하는 방식이 가장 안정적입니다.\n\n제거 명령:\n\(homebrewUninstallCommand)"
                            showAlert = true
                        }
                    )

                    Divider()

                    managedToolRow(
                        title: "yt-dlp",
                        isInstalled: toolManager.status.ytDlp.isInstalled,
                        onInstall: { toolManager.installYtDlp() },
                        onUninstall: { toolManager.uninstallYtDlp() }
                    )

                    Divider()

                    managedToolRow(
                        title: "ffmpeg",
                        isInstalled: toolManager.status.ffmpeg.isInstalled,
                        onInstall: { toolManager.installFfmpeg() },
                        onUninstall: { toolManager.uninstallFfmpeg() }
                    )
                }
                .padding(.top, 4)
            } label: {
                Text("도구 설치/제거")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    commandRow(title: "1) Homebrew 설치(최초 1회)", command: homebrewInstallCommand)
                    commandRow(title: "2) Homebrew 제거", command: homebrewUninstallCommand)
                    commandRow(title: "3) yt-dlp 설치", command: "brew install yt-dlp")
                    commandRow(title: "4) ffmpeg 설치", command: "brew install ffmpeg")
                }
                .padding(.top, 4)
            } label: {
                Text("터미널 설치 방법")
            }

            toolActionConsoleCard
        }
    }

    private var toolActionConsoleCard: some View {
        GroupBox("설치/제거 실행 로그") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if toolManager.isToolActionRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(toolManager.isToolActionRunning
                         ? "실행 중: \(toolManager.toolActionTitle)"
                         : "대기")
                    .font(.caption.weight(.semibold))
                    Spacer()
                    if toolManager.isToolActionRunning {
                        Button("중지") {
                            toolManager.cancelToolAction()
                        }
                    }
                }

                if !toolManager.toolActionMessage.isEmpty {
                    Text(toolManager.toolActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(toolManager.toolActionLog.isEmpty
                         ? "실행 로그가 여기에 표시됩니다."
                         : toolManager.toolActionLog)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 70, maxHeight: 130)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )

                HStack {
                    CopyButton(
                        title: "로그 복사",
                        valueProvider: { toolManager.toolActionLog },
                        disabled: toolManager.toolActionLog.isEmpty,
                        showsInstantHelp: false
                    )
                    Spacer()
                }
            }
            .padding(.top, 4)
        }
    }

    private var updateTroubleshootingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("앱 실행 시 yt-dlp 업데이트 확인", isOn: $ytDlpCheckUpdateOnLaunch)
                    .font(.caption)

                HStack(spacing: 8) {
                    Text("업데이트 확인 상태")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ytDlpUpdateStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ytDlpUpdateStatusColor)
                }

                Text("마지막 업데이트 확인: \(formattedYtDlpUpdateCheckedAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    CopyButton(
                        title: "업데이트 명령 복사",
                        valueProvider: { ytDlpUpgradeCommand },
                        showsInstantHelp: false
                    )

                    Button("업데이트 후 다시 검사") {
                        alertMessage = "Terminal.app을 열어 'brew upgrade yt-dlp'를 실행한 뒤 확인하세요. 지금 설치 여부를 다시 확인합니다."
                        showAlert = true
                        toolManager.refresh(force: true)
                        toolManager.checkYtDlpUpdateAvailability()
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("업데이트 / 문제 해결")
        }
    }

    private func managedToolRow(
        title: String,
        isInstalled: Bool,
        onInstall: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                statusBadge(isInstalled: isInstalled)
            }

            HStack(spacing: 8) {
                Button("설치") {
                    onInstall()
                }
                .disabled(toolManager.isToolActionRunning || isInstalled)

                Button("제거") {
                    onUninstall()
                }
                .disabled(toolManager.isToolActionRunning || !isInstalled)

                Button("검사") {
                    toolManager.refresh(force: true)
                }
                .disabled(toolManager.isToolActionRunning)

                Spacer(minLength: 8)
            }
        }
    }

    private func statusBadge(isInstalled: Bool) -> some View {
        Text(isInstalled ? "설치됨" : "미설치")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isInstalled ? Color.green : Color.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill((isInstalled ? Color.green : Color.red).opacity(0.12))
            )
    }

    private var formattedYtDlpUpdateCheckedAt: String {
        guard let date = toolManager.lastYtDlpUpdateCheckedAt else {
            return "-"
        }
        return Self.lastCheckedFormatter.string(from: date)
    }

    private var ytDlpUpdateStatusText: String {
        switch toolManager.ytDlpUpdateCheckState {
        case .idle:
            return "미확인"
        case .checking:
            return "확인 중"
        case .upToDate:
            return "최신"
        case .updateAvailable:
            return "업데이트 가능"
        case .unavailable:
            return "확인 불가"
        }
    }

    private var ytDlpUpdateStatusColor: Color {
        switch toolManager.ytDlpUpdateCheckState {
        case .upToDate:
            return .green
        case .updateAvailable:
            return .orange
        case .checking:
            return .secondary
        case .idle, .unavailable:
            return .secondary
        }
    }

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                CopyButton(
                    title: "복사",
                    valueProvider: { command },
                    showsInstantHelp: false
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            content()
        }
    }

    private static let lastCheckedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case download
    case tools
    case update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: return "다운로드"
        case .tools: return "도구/설치"
        case .update: return "업데이트"
        }
    }

    var iconName: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .tools: return "wrench.and.screwdriver"
        case .update: return "arrow.triangle.2.circlepath"
        }
    }

    var detail: String {
        switch self {
        case .download:
            return "다운로드 포맷, 파일명 충돌 처리, 병합, m3u8 재접속 기본값을 설정합니다."
        case .tools:
            return "yt-dlp, ffmpeg, Homebrew 설치 상태를 확인하고 설치 또는 제거를 실행합니다."
        case .update:
            return "yt-dlp 업데이트 확인과 문제 해결용 명령을 확인합니다."
        }
    }
}
