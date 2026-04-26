import Foundation
import Combine

final class DownloadManager: ObservableObject {
    private enum ExecutionMode {
        case ytDlp
        case directM3U8Recording
    }

    private struct StatusEvent {
        let phase: DownloadPhase
        let progress: Double?
        let text: String
    }

    private struct SuccessfulDownloadResolution {
        let hasTemporaryArtifacts: Bool
        let resolvedOutput: URL?
        let validation: DownloadValidationSummary?
    }

    private struct LineAnalysis {
        let outputFilePath: URL?
        let statusEvent: StatusEvent?
        let errorMessage: String?
        let failureSignals: DownloadFailureSignals
        let reusedExistingDownload: Bool
    }

    private struct FFmpegRecordingProgressState {
        var outTimeText: String?
        var totalSizeBytes: Int64?
        var bitrateText: String?
        var speedText: String?

        mutating func reset() {
            outTimeText = nil
            totalSizeBytes = nil
            bitrateText = nil
            speedText = nil
        }
    }

    @Published private(set) var phase: DownloadPhase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String = "대기 중"
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var outputFilePath: URL?
    @Published private(set) var failureCategory: DownloadFailureCategory?
    @Published var userMessage: String?

    private var runningProcess: RunningProcess?
    private var didCancel = false
    private var lastTemporaryOutputPath: URL?
    private var hasTemporaryArtifacts = false
    private var aggregatedFailureSignals = DownloadFailureSignals()
    private var currentRunStartedAt: Date?
    private var didReuseExistingDownload = false
    private var pendingAnalyses: [LineAnalysis] = []
    private var analysisFlushWorkItem: DispatchWorkItem?
    private var pendingStatusEvent: StatusEvent?
    private var statusFlushWorkItem: DispatchWorkItem?

    private var currentToolPaths: ToolPaths?
    private var currentOutputDirectory: URL?
    private var currentExecutionMode: ExecutionMode = .ytDlp
    private var ffmpegRecordingProgressState = FFmpegRecordingProgressState()

    private let workerQueue = DispatchQueue(label: "youtube.downloader.worker", qos: .userInitiated)
    private let parsingQueue = DispatchQueue(label: "youtube.downloader.parsing", qos: .userInitiated)
    private let analysisFlushInterval: TimeInterval = 0.10
    private let statusFlushInterval: TimeInterval = 0.12

    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()

    func startDownload(
        url: String,
        outputDir: URL,
        toolPaths: ToolPaths,
        options: DownloadOptions = .default
    ) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            failureCategory = .invalidURL
            userMessage = "URL을 입력해 주세요."
            return
        }

        guard !isDownloading else { return }

        resetForNewDownload(outputDir: outputDir, toolPaths: toolPaths)
        if options.forceDirectStreamCapture || isLikelyM3U8URL(trimmedURL) {
            transition(to: .preparing, status: "스트리밍 녹화 준비 중")
            startDirectM3U8Recording(
                url: trimmedURL,
                outputDir: outputDir,
                toolPaths: toolPaths,
                options: options
            )
        } else {
            transition(to: .preparing, status: "준비 중")
            startYtDlpDownload(
                url: trimmedURL,
                outputDir: outputDir,
                toolPaths: toolPaths,
                options: options
            )
        }
    }

    private func startYtDlpDownload(
        url: String,
        outputDir: URL,
        toolPaths: ToolPaths,
        options: DownloadOptions
    ) {
        currentExecutionMode = .ytDlp

        let outputTemplate = outputDir.appendingPathComponent(options.filenameTemplate).path
        let arguments = buildArguments(
            url: url,
            outputTemplate: outputTemplate,
            toolPaths: toolPaths,
            options: options
        )

        workerQueue.async {
            self.launchStreamingProcess(
                executableURL: toolPaths.ytDlpPath,
                arguments: arguments,
                outputDir: outputDir
            )
        }
    }

    private func startDirectM3U8Recording(
        url: String,
        outputDir: URL,
        toolPaths: ToolPaths,
        options: DownloadOptions
    ) {
        currentExecutionMode = .directM3U8Recording

        let outputURL = buildDirectM3U8OutputURL(
            url: url,
            outputDir: outputDir,
            preset: options.preset
        )

        outputFilePath = outputURL
        statusText = "실시간 스트림 연결 중"
        progress = 0.02

        let arguments = buildDirectM3U8Arguments(
            url: url,
            outputURL: outputURL,
            options: options
        )

        workerQueue.async {
            self.launchStreamingProcess(
                executableURL: toolPaths.ffmpegPath,
                arguments: arguments,
                outputDir: outputDir
            )
        }
    }

    private func launchStreamingProcess(
        executableURL: URL,
        arguments: [String],
        outputDir: URL
    ) {
        do {
            let running = try ProcessRunner.runStreaming(
                executableURL: executableURL,
                arguments: arguments,
                onStdoutLine: { [weak self] line in
                    self?.handleOutputLine(line, isStderr: false)
                },
                onStderrLine: { [weak self] line in
                    self?.handleOutputLine(line, isStderr: true)
                },
                onExit: { [weak self] status in
                    self?.handleProcessExit(status: status, outputDir: outputDir)
                }
            )

            DispatchQueue.main.async {
                guard self.isDownloading else {
                    running.cancel()
                    return
                }
                self.runningProcess = running
                if self.didCancel {
                    self.runningProcess?.cancel()
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.runningProcess = nil
                self.isDownloading = false
                self.isPaused = false
                self.failureCategory = .execution
                self.transition(to: .failed, status: "실행 실패")
                self.userMessage = "다운로드 프로세스를 시작하지 못했습니다."
                self.appendFailureGuidance(for: .execution)
            }
        }
    }

    func cancel() {
        DispatchQueue.main.async {
            guard self.isDownloading else { return }
            self.didCancel = true
            self.isPaused = false
            self.pendingStatusEvent = nil
            self.statusFlushWorkItem?.cancel()
            self.statusFlushWorkItem = nil
            self.phase = .canceled
            self.statusText = self.currentExecutionMode == .directM3U8Recording ? "녹화 종료 요청 중" : "취소 요청 중"
            if self.currentExecutionMode == .directM3U8Recording {
                self.runningProcess?.cancelGracefully()
            } else {
                self.runningProcess?.cancel()
            }
        }
    }

    func togglePause() {
        DispatchQueue.main.async {
            guard self.isDownloading, !self.didCancel else { return }
            guard let runningProcess = self.runningProcess else { return }

            if self.isPaused {
                if runningProcess.resume() {
                    self.isPaused = false
                    self.phase = self.currentExecutionMode == .directM3U8Recording ? .recording : .downloading
                    self.userMessage = nil
                } else {
                    self.userMessage = "다운로드 재개에 실패했습니다."
                }
            } else {
                if runningProcess.pause() {
                    self.isPaused = true
                    self.phase = .paused
                    self.userMessage = nil
                } else {
                    self.userMessage = "다운로드 일시정지에 실패했습니다."
                }
            }
        }
    }

    private func resetForNewDownload(outputDir: URL, toolPaths: ToolPaths) {
        didCancel = false
        hasTemporaryArtifacts = false
        aggregatedFailureSignals = DownloadFailureSignals()
        currentRunStartedAt = Date()
        didReuseExistingDownload = false
        currentExecutionMode = .ytDlp
        ffmpegRecordingProgressState.reset()

        parsingQueue.sync {
            pendingAnalyses.removeAll(keepingCapacity: true)
            analysisFlushWorkItem?.cancel()
            analysisFlushWorkItem = nil
        }

        pendingStatusEvent = nil
        statusFlushWorkItem?.cancel()
        statusFlushWorkItem = nil

        progress = 0
        phase = .preparing
        statusText = "준비 중"
        isDownloading = true
        isPaused = false
        outputFilePath = nil
        failureCategory = nil
        userMessage = nil
        lastTemporaryOutputPath = nil

        currentToolPaths = toolPaths
        currentOutputDirectory = outputDir
    }

    private func buildArguments(
        url: String,
        outputTemplate: String,
        toolPaths: ToolPaths,
        options: DownloadOptions
    ) -> [String] {
        var arguments: [String] = []
        let isM3U8 = isLikelyM3U8URL(url)

        if isM3U8 {
            // Direct HLS(.m3u8) URLs are handled more reliably through ffmpeg downloader.
            arguments += ["--downloader", "ffmpeg"]
            arguments += ["--hls-use-mpegts"]

            if options.hlsAutoReconnectEnabled {
                let timeoutSeconds = min(max(options.hlsReconnectFailTimeoutSeconds, 15), 1800)
                let timeoutMicroseconds = timeoutSeconds * 1_000_000
                let ffmpegReconnectArgs = "-reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_delay_max 5 -rw_timeout \(timeoutMicroseconds)"
                arguments += ["--downloader-args", "ffmpeg_i:\(ffmpegReconnectArgs)"]
            }

            switch options.preset {
            case .audioOnlyM4A:
                arguments += ["-x", "--audio-format", "m4a"]
            case .macCompatibleMP4, .bestQualityMP4:
                arguments += ["--remux-video", "mp4"]
                arguments += ["--postprocessor-args", "Merger:-movflags +faststart"]
            }
        } else {
            switch options.preset {
            case .macCompatibleMP4:
                arguments += ["-f", "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"]
                arguments += ["--merge-output-format", "mp4"]
                arguments += ["--postprocessor-args", "Merger:-movflags +faststart"]
            case .bestQualityMP4:
                arguments += ["-f", "bv*+ba/b"]
                arguments += ["--merge-output-format", "mp4"]
                arguments += ["--postprocessor-args", "Merger:-movflags +faststart"]
            case .audioOnlyM4A:
                arguments += ["-f", "ba[ext=m4a]/ba"]
                arguments += ["-x", "--audio-format", "m4a"]
            }
        }

        arguments += [
            "--retries", "10",
            "--fragment-retries", "20",
            "--extractor-retries", "3",
            "--file-access-retries", "3",
            "--retry-sleep", "2",
            "--abort-on-unavailable-fragments",
            "--concurrent-fragments", "1"
        ]

        switch options.conflictPolicy {
        case .autoRename:
            break
        case .overwrite:
            arguments += ["--force-overwrites"]
        case .skipExisting:
            arguments += ["--no-overwrites"]
        }

        arguments += [
            "--print", "before_dl:\(DownloadLineHeuristics.plannedPathPrintPrefix)%(filepath)s",
            "--print", "after_move:\(DownloadLineHeuristics.finalPathPrintPrefix)%(filepath)s",
            "--no-quiet",
            "--newline",
            "--ffmpeg-location", toolPaths.ffmpegPath.path,
            "-o", outputTemplate,
            url
        ]

        return arguments
    }

    private func buildDirectM3U8Arguments(
        url: String,
        outputURL: URL,
        options: DownloadOptions
    ) -> [String] {
        var arguments: [String] = [
            "-y",
            "-hide_banner",
            "-nostats",
            "-loglevel", "warning",
            "-progress", "pipe:2"
        ]

        arguments += directStreamInputArguments(for: url)

        if options.hlsAutoReconnectEnabled {
            let timeoutSeconds = min(max(options.hlsReconnectFailTimeoutSeconds, 15), 1800)
            let timeoutMicroseconds = timeoutSeconds * 1_000_000
            arguments += [
                "-reconnect", "1",
                "-reconnect_streamed", "1",
                "-reconnect_at_eof", "1",
                "-reconnect_delay_max", "5",
                "-rw_timeout", "\(timeoutMicroseconds)"
            ]
        }

        arguments += ["-i", url]

        switch options.preset {
        case .macCompatibleMP4:
            arguments += [
                "-map", "0:v:0?",
                "-map", "0:a:0?",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "20",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart"
            ]
        case .bestQualityMP4:
            arguments += [
                "-map", "0:v:0?",
                "-map", "0:a:0?",
                "-c", "copy",
                "-movflags", "+faststart"
            ]
        case .audioOnlyM4A:
            arguments += [
                "-map", "0:a:0?",
                "-vn",
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart"
            ]
        }

        arguments.append(outputURL.path)
        return arguments
    }

    private func directStreamInputArguments(for url: String) -> [String] {
        let requestOptions = directStreamRequestOptions(for: url)
        var arguments: [String] = []

        if let userAgent = requestOptions.userAgent {
            arguments += ["-user_agent", userAgent]
        }

        if !requestOptions.headers.isEmpty {
            arguments += ["-headers", formatFFmpegHeaders(requestOptions.headers)]
        }

        return arguments
    }

    private func directStreamRequestOptions(for url: String) -> (userAgent: String?, headers: [String: String]) {
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
        var headers: [String: String] = [:]

        if let origin = inferredAllowedOrigin(from: url) {
            headers["Origin"] = origin
            headers["Referer"] = origin.hasSuffix("/") ? origin : "\(origin)/"
        }

        return (userAgent: userAgent, headers: headers)
    }

    private func formatFFmpegHeaders(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
            .appending("\r\n")
    }

    private func inferredAllowedOrigin(from url: String) -> String? {
        guard let components = URLComponents(string: url) else {
            return nil
        }

        if let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
           let origin = extractAllowedOrigin(fromJWT: token) {
            return origin
        }

        return nil
    }

    private func extractAllowedOrigin(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = Data(base64URLEncoded: String(segments[1])),
              let jsonObject = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let rawOrigins = jsonObject["aws:access-control-allow-origin"] as? String
        else {
            return nil
        }

        let origins = rawOrigins
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("https://") && !$0.contains("*") }

        if let preferredKickOrigin = origins.first(where: { $0.contains("kick.com") }) {
            return preferredKickOrigin
        }

        return origins.first
    }

    private func buildDirectM3U8OutputURL(
        url: String,
        outputDir: URL,
        preset: DownloadPreset
    ) -> URL {
        let host = URLComponents(string: url)?.host?
            .replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-")) ?? "stream"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let baseName = "live-\(host.isEmpty ? "stream" : host)-\(formatter.string(from: Date()))-\(suffix)"
        let fileExtension = preset == .audioOnlyM4A ? "m4a" : "mp4"

        return outputDir
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)
    }

    private func isLikelyM3U8URL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        if lowered.contains(".m3u8") {
            return true
        }

        guard let components = URLComponents(string: url) else {
            return false
        }

        if components.path.lowercased().contains(".m3u8") {
            return true
        }

        guard let items = components.queryItems else {
            return false
        }

        for item in items {
            let name = item.name.lowercased()
            let value = (item.value ?? "").lowercased()
            if name.contains("m3u8") || value.contains(".m3u8") || value == "m3u8" {
                return true
            }
        }

        return false
    }

    private func handleOutputLine(_ line: String, isStderr: Bool) {
        guard !line.isEmpty else { return }
        parsingQueue.async { [weak self] in
            guard let self else { return }
            let analysis = self.analyzeLine(line, isStderr: isStderr)
            self.enqueueLineAnalysis(analysis)
        }
    }

    private func handleProcessExit(status: Int32, outputDir: URL) {
        let pendingAnalyses = parsingQueue.sync { drainPendingAnalysesOnParsingQueue() }

        DispatchQueue.main.async {
            self.applyLineAnalyses(pendingAnalyses)
            self.flushPendingStatusEventNow()

            self.runningProcess?.cleanup()
            self.runningProcess = nil
            self.isDownloading = false
            self.isPaused = false

            if self.didCancel {
                if self.currentExecutionMode == .directM3U8Recording {
                    self.transition(to: .verifying, status: "녹화 마무리 중")
                    let workingDirectory = self.currentOutputDirectory ?? outputDir
                    self.workerQueue.async {
                        let resolution = self.finalizeSuccessfulDownload(in: workingDirectory)
                        DispatchQueue.main.async {
                            self.applyStoppedRecordingResolution(resolution)
                        }
                    }
                    return
                }
                self.transition(to: .canceled, status: "취소됨")
                return
            }

            if status == 0 {
                self.transition(to: .verifying, status: "완료 검증 중")
                let workingDirectory = self.currentOutputDirectory ?? outputDir
                self.workerQueue.async {
                    let resolution = self.finalizeSuccessfulDownload(in: workingDirectory)
                    DispatchQueue.main.async {
                        self.applySuccessfulDownloadResolution(resolution)
                    }
                }
                return
            }

            let workingDirectory = self.currentOutputDirectory ?? outputDir
            self.workerQueue.async {
                let hasTemporaryArtifacts = !self.scanTemporaryArtifacts(in: workingDirectory).isEmpty
                let category = self.classifyFailureCategory(exitCode: status)
                DispatchQueue.main.async {
                    self.hasTemporaryArtifacts = hasTemporaryArtifacts
                    self.failureCategory = category
                    self.transition(to: .failed, status: "실패 (코드: \(status))")
                    self.userMessage = self.failureUserMessage(for: category)
                    self.appendFailureGuidance(for: category)
                }
            }
        }
    }

    private func enqueueLineAnalysis(_ analysis: LineAnalysis) {
        pendingAnalyses.append(analysis)

        guard analysisFlushWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.drainPendingAnalysesOnParsingQueue()
            guard !batch.isEmpty else { return }
            DispatchQueue.main.async {
                self.applyLineAnalyses(batch)
            }
        }

        analysisFlushWorkItem = workItem
        parsingQueue.asyncAfter(deadline: .now() + analysisFlushInterval, execute: workItem)
    }

    private func drainPendingAnalysesOnParsingQueue() -> [LineAnalysis] {
        analysisFlushWorkItem?.cancel()
        analysisFlushWorkItem = nil

        guard !pendingAnalyses.isEmpty else { return [] }
        let batch = pendingAnalyses
        pendingAnalyses.removeAll(keepingCapacity: true)
        return batch
    }

    private func applyLineAnalyses(_ analyses: [LineAnalysis]) {
        for analysis in analyses {
            applyLineAnalysis(analysis)
        }
    }

    private func applyLineAnalysis(_ analysis: LineAnalysis) {
        aggregatedFailureSignals.merge(analysis.failureSignals)
        didReuseExistingDownload = didReuseExistingDownload || analysis.reusedExistingDownload

        if let outputFilePath = analysis.outputFilePath {
            if isTemporaryPath(outputFilePath) {
                lastTemporaryOutputPath = outputFilePath
            } else {
                self.outputFilePath = outputFilePath
            }
        }

        if isDownloading, let statusEvent = analysis.statusEvent {
            enqueueStatusEvent(statusEvent)
        }

        if isDownloading, let errorMessage = analysis.errorMessage {
            userMessage = errorMessage
        }
    }

    private func enqueueStatusEvent(_ event: StatusEvent) {
        pendingStatusEvent = event
        guard statusFlushWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingStatusEventNow()
        }
        statusFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + statusFlushInterval, execute: workItem)
    }

    private func flushPendingStatusEventNow() {
        statusFlushWorkItem?.cancel()
        statusFlushWorkItem = nil

        guard let event = pendingStatusEvent else { return }
        pendingStatusEvent = nil

        phase = event.phase
        if let progressValue = event.progress {
            progress = min(max(progressValue, 0), 1)
        }
        statusText = event.text
    }

    private func analyzeLine(_ line: String, isStderr: Bool) -> LineAnalysis {
        let failureSignals = DownloadLineHeuristics.classifyFailureSignals(line: line, isStderr: isStderr)
        let detectedOutputFilePath = DownloadLineHeuristics.parseOutputPath(line: line)
            .map(resolveDetectedOutputURL(from:))

        let statusEvent: StatusEvent?
        if currentExecutionMode == .directM3U8Recording {
            statusEvent = parseFFmpegRecordingStatusEvent(from: line) ?? parseStatusEvent(from: line)
        } else {
            statusEvent = parseStatusEvent(from: line)
        }

        var errorMessage: String?
        if line.localizedCaseInsensitiveContains("ERROR:") {
            let simplified = line.replacingOccurrences(of: "ERROR:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = simplified.isEmpty ? "다운로드 중 오류가 발생했습니다." : simplified
        } else if currentExecutionMode == .directM3U8Recording &&
                    (line.localizedCaseInsensitiveContains("error") ||
                     line.localizedCaseInsensitiveContains("failed")) {
            errorMessage = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return LineAnalysis(
            outputFilePath: detectedOutputFilePath,
            statusEvent: statusEvent,
            errorMessage: errorMessage,
            failureSignals: failureSignals,
            reusedExistingDownload: line.localizedCaseInsensitiveContains("has already been downloaded")
        )
    }

    private func resolveDetectedOutputURL(from rawPath: String) -> URL {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPath.hasPrefix("/") {
            return URL(fileURLWithPath: trimmedPath).standardizedFileURL
        }

        if let currentOutputDirectory {
            return currentOutputDirectory
                .appendingPathComponent(trimmedPath)
                .standardizedFileURL
        }

        return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }

    private func parseStatusEvent(from line: String) -> StatusEvent? {
        if let progress = DownloadLineHeuristics.parseProgress(line: line) {
            var parts: [String] = [String(format: "%.1f%%", progress.percent)]
            if let sizeText = progress.sizeText, !sizeText.isEmpty { parts.append(sizeText) }
            if let speedText = progress.speedText, !speedText.isEmpty { parts.append(speedText) }
            if let etaText = progress.etaText, !etaText.isEmpty { parts.append("ETA \(etaText)") }
            parts.append(DownloadPhase.downloading.displayName)
            return StatusEvent(
                phase: .downloading,
                progress: progress.percent / 100.0,
                text: parts.joined(separator: " | ")
            )
        }

        if line.contains("[Merger]") {
            return StatusEvent(phase: .merging, progress: nil, text: "병합 중")
        }
        if line.contains("[ExtractAudio]") || line.contains("[PostProcess]") {
            return StatusEvent(phase: .postProcessing, progress: nil, text: "후처리 중")
        }
        if line.contains("Destination:") {
            return StatusEvent(phase: .preparing, progress: nil, text: "파일 준비 중")
        }

        return nil
    }

    private func parseFFmpegRecordingStatusEvent(from line: String) -> StatusEvent? {
        if line.hasPrefix("out_time=") {
            let raw = String(line.dropFirst("out_time=".count))
            ffmpegRecordingProgressState.outTimeText = formattedRecordingTime(raw)
            return nil
        }

        if line.hasPrefix("total_size=") {
            let raw = String(line.dropFirst("total_size=".count))
            ffmpegRecordingProgressState.totalSizeBytes = Int64(raw)
            return nil
        }

        if line.hasPrefix("bitrate=") {
            let raw = String(line.dropFirst("bitrate=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            ffmpegRecordingProgressState.bitrateText = raw == "N/A" ? nil : raw
            return nil
        }

        if line.hasPrefix("speed=") {
            let raw = String(line.dropFirst("speed=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            ffmpegRecordingProgressState.speedText = raw == "N/A" ? nil : raw
            return nil
        }

        if line == "progress=continue" {
            var parts = ["실시간 녹화 중"]
            if let outTimeText = ffmpegRecordingProgressState.outTimeText, !outTimeText.isEmpty {
                parts.append(outTimeText)
            }
            if let totalSizeBytes = ffmpegRecordingProgressState.totalSizeBytes, totalSizeBytes > 0 {
                parts.append(byteCountFormatter.string(fromByteCount: totalSizeBytes))
            }
            if let speedText = ffmpegRecordingProgressState.speedText, !speedText.isEmpty {
                parts.append(speedText)
            }
            return StatusEvent(
                phase: .recording,
                progress: nil,
                text: parts.joined(separator: " | ")
            )
        }

        if line == "progress=end" {
            return StatusEvent(
                phase: .verifying,
                progress: nil,
                text: "녹화 마무리 중"
            )
        }

        return nil
    }

    private func formattedRecordingTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "00:00:00" }

        let components = trimmed.split(separator: ".", maxSplits: 1).map(String.init)
        return components.first ?? trimmed
    }

    private func classifyFailureCategory(exitCode: Int32) -> DownloadFailureCategory {
        if aggregatedFailureSignals.sawDiskFullIssue {
            return .diskFull
        }
        if aggregatedFailureSignals.sawPermissionIssue {
            return .permission
        }
        if aggregatedFailureSignals.sawAuthOrGeoRestriction {
            return .authOrGeo
        }
        if aggregatedFailureSignals.sawFfmpegIssue {
            return .ffmpeg
        }
        if aggregatedFailureSignals.sawNetworkIssue {
            return .network
        }
        if aggregatedFailureSignals.sawYtDlpOutdatedLikely || aggregatedFailureSignals.sawStderrFailureKeyword {
            return .ytdlpOutdatedLikely
        }
        if exitCode != 0 {
            return .unknown
        }
        return .unknown
    }

    private func failureUserMessage(for category: DownloadFailureCategory) -> String {
        if currentExecutionMode == .directM3U8Recording {
            switch category {
            case .toolMissing:
                return "ffmpeg를 찾지 못했습니다. 설정에서 설치 여부를 확인해 주세요."
            case .invalidURL:
                return "유효한 스트리밍 URL을 입력해 주세요."
            case .network:
                return "실시간 스트리밍 녹화가 네트워크 문제로 중단되었습니다. 재접속 설정을 확인해 주세요."
            case .permission:
                return "저장 폴더 권한 문제로 녹화에 실패했습니다. 다른 폴더를 선택해 보세요."
            case .diskFull:
                return "디스크 공간이 부족해 녹화에 실패했습니다. 여유 공간을 확보해 주세요."
            case .authOrGeo:
                return "실시간 스트림 접근이 거부되었습니다. 만료된 주소이거나 필요한 헤더가 부족할 수 있습니다."
            case .ytdlpOutdatedLikely:
                return "실시간 스트리밍 녹화에 실패했습니다. 스트림 주소와 ffmpeg 상태를 확인해 주세요."
            case .ffmpeg:
                return "실시간 스트리밍 녹화에 실패했습니다. ffmpeg를 확인해 주세요."
            case .incompleteFile:
                return "실시간 녹화 파일이 불완전하게 끝났습니다. ffmpeg 상태를 확인해 주세요."
            case .execution:
                return "녹화 프로세스를 실행하지 못했습니다."
            case .unknown:
                return "실시간 스트리밍 녹화에 실패했습니다. 스트림 주소와 ffmpeg 상태를 확인해 주세요."
            }
        }

        switch category {
        case .toolMissing:
            return "yt-dlp 또는 ffmpeg를 찾지 못했습니다. 설정에서 설치 여부를 확인해 주세요."
        case .invalidURL:
            return "유효한 URL을 입력해 주세요."
        case .network:
            return "네트워크 오류로 다운로드에 실패했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요."
        case .permission:
            return "저장 폴더 권한 문제로 다운로드에 실패했습니다. 다른 폴더를 선택해 보세요."
        case .diskFull:
            return "디스크 공간이 부족해 다운로드에 실패했습니다. 여유 공간을 확보해 주세요."
        case .authOrGeo:
            return "연령/지역/로그인 제한으로 다운로드에 실패했을 수 있습니다. 먼저 yt-dlp 업데이트를 시도해 보세요."
        case .ytdlpOutdatedLikely:
            return "다운로드에 실패했습니다. 먼저 yt-dlp를 업데이트해 보세요."
        case .ffmpeg:
            return "병합/후처리 단계에서 실패했습니다. 먼저 yt-dlp와 ffmpeg를 업데이트해 보세요."
        case .incompleteFile:
            return "다운로드가 불완전하게 끝났습니다. 먼저 yt-dlp를 업데이트해 보세요."
        case .execution:
            return "다운로드 프로세스를 실행하지 못했습니다."
        case .unknown:
            return "다운로드에 실패했습니다. 먼저 yt-dlp를 업데이트해 보세요."
        }
    }

    private func shouldRecommendYtDlpUpdate(for category: DownloadFailureCategory) -> Bool {
        if currentExecutionMode == .directM3U8Recording {
            return false
        }

        switch category {
        case .invalidURL, .permission, .diskFull:
            return false
        default:
            return true
        }
    }

    private func appendFailureGuidance(for category: DownloadFailureCategory) {
        var steps: [String] = []

        if shouldRecommendYtDlpUpdate(for: category) {
            steps.append("yt-dlp 업데이트: brew upgrade yt-dlp")
        }

        switch category {
        case .ffmpeg:
            steps.append("ffmpeg 업데이트: brew upgrade ffmpeg")
        case .authOrGeo:
            if currentExecutionMode == .directM3U8Recording {
                steps.append("스트림 주소를 새로 받아 다시 시도")
                steps.append("웹 플레이어에서 열리는 최신 주소인지 확인")
            } else {
                steps.append("연령/지역 제한 영상은 로그인/쿠키가 필요할 수 있습니다. (MVP 미지원)")
            }
        case .permission:
            steps.append("다른 저장 폴더를 선택해 다시 시도")
        case .diskFull:
            steps.append("디스크 여유 공간 확보 후 다시 시도")
        case .network:
            steps.append("네트워크 상태 확인 후 다시 시도")
        default:
            break
        }

        if currentExecutionMode == .directM3U8Recording,
           category == .network {
            steps.insert("스트리밍 재접속 설정 확인 후 다시 시도", at: 0)
        }

        if hasTemporaryArtifacts {
            steps.append("실패 후 남은 임시 .part 파일 정리")
        }

        let compactSteps = Array(steps.prefix(2))
        guard !compactSteps.isEmpty else { return }

        let guidance = compactSteps.joined(separator: "\n")
        if let userMessage, !userMessage.isEmpty {
            self.userMessage = "\(userMessage)\n\(guidance)"
        } else {
            self.userMessage = guidance
        }
    }

    private func transition(to newPhase: DownloadPhase, status: String? = nil) {
        phase = newPhase
        switch newPhase {
        case .idle:
            isDownloading = false
            isPaused = false
        case .paused:
            isDownloading = true
            isPaused = true
        case .completed, .failed, .canceled:
            isDownloading = false
            isPaused = false
        default:
            isDownloading = true
            isPaused = false
        }
        if let status {
            statusText = status
        }
    }

    private func isTemporaryPath(_ url: URL) -> Bool {
        DownloadLineHeuristics.isTemporaryFilename(url.lastPathComponent)
    }

    private func resolveCompletedOutputPath() -> URL? {
        if let outputFilePath,
           !isTemporaryPath(outputFilePath),
           isEligibleCompletedFile(outputFilePath) {
            return outputFilePath.standardizedFileURL
        }

        if let temporary = lastTemporaryOutputPath {
            if let candidate = completedCandidate(fromTemporaryPath: temporary),
               isEligibleCompletedFile(candidate) {
                return candidate.standardizedFileURL
            }
        }

        if let plannedOutput = outputFilePath,
           !isTemporaryPath(plannedOutput),
           isEligibleCompletedFile(plannedOutput) {
            return plannedOutput.standardizedFileURL
        }

        if let outputFilePath,
           let currentOutputDirectory {
            let outputName = outputFilePath.lastPathComponent
            if !outputName.isEmpty {
                let candidate = currentOutputDirectory
                    .appendingPathComponent(outputName)
                    .standardizedFileURL
                if !isTemporaryPath(candidate),
                   isEligibleCompletedFile(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private func isEligibleCompletedFile(_ fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        guard !didReuseExistingDownload else {
            return true
        }

        guard let currentRunStartedAt else {
            return true
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys) else {
            return false
        }

        let referenceDate = currentRunStartedAt.addingTimeInterval(-5)
        if let modificationDate = values.contentModificationDate, modificationDate >= referenceDate {
            return true
        }
        if let creationDate = values.creationDate, creationDate >= referenceDate {
            return true
        }

        return false
    }

    private func sawIncompleteTemporaryArtifactsWithoutFinalOutput(
        resolvedOutput: URL?,
        temporaryArtifacts: [URL]
    ) -> Bool {
        let hasFinalNonTemporaryFile = {
            guard let resolvedOutput else { return false }
            return !isTemporaryPath(resolvedOutput) && FileManager.default.fileExists(atPath: resolvedOutput.path)
        }()

        guard !hasFinalNonTemporaryFile else { return false }
        if let tempPath = lastTemporaryOutputPath ?? outputFilePath,
           isTemporaryPath(tempPath) {
            return true
        }

        return !temporaryArtifacts.isEmpty
    }

    private func completedCandidate(fromTemporaryPath temporaryURL: URL) -> URL? {
        guard let candidateName = DownloadLineHeuristics.completedCandidateFilename(fromTemporaryFilename: temporaryURL.lastPathComponent) else {
            return nil
        }
        return temporaryURL.deletingLastPathComponent().appendingPathComponent(candidateName)
    }

    private func scanTemporaryArtifacts(in directory: URL?) -> [URL] {
        guard let directory else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return items
            .filter { DownloadLineHeuristics.isTemporaryFilename($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lDate > rDate
            }
    }

    private func validateCompletedFile(at fileURL: URL) -> DownloadValidationSummary {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value

            guard let size, size > 0 else {
                return DownloadValidationSummary(
                    isValid: false,
                    fileSizeBytes: size,
                    durationSeconds: nil,
                    message: "파일 검증 실패: 파일 크기가 0B 입니다."
                )
            }

            if let ffprobeURL = currentToolPaths?.ffprobePath,
               let ffprobe = validateWithFfprobe(fileURL: fileURL, ffprobeURL: ffprobeURL) {
                if ffprobe.isValid {
                    let sizeText = byteCountFormatter.string(fromByteCount: ffprobe.fileSizeBytes ?? size)
                    let durationText = ffprobe.durationSeconds.map { String(format: "%.1fs", $0) } ?? "-"
                    return DownloadValidationSummary(
                        isValid: true,
                        fileSizeBytes: ffprobe.fileSizeBytes ?? size,
                        durationSeconds: ffprobe.durationSeconds,
                        message: "검증 완료 | \(sizeText) | 재생 길이 \(durationText)"
                    )
                }

                return DownloadValidationSummary(
                    isValid: false,
                    fileSizeBytes: size,
                    durationSeconds: nil,
                    message: "파일 검증 실패: ffprobe가 파일 메타데이터를 읽지 못했습니다."
                )
            }

            return DownloadValidationSummary(
                isValid: true,
                fileSizeBytes: size,
                durationSeconds: nil,
                message: "검증 완료 | \(byteCountFormatter.string(fromByteCount: size))"
            )
        } catch {
            return DownloadValidationSummary(
                isValid: false,
                fileSizeBytes: nil,
                durationSeconds: nil,
                message: "파일 검증 실패: 파일 정보를 읽을 수 없습니다."
            )
        }
    }

    private func validateWithFfprobe(fileURL: URL, ffprobeURL: URL) -> (isValid: Bool, fileSizeBytes: Int64?, durationSeconds: Double?)? {
        guard let result = ProcessRunner.runAndCapture(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration,size",
                "-of", "default=noprint_wrappers=1:nokey=0",
                fileURL.path
            ]
        ) else {
            return nil
        }

        guard result.terminationStatus == 0 else {
            return (false, nil, nil)
        }

        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        var durationSeconds: Double?
        var sizeBytes: Int64?
        for line in lines {
            if line.hasPrefix("duration=") {
                durationSeconds = Double(String(line.dropFirst("duration=".count)))
            } else if line.hasPrefix("size=") {
                sizeBytes = Int64(String(line.dropFirst("size=".count)))
            }
        }

        let isValid = (sizeBytes ?? 0) > 0
        return (isValid, sizeBytes, durationSeconds)
    }

    private func finalizeSuccessfulDownload(in outputDir: URL) -> SuccessfulDownloadResolution {
        let temporaryArtifacts = scanTemporaryArtifacts(in: outputDir)
        let resolvedOutput = resolveCompletedOutputPath()

        if sawIncompleteTemporaryArtifactsWithoutFinalOutput(
            resolvedOutput: resolvedOutput,
            temporaryArtifacts: temporaryArtifacts
        ) {
            return SuccessfulDownloadResolution(
                hasTemporaryArtifacts: !temporaryArtifacts.isEmpty,
                resolvedOutput: nil,
                validation: nil
            )
        }

        guard let resolvedOutput else {
            return SuccessfulDownloadResolution(
                hasTemporaryArtifacts: !temporaryArtifacts.isEmpty,
                resolvedOutput: nil,
                validation: nil
            )
        }

        return SuccessfulDownloadResolution(
            hasTemporaryArtifacts: !temporaryArtifacts.isEmpty,
            resolvedOutput: resolvedOutput,
            validation: validateCompletedFile(at: resolvedOutput)
        )
    }

    private func applySuccessfulDownloadResolution(_ resolution: SuccessfulDownloadResolution) {
        hasTemporaryArtifacts = resolution.hasTemporaryArtifacts

        guard let resolvedOutput = resolution.resolvedOutput else {
            failureCategory = .incompleteFile
            transition(to: .failed, status: "실패 (완료 파일 확인)")
            userMessage = "완료된 파일을 확인하지 못했습니다. 먼저 yt-dlp를 업데이트해 보세요."
            appendFailureGuidance(for: .incompleteFile)
            return
        }

        outputFilePath = resolvedOutput

        if let validation = resolution.validation,
           !validation.isValid {
            failureCategory = .incompleteFile
            transition(to: .failed, status: "실패 (완료 검증)")
            userMessage = "파일 검증에 실패했습니다. 먼저 yt-dlp를 업데이트해 보세요."
            appendFailureGuidance(for: .incompleteFile)
            return
        }

        progress = 1
        failureCategory = nil
        userMessage = "저장됨: \(resolvedOutput.path)"
        transition(
            to: .completed,
            status: currentExecutionMode == .directM3U8Recording ? "녹화 완료" : "100% | 완료"
        )
    }

    private func applyStoppedRecordingResolution(_ resolution: SuccessfulDownloadResolution) {
        hasTemporaryArtifacts = resolution.hasTemporaryArtifacts

        guard let resolvedOutput = resolution.resolvedOutput else {
            transition(to: .canceled, status: "취소됨")
            return
        }

        outputFilePath = resolvedOutput

        if let validation = resolution.validation,
           !validation.isValid {
            failureCategory = .incompleteFile
            transition(to: .failed, status: "실패 (녹화 검증)")
            userMessage = "녹화된 파일 검증에 실패했습니다. ffmpeg 상태를 확인해 주세요."
            appendFailureGuidance(for: .incompleteFile)
            return
        }

        progress = 1
        failureCategory = nil
        userMessage = "저장됨: \(resolvedOutput.path)"
        transition(to: .completed, status: "녹화 완료")
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        self.init(base64Encoded: normalized)
    }
}
