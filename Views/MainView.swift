import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class DownloadTaskItem: Identifiable {
    let id = UUID()
    let url: String
    let manager: DownloadManager

    init(url: String, manager: DownloadManager = DownloadManager()) {
        self.url = url
        self.manager = manager
    }
}

private struct ParsedURLSummary {
    let deduplicatedValidURLs: [String]
    let invalidCount: Int
    let duplicateCount: Int
}

private struct DownloadLaunchPlan {
    let url: String
    let options: DownloadOptions
}

private struct DownloadPlanBuildResult {
    let plans: [DownloadLaunchPlan]
    let skippedCount: Int
}

private struct YtDlpVideoIdentity {
    let title: String
    let videoID: String
}

private enum MainContentTab: String, CaseIterable, Identifiable {
    case download = "다운로드"
    case merge = "영상 붙이기"
    case convert = "변환"
    case subtitleVideo = "자막 영상"

    var id: String { rawValue }
}

private enum ConversionOutputFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov
    case mkv
    case webm
    case mp3
    case m4a
    case aac
    case wav
    case flac
    case opus

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .aac: return "AAC"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        }
    }

    var isVideo: Bool {
        Self.videoFormats.contains(self)
    }

    static let videoFormats: [ConversionOutputFormat] = [.mp4, .mov, .mkv, .webm]
    static let audioFormats: [ConversionOutputFormat] = [.mp3, .m4a, .aac, .wav, .flac, .opus]
}

private enum ConversionMediaKind {
    case audio
    case video
}

private final class FileConversionManager: ObservableObject {
    private struct StepResult {
        let terminationStatus: Int32
        let message: String?
        let wasCancelled: Bool
    }

    private struct SourceBitrateSummary {
        let videoBitrate: Int?
        let audioBitrate: Int?
    }

    @Published private(set) var inputFileURL: URL?
    @Published private(set) var isConverting: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String = "변환할 음성 또는 영상 파일을 선택하세요."
    @Published private(set) var outputFileURL: URL?
    @Published var userMessage: String?

    private let workerQueue = DispatchQueue(label: "file.conversion.worker", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "file.conversion.state")
    private var runningProcess: RunningProcess?
    private var didCancel = false

    var canStart: Bool {
        inputFileURL != nil && !isConverting
    }

    func setInputFile(_ url: URL) {
        guard !isConverting else { return }
        inputFileURL = url.standardizedFileURL
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func clearInputFile() {
        guard !isConverting else { return }
        inputFileURL = nil
        progress = 0
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func startConversion(
        outputDirectory: URL,
        ffmpegURL: URL,
        ffprobeURL: URL?,
        outputBaseName: String?,
        outputFormat: ConversionOutputFormat
    ) {
        guard let inputFileURL else {
            userMessage = "변환할 음성 또는 영상 파일을 선택해 주세요."
            return
        }

        let outputURL = uniqueOutputURL(
            in: outputDirectory,
            requestedBaseName: outputBaseName,
            outputFormat: outputFormat,
            inputFile: inputFileURL
        )

        isConverting = true
        progress = 0.01
        outputFileURL = nil
        userMessage = nil
        statusText = "변환 준비 중"

        stateQueue.sync {
            didCancel = false
            runningProcess = nil
        }

        workerQueue.async {
            let durationSeconds = self.readMediaDuration(for: inputFileURL, ffprobeURL: ffprobeURL)
            let sourceBitrates = self.readSourceBitrates(
                for: inputFileURL,
                ffprobeURL: ffprobeURL,
                ffmpegURL: ffmpegURL
            )
            let result = self.runConversionStep(
                executableURL: ffmpegURL,
                arguments: self.conversionArguments(
                    inputURL: inputFileURL,
                    outputURL: outputURL,
                    outputFormat: outputFormat,
                    sourceBitrates: sourceBitrates
                ),
                expectedDuration: durationSeconds,
                outputFormat: outputFormat
            )

            if result.wasCancelled {
                self.finishCanceled(outputURL: outputURL)
                return
            }

            guard result.terminationStatus == 0,
                  self.outputFileExistsAndIsNotEmpty(outputURL) else {
                self.finishFailure(
                    message: result.message ?? "파일 변환에 실패했습니다.",
                    outputURL: outputURL
                )
                return
            }

            self.finishSuccess(outputURL: outputURL)
        }
    }

    func cancel() {
        stateQueue.sync {
            didCancel = true
            runningProcess?.cancel()
        }

        DispatchQueue.main.async {
            self.statusText = "변환 중지 요청 중"
        }
    }

    private var isCancelled: Bool {
        stateQueue.sync { didCancel }
    }

    private func refreshStatus() {
        statusText = inputFileURL == nil
            ? "변환할 음성 또는 영상 파일을 선택하세요."
            : "변환 준비 완료"
    }

    private func conversionArguments(
        inputURL: URL,
        outputURL: URL,
        outputFormat: ConversionOutputFormat,
        sourceBitrates: SourceBitrateSummary
    ) -> [String] {
        var arguments = [
            "-y",
            "-hide_banner",
            "-nostats",
            "-loglevel", "warning",
            "-progress", "pipe:2",
            "-i", inputURL.path
        ]

        if outputFormat.isVideo {
            arguments += [
                "-map", "0:v:0",
                "-map", "0:a:0?"
            ]
            arguments += videoEncodingArguments(
                for: outputFormat,
                sourceBitrate: sourceBitrates.videoBitrate
            )
            arguments += audioEncodingArguments(
                for: outputFormat,
                sourceBitrate: sourceBitrates.audioBitrate
            )
            arguments += containerFlags(for: outputFormat)
        } else {
            arguments += [
                "-vn",
                "-map", "0:a:0"
            ]
            arguments += audioOnlyEncodingArguments(
                for: outputFormat,
                sourceBitrate: sourceBitrates.audioBitrate
            )
        }

        arguments.append(outputURL.path)
        return arguments
    }

    private func videoEncodingArguments(
        for outputFormat: ConversionOutputFormat,
        sourceBitrate: Int?
    ) -> [String] {
        switch outputFormat {
        case .webm:
            var arguments = [
                "-c:v", "libvpx-vp9",
                "-pix_fmt", "yuv420p",
                "-row-mt", "1",
                "-cpu-used", "4"
            ]

            if let sourceBitrate {
                arguments += ["-b:v", "\(sourceBitrate)"]
            } else {
                arguments += ["-b:v", "0", "-crf", "32"]
            }

            return arguments
        default:
            var arguments = [
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-pix_fmt", "yuv420p"
            ]

            if let sourceBitrate {
                arguments += ["-b:v", "\(sourceBitrate)"]
            } else {
                arguments += ["-crf", "20"]
            }

            return arguments
        }
    }

    private func audioEncodingArguments(
        for outputFormat: ConversionOutputFormat,
        sourceBitrate: Int?
    ) -> [String] {
        let bitrate = sourceBitrate.map(String.init)

        switch outputFormat {
        case .webm:
            return [
                "-c:a", "libopus",
                "-b:a", bitrate ?? "160k",
                "-ar", "48000",
                "-ac", "2"
            ]
        default:
            return [
                "-c:a", "aac",
                "-b:a", bitrate ?? "192k",
                "-ar", "48000",
                "-ac", "2"
            ]
        }
    }

    private func audioOnlyEncodingArguments(
        for outputFormat: ConversionOutputFormat,
        sourceBitrate: Int?
    ) -> [String] {
        let bitrate = sourceBitrate.map(String.init)

        switch outputFormat {
        case .mp3:
            return [
                "-c:a", "libmp3lame",
                "-b:a", bitrate ?? "192k",
                "-ar", "48000",
                "-ac", "2"
            ]
        case .m4a, .aac:
            return [
                "-c:a", "aac",
                "-b:a", bitrate ?? "192k",
                "-ar", "48000",
                "-ac", "2"
            ]
        case .wav:
            return [
                "-c:a", "pcm_s16le",
                "-ar", "48000",
                "-ac", "2"
            ]
        case .flac:
            return [
                "-c:a", "flac",
                "-ar", "48000",
                "-ac", "2"
            ]
        case .opus:
            return [
                "-c:a", "libopus",
                "-b:a", bitrate ?? "160k",
                "-ar", "48000",
                "-ac", "2"
            ]
        default:
            return audioEncodingArguments(for: outputFormat, sourceBitrate: sourceBitrate)
        }
    }

    private func containerFlags(for outputFormat: ConversionOutputFormat) -> [String] {
        switch outputFormat {
        case .mp4, .mov:
            return ["-movflags", "+faststart"]
        default:
            return []
        }
    }

    private func readMediaDuration(for fileURL: URL, ffprobeURL: URL?) -> Double? {
        guard let ffprobeURL,
              let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    fileURL.path
                ]
              ),
              result.terminationStatus == 0
        else {
            return nil
        }

        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(raw)
    }

    private func readSourceBitrates(
        for fileURL: URL,
        ffprobeURL: URL?,
        ffmpegURL: URL
    ) -> SourceBitrateSummary {
        let ffprobeSummary = readSourceBitratesFromFFprobe(
            for: fileURL,
            ffprobeURL: ffprobeURL
        )

        if ffprobeSummary.videoBitrate != nil && ffprobeSummary.audioBitrate != nil {
            return ffprobeSummary
        }

        let ffmpegSummary = readSourceBitratesFromFFmpegProbe(
            for: fileURL,
            ffmpegURL: ffmpegURL
        )

        return SourceBitrateSummary(
            videoBitrate: ffprobeSummary.videoBitrate ?? ffmpegSummary.videoBitrate,
            audioBitrate: ffprobeSummary.audioBitrate ?? ffmpegSummary.audioBitrate
        )
    }

    private func readSourceBitratesFromFFprobe(for fileURL: URL, ffprobeURL: URL?) -> SourceBitrateSummary {
        guard let ffprobeURL,
              let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_entries", "stream=codec_type,bit_rate:format=bit_rate,duration,size",
                    "-of", "json",
                    fileURL.path
                ]
              ),
              result.terminationStatus == 0,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return SourceBitrateSummary(videoBitrate: nil, audioBitrate: nil)
        }

        let streams = object["streams"] as? [[String: Any]] ?? []
        let videoStreams = streams.filter { ($0["codec_type"] as? String) == "video" }
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }
        let hasVideo = !videoStreams.isEmpty
        let hasAudio = !audioStreams.isEmpty

        var videoBitrate = videoStreams.compactMap { positiveInt(from: $0["bit_rate"]) }.first
        var audioBitrate = audioStreams.compactMap { positiveInt(from: $0["bit_rate"]) }.first

        let format = object["format"] as? [String: Any]
        let formatBitrate = positiveInt(from: format?["bit_rate"])
        let duration = positiveDouble(from: format?["duration"])
        let size = positiveDouble(from: format?["size"])
        let estimatedTotalBitrate = formatBitrate ?? estimatedBitrate(sizeBytes: size, durationSeconds: duration)

        if audioBitrate == nil, hasAudio, !hasVideo {
            audioBitrate = estimatedTotalBitrate
        }

        if videoBitrate == nil, hasVideo, let estimatedTotalBitrate {
            if let audioBitrate {
                videoBitrate = max(estimatedTotalBitrate - audioBitrate, 1)
            } else {
                videoBitrate = estimatedTotalBitrate
            }
        }

        return SourceBitrateSummary(
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate
        )
    }

    private func readSourceBitratesFromFFmpegProbe(for fileURL: URL, ffmpegURL: URL) -> SourceBitrateSummary {
        guard let result = ProcessRunner.runAndCapture(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-i", fileURL.path
            ]
        ) else {
            return SourceBitrateSummary(videoBitrate: nil, audioBitrate: nil)
        }

        let probeText = result.stdout + "\n" + result.stderr
        var videoBitrate: Int?
        var audioBitrate: Int?
        var totalBitrate: Int?
        var hasVideo = false
        var hasAudio = false

        for rawLine in probeText.split(whereSeparator: \.isNewline).map(String.init) {
            if rawLine.localizedCaseInsensitiveContains("Duration:") {
                totalBitrate = bitrateFromFFmpegInfoLine(rawLine) ?? totalBitrate
            }

            if rawLine.localizedCaseInsensitiveContains("Video:") {
                hasVideo = true
                videoBitrate = bitrateFromFFmpegInfoLine(rawLine) ?? videoBitrate
            }

            if rawLine.localizedCaseInsensitiveContains("Audio:") {
                hasAudio = true
                audioBitrate = bitrateFromFFmpegInfoLine(rawLine) ?? audioBitrate
            }
        }

        if audioBitrate == nil, hasAudio, !hasVideo {
            audioBitrate = totalBitrate
        }

        if videoBitrate == nil, hasVideo, let totalBitrate {
            if let audioBitrate {
                videoBitrate = max(totalBitrate - audioBitrate, 1)
            } else {
                videoBitrate = totalBitrate
            }
        }

        return SourceBitrateSummary(
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate
        )
    }

    private func bitrateFromFFmpegInfoLine(_ line: String) -> Int? {
        let tokens = line
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "=", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        for index in tokens.indices {
            let unit = tokens[index].lowercased()
            let multiplier: Double

            switch unit {
            case "b/s":
                multiplier = 1
            case "kb/s":
                multiplier = 1_000
            case "mb/s":
                multiplier = 1_000_000
            case "gb/s":
                multiplier = 1_000_000_000
            default:
                continue
            }

            guard index > tokens.startIndex,
                  let value = Double(tokens[tokens.index(before: index)])
            else {
                continue
            }

            return max(Int(value * multiplier), 1)
        }

        return nil
    }

    private func positiveInt(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let integerValue = number.intValue
            return integerValue > 0 ? integerValue : nil
        }

        if let string = value as? String,
           let integerValue = Int(string),
           integerValue > 0 {
            return integerValue
        }

        return nil
    }

    private func positiveDouble(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue > 0 ? doubleValue : nil
        }

        if let string = value as? String,
           let doubleValue = Double(string),
           doubleValue > 0 {
            return doubleValue
        }

        return nil
    }

    private func estimatedBitrate(sizeBytes: Double?, durationSeconds: Double?) -> Int? {
        guard let sizeBytes,
              let durationSeconds,
              durationSeconds > 0
        else {
            return nil
        }

        return max(Int((sizeBytes * 8) / durationSeconds), 1)
    }

    private func runConversionStep(
        executableURL: URL,
        arguments: [String],
        expectedDuration: Double?,
        outputFormat: ConversionOutputFormat
    ) -> StepResult {
        let semaphore = DispatchSemaphore(value: 0)
        let lineLock = NSLock()
        var recentLines: [String] = []
        var terminationStatus: Int32 = -1
        var launchError: String?
        var elapsedSeconds: Double = 0

        do {
            let running = try ProcessRunner.runStreaming(
                executableURL: executableURL,
                arguments: arguments,
                onStdoutLine: { _ in },
                onStderrLine: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    lineLock.lock()
                    recentLines.append(trimmed)
                    if recentLines.count > 12 {
                        recentLines.removeFirst(recentLines.count - 12)
                    }

                    if trimmed.hasPrefix("out_time_ms="),
                       let value = Double(trimmed.dropFirst("out_time_ms=".count)) {
                        elapsedSeconds = value / 1_000_000
                    } else if trimmed.hasPrefix("out_time_us="),
                              let value = Double(trimmed.dropFirst("out_time_us=".count)) {
                        elapsedSeconds = value / 1_000_000
                    } else if trimmed.hasPrefix("out_time=") {
                        elapsedSeconds = self.parseFFmpegTime(String(trimmed.dropFirst("out_time=".count)))
                    }
                    lineLock.unlock()

                    if trimmed == "progress=continue" {
                        DispatchQueue.main.async {
                            let progressValue: Double
                            if let expectedDuration, expectedDuration > 0 {
                                progressValue = min(max(elapsedSeconds / expectedDuration, 0.01), 0.99)
                            } else {
                                progressValue = min(max(self.progress, 0.01), 0.95)
                            }

                            self.progress = progressValue
                            self.statusText = "\(outputFormat.title) 변환 중 | \(self.formattedConversionTime(elapsedSeconds))"
                        }
                    }
                },
                onExit: { status in
                    terminationStatus = status
                    semaphore.signal()
                }
            )

            stateQueue.sync {
                self.runningProcess = running
            }

            semaphore.wait()
            running.cleanup()

            stateQueue.sync {
                self.runningProcess = nil
            }
        } catch {
            launchError = error.localizedDescription
            stateQueue.sync {
                self.runningProcess = nil
            }
        }

        if let launchError {
            return StepResult(
                terminationStatus: -1,
                message: "ffmpeg 실행 실패: \(launchError)",
                wasCancelled: isCancelled
            )
        }

        lineLock.lock()
        let message = recentLines.suffix(3).joined(separator: "\n")
        lineLock.unlock()

        return StepResult(
            terminationStatus: terminationStatus,
            message: message.isEmpty ? nil : message,
            wasCancelled: isCancelled
        )
    }

    private func parseFFmpegTime(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: ":")
        guard segments.count == 3 else { return 0 }

        let hours = Double(segments[0]) ?? 0
        let minutes = Double(segments[1]) ?? 0
        let seconds = Double(segments[2]) ?? 0
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private func formattedConversionTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func uniqueOutputURL(
        in directory: URL,
        requestedBaseName: String?,
        outputFormat: ConversionOutputFormat,
        inputFile: URL
    ) -> URL {
        let baseName = sanitizedOutputBaseName(requestedBaseName, inputFile: inputFile)
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(outputFormat.fileExtension)
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension(outputFormat.fileExtension)
            suffix += 1
        }

        return candidate
    }

    private func sanitizedOutputBaseName(_ requestedBaseName: String?, inputFile: URL) -> String {
        let trimmedRequested = requestedBaseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackBaseName = inputFile
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedRequested.isEmpty ? "\(fallbackBaseName)-converted" : trimmedRequested
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let sanitized = candidate
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.isEmpty ? "converted-\(Int(Date().timeIntervalSince1970))" : sanitized
    }

    private func outputFileExistsAndIsNotEmpty(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }

        return size.int64Value > 0
    }

    private func finishSuccess(outputURL: URL) {
        DispatchQueue.main.async {
            self.isConverting = false
            self.progress = 1
            self.statusText = "파일 변환 완료"
            self.outputFileURL = outputURL
            self.userMessage = outputURL.lastPathComponent
        }
    }

    private func finishFailure(message: String, outputURL: URL) {
        try? FileManager.default.removeItem(at: outputURL)

        DispatchQueue.main.async {
            self.isConverting = false
            self.progress = 0
            self.statusText = "파일 변환 실패"
            self.userMessage = message
        }
    }

    private func finishCanceled(outputURL: URL) {
        try? FileManager.default.removeItem(at: outputURL)

        DispatchQueue.main.async {
            self.isConverting = false
            self.progress = 0
            self.statusText = "파일 변환 취소됨"
            self.userMessage = nil
        }
    }
}

private final class VideoMergeManager: ObservableObject {
    private let minimumRequiredFiles = 2
    private let supportedOutputExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm"]

    private struct StepResult {
        let terminationStatus: Int32
        let message: String?
        let wasCancelled: Bool
    }

    private struct MediaStreamSummary: Equatable {
        let fileExtension: String
        let hasAudio: Bool
        let videoCodec: String
        let width: Int
        let height: Int
        let frameRate: String
        let pixelFormat: String
        let audioCodec: String?
        let audioSampleRate: Int?
        let audioChannels: Int?
    }

    @Published private(set) var selectedFiles: [URL] = []
    @Published private(set) var isMerging: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String = "영상 파일을 추가하세요. 병합은 2개 이상부터 가능합니다."
    @Published private(set) var outputFileURL: URL?
    @Published var userMessage: String?

    private let workerQueue = DispatchQueue(label: "video.merge.worker", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "video.merge.state")
    private var runningProcess: RunningProcess?
    private var didCancel = false

    var canStart: Bool {
        selectedFiles.count >= minimumRequiredFiles && !isMerging
    }

    var preferredOutputExtension: String {
        preferredOutputExtension(for: selectedFiles)
    }

    func addFiles(_ urls: [URL]) {
        guard !isMerging else { return }

        let normalized = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }

        guard !normalized.isEmpty else {
            userMessage = "추가할 로컬 영상 파일을 찾지 못했습니다."
            return
        }

        var next = selectedFiles

        for url in normalized {
            if next.contains(where: { $0.standardizedFileURL == url }) {
                continue
            }
            next.append(url)
        }

        selectedFiles = next
        outputFileURL = nil
        userMessage = nil
        refreshSelectionStatus()
    }

    func removeFile(_ url: URL) {
        guard !isMerging else { return }
        selectedFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        outputFileURL = nil
        userMessage = nil
        refreshSelectionStatus()
    }

    func clearFiles() {
        guard !isMerging else { return }
        selectedFiles.removeAll()
        progress = 0
        outputFileURL = nil
        userMessage = nil
        refreshSelectionStatus()
    }

    func startMerge(
        outputDirectory: URL,
        ffmpegURL: URL,
        ffprobeURL: URL?,
        outputBaseName: String?,
        behavior: MergeBehavior
    ) {
        guard canStart else {
            userMessage = "영상 파일을 2개 이상 추가해 주세요."
            return
        }

        let files = selectedFiles
        let outputExtension = preferredOutputExtension(for: files)
        let outputURL = uniqueOutputURL(
            in: outputDirectory,
            requestedBaseName: outputBaseName,
            preferredExtension: outputExtension,
            fallbackFiles: files
        )
        let totalStageCount = files.count + 1

        isMerging = true
        progress = 0.01
        outputFileURL = nil
        userMessage = nil
        statusText = "병합 준비 중"

        stateQueue.sync {
            didCancel = false
            runningProcess = nil
        }

        workerQueue.async {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-merge-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: tempDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                self.finishFailure(
                    message: "임시 작업 폴더를 만들지 못했습니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            let mediaSummaries = self.readMediaStreamSummaries(
                for: files,
                ffprobeURL: ffprobeURL
            )
            let losslessListURL = tempDirectory.appendingPathComponent("concat-lossless.txt")
            let losslessReady = mediaSummaries.map {
                self.canLosslesslyMerge(
                    summaries: $0,
                    preferredExtension: outputExtension
                )
            } ?? false
            let videoPreservingReady = mediaSummaries.map {
                self.canPreserveVideoWithNormalizedAudio(
                    summaries: $0,
                    preferredExtension: outputExtension
                )
            } ?? false
            let timestampSafeConcatReady = mediaSummaries.map {
                self.canUseTimestampSafeConcat(
                    summaries: $0,
                    preferredExtension: outputExtension
                )
            } ?? false

            if losslessReady {
                self.updateStatus(
                    progress: 0.15,
                    text: timestampSafeConcatReady ? "연결부 정리 후 원본 유지 병합 중" : "원본 유지 병합 중"
                )

                let directMergeResult: StepResult
                if timestampSafeConcatReady, let firstSummary = mediaSummaries?.first {
                    directMergeResult = self.runTimestampSafeCopyMerge(
                        executableURL: ffmpegURL,
                        inputURLs: files,
                        outputURL: outputURL,
                        workingDirectory: tempDirectory,
                        videoCodec: firstSummary.videoCodec,
                        audioCodec: firstSummary.audioCodec
                    )
                } else {
                    let losslessContents = files
                        .map { "file '\(self.escapeConcatPath($0.path))'" }
                        .joined(separator: "\n")

                    do {
                        try losslessContents.write(to: losslessListURL, atomically: true, encoding: .utf8)
                    } catch {
                        self.finishFailure(
                            message: "무손실 병합 목록 파일을 만들지 못했습니다.",
                            tempDirectory: tempDirectory
                        )
                        return
                    }

                    directMergeResult = self.runFFmpegStep(
                        executableURL: ffmpegURL,
                        arguments: self.concatCopyArguments(
                            listURL: losslessListURL,
                            outputURL: outputURL
                        )
                    )
                }

                if directMergeResult.wasCancelled {
                    self.finishCanceled(tempDirectory: tempDirectory)
                    return
                }

                if directMergeResult.terminationStatus == 0 {
                    self.finishSuccess(outputURL: outputURL, tempDirectory: tempDirectory)
                    return
                }

                if behavior == .preserveOriginal && !videoPreservingReady {
                    self.finishFailure(
                        message: directMergeResult.message ?? "원본 유지 병합에 실패했습니다. 같은 영상 조건이 맞아야 비디오 무열화 병합이 가능합니다.",
                        tempDirectory: tempDirectory
                    )
                    return
                }
            } else if behavior == .preserveOriginal && !videoPreservingReady {
                self.finishFailure(
                    message: "원본 유지 우선 모드는 같은 영상 조건 파일만 비디오 무열화 병합할 수 있습니다. 오디오만 다르면 오디오만 변환합니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            if videoPreservingReady, let mediaSummaries {
                var preparedFiles: [URL] = []
                var prepareFailureMessage: String?
                var shouldFallbackToCompatibility = false

                for (index, fileURL) in files.enumerated() {
                    if self.isCancelled {
                        self.finishCanceled(tempDirectory: tempDirectory)
                        return
                    }

                    let stageNumber = index + 1
                    let summary = mediaSummaries[index]
                    let preparedURL = tempDirectory.appendingPathComponent("prepared-audio-\(stageNumber).\(outputExtension)")

                    self.updateStatus(
                        progress: Double(index) / Double(totalStageCount),
                        text: "\(stageNumber)/\(totalStageCount) 단계: \(fileURL.lastPathComponent) \(summary.hasAudio ? "오디오 정규화 중" : "무음 오디오 추가 중")"
                    )

                    let result = self.runFFmpegStep(
                        executableURL: ffmpegURL,
                        arguments: self.audioNormalizationArguments(
                            inputURL: fileURL,
                            outputURL: preparedURL,
                            hasAudio: summary.hasAudio
                        )
                    )

                    if result.wasCancelled {
                        self.finishCanceled(tempDirectory: tempDirectory)
                        return
                    }

                    guard result.terminationStatus == 0 else {
                        if behavior == .preserveOriginal {
                            self.finishFailure(
                                message: result.message ?? "오디오 정규화 단계에서 실패했습니다.",
                                tempDirectory: tempDirectory
                            )
                            return
                        }

                        prepareFailureMessage = result.message
                        shouldFallbackToCompatibility = true
                        break
                    }

                    preparedFiles.append(preparedURL)
                    self.updateStatus(
                        progress: Double(stageNumber) / Double(totalStageCount),
                        text: "\(stageNumber)/\(totalStageCount) 단계 완료"
                    )
                }

                if !shouldFallbackToCompatibility {
                    let listURL = tempDirectory.appendingPathComponent("concat-audio-normalized.txt")
                    let listContents = preparedFiles
                        .map { "file '\(self.escapeConcatPath($0.path))'" }
                        .joined(separator: "\n")

                    do {
                        try listContents.write(to: listURL, atomically: true, encoding: .utf8)
                    } catch {
                        if behavior == .preserveOriginal {
                            self.finishFailure(
                                message: "병합 목록 파일을 만들지 못했습니다.",
                                tempDirectory: tempDirectory
                            )
                            return
                        }

                        shouldFallbackToCompatibility = true
                    }

                    if !shouldFallbackToCompatibility {
                        self.updateStatus(
                            progress: Double(totalStageCount - 1) / Double(totalStageCount),
                            text: timestampSafeConcatReady
                                ? "\(totalStageCount)/\(totalStageCount) 단계: 연결부 정리 후 비디오 원본 유지 병합 중"
                                : "\(totalStageCount)/\(totalStageCount) 단계: 비디오 원본 유지 병합 중"
                        )

                        let mergeResult: StepResult
                        if timestampSafeConcatReady, let firstSummary = mediaSummaries.first {
                            mergeResult = self.runTimestampSafeCopyMerge(
                                executableURL: ffmpegURL,
                                inputURLs: preparedFiles,
                                outputURL: outputURL,
                                workingDirectory: tempDirectory,
                                videoCodec: firstSummary.videoCodec,
                                audioCodec: outputExtension == "webm" ? "opus" : "aac"
                            )
                        } else {
                            mergeResult = self.runFFmpegStep(
                                executableURL: ffmpegURL,
                                arguments: self.concatCopyArguments(
                                    listURL: listURL,
                                    outputURL: outputURL
                                )
                            )
                        }

                        if mergeResult.wasCancelled {
                            self.finishCanceled(tempDirectory: tempDirectory)
                            return
                        }

                        if mergeResult.terminationStatus == 0 {
                            self.finishSuccess(outputURL: outputURL, tempDirectory: tempDirectory)
                            return
                        }

                        if behavior == .preserveOriginal {
                            self.finishFailure(
                                message: mergeResult.message ?? "비디오 원본 유지 병합에 실패했습니다.",
                                tempDirectory: tempDirectory
                            )
                            return
                        }

                        prepareFailureMessage = mergeResult.message
                        shouldFallbackToCompatibility = true
                    }
                }

                if shouldFallbackToCompatibility, let prepareFailureMessage {
                    DispatchQueue.main.async {
                        self.userMessage = prepareFailureMessage
                    }
                }
            }

            var preparedFiles: [URL] = []

            for (index, fileURL) in files.enumerated() {
                if self.isCancelled {
                    self.finishCanceled(tempDirectory: tempDirectory)
                    return
                }

                let stageNumber = index + 1
                let hasAudio: Bool
                if let mediaSummaries, mediaSummaries.indices.contains(index) {
                    hasAudio = mediaSummaries[index].hasAudio
                } else {
                    hasAudio = self.detectAudioStream(
                        in: fileURL,
                        ffmpegURL: ffmpegURL,
                        ffprobeURL: ffprobeURL
                    )
                }
                let shouldPassthrough = self.shouldPassthroughFile(
                    fileURL: fileURL,
                    preferredExtension: outputExtension,
                    hasAudio: hasAudio
                )

                self.updateStatus(
                    progress: Double(index) / Double(totalStageCount),
                    text: "\(stageNumber)/\(totalStageCount) 단계: \(fileURL.lastPathComponent) \(shouldPassthrough ? "복사 중" : "변환 중")"
                )

                let preparedURL = tempDirectory.appendingPathComponent("prepared-\(stageNumber).\(outputExtension)")
                let result = self.runFFmpegStep(
                    executableURL: ffmpegURL,
                    arguments: shouldPassthrough
                        ? self.passthroughArguments(
                            inputURL: fileURL,
                            outputURL: preparedURL
                        )
                        : self.normalizationArguments(
                            inputURL: fileURL,
                            outputURL: preparedURL,
                            hasAudio: hasAudio
                        )
                )

                if result.wasCancelled {
                    self.finishCanceled(tempDirectory: tempDirectory)
                    return
                }

                guard result.terminationStatus == 0 else {
                    self.finishFailure(
                        message: result.message ?? "영상 변환 단계에서 실패했습니다.",
                        tempDirectory: tempDirectory
                    )
                    return
                }

                preparedFiles.append(preparedURL)
                self.updateStatus(
                    progress: Double(stageNumber) / Double(totalStageCount),
                    text: "\(stageNumber)/\(totalStageCount) 단계 완료"
                )
            }

            let listURL = tempDirectory.appendingPathComponent("concat-list.txt")
            let listContents = preparedFiles
                .map { "file '\(self.escapeConcatPath($0.path))'" }
                .joined(separator: "\n")

            do {
                try listContents.write(to: listURL, atomically: true, encoding: .utf8)
            } catch {
                self.finishFailure(
                    message: "병합 목록 파일을 만들지 못했습니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            self.updateStatus(
                progress: Double(totalStageCount - 1) / Double(totalStageCount),
                text: "\(totalStageCount)/\(totalStageCount) 단계: 최종 병합 중"
            )

            let copyMergeResult = self.runFFmpegStep(
                executableURL: ffmpegURL,
                arguments: self.concatCopyArguments(
                    listURL: listURL,
                    outputURL: outputURL
                )
            )

            if copyMergeResult.wasCancelled {
                self.finishCanceled(tempDirectory: tempDirectory)
                return
            }

            if copyMergeResult.terminationStatus != 0 {
                self.updateStatus(
                    progress: Double(totalStageCount - 1) / Double(totalStageCount),
                    text: "\(totalStageCount)/\(totalStageCount) 단계: 최종 병합 재시도 중"
                )

                let fallbackMergeResult = self.runFFmpegStep(
                    executableURL: ffmpegURL,
                    arguments: self.concatReencodeArguments(
                        inputURLs: preparedFiles,
                        outputURL: outputURL
                    )
                )

                if fallbackMergeResult.wasCancelled {
                    self.finishCanceled(tempDirectory: tempDirectory)
                    return
                }

                guard fallbackMergeResult.terminationStatus == 0 else {
                    self.finishFailure(
                        message: fallbackMergeResult.message ?? copyMergeResult.message ?? "최종 병합 단계에서 실패했습니다.",
                        tempDirectory: tempDirectory
                    )
                    return
                }
            }

            self.finishSuccess(outputURL: outputURL, tempDirectory: tempDirectory)
        }
    }

    func cancel() {
        stateQueue.sync {
            didCancel = true
            runningProcess?.cancel()
        }

        DispatchQueue.main.async {
            self.statusText = "병합 중지 요청 중"
        }
    }

    private var isCancelled: Bool {
        stateQueue.sync { didCancel }
    }

    private func normalizationArguments(inputURL: URL, outputURL: URL, hasAudio: Bool) -> [String] {
        let outputExtension = outputURL.pathExtension.lowercased()
        var arguments: [String] = ["-y", "-i", inputURL.path]

        if !hasAudio {
            arguments += [
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-shortest",
                "-map", "0:v:0",
                "-map", "1:a:0"
            ]
        } else {
            arguments += [
                "-map", "0:v:0",
                "-map", "0:a:0"
            ]
        }

        arguments += [
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        ]

        arguments += videoEncodingArguments(for: outputExtension)
        arguments += audioEncodingArguments(for: outputExtension)
        arguments += containerFlags(for: outputURL.pathExtension.lowercased())
        arguments.append(outputURL.path)

        return arguments
    }

    private func audioNormalizationArguments(inputURL: URL, outputURL: URL, hasAudio: Bool) -> [String] {
        let outputExtension = outputURL.pathExtension.lowercased()
        var arguments: [String] = ["-y", "-i", inputURL.path]

        if !hasAudio {
            arguments += [
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-shortest",
                "-map", "0:v:0",
                "-map", "1:a:0"
            ]
        } else {
            arguments += [
                "-map", "0:v:0",
                "-map", "0:a:0"
            ]
        }

        arguments += ["-c:v", "copy"]
        arguments += audioEncodingArguments(for: outputExtension)
        arguments += containerFlags(for: outputExtension)
        arguments.append(outputURL.path)

        return arguments
    }

    private func passthroughArguments(inputURL: URL, outputURL: URL) -> [String] {
        var arguments = [
            "-y",
            "-i", inputURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-c", "copy"
        ]

        arguments += containerFlags(for: outputURL.pathExtension.lowercased())
        arguments.append(outputURL.path)
        return arguments
    }

    private func concatCopyArguments(listURL: URL, outputURL: URL) -> [String] {
        var arguments = [
            "-y",
            "-fflags", "+genpts",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path,
            "-c", "copy",
            "-avoid_negative_ts", "make_zero"
        ]

        arguments += containerFlags(for: outputURL.pathExtension.lowercased())
        arguments.append(outputURL.path)
        return arguments
    }

    private func concatReencodeArguments(inputURLs: [URL], outputURL: URL) -> [String] {
        let outputExtension = outputURL.pathExtension.lowercased()
        var arguments: [String] = ["-y"]

        for inputURL in inputURLs {
            arguments += ["-i", inputURL.path]
        }

        var filterParts: [String] = []
        var concatInputs = ""

        for index in inputURLs.indices {
            filterParts.append("[\(index):v:0]scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1[v\(index)]")
            filterParts.append("[\(index):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(index)]")
            concatInputs += "[v\(index)][a\(index)]"
        }

        filterParts.append("\(concatInputs)concat=n=\(inputURLs.count):v=1:a=1[v][a]")

        arguments += [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[v]",
            "-map", "[a]"
        ]

        arguments += videoEncodingArguments(for: outputExtension)
        arguments += audioEncodingArguments(for: outputExtension)
        arguments += containerFlags(for: outputURL.pathExtension.lowercased())
        arguments.append(outputURL.path)

        return arguments
    }

    private func shouldPassthroughFile(fileURL: URL, preferredExtension: String, hasAudio: Bool) -> Bool {
        fileURL.pathExtension.lowercased() == preferredExtension && hasAudio
    }

    private func videoEncodingArguments(for fileExtension: String) -> [String] {
        switch fileExtension {
        case "webm":
            return [
                "-c:v", "libvpx-vp9",
                "-pix_fmt", "yuv420p",
                "-b:v", "0",
                "-crf", "32",
                "-row-mt", "1",
                "-cpu-used", "4"
            ]
        default:
            return [
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "20",
                "-pix_fmt", "yuv420p"
            ]
        }
    }

    private func audioEncodingArguments(for fileExtension: String) -> [String] {
        switch fileExtension {
        case "webm":
            return [
                "-c:a", "libopus",
                "-b:a", "160k",
                "-ar", "48000",
                "-ac", "2"
            ]
        default:
            return [
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-ac", "2"
            ]
        }
    }

    private func readMediaStreamSummaries(for files: [URL], ffprobeURL: URL?) -> [MediaStreamSummary]? {
        guard !files.isEmpty, ffprobeURL != nil else {
            return nil
        }

        let summaries = files.compactMap { readMediaStreamSummary(for: $0, ffprobeURL: ffprobeURL) }
        guard summaries.count == files.count else {
            return nil
        }

        return summaries
    }

    private func canLosslesslyMerge(summaries: [MediaStreamSummary], preferredExtension: String) -> Bool {
        guard hasMatchingVideoStreamConditions(
            summaries: summaries,
            preferredExtension: preferredExtension
        ), let firstSummary = summaries.first else {
            return false
        }

        return summaries.dropFirst().allSatisfy { $0 == firstSummary }
    }

    private func canPreserveVideoWithNormalizedAudio(
        summaries: [MediaStreamSummary],
        preferredExtension: String
    ) -> Bool {
        hasMatchingVideoStreamConditions(
            summaries: summaries,
            preferredExtension: preferredExtension
        )
    }

    private func hasMatchingVideoStreamConditions(
        summaries: [MediaStreamSummary],
        preferredExtension: String
    ) -> Bool {
        guard let firstSummary = summaries.first,
              firstSummary.fileExtension == preferredExtension
        else {
            return false
        }

        return summaries.dropFirst().allSatisfy {
            $0.fileExtension == preferredExtension &&
            $0.videoCodec == firstSummary.videoCodec &&
            $0.width == firstSummary.width &&
            $0.height == firstSummary.height &&
            $0.frameRate == firstSummary.frameRate &&
            $0.pixelFormat == firstSummary.pixelFormat
        }
    }

    private func canUseTimestampSafeConcat(
        summaries: [MediaStreamSummary],
        preferredExtension: String
    ) -> Bool {
        guard let firstSummary = summaries.first else {
            return false
        }

        return ["mp4", "mov", "m4v"].contains(preferredExtension)
            && firstSummary.fileExtension == preferredExtension
            && (firstSummary.videoCodec == "h264" || firstSummary.videoCodec == "hevc")
    }

    private func readMediaStreamSummary(for fileURL: URL, ffprobeURL: URL?) -> MediaStreamSummary? {
        guard let ffprobeURL,
              let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_streams",
                    "-of", "json",
                    fileURL.path
                ]
              ),
              result.terminationStatus == 0,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]],
              let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" })
        else {
            return nil
        }

        let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

        return MediaStreamSummary(
            fileExtension: fileURL.pathExtension.lowercased(),
            hasAudio: audioStream != nil,
            videoCodec: videoStream["codec_name"] as? String ?? "",
            width: videoStream["width"] as? Int ?? 0,
            height: videoStream["height"] as? Int ?? 0,
            frameRate: videoStream["r_frame_rate"] as? String ?? "",
            pixelFormat: videoStream["pix_fmt"] as? String ?? "",
            audioCodec: audioStream?["codec_name"] as? String,
            audioSampleRate: (audioStream?["sample_rate"] as? String).flatMap(Int.init),
            audioChannels: audioStream?["channels"] as? Int
        )
    }

    private func detectAudioStream(in fileURL: URL, ffmpegURL: URL, ffprobeURL: URL?) -> Bool {
        if let ffprobeURL,
           let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-select_streams", "a:0",
                    "-show_entries", "stream=index",
                    "-of", "csv=p=0",
                    fileURL.path
                ]
           ),
           result.terminationStatus == 0 {
            return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let fallbackResult = ProcessRunner.runAndCapture(
            executableURL: ffmpegURL,
            arguments: ["-i", fileURL.path]
        ) {
            return fallbackResult.stderr.localizedCaseInsensitiveContains("Audio:")
        }

        return true
    }

    private func runFFmpegStep(executableURL: URL, arguments: [String]) -> StepResult {
        let semaphore = DispatchSemaphore(value: 0)
        let messageLock = NSLock()
        var recentLines: [String] = []
        var terminationStatus: Int32 = -1
        var launchError: String?

        do {
            let running = try ProcessRunner.runStreaming(
                executableURL: executableURL,
                arguments: arguments,
                onStdoutLine: { _ in },
                onStderrLine: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    messageLock.lock()
                    recentLines.append(trimmed)
                    if recentLines.count > 12 {
                        recentLines.removeFirst(recentLines.count - 12)
                    }
                    messageLock.unlock()
                },
                onExit: { status in
                    terminationStatus = status
                    semaphore.signal()
                }
            )

            stateQueue.sync {
                self.runningProcess = running
            }

            semaphore.wait()
            running.cleanup()

            stateQueue.sync {
                self.runningProcess = nil
            }
        } catch {
            launchError = error.localizedDescription
            stateQueue.sync {
                self.runningProcess = nil
            }
        }

        let wasCancelled = isCancelled

        if let launchError {
            return StepResult(
                terminationStatus: -1,
                message: "ffmpeg 실행 실패: \(launchError)",
                wasCancelled: wasCancelled
            )
        }

        messageLock.lock()
        let message = recentLines.suffix(3).joined(separator: "\n")
        messageLock.unlock()

        return StepResult(
            terminationStatus: terminationStatus,
            message: message.isEmpty ? nil : message,
            wasCancelled: wasCancelled
        )
    }

    private func runTimestampSafeCopyMerge(
        executableURL: URL,
        inputURLs: [URL],
        outputURL: URL,
        workingDirectory: URL,
        videoCodec: String,
        audioCodec: String?
    ) -> StepResult {
        let segmentDirectory = workingDirectory.appendingPathComponent("timestamp-safe-segments", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: segmentDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return StepResult(
                terminationStatus: -1,
                message: "연결부 정리용 임시 폴더를 만들지 못했습니다.",
                wasCancelled: isCancelled
            )
        }

        var segmentURLs: [URL] = []

        for (index, inputURL) in inputURLs.enumerated() {
            let segmentURL = segmentDirectory.appendingPathComponent(String(format: "segment-%03d.ts", index + 1))
            let remuxResult = runFFmpegStep(
                executableURL: executableURL,
                arguments: transportStreamRemuxArguments(
                    inputURL: inputURL,
                    outputURL: segmentURL,
                    videoCodec: videoCodec
                )
            )

            if remuxResult.terminationStatus != 0 || remuxResult.wasCancelled {
                return remuxResult
            }

            segmentURLs.append(segmentURL)
        }

        let listURL = workingDirectory.appendingPathComponent("concat-timestamp-safe.txt")
        let listContents = segmentURLs
            .map { "file '\(escapeConcatPath($0.path))'" }
            .joined(separator: "\n")

        do {
            try listContents.write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            return StepResult(
                terminationStatus: -1,
                message: "연결부 정리 병합 목록 파일을 만들지 못했습니다.",
                wasCancelled: isCancelled
            )
        }

        return runFFmpegStep(
            executableURL: executableURL,
            arguments: transportStreamConcatArguments(
                listURL: listURL,
                outputURL: outputURL,
                audioCodec: audioCodec
            )
        )
    }

    private func transportStreamRemuxArguments(
        inputURL: URL,
        outputURL: URL,
        videoCodec: String
    ) -> [String] {
        var arguments = [
            "-y",
            "-fflags", "+genpts",
            "-i", inputURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-muxdelay", "0",
            "-muxpreload", "0"
        ]

        if videoCodec == "h264" {
            arguments += ["-bsf:v", "h264_mp4toannexb"]
        } else if videoCodec == "hevc" {
            arguments += ["-bsf:v", "hevc_mp4toannexb"]
        }

        arguments += ["-f", "mpegts", outputURL.path]
        return arguments
    }

    private func transportStreamConcatArguments(
        listURL: URL,
        outputURL: URL,
        audioCodec: String?
    ) -> [String] {
        var arguments = [
            "-y",
            "-fflags", "+genpts",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path,
            "-c", "copy",
            "-avoid_negative_ts", "make_zero"
        ]

        if ["mp4", "mov", "m4v"].contains(outputURL.pathExtension.lowercased()),
           audioCodec == "aac" {
            arguments += ["-bsf:a", "aac_adtstoasc"]
        }

        arguments += containerFlags(for: outputURL.pathExtension.lowercased())
        arguments.append(outputURL.path)
        return arguments
    }

    private func uniqueOutputURL(
        in directory: URL,
        requestedBaseName: String?,
        preferredExtension: String,
        fallbackFiles: [URL]
    ) -> URL {
        let baseName = sanitizedOutputBaseName(
            requestedBaseName,
            fallbackFiles: fallbackFiles
        )
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(preferredExtension)
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension(preferredExtension)
            suffix += 1
        }

        return candidate
    }

    private func sanitizedOutputBaseName(_ requestedBaseName: String?, fallbackFiles: [URL]) -> String {
        let trimmedRequested = requestedBaseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackBaseName = fallbackFiles.first?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedRequested.isEmpty ? (fallbackBaseName ?? defaultMergedBaseName()) : trimmedRequested

        var normalizedBaseName = (candidate as NSString).deletingPathExtension
        if normalizedBaseName.isEmpty {
            normalizedBaseName = candidate
        }

        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let sanitized = normalizedBaseName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.isEmpty ? defaultMergedBaseName() : sanitized
    }

    private func defaultMergedBaseName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "merged-\(formatter.string(from: Date()))"
    }

    private func preferredOutputExtension(for files: [URL]) -> String {
        guard let firstExtension = files.first?.pathExtension.lowercased(),
              supportedOutputExtensions.contains(firstExtension)
        else {
            return "mp4"
        }

        return firstExtension
    }

    private func containerFlags(for fileExtension: String) -> [String] {
        switch fileExtension {
        case "mp4", "mov", "m4v":
            return ["-movflags", "+faststart"]
        default:
            return []
        }
    }

    private func escapeConcatPath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func refreshSelectionStatus() {
        if selectedFiles.isEmpty {
            statusText = "영상 파일을 추가하세요. 병합은 2개 이상부터 가능합니다."
        } else if canStart {
            statusText = "영상 \(selectedFiles.count)개 준비됨"
        } else {
            statusText = "영상 \(selectedFiles.count)개 선택됨. 2개 이상 필요"
        }
    }

    private func updateStatus(progress: Double, text: String) {
        DispatchQueue.main.async {
            self.progress = min(max(progress, 0), 1)
            self.statusText = text
        }
    }

    private func finishSuccess(outputURL: URL, tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isMerging = false
            self.progress = 1
            self.statusText = "영상 병합 완료"
            self.outputFileURL = outputURL
            self.userMessage = outputURL.lastPathComponent
        }
    }

    private func finishFailure(message: String, tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isMerging = false
            self.progress = 0
            self.statusText = "영상 병합 실패"
            self.userMessage = message
        }
    }

    private func finishCanceled(tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isMerging = false
            self.progress = 0
            self.statusText = "영상 병합 취소됨"
            self.userMessage = nil
        }
    }

    private func cleanupTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SubtitleVideoRenderManager: ObservableObject {
    private struct StepResult {
        let terminationStatus: Int32
        let message: String?
        let wasCancelled: Bool
    }

    @Published private(set) var mediaFileURL: URL?
    @Published private(set) var subtitleFileURL: URL?
    @Published private(set) var isRendering: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String = "음성/영상 파일과 자막 파일을 선택하세요."
    @Published private(set) var outputFileURL: URL?
    @Published var userMessage: String?

    private let supportedSubtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
    private let workerQueue = DispatchQueue(label: "subtitle.video.render.worker", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "subtitle.video.render.state")
    private var runningProcess: RunningProcess?
    private var didCancel = false

    var canStart: Bool {
        mediaFileURL != nil && subtitleFileURL != nil && !isRendering
    }

    func setMediaFile(_ url: URL) {
        guard !isRendering else { return }
        mediaFileURL = url.standardizedFileURL
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func setSubtitleFile(_ url: URL) {
        guard !isRendering else { return }

        let normalizedURL = url.standardizedFileURL
        let ext = normalizedURL.pathExtension.lowercased()
        guard supportedSubtitleExtensions.contains(ext) else {
            userMessage = "자막 파일은 srt, ass, ssa, vtt 형식만 지원합니다."
            return
        }

        subtitleFileURL = normalizedURL
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func clearMediaFile() {
        guard !isRendering else { return }
        mediaFileURL = nil
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func clearSubtitleFile() {
        guard !isRendering else { return }
        subtitleFileURL = nil
        outputFileURL = nil
        userMessage = nil
        refreshStatus()
    }

    func startRender(
        outputDirectory: URL,
        ffmpegURL: URL,
        ffprobeURL: URL?,
        outputBaseName: String?,
        subtitleFontSize: Double
    ) {
        guard let mediaFileURL, let subtitleFileURL else {
            userMessage = "음성/영상 파일과 자막 파일을 모두 선택해 주세요."
            return
        }

        let outputURL = uniqueOutputURL(
            in: outputDirectory,
            requestedBaseName: outputBaseName,
            fallbackMediaFile: mediaFileURL
        )

        isRendering = true
        progress = 0.01
        outputFileURL = nil
        userMessage = nil
        statusText = "자막 영상 준비 중"

        stateQueue.sync {
            didCancel = false
            runningProcess = nil
        }

        workerQueue.async {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("subtitle-video-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: tempDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                self.finishFailure(
                    message: "임시 작업 폴더를 만들지 못했습니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            let safeSubtitleURL = tempDirectory
                .appendingPathComponent("subtitle")
                .appendingPathExtension(subtitleFileURL.pathExtension.lowercased())

            do {
                try FileManager.default.copyItem(at: subtitleFileURL, to: safeSubtitleURL)
            } catch {
                self.finishFailure(
                    message: "자막 파일을 준비하지 못했습니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            let usesSourceVideo = self.hasVideoStream(
                in: mediaFileURL,
                ffmpegURL: ffmpegURL,
                ffprobeURL: ffprobeURL
            )
            let durationSeconds = self.readMediaDuration(for: mediaFileURL, ffprobeURL: ffprobeURL)
            let result = self.runRenderStep(
                executableURL: ffmpegURL,
                arguments: self.renderArguments(
                    mediaURL: mediaFileURL,
                    subtitleURL: safeSubtitleURL,
                    outputURL: outputURL,
                    subtitleFontSize: subtitleFontSize,
                    usesSourceVideo: usesSourceVideo
                ),
                expectedDuration: durationSeconds
            )

            if result.wasCancelled {
                self.finishCanceled(tempDirectory: tempDirectory)
                return
            }

            guard result.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                self.finishFailure(
                    message: result.message ?? "자막 영상 생성에 실패했습니다.",
                    tempDirectory: tempDirectory
                )
                return
            }

            self.finishSuccess(outputURL: outputURL, tempDirectory: tempDirectory)
        }
    }

    func cancel() {
        stateQueue.sync {
            didCancel = true
            runningProcess?.cancel()
        }

        DispatchQueue.main.async {
            self.statusText = "자막 영상 생성 중지 요청 중"
        }
    }

    private var isCancelled: Bool {
        stateQueue.sync { didCancel }
    }

    private func refreshStatus() {
        if mediaFileURL == nil && subtitleFileURL == nil {
            statusText = "음성/영상 파일과 자막 파일을 선택하세요."
        } else if mediaFileURL == nil {
            statusText = "음성/영상 파일을 선택해 주세요."
        } else if subtitleFileURL == nil {
            statusText = "자막 파일을 선택해 주세요."
        } else {
            statusText = "하드자막 영상 생성 준비 완료"
        }
    }

    private func renderArguments(
        mediaURL: URL,
        subtitleURL: URL,
        outputURL: URL,
        subtitleFontSize: Double,
        usesSourceVideo: Bool
    ) -> [String] {
        let safePath = escapeSubtitleFilterPath(subtitleURL.path)
        let fontSize = max(8, Int(subtitleFontSize.rounded()))
        let subtitleFilter = "subtitles='\(safePath)':force_style='FontSize=\(fontSize)'"

        if usesSourceVideo {
            return [
                "-y",
                "-hide_banner",
                "-nostats",
                "-loglevel", "warning",
                "-progress", "pipe:2",
                "-i", mediaURL.path,
                "-vf", subtitleFilter,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "18",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart",
                outputURL.path
            ]
        }

        return [
            "-y",
            "-hide_banner",
            "-nostats",
            "-loglevel", "warning",
            "-progress", "pipe:2",
            "-f", "lavfi",
            "-i", "color=c=black:s=1280x720:r=30",
            "-i", mediaURL.path,
            "-vf", subtitleFilter,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2",
            "-shortest",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    private func hasVideoStream(in fileURL: URL, ffmpegURL: URL, ffprobeURL: URL?) -> Bool {
        if let ffprobeURL,
           let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-select_streams", "v",
                    "-show_streams",
                    "-of", "json",
                    fileURL.path
                ]
           ),
           result.terminationStatus == 0,
           let hasRealVideo = parseHasRealVideoStream(from: result.stdout) {
            return hasRealVideo
        }

        if let result = ProcessRunner.runAndCapture(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-i", fileURL.path
            ]
        ) {
            let probeText = result.stdout + "\n" + result.stderr
            let videoLines = probeText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.localizedCaseInsensitiveContains("Video:") }

            if videoLines.contains(where: { !$0.localizedCaseInsensitiveContains("attached pic") }) {
                return true
            }
            if !videoLines.isEmpty || probeText.localizedCaseInsensitiveContains("Audio:") {
                return false
            }
        }

        return isLikelyVideoFile(fileURL)
    }

    private func parseHasRealVideoStream(from jsonText: String) -> Bool? {
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]]
        else {
            return nil
        }

        return streams.contains { stream in
            let disposition = stream["disposition"] as? [String: Any]
            let attachedPicture = disposition?["attached_pic"] as? Int ?? 0
            return attachedPicture != 1
        }
    }

    private func isLikelyVideoFile(_ fileURL: URL) -> Bool {
        let videoExtensions: Set<String> = [
            "mp4", "mov", "m4v", "mkv", "webm", "avi",
            "ts", "mts", "m2ts"
        ]
        return videoExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private func escapeSubtitleFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func readMediaDuration(for fileURL: URL, ffprobeURL: URL?) -> Double? {
        guard let ffprobeURL,
              let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    fileURL.path
                ]
              ),
              result.terminationStatus == 0
        else {
            return nil
        }

        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(raw)
    }

    private func runRenderStep(
        executableURL: URL,
        arguments: [String],
        expectedDuration: Double?
    ) -> StepResult {
        let semaphore = DispatchSemaphore(value: 0)
        let lineLock = NSLock()
        var recentLines: [String] = []
        var terminationStatus: Int32 = -1
        var launchError: String?
        var elapsedSeconds: Double = 0

        do {
            let running = try ProcessRunner.runStreaming(
                executableURL: executableURL,
                arguments: arguments,
                onStdoutLine: { _ in },
                onStderrLine: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    lineLock.lock()
                    recentLines.append(trimmed)
                    if recentLines.count > 12 {
                        recentLines.removeFirst(recentLines.count - 12)
                    }

                    if trimmed.hasPrefix("out_time_ms="),
                       let value = Double(trimmed.dropFirst("out_time_ms=".count)) {
                        elapsedSeconds = value / 1_000_000
                    } else if trimmed.hasPrefix("out_time_us="),
                              let value = Double(trimmed.dropFirst("out_time_us=".count)) {
                        elapsedSeconds = value / 1_000_000
                    } else if trimmed.hasPrefix("out_time=") {
                        elapsedSeconds = self.parseFFmpegTime(String(trimmed.dropFirst("out_time=".count)))
                    }
                    lineLock.unlock()

                    if trimmed == "progress=continue" {
                        DispatchQueue.main.async {
                            let progressValue: Double
                            if let expectedDuration, expectedDuration > 0 {
                                progressValue = min(max(elapsedSeconds / expectedDuration, 0.01), 0.99)
                            } else {
                                progressValue = min(max(self.progress, 0.01), 0.95)
                            }

                            self.progress = progressValue
                            self.statusText = "하드자막 영상 생성 중 | \(self.formattedRenderTime(elapsedSeconds))"
                        }
                    }
                },
                onExit: { status in
                    terminationStatus = status
                    semaphore.signal()
                }
            )

            stateQueue.sync {
                self.runningProcess = running
            }

            semaphore.wait()
            running.cleanup()

            stateQueue.sync {
                self.runningProcess = nil
            }
        } catch {
            launchError = error.localizedDescription
            stateQueue.sync {
                self.runningProcess = nil
            }
        }

        if let launchError {
            return StepResult(
                terminationStatus: -1,
                message: "ffmpeg 실행 실패: \(launchError)",
                wasCancelled: isCancelled
            )
        }

        lineLock.lock()
        let message = recentLines.suffix(3).joined(separator: "\n")
        lineLock.unlock()

        return StepResult(
            terminationStatus: terminationStatus,
            message: message.isEmpty ? nil : message,
            wasCancelled: isCancelled
        )
    }

    private func parseFFmpegTime(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: ":")
        guard segments.count == 3 else { return 0 }

        let hours = Double(segments[0]) ?? 0
        let minutes = Double(segments[1]) ?? 0
        let seconds = Double(segments[2]) ?? 0
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private func formattedRenderTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func uniqueOutputURL(in directory: URL, requestedBaseName: String?, fallbackMediaFile: URL) -> URL {
        let baseName = sanitizedOutputBaseName(requestedBaseName, fallbackMediaFile: fallbackMediaFile)
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("mp4")
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }

        return candidate
    }

    private func sanitizedOutputBaseName(_ requestedBaseName: String?, fallbackMediaFile: URL) -> String {
        let trimmedRequested = requestedBaseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackBaseName = fallbackMediaFile
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedRequested.isEmpty ? "\(fallbackBaseName)-subtitle-video" : trimmedRequested
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let sanitized = candidate
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.isEmpty ? "subtitle-video-\(Int(Date().timeIntervalSince1970))" : sanitized
    }

    private func finishSuccess(outputURL: URL, tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isRendering = false
            self.progress = 1
            self.statusText = "하드자막 영상 생성 완료"
            self.outputFileURL = outputURL
            self.userMessage = outputURL.lastPathComponent
        }
    }

    private func finishFailure(message: String, tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isRendering = false
            self.progress = 0
            self.statusText = "하드자막 영상 생성 실패"
            self.userMessage = message
        }
    }

    private func finishCanceled(tempDirectory: URL) {
        cleanupTemporaryDirectory(tempDirectory)

        DispatchQueue.main.async {
            self.isRendering = false
            self.progress = 0
            self.statusText = "하드자막 영상 생성 취소됨"
            self.userMessage = nil
        }
    }

    private func cleanupTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct MainView: View {
    private struct SubtitlePreviewMetrics {
        let playResY: CGFloat
        let marginV: CGFloat
    }

    @EnvironmentObject private var toolManager: ToolManager

    @AppStorage(SettingsKeys.defaultOutputDirectory) private var defaultOutputDirectoryPath: String = ""
    @AppStorage(SettingsKeys.defaultDownloadPreset) private var defaultDownloadPresetRaw: String = DownloadPreset.macCompatibleMP4.rawValue
    @AppStorage(SettingsKeys.defaultFilenameConflictPolicy) private var defaultFilenameConflictPolicyRaw: String = FilenameConflictPolicy.autoRename.rawValue
    @AppStorage(SettingsKeys.mergeBehavior) private var mergeBehaviorRaw: String = MergeBehavior.compatibilityPreferred.rawValue
    @AppStorage(SettingsKeys.hlsAutoReconnectEnabled) private var hlsAutoReconnectEnabled: Bool = true
    @AppStorage(SettingsKeys.hlsReconnectFailTimeoutSeconds) private var hlsReconnectFailTimeoutSeconds: Int = 90

    @State private var urlText: String = ""
    @State private var selectedOutputDirectory: URL?
    @State private var alertMessage: String = ""
    @State private var showAlert = false
    @State private var isSettingsPresented = false
    @State private var isPreparingDownloads = false
    @State private var taskItems: [DownloadTaskItem] = []
    @StateObject private var fileConversionManager = FileConversionManager()
    @StateObject private var videoMergeManager = VideoMergeManager()
    @StateObject private var subtitleVideoManager = SubtitleVideoRenderManager()
    @State private var isConversionDropTargeted = false
    @State private var isMergeDropTargeted = false
    @State private var isSubtitleDropTargeted = false
    @State private var selectedTab: MainContentTab = .download
    @State private var conversionOutputName: String = ""
    @State private var conversionOutputFormat: ConversionOutputFormat = .mp4
    @State private var mergeOutputName: String = ""
    @State private var subtitleVideoOutputName: String = ""
    @State private var subtitlePreviewFontSize: Double = 16

    private let defaultSubtitlePreviewMetrics = SubtitlePreviewMetrics(playResY: 288, marginV: 10)

    private var selectedPreset: DownloadPreset {
        DownloadPreset(rawValue: defaultDownloadPresetRaw) ?? .macCompatibleMP4
    }

    private var selectedConflictPolicy: FilenameConflictPolicy {
        FilenameConflictPolicy(rawValue: defaultFilenameConflictPolicyRaw) ?? .autoRename
    }

    private var mergeBehavior: MergeBehavior {
        MergeBehavior(rawValue: mergeBehaviorRaw) ?? .compatibilityPreferred
    }

    private var parsedURLSummary: ParsedURLSummary {
        let lines = urlText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var recognizedURLs: [String] = []
        var invalidCount = 0

        for line in lines {
            let detectedURLs = detectHTTPURLs(in: line)
            guard !detectedURLs.isEmpty else {
                invalidCount += 1
                continue
            }
            recognizedURLs.append(contentsOf: detectedURLs)
        }

        var seen = Set<String>()
        var valid: [String] = []
        var duplicateCount = 0

        for url in recognizedURLs {
            if seen.insert(url).inserted {
                valid.append(url)
            } else {
                duplicateCount += 1
            }
        }

        return ParsedURLSummary(
            deduplicatedValidURLs: valid,
            invalidCount: invalidCount,
            duplicateCount: duplicateCount
        )
    }

    private var runningTaskCount: Int {
        taskItems.filter { $0.manager.isDownloading }.count
    }

    private var allDownloadTargetsCanAttemptDirectCapture: Bool {
        let urls = parsedURLSummary.deduplicatedValidURLs
        return !urls.isEmpty && urls.allSatisfy(isLikelyDirectStreamCaptureCandidate)
    }

    private var downloadToolsReady: Bool {
        if allDownloadTargetsCanAttemptDirectCapture {
            return toolManager.status.ffmpeg.isInstalled
        }
        return toolManager.status.allRequiredInstalled
    }

    private var canStartDownloads: Bool {
        !parsedURLSummary.deduplicatedValidURLs.isEmpty
            && selectedOutputDirectory != nil
            && downloadToolsReady
            && !isPreparingDownloads
    }

    private var canStartMerge: Bool {
        videoMergeManager.canStart
            && selectedOutputDirectory != nil
            && toolManager.status.ffmpeg.isInstalled
    }

    private var canStartConversion: Bool {
        fileConversionManager.canStart
            && selectedOutputDirectory != nil
            && toolManager.status.ffmpeg.isInstalled
            && availableConversionOutputFormats.contains(conversionOutputFormat)
    }

    private var canStartSubtitleVideo: Bool {
        subtitleVideoManager.canStart
            && selectedOutputDirectory != nil
            && toolManager.status.ffmpeg.isInstalled
    }

    private var conversionMediaKind: ConversionMediaKind? {
        guard let inputFileURL = fileConversionManager.inputFileURL else { return nil }
        if Self.supportedAudioConversionInputExtensions.contains(inputFileURL.pathExtension.lowercased()) {
            return .audio
        }
        if Self.supportedVideoConversionInputExtensions.contains(inputFileURL.pathExtension.lowercased()) {
            return .video
        }
        return nil
    }

    private var availableConversionOutputFormats: [ConversionOutputFormat] {
        switch conversionMediaKind {
        case .audio:
            return ConversionOutputFormat.audioFormats
        case .video:
            return ConversionOutputFormat.videoFormats + ConversionOutputFormat.audioFormats
        case nil:
            return ConversionOutputFormat.videoFormats + ConversionOutputFormat.audioFormats
        }
    }

    private var conversionOutputExtension: String {
        conversionOutputFormat.fileExtension
    }

    private var mergeOutputExtension: String {
        videoMergeManager.preferredOutputExtension
    }

    private static let supportedAudioConversionInputExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif",
        "flac", "ogg", "opus", "alac", "wma", "caf"
    ]

    private static let supportedVideoConversionInputExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi",
        "ts", "mts", "m2ts", "wmv", "flv"
    ]

    private var subtitlePreviewText: String {
        guard let subtitleURL = subtitleVideoManager.subtitleFileURL else {
            return "자막 미리보기"
        }

        return loadSubtitlePreviewText(from: subtitleURL) ?? "자막 내용을 읽지 못했습니다."
    }

    private func subtitlePreviewHeight(availableSize: CGSize?) -> CGFloat {
        guard let availableSize else { return 220 }

        let aspectRatio = 16.0 / 9.0
        let fixedContentHeight: CGFloat = 350
        let groupBoxHorizontalChrome: CGFloat = 44
        let verticalHeight = max(84, availableSize.height - fixedContentHeight)
        let widthLimitedHeight = max(84, (availableSize.width - groupBoxHorizontalChrome) / aspectRatio)
        return min(verticalHeight, widthLimitedHeight)
    }

    private func subtitlePreviewSize(containerSize: CGSize, maxHeight: CGFloat) -> CGSize {
        let aspectRatio = 16.0 / 9.0
        let width = max(containerSize.width, 0)
        let height = min(maxHeight, width / aspectRatio)
        return CGSize(width: height * aspectRatio, height: height)
    }

    private func scaledSubtitlePreviewFontSize(previewHeight: CGFloat, metrics: SubtitlePreviewMetrics) -> CGFloat {
        let playResY = max(metrics.playResY, 1)
        let renderedSize = CGFloat(subtitlePreviewFontSize) * previewHeight / playResY
        return max(5, renderedSize)
    }

    private func subtitlePreviewBottomPadding(
        previewHeight: CGFloat,
        fontSize: CGFloat,
        metrics: SubtitlePreviewMetrics
    ) -> CGFloat {
        let playResY = max(metrics.playResY, 1)
        let scaledMargin = metrics.marginV * previewHeight / playResY
        return max(4, scaledMargin + (fontSize * 0.15))
    }

    private func subtitlePreviewOutlineSize(previewHeight: CGFloat, metrics: SubtitlePreviewMetrics) -> CGFloat {
        let playResY = max(metrics.playResY, 1)
        return max(0.5, min(2, previewHeight / playResY))
    }

    private func subtitlePreviewMetrics(for subtitleURL: URL?) -> SubtitlePreviewMetrics {
        guard let subtitleURL,
              ["ass", "ssa"].contains(subtitleURL.pathExtension.lowercased()),
              let data = try? Data(contentsOf: subtitleURL),
              let rawText =
                String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .unicode) ??
                String(data: data, encoding: .utf16) ??
                String(data: data, encoding: .utf16LittleEndian) ??
                String(data: data, encoding: .utf16BigEndian)
        else {
            return defaultSubtitlePreviewMetrics
        }

        return parseASSPreviewMetrics(rawText) ?? defaultSubtitlePreviewMetrics
    }

    private func parseASSPreviewMetrics(_ rawText: String) -> SubtitlePreviewMetrics? {
        var playResY: CGFloat?
        var styleFields: [String] = []
        var defaultStyleMarginV: CGFloat?
        var firstStyleMarginV: CGFloat?

        for rawLine in rawText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = line.lowercased()

            if lowercasedLine.hasPrefix("playresy:") {
                let value = line.dropFirst("PlayResY:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = Double(value), parsed > 0 {
                    playResY = CGFloat(parsed)
                }
                continue
            }

            if lowercasedLine.hasPrefix("format:") {
                styleFields = line.dropFirst("Format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }

            guard lowercasedLine.hasPrefix("style:"),
                  !styleFields.isEmpty,
                  let marginIndex = styleFields.firstIndex(of: "marginv")
            else {
                continue
            }

            let values = line.dropFirst("Style:".count)
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard values.indices.contains(marginIndex),
                  let marginValue = Double(values[marginIndex])
            else {
                continue
            }

            let parsedMargin = CGFloat(max(marginValue, 0))
            if firstStyleMarginV == nil {
                firstStyleMarginV = parsedMargin
            }

            if let nameIndex = styleFields.firstIndex(of: "name"),
               values.indices.contains(nameIndex),
               values[nameIndex].caseInsensitiveCompare("Default") == .orderedSame {
                defaultStyleMarginV = parsedMargin
            }
        }

        guard playResY != nil || defaultStyleMarginV != nil || firstStyleMarginV != nil else {
            return nil
        }

        return SubtitlePreviewMetrics(
            playResY: playResY ?? defaultSubtitlePreviewMetrics.playResY,
            marginV: defaultStyleMarginV ?? firstStyleMarginV ?? defaultSubtitlePreviewMetrics.marginV
        )
    }

    private var defaultDownloadFilenameTemplate: String {
        "%(title)s.%(ext)s"
    }

    private var collisionSafeDownloadFilenameTemplate: String {
        "%(title)s [%(id)s].%(ext)s"
    }

    var body: some View {
        Group {
            if selectedTab == .subtitleVideo {
                GeometryReader { geometry in
                    mainContent(availableSize: geometry.size)
                }
            } else {
                ScrollView {
                    mainContent(availableSize: nil)
                }
            }
        }
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            configureDefaultOutputDirectory()
        }
        .onChange(of: videoMergeManager.selectedFiles.map(\.path)) { _ in
            syncMergeOutputNameIfNeeded()
        }
        .onChange(of: fileConversionManager.inputFileURL?.path) { _ in
            syncConversionOutputNameIfNeeded()
            syncConversionOutputFormatIfNeeded()
        }
        .onChange(of: subtitleVideoManager.mediaFileURL?.path) { _ in
            syncSubtitleVideoOutputNameIfNeeded()
        }
        .alert("안내", isPresented: $showAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $isSettingsPresented) {
            ToolsView()
                .environmentObject(toolManager)
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    @ViewBuilder
    private func mainContent(availableSize: CGSize?) -> some View {
        let subtitleAvailableSize = availableSize.map {
            CGSize(width: max($0.width - 20, 0), height: max($0.height - 16, 0))
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("기능", selection: $selectedTab) {
                    ForEach(MainContentTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }

            if selectedTab == .download {
                downloadTabContent
            } else if selectedTab == .merge {
                mergeTabContent
            } else if selectedTab == .convert {
                conversionTabContent
            } else {
                subtitleVideoTabContent(availableSize: subtitleAvailableSize)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var outputFolderSection: some View {
        GroupBox("저장 폴더") {
            HStack(spacing: 8) {
                Text(selectedOutputDirectory?.path ?? "폴더를 선택해 주세요")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .textSelection(.enabled)

                Spacer()

                Button("폴더 선택") {
                    selectOutputFolder()
                }
                .instantHelp("다운로드, 병합, 변환, 자막 영상 파일을 저장할 폴더를 선택합니다.")
            }
        }
    }

    @ViewBuilder
    private var downloadTabContent: some View {
        let urlInputHelp = "여러 개를 한 번에 시작하려면 URL을 한 줄씩 입력하세요. IINA 같은 플레이어에서 주소로 열 수 있는 스트리밍 URL도 지원합니다."

        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $urlText)
                    .font(.callout)
                    .frame(minHeight: 96, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                    )
                    .instantHelp(urlInputHelp)

                HStack(spacing: 8) {
                    Text("인식된 URL: \(parsedURLSummary.deduplicatedValidURLs.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if parsedURLSummary.invalidCount > 0 {
                        Text("잘못된 형식: \(parsedURLSummary.invalidCount)개")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if parsedURLSummary.duplicateCount > 0 {
                        Text("중복 제외: \(parsedURLSummary.duplicateCount)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(isPreparingDownloads ? "준비 중..." : "일괄 다운로드 시작") {
                        startDownloads()
                    }
                    .disabled(!canStartDownloads)
                    .instantHelp("입력한 URL을 확인한 뒤 다운로드 작업을 한 번에 시작합니다.")
                }
            }
        } label: {
            Text("동영상 URL (YouTube / m3u8 / 스트리밍)")
                .instantHelp(urlInputHelp)
        }

        outputFolderSection

        if !downloadToolsReady {
            Text(allDownloadTargetsCanAttemptDirectCapture ? "직접 스트리밍 녹화는 ffmpeg가 필요합니다." : "다운로드는 yt-dlp와 ffmpeg가 필요합니다.")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        HStack(spacing: 8) {
            Text("진행 중: \(runningTaskCount) / 전체: \(taskItems.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if runningTaskCount > 0 {
                Button("전체 중지") {
                    cancelAllRunningTasks()
                }
                .instantHelp("진행 중인 모든 다운로드 작업을 중지합니다.")
            }
        }

        Text("기본 설정: \(selectedPreset.title) · \(selectedConflictPolicy.title)")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if taskItems.isEmpty {
            Text("다운로드 작업이 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else {
            GroupBox("다운로드 작업") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(taskItems) { item in
                            DownloadTaskRow(
                                task: item,
                                onRemove: { removeTask(item) }
                            )

                            if item.id != taskItems.last?.id {
                                Divider()
                            }
                        }

                        HStack {
                            Spacer()
                            Button("완료/실패 작업 정리") {
                                cleanupFinishedTasks()
                            }
                            .disabled(taskItems.isEmpty)
                            .instantHelp("완료되었거나 실패한 다운로드 작업만 목록에서 제거합니다.")
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: 200)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var mergeTabContent: some View {
        let mergeDropHelp = "Finder에서 영상 파일을 드래그해 추가하세요. 출력 형식은 첫 번째 파일 기준으로 맞춥니다."

        outputFolderSection

        if !toolManager.status.ffmpeg.isInstalled {
            Text("영상 붙이기는 ffmpeg만 있으면 됩니다. 설정에서 ffmpeg 설치 상태를 확인해 주세요.")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("병합 모드", selection: $mergeBehaviorRaw) {
                    ForEach(MergeBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .instantHelp("재인코딩 우선 또는 무손실 병합 우선 등 병합 방식을 선택합니다. \(mergeBehavior.shortDescription)")

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if videoMergeManager.selectedFiles.isEmpty {
                            Text("여기에 영상 파일을 드래그")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(videoMergeManager.selectedFiles.enumerated()), id: \.element) { index, fileURL in
                                HStack(spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(fileURL.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)

                                    Spacer()

                                    if !videoMergeManager.isMerging {
                                        Button("제거", role: .destructive) {
                                            videoMergeManager.removeFile(fileURL)
                                        }
                                        .font(.callout)
                                        .instantHelp("이 파일을 병합 목록에서 제거합니다.")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 240, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isMergeDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isMergeDropTargeted ? Color.accentColor : Color.secondary.opacity(0.24),
                            style: StrokeStyle(lineWidth: 1, dash: isMergeDropTargeted ? [4, 4] : [])
                        )
                )
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isMergeDropTargeted) { providers in
                    handleVideoDrop(providers: providers)
                }
                .instantHelp(mergeDropHelp)

                HStack(spacing: 8) {
                    Text("선택된 파일: \(videoMergeManager.selectedFiles.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("출력 형식: .\(mergeOutputExtension)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("파일 선택") {
                        selectMergeFiles()
                    }
                    .disabled(videoMergeManager.isMerging)
                    .instantHelp("Finder에서 병합할 영상 파일을 선택합니다.")

                    Button("비우기") {
                        videoMergeManager.clearFiles()
                    }
                    .disabled(videoMergeManager.selectedFiles.isEmpty || videoMergeManager.isMerging)
                    .instantHelp("현재 병합 목록을 모두 비웁니다.")

                    Spacer()

                    if videoMergeManager.isMerging {
                        Button("중지") {
                            videoMergeManager.cancel()
                        }
                        .instantHelp("진행 중인 영상 병합을 중지합니다.")
                    }

                    Button("영상 합치기") {
                        startVideoMerge()
                    }
                    .disabled(!canStartMerge)
                    .instantHelp("선택한 영상들을 현재 병합 모드로 하나의 파일로 만듭니다.")
                }

                HStack(spacing: 8) {
                    Text("파일 이름")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .instantHelp("확장자를 제외한 병합 결과 파일 이름입니다.")

                    TextField("병합 파일 이름", text: $mergeOutputName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(videoMergeManager.isMerging)

                    Text(".\(mergeOutputExtension)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: videoMergeManager.progress, total: 1)

                Text(videoMergeManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let message = videoMergeManager.userMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(videoMergeManager.outputFileURL == nil ? .red : .secondary)
                        .lineLimit(2)
                }

                if let outputFileURL = videoMergeManager.outputFileURL {
                    HStack(spacing: 8) {
                        Text(outputFileURL.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button("폴더 열기") {
                            NSWorkspace.shared.open(outputFileURL.deletingLastPathComponent())
                        }
                        .instantHelp("생성된 병합 파일이 있는 폴더를 Finder에서 엽니다.")
                    }
                }
            }
        } label: {
            Text("영상 이어붙이기")
                .instantHelp(mergeDropHelp)
        }
    }

    @ViewBuilder
    private var conversionTabContent: some View {
        let conversionDropHelp = "Finder에서 음성 또는 영상 파일을 드래그해 추가하세요. ffmpeg로 변환 가능한 일반 파일 형식을 지원합니다."

        outputFolderSection

        if !toolManager.status.ffmpeg.isInstalled {
            Text("파일 변환은 ffmpeg가 필요합니다. 설정에서 ffmpeg 설치 상태를 확인해 주세요.")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("입력 파일")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .instantHelp(conversionDropHelp)

                        Spacer()

                        if fileConversionManager.inputFileURL != nil && !fileConversionManager.isConverting {
                            Button("제거", role: .destructive) {
                                fileConversionManager.clearInputFile()
                            }
                            .instantHelp("선택된 변환 입력 파일을 해제합니다.")
                        }

                        Button("선택") {
                            selectConversionInputFile()
                        }
                        .disabled(fileConversionManager.isConverting)
                        .instantHelp("변환할 음성 또는 영상 파일을 선택합니다.")
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(isConversionDropTargeted ? 0.14 : 0.08))

                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.title2)
                                .foregroundStyle(isConversionDropTargeted ? Color.accentColor : Color.secondary)

                            Text(fileConversionManager.inputFileURL?.lastPathComponent ?? "여기에 음성/영상 파일을 드래그")
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            if fileConversionManager.inputFileURL != nil {
                                Text(fileConversionManager.inputFileURL?.path ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                Color.accentColor.opacity(isConversionDropTargeted ? 0.75 : 0.22),
                                style: StrokeStyle(lineWidth: 1, dash: isConversionDropTargeted ? [4, 4] : [])
                            )
                    )
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        isTargeted: $isConversionDropTargeted
                    ) { providers in
                        handleConversionDrop(providers: providers)
                    }
                    .instantHelp(conversionDropHelp)
                }

                HStack(spacing: 8) {
                    Text("출력 형식")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                        .instantHelp("영상 파일은 영상 또는 음성 형식으로, 음성 파일은 음성 형식으로 변환합니다.")

                    Picker("출력 형식", selection: $conversionOutputFormat) {
                        if availableConversionOutputFormats.contains(where: \.isVideo) {
                            Section("영상") {
                                ForEach(ConversionOutputFormat.videoFormats.filter { availableConversionOutputFormats.contains($0) }) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                        }

                        Section("음성") {
                            ForEach(ConversionOutputFormat.audioFormats.filter { availableConversionOutputFormats.contains($0) }) { format in
                                Text(format.title).tag(format)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(fileConversionManager.isConverting)
                    .instantHelp("터미널에서 ffmpeg로 변환할 때 쓰는 일반 출력 컨테이너/코덱 조합으로 저장합니다.")

                    Text(conversionOutputFormat.isVideo ? "영상 출력" : "음성 출력")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("파일 이름")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                        .instantHelp("확장자를 제외한 변환 결과 파일 이름입니다.")

                    TextField("출력 파일 이름", text: $conversionOutputName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(fileConversionManager.isConverting)

                    Text(".\(conversionOutputExtension)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Spacer()

                    if fileConversionManager.isConverting {
                        Button("중지") {
                            fileConversionManager.cancel()
                        }
                        .instantHelp("진행 중인 파일 변환을 중지합니다.")
                    }

                    Button("변환 시작") {
                        startFileConversion()
                    }
                    .disabled(!canStartConversion)
                    .instantHelp("선택한 파일을 지정한 출력 형식으로 변환합니다.")
                }

                ProgressView(value: fileConversionManager.progress, total: 1)

                Text(fileConversionManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let message = fileConversionManager.userMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(fileConversionManager.outputFileURL == nil ? .red : .secondary)
                        .lineLimit(2)
                }

                if let outputFileURL = fileConversionManager.outputFileURL {
                    HStack(spacing: 8) {
                        Text(outputFileURL.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button("폴더 열기") {
                            NSWorkspace.shared.open(outputFileURL.deletingLastPathComponent())
                        }
                        .instantHelp("생성된 변환 파일이 있는 폴더를 Finder에서 엽니다.")
                    }
                }
            }
        } label: {
            Text("파일 형식 변환")
                .instantHelp(conversionDropHelp)
        }
    }

    @ViewBuilder
    private func subtitleVideoTabContent(availableSize: CGSize?) -> some View {
        let previewHeight = subtitlePreviewHeight(availableSize: availableSize)
        let previewMetrics = subtitlePreviewMetrics(for: subtitleVideoManager.subtitleFileURL)
        let subtitleModeHelp = "영상 파일은 원본 화면에 자막을 입히고, 음성 파일은 기존처럼 1280x720 검은 화면 자막 MP4로 만듭니다."
        let subtitleDropHelp = "음성/영상 파일과 자막 파일을 함께 드래그하면 확장자로 자동 분류합니다."

        outputFolderSection

        if !toolManager.status.ffmpeg.isInstalled {
            Text("자막 영상 만들기는 ffmpeg만 있으면 됩니다. 설정에서 ffmpeg 설치 상태를 확인해 주세요.")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("파일 자동 분류")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .instantHelp(subtitleDropHelp)

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Text("음성/영상")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                            .instantHelp("영상 파일은 원본 화면에 자막을 입히고, 음성 파일은 검은 화면 자막 영상으로 만듭니다.")

                        Text(subtitleVideoManager.mediaFileURL?.lastPathComponent ?? "미선택")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        if subtitleVideoManager.mediaFileURL != nil && !subtitleVideoManager.isRendering {
                            Button("제거", role: .destructive) {
                                subtitleVideoManager.clearMediaFile()
                            }
                            .instantHelp("선택된 음성/영상 파일을 해제합니다.")
                        }

                        Button("선택") {
                            selectSubtitleVideoMediaFile()
                        }
                        .disabled(subtitleVideoManager.isRendering)
                        .instantHelp("자막을 입힐 음성 또는 영상 파일을 선택합니다.")
                    }

                    HStack(spacing: 8) {
                        Text("자막")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                            .instantHelp("srt, ass, ssa, vtt 자막 파일을 사용할 수 있습니다.")

                        Text(subtitleVideoManager.subtitleFileURL?.lastPathComponent ?? "미선택 (srt/ass/ssa/vtt)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        if subtitleVideoManager.subtitleFileURL != nil && !subtitleVideoManager.isRendering {
                            Button("제거", role: .destructive) {
                                subtitleVideoManager.clearSubtitleFile()
                            }
                            .instantHelp("선택된 자막 파일을 해제합니다.")
                        }

                        Button("선택") {
                            selectSubtitleVideoSubtitleFile()
                        }
                        .disabled(subtitleVideoManager.isRendering)
                        .instantHelp("영상에 하드코딩할 자막 파일을 선택합니다.")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(isSubtitleDropTargeted ? 0.14 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            Color.accentColor.opacity(isSubtitleDropTargeted ? 0.75 : 0.22),
                            style: StrokeStyle(lineWidth: 1, dash: isSubtitleDropTargeted ? [4, 4] : [])
                        )
                )
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: $isSubtitleDropTargeted
                ) { providers in
                    handleSubtitleMediaDrop(providers: providers)
                }
                .instantHelp("\(subtitleDropHelp) \(subtitleModeHelp)")

                HStack(spacing: 8) {
                    Text("파일 이름")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .instantHelp("확장자를 제외한 자막 영상 결과 파일 이름입니다.")

                    TextField("출력 파일 이름", text: $subtitleVideoOutputName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(subtitleVideoManager.isRendering)

                    Text(".mp4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("자막 크기")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .instantHelp("ffmpeg 자막 스타일의 FontSize 값입니다. 미리보기는 실제 출력 기준에 맞춰 축소 표시됩니다.")

                    Slider(value: $subtitlePreviewFontSize, in: 10...36, step: 1)
                        .disabled(subtitleVideoManager.isRendering)

                    Text("\(Int(subtitlePreviewFontSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("미리보기")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .instantHelp("현재 자막 크기와 위치를 실제 출력 비율에 맞춰 보여줍니다.")

                    GeometryReader { geometry in
                        let previewSize = subtitlePreviewSize(
                            containerSize: geometry.size,
                            maxHeight: previewHeight
                        )
                        let renderedFontSize = scaledSubtitlePreviewFontSize(
                            previewHeight: previewSize.height,
                            metrics: previewMetrics
                        )
                        let bottomPadding = subtitlePreviewBottomPadding(
                            previewHeight: previewSize.height,
                            fontSize: renderedFontSize,
                            metrics: previewMetrics
                        )
                        let outlineSize = subtitlePreviewOutlineSize(
                            previewHeight: previewSize.height,
                            metrics: previewMetrics
                        )

                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black)

                            Text(subtitlePreviewText)
                                .font(.custom("Arial", size: renderedFontSize))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, min(24, previewSize.width * 0.08))
                                .padding(.bottom, bottomPadding)
                                .shadow(color: .black.opacity(0.95), radius: 0, x: outlineSize, y: 0)
                                .shadow(color: .black.opacity(0.95), radius: 0, x: -outlineSize, y: 0)
                                .shadow(color: .black.opacity(0.95), radius: 0, x: 0, y: outlineSize)
                                .shadow(color: .black.opacity(0.95), radius: 0, x: 0, y: -outlineSize)
                        }
                        .frame(width: previewSize.width, height: previewSize.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                .frame(width: previewSize.width, height: previewSize.height)
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                }

                HStack(spacing: 8) {
                    Spacer()

                    if subtitleVideoManager.isRendering {
                        Button("중지") {
                            subtitleVideoManager.cancel()
                        }
                        .instantHelp("진행 중인 자막 영상 생성을 중지합니다.")
                    }

                    Button("영상 만들기") {
                        startSubtitleVideoRender()
                    }
                    .disabled(!canStartSubtitleVideo)
                    .instantHelp("선택한 음성/영상과 자막을 사용해 하드자막 MP4를 생성합니다. \(subtitleModeHelp)")
                }

                ProgressView(value: subtitleVideoManager.progress, total: 1)

                Text(subtitleVideoManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let message = subtitleVideoManager.userMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(subtitleVideoManager.outputFileURL == nil ? .red : .secondary)
                        .lineLimit(2)
                }

                if let outputFileURL = subtitleVideoManager.outputFileURL {
                    HStack(spacing: 8) {
                        Text(outputFileURL.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button("폴더 열기") {
                            NSWorkspace.shared.open(outputFileURL.deletingLastPathComponent())
                        }
                        .instantHelp("생성된 파일이 있는 폴더를 Finder에서 엽니다.")
                    }
                }
            }
        } label: {
            Text("자막 하드코딩 영상")
                .instantHelp(subtitleModeHelp)
        }
    }

    private func detectHTTPURLs(in value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        var urls: [String] = []

        detector.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                return
            }
            urls.append(url.absoluteString)
        }

        return urls
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "다운로드 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            selectedOutputDirectory = url
            defaultOutputDirectoryPath = url.path
        }
    }

    private func selectMergeFiles() {
        let panel = NSOpenPanel()
        panel.title = "합칠 영상 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            videoMergeManager.addFiles(panel.urls)
        }
    }

    private func selectConversionInputFile() {
        let panel = NSOpenPanel()
        panel.title = "변환할 음성/영상 파일 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            guard isSupportedConversionInputFile(url) else {
                fileConversionManager.userMessage = "지원하는 음성/영상 파일을 선택해 주세요."
                return
            }
            fileConversionManager.setInputFile(url)
        }
    }

    private func selectSubtitleVideoMediaFile() {
        let panel = NSOpenPanel()
        panel.title = "음성/영상 파일 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            subtitleVideoManager.setMediaFile(url)
        }
    }

    private func selectSubtitleVideoSubtitleFile() {
        let panel = NSOpenPanel()
        panel.title = "자막 파일 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            subtitleVideoManager.setSubtitleFile(url)
        }
    }

    private func configureDefaultOutputDirectory() {
        if !defaultOutputDirectoryPath.isEmpty {
            let savedURL = URL(fileURLWithPath: defaultOutputDirectoryPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                selectedOutputDirectory = savedURL
                return
            }
        }

        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            selectedOutputDirectory = downloads
            defaultOutputDirectoryPath = downloads.path
        }
    }

    private func handleVideoDrop(providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in validProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let string = item as? String {
                    resolvedURL = URL(string: string)
                } else {
                    resolvedURL = nil
                }

                guard let resolvedURL, resolvedURL.isFileURL else { return }
                lock.lock()
                droppedURLs.append(resolvedURL)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            self.videoMergeManager.addFiles(droppedURLs)
        }

        return true
    }

    private func handleConversionDrop(providers: [NSItemProvider]) -> Bool {
        guard !fileConversionManager.isConverting else { return false }

        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in validProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                guard let resolvedURL = resolvedFileURL(from: item), resolvedURL.isFileURL else {
                    return
                }

                lock.lock()
                droppedURLs.append(resolvedURL.standardizedFileURL)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            applyDroppedConversionFiles(droppedURLs)
        }

        return true
    }

    private func handleSubtitleMediaDrop(providers: [NSItemProvider]) -> Bool {
        guard !subtitleVideoManager.isRendering else { return false }

        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in validProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                guard let resolvedURL = resolvedFileURL(from: item), resolvedURL.isFileURL else {
                    return
                }

                lock.lock()
                droppedURLs.append(resolvedURL.standardizedFileURL)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            applyDroppedSubtitleMediaFiles(droppedURLs)
        }

        return true
    }

    private func applyDroppedConversionFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        if let selectedFile = urls.first(where: isSupportedConversionInputFile) {
            fileConversionManager.setInputFile(selectedFile)
            let skippedCount = urls.filter { !isSupportedConversionInputFile($0) }.count
            if skippedCount > 0 {
                fileConversionManager.userMessage = "지원하지 않는 파일 \(skippedCount)개는 건너뛰었습니다."
            }
        } else {
            fileConversionManager.userMessage = "지원하는 음성/영상 파일을 찾지 못했습니다."
        }
    }

    private func applyDroppedSubtitleMediaFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var selectedMediaURL: URL?
        var selectedSubtitleURL: URL?
        var unsupportedCount = 0

        for url in urls {
            if isSupportedSubtitleFile(url) {
                selectedSubtitleURL = url
            } else if isSupportedSubtitleMediaFile(url) {
                selectedMediaURL = url
            } else {
                unsupportedCount += 1
            }
        }

        if let selectedMediaURL {
            subtitleVideoManager.setMediaFile(selectedMediaURL)
        }

        if let selectedSubtitleURL {
            subtitleVideoManager.setSubtitleFile(selectedSubtitleURL)
        }

        if selectedMediaURL == nil && selectedSubtitleURL == nil {
            subtitleVideoManager.userMessage = "지원하는 음성/영상 또는 자막 파일을 찾지 못했습니다."
        } else if unsupportedCount > 0 {
            subtitleVideoManager.userMessage = "지원하지 않는 파일 \(unsupportedCount)개는 건너뛰었습니다."
        }
    }

    private func resolvedFileURL(from item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let url = item as? URL {
            return url
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }

    private func isSupportedConversionInputFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return Self.supportedAudioConversionInputExtensions.contains(fileExtension)
            || Self.supportedVideoConversionInputExtensions.contains(fileExtension)
    }

    private func isSupportedSubtitleMediaFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "mp3", "m4a", "aac", "wav", "aiff", "aif",
            "flac", "ogg", "opus", "alac", "wma", "caf",
            "mp4", "mov", "m4v", "mkv", "webm", "avi",
            "ts", "mts", "m2ts"
        ]

        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSupportedSubtitleFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func startDownloads() {
        guard downloadToolsReady else {
            showAlert(message: allDownloadTargetsCanAttemptDirectCapture ? "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요." : "yt-dlp/ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
            return
        }

        guard let ffmpegPath = toolManager.status.ffmpeg.path else {
            showAlert(message: "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
            return
        }
        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)
        let ffprobeURL = toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) }
        let ytDlpURL = toolManager.status.ytDlp.path.map { URL(fileURLWithPath: $0) }

        if !allDownloadTargetsCanAttemptDirectCapture && ytDlpURL == nil {
            showAlert(message: "yt-dlp/ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
            return
        }

        let toolPaths = ToolPaths(
            ytDlpPath: ytDlpURL ?? ffmpegURL,
            ffmpegPath: ffmpegURL,
            ffprobePath: ffprobeURL
        )

        guard let outputDir = selectedOutputDirectory else {
            showAlert(message: "저장 폴더를 먼저 선택해 주세요.")
            return
        }

        let targets = parsedURLSummary.deduplicatedValidURLs
        guard !targets.isEmpty else {
            showAlert(message: "유효한 URL을 한 줄에 하나씩 입력해 주세요.")
            return
        }

        let options = DownloadOptions(
            preset: selectedPreset,
            conflictPolicy: selectedConflictPolicy,
            filenameTemplate: defaultDownloadFilenameTemplate,
            forceDirectStreamCapture: false,
            hlsAutoReconnectEnabled: hlsAutoReconnectEnabled,
            hlsReconnectFailTimeoutSeconds: min(max(hlsReconnectFailTimeoutSeconds, 15), 1800)
        )

        isPreparingDownloads = true

        DispatchQueue.global(qos: .userInitiated).async {
            let buildResult = self.buildDownloadPlans(
                targets: targets,
                ytDlpURL: ytDlpURL,
                ffmpegURL: ffmpegURL,
                ffprobeURL: ffprobeURL,
                baseOptions: options
            )

            DispatchQueue.main.async {
                self.isPreparingDownloads = false

                guard !buildResult.plans.isEmpty else {
                    self.showAlert(message: "직접 녹화 가능한 스트림을 찾지 못했습니다. 이 주소는 yt-dlp가 필요하거나 현재 지원되지 않을 수 있습니다.")
                    return
                }

                let newTasks = buildResult.plans.map { DownloadTaskItem(url: $0.url) }
                self.taskItems.append(contentsOf: newTasks)

                for (task, plan) in zip(newTasks, buildResult.plans) {
                    task.manager.startDownload(
                        url: plan.url,
                        outputDir: outputDir,
                        toolPaths: toolPaths,
                        options: plan.options
                    )
                }

                var parts: [String] = []
                if self.parsedURLSummary.invalidCount > 0 {
                    parts.append("잘못된 형식 \(self.parsedURLSummary.invalidCount)개 제외")
                }
                if self.parsedURLSummary.duplicateCount > 0 {
                    parts.append("중복 \(self.parsedURLSummary.duplicateCount)개 제외")
                }
                if buildResult.skippedCount > 0 {
                    parts.append("직접 녹화 불가 또는 yt-dlp 필요 \(buildResult.skippedCount)개 제외")
                }
                parts.append("\(buildResult.plans.count)개 다운로드 시작")

                if self.parsedURLSummary.invalidCount > 0
                    || self.parsedURLSummary.duplicateCount > 0
                    || buildResult.skippedCount > 0 {
                    self.showAlert(message: parts.joined(separator: ", "))
                } else {
                    self.urlText = ""
                }
            }
        }
    }

    private func startVideoMerge() {
        guard let ffmpegPath = toolManager.status.ffmpeg.path
        else {
            showAlert(message: "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 상태를 확인해 주세요.")
            return
        }

        guard let outputDirectory = selectedOutputDirectory else {
            showAlert(message: "저장 폴더를 먼저 선택해 주세요.")
            return
        }

        videoMergeManager.startMerge(
            outputDirectory: outputDirectory,
            ffmpegURL: URL(fileURLWithPath: ffmpegPath),
            ffprobeURL: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) },
            outputBaseName: mergeOutputName,
            behavior: mergeBehavior
        )
    }

    private func startFileConversion() {
        guard let ffmpegPath = toolManager.status.ffmpeg.path else {
            showAlert(message: "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 상태를 확인해 주세요.")
            return
        }

        guard let outputDirectory = selectedOutputDirectory else {
            showAlert(message: "저장 폴더를 먼저 선택해 주세요.")
            return
        }

        guard availableConversionOutputFormats.contains(conversionOutputFormat) else {
            showAlert(message: "선택한 입력 파일에 맞는 출력 형식을 선택해 주세요.")
            return
        }

        fileConversionManager.startConversion(
            outputDirectory: outputDirectory,
            ffmpegURL: URL(fileURLWithPath: ffmpegPath),
            ffprobeURL: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) },
            outputBaseName: conversionOutputName,
            outputFormat: conversionOutputFormat
        )
    }

    private func startSubtitleVideoRender() {
        guard let ffmpegPath = toolManager.status.ffmpeg.path else {
            showAlert(message: "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 상태를 확인해 주세요.")
            return
        }

        guard let outputDirectory = selectedOutputDirectory else {
            showAlert(message: "저장 폴더를 먼저 선택해 주세요.")
            return
        }

        subtitleVideoManager.startRender(
            outputDirectory: outputDirectory,
            ffmpegURL: URL(fileURLWithPath: ffmpegPath),
            ffprobeURL: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) },
            outputBaseName: subtitleVideoOutputName,
            subtitleFontSize: subtitlePreviewFontSize
        )
    }

    private func syncMergeOutputNameIfNeeded() {
        if videoMergeManager.selectedFiles.isEmpty {
            mergeOutputName = ""
            return
        }

        guard mergeOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let firstFile = videoMergeManager.selectedFiles.first
        else {
            return
        }

        mergeOutputName = "\(firstFile.deletingPathExtension().lastPathComponent)-merged"
    }

    private func syncConversionOutputNameIfNeeded() {
        guard let inputFileURL = fileConversionManager.inputFileURL else {
            conversionOutputName = ""
            return
        }

        guard conversionOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        conversionOutputName = "\(inputFileURL.deletingPathExtension().lastPathComponent)-converted"
    }

    private func syncConversionOutputFormatIfNeeded() {
        let formats = availableConversionOutputFormats
        guard !formats.contains(conversionOutputFormat),
              let fallbackFormat = formats.first
        else {
            return
        }

        conversionOutputFormat = fallbackFormat
    }

    private func syncSubtitleVideoOutputNameIfNeeded() {
        guard subtitleVideoOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mediaFileURL = subtitleVideoManager.mediaFileURL else {
            return
        }

        subtitleVideoOutputName = "\(mediaFileURL.deletingPathExtension().lastPathComponent)-subtitle-video"
    }

    private func loadSubtitlePreviewText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let rawText =
            String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .unicode) ??
            String(data: data, encoding: .utf16) ??
            String(data: data, encoding: .utf16LittleEndian) ??
            String(data: data, encoding: .utf16BigEndian)

        guard let rawText else { return nil }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt", "vtt":
            return extractPreviewTextFromLineSubtitles(rawText)
        case "ass", "ssa":
            return extractPreviewTextFromASS(rawText)
        default:
            return nil
        }
    }

    private func extractPreviewTextFromLineSubtitles(_ rawText: String) -> String? {
        let lines = rawText.components(separatedBy: .newlines)
        var collected: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !collected.isEmpty { break }
                continue
            }
            if trimmed == "WEBVTT" { continue }
            if Int(trimmed) != nil { continue }
            if trimmed.contains("-->") { continue }
            collected.append(trimmed)
            if collected.count >= 2 { break }
        }

        let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func extractPreviewTextFromASS(_ rawText: String) -> String? {
        for line in rawText.components(separatedBy: .newlines) {
            guard line.hasPrefix("Dialogue:") else { continue }
            let components = line.components(separatedBy: ",")
            guard components.count >= 10 else { continue }
            let text = components.dropFirst(9).joined(separator: ",")
            let cleaned = text
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\{.*?\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }

    private func cancelAllRunningTasks() {
        for item in taskItems where item.manager.isDownloading {
            item.manager.cancel()
        }
    }

    private func cleanupFinishedTasks() {
        taskItems.removeAll { !$0.manager.isDownloading }
    }

    private func removeTask(_ task: DownloadTaskItem) {
        if task.manager.isDownloading {
            task.manager.cancel()
        }
        taskItems.removeAll { $0.id == task.id }
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    private func buildDownloadPlans(
        targets: [String],
        ytDlpURL: URL?,
        ffmpegURL: URL,
        ffprobeURL: URL?,
        baseOptions: DownloadOptions
    ) -> DownloadPlanBuildResult {
        var identities: [String: YtDlpVideoIdentity] = [:]
        var ytDlpTargets: [String] = []
        var plans: [DownloadLaunchPlan] = []
        var skippedCount = 0

        for url in targets {
            if canRecordWithDirectStreamCapture(
                url: url,
                ffmpegURL: ffmpegURL,
                ffprobeURL: ffprobeURL
            ) {
                plans.append(
                    DownloadLaunchPlan(
                        url: url,
                        options: DownloadOptions(
                            preset: baseOptions.preset,
                            conflictPolicy: baseOptions.conflictPolicy,
                            filenameTemplate: baseOptions.filenameTemplate,
                            forceDirectStreamCapture: true,
                            hlsAutoReconnectEnabled: baseOptions.hlsAutoReconnectEnabled,
                            hlsReconnectFailTimeoutSeconds: baseOptions.hlsReconnectFailTimeoutSeconds
                        )
                    )
                )
                continue
            }

            guard let ytDlpURL else {
                skippedCount += 1
                continue
            }

            ytDlpTargets.append(url)
            identities[url] = fetchYtDlpIdentity(
                url: url,
                ytDlpURL: ytDlpURL
            )
        }

        let failedIdentityLookupExists = ytDlpTargets.contains { identities[$0] == nil }
        let titleCounts = ytDlpTargets.compactMap { identities[$0] }.reduce(into: [String: Int]()) { partialResult, identity in
            partialResult[identity.title, default: 0] += 1
        }

        let ytDlpPlans = ytDlpTargets.map { url in
            let filenameTemplate: String
            if ytDlpTargets.count > 1 && failedIdentityLookupExists {
                filenameTemplate = collisionSafeDownloadFilenameTemplate
            } else if let identity = identities[url],
               titleCounts[identity.title, default: 0] > 1 {
                filenameTemplate = collisionSafeDownloadFilenameTemplate
            } else {
                filenameTemplate = defaultDownloadFilenameTemplate
            }

            return DownloadLaunchPlan(
                url: url,
                options: DownloadOptions(
                    preset: baseOptions.preset,
                    conflictPolicy: baseOptions.conflictPolicy,
                    filenameTemplate: filenameTemplate,
                    forceDirectStreamCapture: false,
                    hlsAutoReconnectEnabled: baseOptions.hlsAutoReconnectEnabled,
                    hlsReconnectFailTimeoutSeconds: baseOptions.hlsReconnectFailTimeoutSeconds
                )
            )
        }

        plans.append(contentsOf: ytDlpPlans)
        let orderedPlans = plans.sorted { lhs, rhs in
            targets.firstIndex(of: lhs.url) ?? Int.max < targets.firstIndex(of: rhs.url) ?? Int.max
        }

        return DownloadPlanBuildResult(
            plans: orderedPlans,
            skippedCount: skippedCount
        )
    }

    private func fetchYtDlpIdentity(url: String, ytDlpURL: URL) -> YtDlpVideoIdentity? {
        guard let result = ProcessRunner.runAndCapture(
            executableURL: ytDlpURL,
            arguments: [
                "--skip-download",
                "--no-warnings",
                "--print", "__TITLE__:%(title)s",
                "--print", "__ID__:%(id)s",
                url
            ]
        ), result.terminationStatus == 0 else {
            return nil
        }

        var title: String?
        var videoID: String?

        for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("__TITLE__:") {
                title = String(line.dropFirst("__TITLE__:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("__ID__:") {
                videoID = String(line.dropFirst("__ID__:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let title, !title.isEmpty,
              let videoID, !videoID.isEmpty else {
            return nil
        }

        return YtDlpVideoIdentity(title: title, videoID: videoID)
    }

    private func isLikelyDirectM3U8URL(_ url: String) -> Bool {
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

    private func isLikelyYouTubeURL(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else {
            return false
        }

        return host == "youtu.be"
            || host == "www.youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
    }

    private func isLikelyDirectStreamCaptureCandidate(_ url: String) -> Bool {
        !isLikelyYouTubeURL(url)
    }

    private func canRecordWithDirectStreamCapture(
        url: String,
        ffmpegURL: URL,
        ffprobeURL: URL?
    ) -> Bool {
        guard isLikelyDirectStreamCaptureCandidate(url) else {
            return false
        }

        if isLikelyDirectM3U8URL(url) {
            return true
        }

        let inputArguments = directStreamProbeInputArguments(for: url)

        if let ffprobeURL,
           let result = ProcessRunner.runAndCapture(
                executableURL: ffprobeURL,
                arguments: inputArguments + [
                    "-v", "error",
                    "-rw_timeout", "5000000",
                    "-show_entries", "stream=codec_type",
                    "-of", "csv=p=0",
                    url
                ]
           ),
           result.terminationStatus == 0 {
            let streamKinds = result.stdout
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            if streamKinds.contains("video") || streamKinds.contains("audio") {
                return true
            }
        }

        guard let ffmpegProbe = ProcessRunner.runAndCapture(
            executableURL: ffmpegURL,
            arguments: inputArguments + [
                "-v", "error",
                "-rw_timeout", "5000000",
                "-i", url,
                "-t", "1",
                "-f", "null",
                "-"
            ]
        ) else {
            return false
        }

        return ffmpegProbe.terminationStatus == 0
    }

    private func directStreamProbeInputArguments(for url: String) -> [String] {
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
              let payload = decodeBase64URLData(String(segments[1])),
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

    private func decodeBase64URLData(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: normalized)
    }
}

private struct DownloadTaskRow: View {
    let task: DownloadTaskItem
    let onRemove: () -> Void

    @ObservedObject private var manager: DownloadManager

    init(task: DownloadTaskItem, onRemove: @escaping () -> Void) {
        self.task = task
        self.onRemove = onRemove
        _manager = ObservedObject(wrappedValue: task.manager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(task.url)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Text(manager.phase.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            HStack(spacing: 8) {
                ProgressView(value: manager.progress, total: 1)

                if manager.isDownloading {
                    Button(manager.isPaused ? "재개" : "일시정지") {
                        manager.togglePause()
                    }
                    .instantHelp(manager.isPaused ? "일시정지한 다운로드를 다시 시작합니다." : "현재 다운로드를 일시정지합니다.")

                    Button("중지") {
                        manager.cancel()
                    }
                    .instantHelp("현재 다운로드 작업을 중지합니다.")
                } else {
                    Button("삭제", role: .destructive) {
                        onRemove()
                    }
                    .instantHelp("이 다운로드 작업을 목록에서 제거합니다.")
                }
            }

            Text(manager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let message = manager.userMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageColor)
                    .lineLimit(2)
            }
        }
    }

    private var phaseColor: Color {
        switch manager.phase {
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .orange
        case .paused:
            return .yellow
        default:
            return .secondary
        }
    }

    private var messageColor: Color {
        switch manager.phase {
        case .failed:
            return .red
        case .canceled:
            return .orange
        default:
            return .secondary
        }
    }
}
