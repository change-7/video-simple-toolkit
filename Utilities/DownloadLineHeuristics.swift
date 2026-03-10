import Foundation

struct DownloadProgressSnapshot {
    let percent: Double
    let sizeText: String?
    let speedText: String?
    let etaText: String?
}

struct DownloadFailureSignals {
    var sawStderrFailureKeyword = false
    var sawFfmpegIssue = false
    var sawAuthOrGeoRestriction = false
    var sawNetworkIssue = false
    var sawPermissionIssue = false
    var sawDiskFullIssue = false
    var sawYtDlpOutdatedLikely = false

    mutating func merge(_ other: DownloadFailureSignals) {
        sawStderrFailureKeyword = sawStderrFailureKeyword || other.sawStderrFailureKeyword
        sawFfmpegIssue = sawFfmpegIssue || other.sawFfmpegIssue
        sawAuthOrGeoRestriction = sawAuthOrGeoRestriction || other.sawAuthOrGeoRestriction
        sawNetworkIssue = sawNetworkIssue || other.sawNetworkIssue
        sawPermissionIssue = sawPermissionIssue || other.sawPermissionIssue
        sawDiskFullIssue = sawDiskFullIssue || other.sawDiskFullIssue
        sawYtDlpOutdatedLikely = sawYtDlpOutdatedLikely || other.sawYtDlpOutdatedLikely
    }
}

enum DownloadLineHeuristics {
    private static let percentRegex = try! NSRegularExpression(pattern: #"\[download\]\s+(\d{1,3}(?:\.\d+)?)%"#)
    private static let speedRegex = try! NSRegularExpression(pattern: #"\bat\s+([^\s]+)"#)
    private static let etaRegex = try! NSRegularExpression(pattern: #"\bETA\s+([0-9:]+)"#)
    private static let sizeRegex = try! NSRegularExpression(pattern: #"%\s+of\s+(.+?)(?:\s+at\s|\s+ETA\s|\s+in\s|$)"#)
    private static let destinationRegex = try! NSRegularExpression(pattern: #"Destination:\s+(.+)$"#)
    private static let mergedOutputRegex = try! NSRegularExpression(pattern: #"Merging formats into\s+\"([^\"]+)\""#)
    private static let alreadyDownloadedRegex = try! NSRegularExpression(pattern: #"\[download\]\s+(.+)\s+has already been downloaded"#)

    static let plannedPathPrintPrefix = "__YTDLP_TARGET__:"
    static let finalPathPrintPrefix = "__YTDLP_FINAL__:"

    static func parseProgress(line: String) -> DownloadProgressSnapshot? {
        guard line.contains("[download]"),
              let percentText = firstMatch(in: line, regex: percentRegex),
              let percent = Double(percentText)
        else {
            return nil
        }

        return DownloadProgressSnapshot(
            percent: percent,
            sizeText: firstMatch(in: line, regex: sizeRegex),
            speedText: firstMatch(in: line, regex: speedRegex),
            etaText: firstMatch(in: line, regex: etaRegex)
        )
    }

    static func classifyFailureSignals(line: String, isStderr: Bool) -> DownloadFailureSignals {
        let lowercased = line.lowercased()
        var signals = DownloadFailureSignals()

        signals.sawFfmpegIssue =
            lowercased.contains("ffmpeg")
            || lowercased.contains("ffprobe")
            || lowercased.contains("[merger]")
            || lowercased.contains("[extractaudio]")
            || lowercased.contains("postprocess")
            || lowercased.contains("conversion failed")

        signals.sawAuthOrGeoRestriction =
            lowercased.contains("sign in to confirm your age")
            || lowercased.contains("age-restricted")
            || lowercased.contains("not available in your country")
            || lowercased.contains("login required")
            || lowercased.contains("members-only")
            || lowercased.contains("private video")
            || lowercased.contains("cookies")

        signals.sawNetworkIssue =
            lowercased.contains("timed out")
            || lowercased.contains("temporary failure")
            || lowercased.contains("connection reset")
            || lowercased.contains("network is unreachable")
            || lowercased.contains("name or service not known")
            || lowercased.contains("http error 5")
            || lowercased.contains("unable to download webpage")
            || lowercased.contains("server disconnected")

        signals.sawPermissionIssue =
            lowercased.contains("permission denied")
            || lowercased.contains("operation not permitted")
            || lowercased.contains("read-only file system")

        signals.sawDiskFullIssue =
            lowercased.contains("no space left on device")
            || lowercased.contains("disk full")

        signals.sawYtDlpOutdatedLikely =
            lowercased.contains("unable to extract")
            || lowercased.contains("unsupported url")
            || lowercased.contains("please report this issue on ")
            || lowercased.contains("extractorerror")

        signals.sawStderrFailureKeyword =
            isStderr && (
                lowercased.contains("error:")
                || lowercased.contains("extractorerror")
                || lowercased.contains("unable to extract")
                || lowercased.contains("unsupported url")
                || lowercased.contains("http error")
                || lowercased.contains("forbidden")
            )

        return signals
    }

    static func parseOutputPath(line: String) -> String? {
        if let plannedPath = path(afterPrefix: plannedPathPrintPrefix, in: line) {
            return plannedPath
        }

        if let finalPath = path(afterPrefix: finalPathPrintPrefix, in: line) {
            return finalPath
        }

        if let destination = firstMatch(in: line, regex: destinationRegex) {
            return cleanQuotedPath(destination)
        }

        if let mergedPath = firstMatch(in: line, regex: mergedOutputRegex) {
            return cleanQuotedPath(mergedPath)
        }

        if let downloadedPath = firstMatch(in: line, regex: alreadyDownloadedRegex) {
            return cleanQuotedPath(downloadedPath)
        }

        return nil
    }

    static func isTemporaryFilename(_ filename: String) -> Bool {
        let name = filename.lowercased()
        return name.hasSuffix(".part") || name.contains(".part-frag")
    }

    static func completedCandidateFilename(fromTemporaryFilename temporaryName: String) -> String? {
        var name = temporaryName
        if let fragRange = name.range(of: #"-Frag\d+\.part$"#, options: .regularExpression) {
            name.removeSubrange(fragRange)
        }
        if name.hasSuffix(".part") {
            name.removeLast(".part".count)
        }
        return name.isEmpty ? nil : name
    }

    private static func path(afterPrefix prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return cleanQuotedPath(String(line.dropFirst(prefix.count)))
    }

    private static func cleanQuotedPath(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }
        return cleaned
    }

    private static func firstMatch(in line: String, regex: NSRegularExpression, group: Int = 1) -> String? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              group < match.numberOfRanges
        else {
            return nil
        }
        let matchRange = match.range(at: group)
        guard matchRange.location != NSNotFound,
              let swiftRange = Range(matchRange, in: line)
        else {
            return nil
        }
        return String(line[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
