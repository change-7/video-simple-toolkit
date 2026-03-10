import Foundation
import Combine

enum YtDlpUpdateCheckState {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case unavailable
}

final class ToolManager: ObservableObject {
    @Published private(set) var status: ToolStatus = .empty
    @Published private(set) var ytDlpUpdateCheckState: YtDlpUpdateCheckState = .idle
    @Published private(set) var lastYtDlpUpdateCheckedAt: Date?
    @Published private(set) var homebrewInstalled: Bool = false
    @Published private(set) var isToolActionRunning: Bool = false
    @Published private(set) var toolActionTitle: String = ""
    @Published private(set) var toolActionMessage: String = ""
    @Published private(set) var toolActionLog: String = ""

    private let defaults: UserDefaults
    private let fileManager: FileManager

    private let defaultYtDlpPath = "/opt/homebrew/bin/yt-dlp"
    private let defaultFfmpegPath = "/opt/homebrew/bin/ffmpeg"
    private let defaultFfprobePath = "/opt/homebrew/bin/ffprobe"
    private let defaultHomebrewPath = "/opt/homebrew/bin/brew"
    private let refreshStateQueue = DispatchQueue(label: "tool.manager.refresh.state")
    private let detectQueue = DispatchQueue(label: "tool.manager.detect", qos: .userInitiated, attributes: .concurrent)
    private let actionStateQueue = DispatchQueue(label: "tool.manager.action.state")
    private var latestRefreshRequestID: Int = 0
    private var lastRefreshStartedAt: Date?
    private let refreshDebounceInterval: TimeInterval = 2.0
    private var isCheckingYtDlpUpdate = false
    private var isToolActionBusy = false
    private var activeToolActionProcess: RunningProcess?
    private var pendingToolActionLogLines: [String] = []
    private var toolActionLogFlushWorkItem: DispatchWorkItem?
    private let maxToolActionLogChars = 40_000
    private let toolActionLogFlushInterval: TimeInterval = 0.20

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func refresh(force: Bool = false) {
        let maybeRequestID = refreshStateQueue.sync { () -> Int? in
            let now = Date()
            if !force,
               let lastRefreshStartedAt,
               now.timeIntervalSince(lastRefreshStartedAt) < refreshDebounceInterval {
                return nil
            }

            self.lastRefreshStartedAt = now
            latestRefreshRequestID += 1
            return latestRefreshRequestID
        }

        guard let requestID = maybeRequestID else { return }

        detectQueue.async {
            let detected = self.detectTools()
            let brewPath = self.resolveHomebrewExecutable()
            DispatchQueue.main.async {
                let isLatest = self.refreshStateQueue.sync { requestID == self.latestRefreshRequestID }
                guard isLatest else { return }
                self.status = detected
                self.homebrewInstalled = brewPath != nil
            }
        }
    }

    func checkYtDlpUpdateAvailability() {
        let shouldStart = refreshStateQueue.sync { () -> Bool in
            if isCheckingYtDlpUpdate {
                return false
            }
            isCheckingYtDlpUpdate = true
            return true
        }

        guard shouldStart else { return }

        DispatchQueue.main.async {
            self.ytDlpUpdateCheckState = .checking
        }

        detectQueue.async {
            let detected = self.detectTools()
            let brewPath = self.resolveHomebrewExecutable()
            let updateState = self.resolveYtDlpUpdateState(from: detected, brewPath: brewPath)
            let checkedAt = Date()

            DispatchQueue.main.async {
                self.ytDlpUpdateCheckState = updateState
                self.lastYtDlpUpdateCheckedAt = checkedAt
                self.homebrewInstalled = brewPath != nil
            }

            self.refreshStateQueue.sync {
                self.isCheckingYtDlpUpdate = false
            }
        }
    }

    func installHomebrew() {
        let script = "NONINTERACTIVE=1 /bin/bash -c \"$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        runShellToolAction(
            title: "Homebrew 설치",
            command: script
        )
    }

    func uninstallHomebrew() {
        let script = "NONINTERACTIVE=1 /bin/bash -c \"$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)\" -- --force"
        runShellToolAction(
            title: "Homebrew 제거",
            command: script
        )
    }

    func installYtDlp() {
        runBrewToolAction(
            title: "yt-dlp 설치",
            arguments: ["install", "yt-dlp"]
        )
    }

    func uninstallYtDlp() {
        runBrewToolAction(
            title: "yt-dlp 제거",
            arguments: ["uninstall", "yt-dlp"]
        )
    }

    func installFfmpeg() {
        runBrewToolAction(
            title: "ffmpeg 설치",
            arguments: ["install", "ffmpeg"]
        )
    }

    func uninstallFfmpeg() {
        runBrewToolAction(
            title: "ffmpeg 제거",
            arguments: ["uninstall", "ffmpeg"]
        )
    }

    func cancelToolAction() {
        let running = actionStateQueue.sync { activeToolActionProcess }
        guard let running else { return }
        running.cancel()
        DispatchQueue.main.async {
            self.toolActionMessage = "실행 중지 요청을 보냈습니다."
        }
    }

    func detectTools() -> ToolStatus {
        let savedYtDlpPath = normalizedSavedPath(forKey: SettingsKeys.ytDlpPath)
        let savedFfmpegPath = normalizedSavedPath(forKey: SettingsKeys.ffmpegPath)

        let ytDlpResolved = resolveToolExecutable(
            savedPath: savedYtDlpPath,
            defaultPath: defaultYtDlpPath,
            commandName: "yt-dlp"
        )
        let ffmpegResolved = resolveToolExecutable(
            savedPath: savedFfmpegPath,
            defaultPath: defaultFfmpegPath,
            commandName: "ffmpeg"
        )
        let ffprobeResolved = resolveToolExecutable(
            savedPath: nil,
            defaultPath: defaultFfprobePath,
            commandName: "ffprobe"
        )

        return ToolStatus(
            ytDlp: ToolInfo(
                name: "yt-dlp",
                isInstalled: ytDlpResolved.isInstalled,
                path: ytDlpResolved.path
            ),
            ffmpeg: ToolInfo(
                name: "ffmpeg",
                isInstalled: ffmpegResolved.isInstalled,
                path: ffmpegResolved.path
            ),
            ffprobe: ToolInfo(
                name: "ffprobe",
                isInstalled: ffprobeResolved.isInstalled,
                path: ffprobeResolved.path
            )
        )
    }

    private func resolveToolExecutable(
        savedPath: String?,
        defaultPath: String,
        commandName: String
    ) -> (path: String?, isInstalled: Bool) {
        if let savedPath,
           isExecutableTool(at: savedPath) {
            return (savedPath, true)
        }

        if isExecutableTool(at: defaultPath) {
            return (defaultPath, true)
        }

        if let whichPath = resolvePathUsingWhich(commandName),
           isExecutableTool(at: whichPath) {
            return (whichPath, true)
        }

        return (nil, false)
    }

    private func isExecutableTool(at path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func resolvePathUsingWhich(_ commandName: String) -> String? {
        guard let result = ProcessRunner.runAndCapture(
            executablePath: "/usr/bin/which",
            arguments: [commandName]
        ), result.terminationStatus == 0
        else {
            return nil
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func resolveHomebrewExecutable() -> String? {
        if isExecutableTool(at: defaultHomebrewPath) {
            return defaultHomebrewPath
        }

        if let whichPath = resolvePathUsingWhich("brew"),
           isExecutableTool(at: whichPath) {
            return whichPath
        }

        return nil
    }

    private func resolveYtDlpUpdateState(from detected: ToolStatus, brewPath: String?) -> YtDlpUpdateCheckState {
        guard detected.ytDlp.isInstalled else {
            return .unavailable
        }

        guard let brewPath,
              fileManager.isExecutableFile(atPath: brewPath) else {
            return .unavailable
        }

        guard let result = ProcessRunner.runAndCapture(
            executablePath: brewPath,
            arguments: ["outdated", "yt-dlp"]
        ), result.terminationStatus == 0 else {
            return .unavailable
        }

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let hasOutdatedYtDlp = lines.contains { line in
            line == "yt-dlp" || line.hasPrefix("yt-dlp ")
        }
        return hasOutdatedYtDlp ? .updateAvailable : .upToDate
    }

    private func normalizedSavedPath(forKey key: String) -> String? {
        guard let saved = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !saved.isEmpty
        else {
            return nil
        }
        return saved
    }

    private func runBrewToolAction(title: String, arguments: [String]) {
        guard let brewPath = resolveHomebrewExecutable() else {
            DispatchQueue.main.async {
                self.toolActionMessage = "Homebrew가 설치되어 있지 않습니다. 먼저 Homebrew를 설치하세요."
            }
            return
        }

        runToolAction(
            title: title,
            executableURL: URL(fileURLWithPath: brewPath),
            arguments: arguments,
            environment: baseToolEnvironment()
        )
    }

    private func runShellToolAction(title: String, command: String) {
        runToolAction(
            title: title,
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", command],
            environment: baseToolEnvironment()
        )
    }

    private func runToolAction(
        title: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        let canStart = actionStateQueue.sync { () -> Bool in
            if isToolActionBusy {
                return false
            }
            isToolActionBusy = true
            return true
        }

        guard canStart else {
            DispatchQueue.main.async {
                self.toolActionMessage = "다른 설치/제거 작업이 실행 중입니다."
            }
            return
        }

        DispatchQueue.main.async {
            self.isToolActionRunning = true
            self.toolActionTitle = title
            self.toolActionMessage = "\(title) 실행 중..."
            self.toolActionLog = ""
        }

        actionStateQueue.async {
            self.pendingToolActionLogLines.removeAll(keepingCapacity: true)
            self.toolActionLogFlushWorkItem?.cancel()
            self.toolActionLogFlushWorkItem = nil
        }

        detectQueue.async {
            do {
                let running = try ProcessRunner.runStreaming(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    onStdoutLine: { [weak self] line in
                        self?.appendToolActionLog(line)
                    },
                    onStderrLine: { [weak self] line in
                        self?.appendToolActionLog(line)
                    },
                    onExit: { [weak self] status in
                        self?.finishToolAction(title: title, terminationStatus: status)
                    }
                )

                self.actionStateQueue.sync {
                    self.activeToolActionProcess = running
                }
            } catch {
                self.finishToolActionWithLaunchError(title: title, error: error.localizedDescription)
            }
        }
    }

    private func appendToolActionLog(_ line: String) {
        let sanitized = line
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .newlines)
        guard !sanitized.isEmpty else { return }

        actionStateQueue.async {
            self.pendingToolActionLogLines.append(sanitized)
            guard self.toolActionLogFlushWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.flushPendingToolActionLogsOnActionQueue()
            }
            self.toolActionLogFlushWorkItem = workItem
            self.actionStateQueue.asyncAfter(deadline: .now() + self.toolActionLogFlushInterval, execute: workItem)
        }
    }

    private func finishToolAction(title: String, terminationStatus: Int32) {
        flushPendingToolActionLogs()

        actionStateQueue.sync {
            activeToolActionProcess = nil
            isToolActionBusy = false
        }

        let success = terminationStatus == 0
        DispatchQueue.main.async {
            self.isToolActionRunning = false
            self.toolActionMessage = success
                ? "\(title) 완료"
                : "\(title) 실패 (종료 코드: \(terminationStatus))"
        }

        refresh(force: true)

        if title.contains("yt-dlp") {
            checkYtDlpUpdateAvailability()
        }
    }

    private func finishToolActionWithLaunchError(title: String, error: String) {
        flushPendingToolActionLogs()

        actionStateQueue.sync {
            activeToolActionProcess = nil
            isToolActionBusy = false
        }

        DispatchQueue.main.async {
            self.isToolActionRunning = false
            self.toolActionMessage = "\(title) 실행 실패: \(error)"
        }
    }

    private func baseToolEnvironment() -> [String: String] {
        let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "PATH": basePath
        ]
    }

    private func flushPendingToolActionLogs() {
        actionStateQueue.async {
            self.flushPendingToolActionLogsOnActionQueue()
        }
    }

    private func flushPendingToolActionLogsOnActionQueue() {
        toolActionLogFlushWorkItem?.cancel()
        toolActionLogFlushWorkItem = nil

        guard !pendingToolActionLogLines.isEmpty else { return }

        let chunk = pendingToolActionLogLines.joined(separator: "\n")
        pendingToolActionLogLines.removeAll(keepingCapacity: true)

        DispatchQueue.main.async {
            var next = self.toolActionLog
            if !next.isEmpty {
                next.append("\n")
            }
            next.append(chunk)

            if next.count > self.maxToolActionLogChars {
                next = String(next.suffix(self.maxToolActionLogChars))
            }
            self.toolActionLog = next
        }
    }
}
