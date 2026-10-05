import AppKit
import Foundation

enum EditorExportPreset: String, CaseIterable, Identifiable {
    case balanced
    case highQuality
    case smallFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .highQuality: return "High Quality"
        case .smallFile: return "Small File"
        }
    }

    var videoPreset: String {
        switch self {
        case .balanced: return "veryfast"
        case .highQuality: return "slow"
        case .smallFile: return "medium"
        }
    }

    var crf: String {
        switch self {
        case .balanced: return "20"
        case .highQuality: return "16"
        case .smallFile: return "28"
        }
    }

    var audioBitrate: String {
        switch self {
        case .balanced: return "192k"
        case .highQuality: return "256k"
        case .smallFile: return "128k"
        }
    }
}

struct EditorExportClip: Hashable {
    let sourceURL: URL
    let kind: EditorClipKind
    let title: String
    let startTime: Double
    let trimStart: Double
    let duration: Double
    let transform: EditorTransform
    let hasAudio: Bool
    let fadeInDuration: Double
    let fadeOutDuration: Double

    init(_ clip: EditorClip) {
        self.sourceURL = clip.sourceURL ?? URL(fileURLWithPath: "/dev/null")
        self.kind = clip.kind
        self.title = clip.title
        self.startTime = clip.startTime
        self.trimStart = clip.trimStart
        self.duration = clip.duration
        self.transform = clip.transform
        self.hasAudio = clip.hasAudio
        self.fadeInDuration = min(max(clip.fadeInDuration ?? 0, 0), max(0, clip.duration / 2))
        self.fadeOutDuration = min(max(clip.fadeOutDuration ?? 0, 0), max(0, clip.duration / 2))
    }
}

struct EditorExportText: Hashable {
    let text: String
    let startTime: Double
    let duration: Double
    let transform: EditorTransform
    let fadeInDuration: Double
    let fadeOutDuration: Double

    init(_ clip: EditorClip) {
        self.text = clip.text
        self.startTime = clip.startTime
        self.duration = clip.duration
        self.transform = clip.transform
        self.fadeInDuration = min(max(clip.fadeInDuration ?? 0, 0), max(0, clip.duration / 2))
        self.fadeOutDuration = min(max(clip.fadeOutDuration ?? 0, 0), max(0, clip.duration / 2))
    }
}

struct EditorExportRequest {
    let visualClips: [EditorExportClip]
    let audioClips: [EditorExportClip]
    let textOverlays: [EditorExportText]
    let outputDirectory: URL
    let outputBaseName: String
    let renderSize: CGSize
    let frameRate: Int
    let preset: EditorExportPreset
    let ffmpegURL: URL
    let ffprobeURL: URL?

    var expectedDuration: Double {
        let visualDuration = visualSequenceDuration
        let audioDuration = audioClips.map { $0.startTime + $0.duration }.max() ?? 0
        let textDuration = textOverlays.map { $0.startTime + $0.duration }.max() ?? 0
        return max(visualDuration, audioDuration, textDuration, 1)
    }

    private var visualSequenceDuration: Double {
        var cursor = 0.0
        for clip in visualClips.sorted(by: { $0.startTime < $1.startTime }) {
            cursor = max(cursor, clip.startTime)
            cursor += max(clip.duration, 0)
        }
        return cursor
    }
}

struct RoundedSubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

enum RoundedSubtitleASSGenerator {
    private struct Event {
        let cue: RoundedSubtitleCue
        let center: CGPoint
        let fontSize: CGFloat
        let fadeInDuration: Double
        let fadeOutDuration: Double
    }

    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let cornerRadius: CGFloat = 6

    static func writeSubtitleFile(
        sourceURL: URL,
        outputDirectory: URL,
        fontSize: Double,
        backgroundOpacity: Double
    ) -> URL? {
        guard let rawText = loadText(from: sourceURL) else { return nil }
        let cues = parseCues(rawText, fileExtension: sourceURL.pathExtension)
        guard !cues.isEmpty else { return nil }

        let content = makeASSContent(
            events: cues.map {
                Event(
                    cue: $0,
                    center: .zero,
                    fontSize: CGFloat(max(8, Int(fontSize.rounded()))),
                    fadeInDuration: 0,
                    fadeOutDuration: 0
                )
            },
            canvasSize: CGSize(width: 1280, height: 720),
            backgroundOpacity: backgroundOpacity,
            subtitlePosition: true
        )

        let outputURL = outputDirectory.appendingPathComponent("rounded-subtitles.ass")
        guard (try? content.write(to: outputURL, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return outputURL
    }

    static func writeEditorFile(
        overlays: [EditorExportText],
        canvasSize: CGSize,
        outputDirectory: URL
    ) throws -> URL {
        let width = max(canvasSize.width, 2)
        let height = max(canvasSize.height, 2)
        let events = overlays.map { overlay in
            Event(
                cue: RoundedSubtitleCue(
                    start: overlay.startTime,
                    end: overlay.startTime + overlay.duration,
                    text: overlay.text
                ),
                center: CGPoint(
                    x: width / 2 + overlay.transform.positionX * width,
                    y: height / 2 + overlay.transform.positionY * height
                ),
                fontSize: CGFloat(max(16, Int((34 * overlay.transform.scaleY).rounded()))),
                fadeInDuration: overlay.fadeInDuration,
                fadeOutDuration: overlay.fadeOutDuration
            )
        }

        let content = makeASSContent(
            events: events,
            canvasSize: CGSize(width: width, height: height),
            backgroundOpacity: nil,
            subtitlePosition: false,
            overlayOpacities: overlays.map { $0.transform.resolvedSubtitleBackgroundOpacity },
            textOpacities: overlays.map { $0.transform.opacity }
        )

        let outputURL = outputDirectory.appendingPathComponent("rounded-text-overlays.ass")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    static func makeSubtitleASSContent(
        cues: [RoundedSubtitleCue],
        fontSize: Double,
        backgroundOpacity: Double
    ) -> String {
        makeASSContent(
            events: cues.map {
                Event(
                    cue: $0,
                    center: .zero,
                    fontSize: CGFloat(max(8, Int(fontSize.rounded()))),
                    fadeInDuration: 0,
                    fadeOutDuration: 0
                )
            },
            canvasSize: CGSize(width: 1280, height: 720),
            backgroundOpacity: backgroundOpacity,
            subtitlePosition: true
        )
    }

    private static func makeASSContent(
        events: [Event],
        canvasSize: CGSize,
        backgroundOpacity: Double?,
        subtitlePosition: Bool,
        overlayOpacities: [Double] = [],
        textOpacities: [Double] = []
    ) -> String {
        let width = max(Int(canvasSize.width.rounded()), 2)
        let height = max(Int(canvasSize.height.rounded()), 2)
        let subtitleFontSize = events.first?.fontSize ?? 16
        let subtitleBottomMargin: CGFloat = max(25, subtitleFontSize * 1.5)
        let defaultOpacity = min(max(backgroundOpacity ?? 0.45, 0), 1)
        var lines = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "PlayResX: \(width)",
            "PlayResY: \(height)",
            "WrapStyle: 2",
            "ScaledBorderAndShadow: yes",
            "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Subtitle,Arial,\(formatASSNumber(subtitleFontSize)),&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
        ]

        for (index, event) in events.enumerated() {
            let measured = textMetrics(for: event.cue.text, fontSize: event.fontSize)
            let boxWidth = measured.width + horizontalPadding * 2
            let boxHeight = measured.height + verticalPadding * 2
            let center: CGPoint
            if subtitlePosition {
                center = CGPoint(
                    x: canvasSize.width / 2,
                    y: canvasSize.height - subtitleBottomMargin - measured.height / 2
                )
            } else {
                center = event.center
            }

            let backgroundOpacity = subtitlePosition
                ? defaultOpacity
                : min(max(index < overlayOpacities.count ? overlayOpacities[index] : defaultOpacity, 0), 1)
            let textOpacity = subtitlePosition
                ? 1
                : min(max(index < textOpacities.count ? textOpacities[index] : 1, 0), 1)
            let backgroundAlpha = alphaHex(for: backgroundOpacity)
            let textAlpha = alphaHex(for: textOpacity)
            let fade = fadeTag(inDuration: event.fadeInDuration, outDuration: event.fadeOutDuration)
            let position = "\\an5\\pos(\(formatASSNumber(center.x)),\(formatASSNumber(center.y)))"
            let backgroundTags = "{\(position)\\p1\\c&H000000&\\1a&H\(backgroundAlpha)&\(fade)}"
            let textTags = "{\(position)\\fs\(formatASSNumber(event.fontSize))\\bord0\\shad0\\1c&HFFFFFF&\\1a&H\(textAlpha)&\\q2\(fade)}"

            lines.append("Dialogue: 0,\(formatASSTime(event.cue.start)),\(formatASSTime(event.cue.end)),Subtitle,,0,0,0,,\(backgroundTags)\(roundedRectPath(width: boxWidth, height: boxHeight))")
            lines.append("Dialogue: 1,\(formatASSTime(event.cue.start)),\(formatASSTime(event.cue.end)),Subtitle,,0,0,0,,\(textTags)\(escapeASSText(event.cue.text))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseCues(_ rawText: String, fileExtension: String) -> [RoundedSubtitleCue] {
        switch fileExtension.lowercased() {
        case "srt", "vtt":
            return parseLineCues(rawText)
        case "ass", "ssa":
            return parseASSCues(rawText)
        default:
            return []
        }
    }

    private static func parseLineCues(_ rawText: String) -> [RoundedSubtitleCue] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count >= 2,
                  let start = parseTimestamp(timingParts[0]),
                  let end = parseTimestamp(timingParts[1]) else { return nil }

            let text = cleanText(lines.dropFirst(timingIndex + 1).joined(separator: "\n"))
            guard start < end, !text.isEmpty else { return nil }
            return RoundedSubtitleCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    private static func parseASSCues(_ rawText: String) -> [RoundedSubtitleCue] {
        rawText.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Dialogue:") else { return nil }
            let components = trimmed.dropFirst("Dialogue:".count).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard components.count >= 9,
                  let start = parseTimestamp(components[1]),
                  let end = parseTimestamp(components[2]) else { return nil }

            let text = cleanText(components.dropFirst(9).joined(separator: ",").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n"))
            guard start < end, !text.isEmpty else { return nil }
            return RoundedSubtitleCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    private static func loadText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .unicode) ??
            String(data: data, encoding: .utf16) ??
            String(data: data, encoding: .utf16LittleEndian) ??
            String(data: data, encoding: .utf16BigEndian)
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let components = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last.map(String.init) ?? "") else { return nil }

        if components.count == 2 {
            return (Double(components[0]) ?? 0) * 60 + seconds
        }
        return (Double(components[0]) ?? 0) * 3600 + (Double(components[1]) ?? 0) * 60 + seconds
    }

    private static func cleanText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\{.*?\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textMetrics(for text: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lines = text.components(separatedBy: "\n")
        let widths = lines.map {
            NSAttributedString(string: $0, attributes: [.font: font]).size().width
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGSize(
            width: max(widths.max() ?? 0, 1),
            height: max(lineHeight * CGFloat(max(lines.count, 1)), lineHeight)
        )
    }

    private static func roundedRectPath(width: CGFloat, height: CGFloat) -> String {
        let radius = min(cornerRadius, min(width, height) / 2)
        let curve = radius * 0.5522848
        let left = -width / 2
        let right = width / 2
        let top = -height / 2
        let bottom = height / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> String {
            "\(formatASSNumber(x)) \(formatASSNumber(y))"
        }

        return [
            "m \(point(left + radius, top))",
            "l \(point(right - radius, top))",
            "b \(point(right - radius + curve, top)) \(point(right, top + radius - curve)) \(point(right, top + radius))",
            "l \(point(right, bottom - radius))",
            "b \(point(right, bottom - radius + curve)) \(point(right - radius + curve, bottom)) \(point(right - radius, bottom))",
            "l \(point(left + radius, bottom))",
            "b \(point(left + radius - curve, bottom)) \(point(left, bottom - radius + curve)) \(point(left, bottom - radius))",
            "l \(point(left, top + radius))",
            "b \(point(left, top + radius - curve)) \(point(left + radius - curve, top)) \(point(left + radius, top))"
        ].joined(separator: " ")
    }

    private static func escapeASSText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r\n", with: "\\N")
            .replacingOccurrences(of: "\r", with: "\\N")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    private static func alphaHex(for opacity: Double) -> String {
        String(format: "%02X", Int(((1 - min(max(opacity, 0), 1)) * 255).rounded()))
    }

    private static func fadeTag(inDuration: Double, outDuration: Double) -> String {
        guard inDuration > 0.001 || outDuration > 0.001 else { return "" }
        return "\\fad(\(Int((max(inDuration, 0) * 1000).rounded())),\(Int((max(outDuration, 0) * 1000).rounded())))"
    }

    private static func formatASSTime(_ seconds: Double) -> String {
        let total = max(seconds, 0)
        let hours = Int(total / 3600)
        let minutes = Int(total / 60) % 60
        let remainder = total - Double(hours * 3600 + minutes * 60)
        return String(format: "%d:%02d:%05.2f", hours, minutes, remainder)
    }

    private static func formatASSNumber(_ value: CGFloat) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}

final class EditorExportManager: ObservableObject {
    private struct StepResult {
        let terminationStatus: Int32
        let message: String?
        let wasCancelled: Bool
    }

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = "출력 대기 중"
    @Published private(set) var outputURL: URL?
    @Published var userMessage: String?

    private let workerQueue = DispatchQueue(label: "editor.export.worker", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "editor.export.state")
    private var runningProcess: RunningProcess?
    private var didCancel = false

    func startExport(request: EditorExportRequest) {
        guard !isExporting else { return }

        let outputURL = uniqueOutputURL(
            in: request.outputDirectory,
            requestedBaseName: request.outputBaseName
        )

        isExporting = true
        progress = 0.01
        statusText = "출력 준비 중"
        self.outputURL = nil
        userMessage = nil

        stateQueue.sync {
            didCancel = false
            runningProcess = nil
        }

        workerQueue.async {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("editor-export-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                self.finishFailure(message: "임시 작업 폴더를 만들지 못했습니다.")
                return
            }

            let arguments: [String]
            do {
                arguments = try self.exportArguments(
                    request: request,
                    outputURL: outputURL,
                    temporaryDirectory: temporaryDirectory
                )
            } catch {
                self.cleanupTemporaryDirectory(temporaryDirectory)
                self.finishFailure(message: "자막 오버레이를 준비하지 못했습니다.")
                return
            }

            let result = self.runExportStep(
                executableURL: request.ffmpegURL,
                arguments: arguments,
                expectedDuration: request.expectedDuration
            )

            if result.wasCancelled {
                self.cleanupTemporaryDirectory(temporaryDirectory)
                self.finishCanceled()
                return
            }

            guard result.terminationStatus == 0 else {
                self.cleanupTemporaryDirectory(temporaryDirectory)
                self.finishFailure(message: result.message ?? "ffmpeg 출력에 실패했습니다.")
                return
            }

            let validation = self.validateOutput(
                outputURL: outputURL,
                ffprobeURL: request.ffprobeURL
            )

            guard validation.isValid else {
                self.cleanupTemporaryDirectory(temporaryDirectory)
                self.finishFailure(message: validation.message)
                return
            }

            self.cleanupTemporaryDirectory(temporaryDirectory)
            self.finishSuccess(outputURL: outputURL)
        }
    }

    func cancel() {
        stateQueue.sync {
            didCancel = true
            runningProcess?.cancel()
        }

        DispatchQueue.main.async {
            self.statusText = "출력 중지 요청 중"
        }
    }

    private var isCancelled: Bool {
        stateQueue.sync { didCancel }
    }

    private func exportArguments(
        request: EditorExportRequest,
        outputURL: URL,
        temporaryDirectory: URL
    ) throws -> [String] {
        let width = evenDimension(Int(request.renderSize.width.rounded()))
        let height = evenDimension(Int(request.renderSize.height.rounded()))
        let fps = max(request.frameRate, 1)
        let roundedSubtitleURL: URL?
        if request.textOverlays.isEmpty {
            roundedSubtitleURL = nil
        } else {
            roundedSubtitleURL = try RoundedSubtitleASSGenerator.writeEditorFile(
                overlays: request.textOverlays,
                canvasSize: CGSize(width: width, height: height),
                outputDirectory: temporaryDirectory
            )
        }
        var arguments = [
            "-y",
            "-hide_banner",
            "-nostats",
            "-loglevel", "warning",
            "-progress", "pipe:2"
        ]

        if request.visualClips.isEmpty {
            let duration = formatSeconds(request.expectedDuration)
            arguments += [
                "-f", "lavfi",
                "-t", duration,
                "-i", "color=c=black:s=\(width)x\(height):r=\(fps)",
                "-f", "lavfi",
                "-t", duration,
                "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"
            ]
        } else {
            for clip in request.visualClips {
                let duration = formatSeconds(clip.duration)
                if clip.kind == .image {
                    arguments += ["-loop", "1", "-t", duration, "-i", clip.sourceURL.path]
                } else {
                    arguments += [
                        "-ss", formatSeconds(clip.trimStart),
                        "-t", duration,
                        "-i", clip.sourceURL.path
                    ]
                }
            }
        }

        for clip in request.audioClips {
            arguments += [
                "-ss", formatSeconds(clip.trimStart),
                "-t", formatSeconds(clip.duration),
                "-i", clip.sourceURL.path
            ]
        }

        arguments += [
            "-filter_complex",
            filterComplex(
                request: request,
                width: width,
                height: height,
                fps: fps,
                roundedSubtitleURL: roundedSubtitleURL
            ),
            "-map", finalVideoMapName(textCount: request.textOverlays.count),
            "-map", finalAudioMapName(audioCount: request.audioClips.count),
            "-c:v", "libx264",
            "-preset", request.preset.videoPreset,
            "-crf", request.preset.crf,
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", request.preset.audioBitrate,
            "-ar", "48000",
            "-ac", "2",
            "-movflags", "+faststart",
            outputURL.path
        ]

        return arguments
    }

    private func filterComplex(
        request: EditorExportRequest,
        width: Int,
        height: Int,
        fps: Int,
        roundedSubtitleURL: URL?
    ) -> String {
        var parts: [String] = []

        if request.visualClips.isEmpty {
            parts.append("[0:v]format=yuv420p[vcat]")
            parts.append("[1:a]atrim=duration=\(formatSeconds(request.expectedDuration)),asetpts=PTS-STARTPTS[acat]")
        } else {
            for (index, clip) in request.visualClips.enumerated() {
                var filters = [
                    "[\(index):v:0]fps=\(fps)",
                    "scale=\(width):\(height):force_original_aspect_ratio=decrease",
                    "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2",
                    "setsar=1",
                    "setpts=PTS-STARTPTS"
                ]

                let perspective = perspectiveFilter(
                    for: clip.transform.perspective,
                    width: width,
                    height: height
                )
                if !perspective.isEmpty {
                    filters.append(perspective)
                }

                filters.append("format=rgba[vbase\(index)]")
                parts.append(filters.joined(separator: ","))
                parts.append(contentsOf: transformedVideoParts(
                    for: clip,
                    index: index,
                    width: width,
                    height: height,
                    fps: fps
                ))

                if clip.hasAudio {
                    parts.append("[\(index):a:0]atrim=duration=\(formatSeconds(clip.duration)),asetpts=PTS-STARTPTS\(audioFadeFilter(for: clip))[a\(index)]")
                } else {
                    parts.append("anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=\(formatSeconds(clip.duration)),asetpts=PTS-STARTPTS\(audioFadeFilter(for: clip))[a\(index)]")
                }
            }

            var sequenceInputs: [String] = []
            var cursor = 0.0
            var gapIndex = 0

            func appendGap(duration: Double) {
                let safeDuration = max(duration, 0)
                guard safeDuration > 0.001 else { return }
                let videoLabel = "vgap\(gapIndex)"
                let audioLabel = "agap\(gapIndex)"
                parts.append("color=c=black:s=\(width)x\(height):r=\(fps):d=\(formatSeconds(safeDuration))[\(videoLabel)]")
                parts.append("anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=\(formatSeconds(safeDuration)),asetpts=PTS-STARTPTS[\(audioLabel)]")
                sequenceInputs.append("[\(videoLabel)][\(audioLabel)]")
                cursor += safeDuration
                gapIndex += 1
            }

            for (index, clip) in request.visualClips.enumerated() {
                if clip.startTime > cursor {
                    appendGap(duration: clip.startTime - cursor)
                }

                sequenceInputs.append("[v\(index)][a\(index)]")
                cursor += max(clip.duration, 0)
            }

            if request.expectedDuration > cursor {
                appendGap(duration: request.expectedDuration - cursor)
            }

            let concatInputs = sequenceInputs.joined()
            parts.append("\(concatInputs)concat=n=\(sequenceInputs.count):v=1:a=1[vcat][acat]")
        }

        if !request.audioClips.isEmpty {
            let audioInputOffset = request.visualClips.isEmpty ? 2 : request.visualClips.count
            var mixInputs = ["[acat]"]

            for (index, clip) in request.audioClips.enumerated() {
                let inputIndex = audioInputOffset + index
                let delayMilliseconds = max(0, Int((clip.startTime * 1000).rounded()))
                let label = "atrack\(index)"
                parts.append("[\(inputIndex):a:0]atrim=duration=\(formatSeconds(clip.duration)),asetpts=PTS-STARTPTS\(audioFadeFilter(for: clip)),adelay=\(delayMilliseconds)|\(delayMilliseconds)[\(label)]")
                mixInputs.append("[\(label)]")
            }

            parts.append("\(mixInputs.joined())amix=inputs=\(mixInputs.count):duration=longest:dropout_transition=0[aout]")
        }

        var currentVideo = "vcat"
        if let roundedSubtitleURL {
            let safePath = escapeSubtitleFilterPath(roundedSubtitleURL.path)
            parts.append("[\(currentVideo)]subtitles='\(safePath)'[vtext0]")
            currentVideo = "vtext0"
        }

        return parts.joined(separator: ";")
    }

    private func perspectiveFilter(for quad: PerspectiveQuad, width: Int, height: Int) -> String {
        guard quad != .unit else { return "" }

        func x(_ point: CGPoint) -> Int {
            Int((point.x * Double(width)).rounded())
        }

        func y(_ point: CGPoint) -> Int {
            Int((point.y * Double(height)).rounded())
        }

        return [
            "perspective=x0=\(x(quad.topLeft))",
            "y0=\(y(quad.topLeft))",
            "x1=\(x(quad.topRight))",
            "y1=\(y(quad.topRight))",
            "x2=\(x(quad.bottomLeft))",
            "y2=\(y(quad.bottomLeft))",
            "x3=\(x(quad.bottomRight))",
            "y3=\(y(quad.bottomRight))",
            "sense=source"
        ].joined(separator: ":")
    }

    private func finalVideoMapName(textCount: Int) -> String {
        textCount == 0 ? "[vcat]" : "[vtext0]"
    }

    private func finalAudioMapName(audioCount: Int) -> String {
        audioCount == 0 ? "[acat]" : "[aout]"
    }

    private func transformedVideoParts(
        for clip: EditorExportClip,
        index: Int,
        width: Int,
        height: Int,
        fps: Int
    ) -> [String] {
        let transform = clip.transform
        let scaleX = max(transform.scaleX, 0.01)
        let scaleY = max(transform.scaleY, 0.01)
        let opacity = clamped(transform.opacity, lower: 0, upper: 1)
        let radians = transform.rotationDegrees * .pi / 180
        let offsetX = Int((transform.positionX * Double(width)).rounded())
        let offsetY = Int((transform.positionY * Double(height)).rounded())
        let duration = formatSeconds(max(clip.duration, 0.001))

        let scaleExpression = "scale=w='\(scaleExpression(multiplier: scaleX, axis: "iw"))':h='\(scaleExpression(multiplier: scaleY, axis: "ih"))'"
        let angle = formatFilterNumber(radians)
        let finalVideoFilters = ([
            "overlay=x='(W-w)/2+\(offsetX)':y='(H-h)/2+\(offsetY)':shortest=1",
            "format=yuv420p"
        ] + videoFadeFilters(for: clip)).joined(separator: ",")

        return [
            "[vbase\(index)]\(scaleExpression)[vscaled\(index)]",
            "[vscaled\(index)]rotate=\(angle):ow=rotw(\(angle)):oh=roth(\(angle)):c=black@0[vrot\(index)]",
            "[vrot\(index)]colorchannelmixer=aa=\(formatFilterNumber(opacity))[vrgba\(index)]",
            "color=c=black:s=\(width)x\(height):r=\(fps):d=\(duration)[vbg\(index)]",
            "[vbg\(index)][vrgba\(index)]\(finalVideoFilters)[v\(index)]"
        ]
    }

    private func videoFadeFilters(for clip: EditorExportClip) -> [String] {
        var filters: [String] = []
        if clip.fadeInDuration > 0.001 {
            filters.append("fade=t=in:st=0:d=\(formatSeconds(clip.fadeInDuration))")
        }
        if clip.fadeOutDuration > 0.001 {
            filters.append("fade=t=out:st=\(formatSeconds(max(clip.duration - clip.fadeOutDuration, 0))):d=\(formatSeconds(clip.fadeOutDuration))")
        }
        return filters
    }

    private func audioFadeFilter(for clip: EditorExportClip) -> String {
        var filters: [String] = []
        if clip.fadeInDuration > 0.001 {
            filters.append("afade=t=in:st=0:d=\(formatSeconds(clip.fadeInDuration))")
        }
        if clip.fadeOutDuration > 0.001 {
            filters.append("afade=t=out:st=\(formatSeconds(max(clip.duration - clip.fadeOutDuration, 0))):d=\(formatSeconds(clip.fadeOutDuration))")
        }
        return filters.isEmpty ? "" : "," + filters.joined(separator: ",")
    }

    private func scaleExpression(multiplier: Double, axis: String) -> String {
        "max(2,trunc(\(axis)*\(formatFilterNumber(multiplier))/2)*2)"
    }

    private func evenDimension(_ value: Int) -> Int {
        let safeValue = max(value, 2)
        return safeValue.isMultiple(of: 2) ? safeValue : safeValue + 1
    }

    private func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func runExportStep(
        executableURL: URL,
        arguments: [String],
        expectedDuration: Double
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
                    if recentLines.count > 14 {
                        recentLines.removeFirst(recentLines.count - 14)
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
                            self.progress = min(max(elapsedSeconds / max(expectedDuration, 1), 0.01), 0.99)
                            self.statusText = "출력 중 | \(self.formattedTime(elapsedSeconds))"
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
        let message = recentLines.suffix(4).joined(separator: "\n")
        lineLock.unlock()

        return StepResult(
            terminationStatus: terminationStatus,
            message: message.isEmpty ? nil : message,
            wasCancelled: isCancelled
        )
    }

    private func validateOutput(outputURL: URL, ffprobeURL: URL?) -> DownloadValidationSummary {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return DownloadValidationSummary(
                isValid: false,
                fileSizeBytes: nil,
                durationSeconds: nil,
                message: "출력 파일을 찾지 못했습니다."
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes?[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            return DownloadValidationSummary(
                isValid: false,
                fileSizeBytes: fileSize,
                durationSeconds: nil,
                message: "출력 파일 크기가 0입니다."
            )
        }

        guard let ffprobeURL else {
            return DownloadValidationSummary(
                isValid: true,
                fileSizeBytes: fileSize,
                durationSeconds: nil,
                message: "출력 파일 생성 완료"
            )
        }

        guard let result = ProcessRunner.runAndCapture(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                outputURL.path
            ]
        ), result.terminationStatus == 0 else {
            return DownloadValidationSummary(
                isValid: false,
                fileSizeBytes: fileSize,
                durationSeconds: nil,
                message: "ffprobe가 출력 파일을 검증하지 못했습니다."
            )
        }

        let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let duration, duration.isFinite, duration > 0 else {
            return DownloadValidationSummary(
                isValid: false,
                fileSizeBytes: fileSize,
                durationSeconds: duration,
                message: "출력 파일 길이를 읽지 못했습니다."
            )
        }

        return DownloadValidationSummary(
            isValid: true,
            fileSizeBytes: fileSize,
            durationSeconds: duration,
            message: "출력 파일 생성 완료"
        )
    }

    private func uniqueOutputURL(in directory: URL, requestedBaseName: String) -> URL {
        let baseName = sanitizedOutputBaseName(requestedBaseName)
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

    private func sanitizedOutputBaseName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "edited-video-\(Int(Date().timeIntervalSince1970))"
        let candidate = trimmed.isEmpty ? fallback : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let sanitized = candidate
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func escapeSubtitleFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", max(seconds, 0))
    }

    private func formatFilterNumber(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func parseFFmpegTime(_ value: String) -> Double {
        let segments = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard segments.count == 3 else { return 0 }
        return (Double(segments[0]) ?? 0) * 3600
            + (Double(segments[1]) ?? 0) * 60
            + (Double(segments[2]) ?? 0)
    }

    private func formattedTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func finishSuccess(outputURL: URL) {
        DispatchQueue.main.async {
            self.isExporting = false
            self.progress = 1
            self.statusText = "출력 완료"
            self.outputURL = outputURL
            self.userMessage = outputURL.lastPathComponent
        }
    }

    private func finishFailure(message: String) {
        DispatchQueue.main.async {
            self.isExporting = false
            self.progress = 0
            self.outputURL = nil
            self.statusText = "출력 실패"
            self.userMessage = message
        }
    }

    private func finishCanceled() {
        DispatchQueue.main.async {
            self.isExporting = false
            self.progress = 0
            self.outputURL = nil
            self.statusText = "출력 취소됨"
            self.userMessage = "출력을 취소했습니다."
        }
    }

    private func cleanupTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
