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
}

private enum MainContentTab: String, CaseIterable, Identifiable {
    case download = "다운로드"
    case merge = "영상 붙이기"

    var id: String { rawValue }
}

private final class VideoMergeManager: ObservableObject {
    private let minimumRequiredFiles = 3
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
    @Published private(set) var statusText: String = "영상 파일을 추가하세요. 병합은 3개 이상부터 가능합니다."
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
            userMessage = "영상 파일을 3개 이상 추가해 주세요."
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

            if losslessReady {
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

                self.updateStatus(
                    progress: 0.15,
                    text: "원본 유지 병합 중"
                )

                let directMergeResult = self.runFFmpegStep(
                    executableURL: ffmpegURL,
                    arguments: self.concatCopyArguments(
                        listURL: losslessListURL,
                        outputURL: outputURL
                    )
                )

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
                            text: "\(totalStageCount)/\(totalStageCount) 단계: 비디오 원본 유지 병합 중"
                        )

                        let mergeResult = self.runFFmpegStep(
                            executableURL: ffmpegURL,
                            arguments: self.concatCopyArguments(
                                listURL: listURL,
                                outputURL: outputURL
                            )
                        )

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
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path,
            "-c", "copy"
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
            statusText = "영상 파일을 추가하세요. 병합은 3개 이상부터 가능합니다."
        } else if canStart {
            statusText = "영상 \(selectedFiles.count)개 준비됨"
        } else {
            statusText = "영상 \(selectedFiles.count)개 선택됨. 3개 이상 필요"
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

struct MainView: View {
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
    @State private var taskItems: [DownloadTaskItem] = []
    @StateObject private var videoMergeManager = VideoMergeManager()
    @State private var isMergeDropTargeted = false
    @State private var selectedTab: MainContentTab = .download
    @State private var mergeOutputName: String = ""

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

        var seen = Set<String>()
        var valid: [String] = []
        var invalidCount = 0

        for line in lines {
            guard isValidURL(line) else {
                invalidCount += 1
                continue
            }

            if seen.insert(line).inserted {
                valid.append(line)
            }
        }

        return ParsedURLSummary(
            deduplicatedValidURLs: valid,
            invalidCount: invalidCount
        )
    }

    private var runningTaskCount: Int {
        taskItems.filter { $0.manager.isDownloading }.count
    }

    private var allDownloadTargetsAreDirectM3U8: Bool {
        let urls = parsedURLSummary.deduplicatedValidURLs
        return !urls.isEmpty && urls.allSatisfy(isLikelyDirectM3U8URL)
    }

    private var downloadToolsReady: Bool {
        if allDownloadTargetsAreDirectM3U8 {
            return toolManager.status.ffmpeg.isInstalled
        }
        return toolManager.status.allRequiredInstalled
    }

    private var canStartDownloads: Bool {
        !parsedURLSummary.deduplicatedValidURLs.isEmpty
            && selectedOutputDirectory != nil
            && downloadToolsReady
    }

    private var canStartMerge: Bool {
        videoMergeManager.canStart
            && selectedOutputDirectory != nil
            && toolManager.status.ffmpeg.isInstalled
    }

    private var mergeOutputExtension: String {
        videoMergeManager.preferredOutputExtension
    }

    var body: some View {
        ScrollView {
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
                    .help("설정")
                }

                if selectedTab == .download {
                    downloadTabContent
                } else {
                    mergeTabContent
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            configureDefaultOutputDirectory()
        }
        .onChange(of: videoMergeManager.selectedFiles.map(\.path)) { _ in
            syncMergeOutputNameIfNeeded()
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
            }
        }
    }

    @ViewBuilder
    private var downloadTabContent: some View {
        GroupBox("동영상 URL (YouTube / m3u8)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("여러 개를 한 번에 시작하려면 아래 박스에 한 줄씩 입력하세요. (m3u8 주소 포함)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextEditor(text: $urlText)
                    .font(.callout)
                    .frame(minHeight: 54, maxHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Text("인식된 URL: \(parsedURLSummary.deduplicatedValidURLs.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if parsedURLSummary.invalidCount > 0 {
                        Text("잘못된 형식: \(parsedURLSummary.invalidCount)개")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Button("일괄 다운로드 시작") {
                        startDownloads()
                    }
                    .disabled(!canStartDownloads)
                }
            }
        }

        outputFolderSection

        if !downloadToolsReady {
            Text(allDownloadTargetsAreDirectM3U8 ? "직접 m3u8 녹화는 ffmpeg가 필요합니다." : "다운로드는 yt-dlp와 ffmpeg가 필요합니다.")
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
        outputFolderSection

        if !toolManager.status.ffmpeg.isInstalled {
            Text("영상 붙이기는 ffmpeg만 있으면 됩니다. 설정에서 ffmpeg 설치 상태를 확인해 주세요.")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        GroupBox("영상 이어붙이기") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Finder에서 영상 파일을 드래그해 추가하세요. 출력 형식은 첫 번째 파일 기준으로 맞춥니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("병합 모드", selection: $mergeBehaviorRaw) {
                    ForEach(MergeBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(mergeBehavior.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 180, alignment: .topLeading)
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

                    Button("비우기") {
                        videoMergeManager.clearFiles()
                    }
                    .disabled(videoMergeManager.selectedFiles.isEmpty || videoMergeManager.isMerging)

                    Spacer()

                    if videoMergeManager.isMerging {
                        Button("중지") {
                            videoMergeManager.cancel()
                        }
                    }

                    Button("영상 합치기") {
                        startVideoMerge()
                    }
                    .disabled(!canStartMerge)
                }

                HStack(spacing: 8) {
                    Text("파일 이름")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    }
                }
            }
        }
    }

    private func isValidURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return false
        }
        return true
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

    private func startDownloads() {
        guard downloadToolsReady else {
            showAlert(message: allDownloadTargetsAreDirectM3U8 ? "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요." : "yt-dlp/ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
            return
        }

        let toolPaths: ToolPaths
        if allDownloadTargetsAreDirectM3U8 {
            guard let ffmpegPath = toolManager.status.ffmpeg.path else {
                showAlert(message: "ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
                return
            }

            toolPaths = ToolPaths(
                ytDlpPath: URL(fileURLWithPath: ffmpegPath),
                ffmpegPath: URL(fileURLWithPath: ffmpegPath),
                ffprobePath: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) }
            )
        } else {
            guard let resolvedPaths = toolManager.status.resolvedPaths else {
                showAlert(message: "yt-dlp/ffmpeg를 찾을 수 없습니다. 설정 버튼에서 설치 안내를 확인해 주세요.")
                return
            }
            toolPaths = resolvedPaths
        }

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
            filenameTemplate: "%(title)s.%(ext)s",
            hlsAutoReconnectEnabled: hlsAutoReconnectEnabled,
            hlsReconnectFailTimeoutSeconds: min(max(hlsReconnectFailTimeoutSeconds, 15), 1800)
        )

        let newTasks = targets.map { DownloadTaskItem(url: $0) }
        taskItems.append(contentsOf: newTasks)

        for task in newTasks {
            task.manager.startDownload(
                url: task.url,
                outputDir: outputDir,
                toolPaths: toolPaths,
                options: options
            )
        }

        if parsedURLSummary.invalidCount > 0 {
            showAlert(message: "잘못된 URL \(parsedURLSummary.invalidCount)개는 제외하고 \(targets.count)개 다운로드를 시작했습니다.")
        } else {
            urlText = ""
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

                    Button("중지") {
                        manager.cancel()
                    }
                } else {
                    Button("삭제", role: .destructive) {
                        onRemove()
                    }
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
                    .foregroundStyle(.red)
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
}
