import XCTest
@testable import VideoSimpleToolkit

final class DownloadLineHeuristicsTests: XCTestCase {
    func testParseProgressExtractsPercentSizeSpeedEta() {
        let line = "[download]  12.3% of 1.23GiB at 4.56MiB/s ETA 03:21"
        let progress = DownloadLineHeuristics.parseProgress(line: line)

        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.percent ?? -1, 12.3, accuracy: 0.001)
        XCTAssertEqual(progress?.sizeText, "1.23GiB")
        XCTAssertEqual(progress?.speedText, "4.56MiB/s")
        XCTAssertEqual(progress?.etaText, "03:21")
    }

    func testClassifySignalsDetectsDiskAndPermissionAndOutdatedHints() {
        let diskLine = "ERROR: No space left on device"
        let diskSignals = DownloadLineHeuristics.classifyFailureSignals(line: diskLine, isStderr: true)
        XCTAssertTrue(diskSignals.sawDiskFullIssue)
        XCTAssertTrue(diskSignals.sawStderrFailureKeyword)

        let permissionLine = "ffmpeg: Permission denied"
        let permissionSignals = DownloadLineHeuristics.classifyFailureSignals(line: permissionLine, isStderr: true)
        XCTAssertTrue(permissionSignals.sawPermissionIssue)
        XCTAssertTrue(permissionSignals.sawFfmpegIssue)

        let extractorLine = "ERROR: unable to extract player response"
        let extractorSignals = DownloadLineHeuristics.classifyFailureSignals(line: extractorLine, isStderr: true)
        XCTAssertTrue(extractorSignals.sawYtDlpOutdatedLikely)
    }

    func testTemporaryFilenameHelpers() {
        XCTAssertTrue(DownloadLineHeuristics.isTemporaryFilename("f614.mp4.part-Frag177.part"))
        XCTAssertTrue(DownloadLineHeuristics.isTemporaryFilename("video.mp4.part"))
        XCTAssertFalse(DownloadLineHeuristics.isTemporaryFilename("video.mp4"))

        XCTAssertEqual(
            DownloadLineHeuristics.completedCandidateFilename(fromTemporaryFilename: "f614.mp4.part-Frag177.part"),
            "f614.mp4"
        )
        XCTAssertEqual(
            DownloadLineHeuristics.completedCandidateFilename(fromTemporaryFilename: "video.mp4.part"),
            "video.mp4"
        )
    }

    func testParseOutputPathSupportsPrintedAndLegacyLines() {
        XCTAssertEqual(
            DownloadLineHeuristics.parseOutputPath(
                line: "\(DownloadLineHeuristics.plannedPathPrintPrefix)/Users/test/Movies/clip.mp4"
            ),
            "/Users/test/Movies/clip.mp4"
        )

        XCTAssertEqual(
            DownloadLineHeuristics.parseOutputPath(
                line: "\(DownloadLineHeuristics.finalPathPrintPrefix)/Users/test/Movies/final clip.mp4"
            ),
            "/Users/test/Movies/final clip.mp4"
        )

        XCTAssertEqual(
            DownloadLineHeuristics.parseOutputPath(
                line: "[download] Destination: /Users/test/Movies/video.mp4"
            ),
            "/Users/test/Movies/video.mp4"
        )

        XCTAssertEqual(
            DownloadLineHeuristics.parseOutputPath(
                line: "[Merger] Merging formats into \"/Users/test/Movies/merged.mp4\""
            ),
            "/Users/test/Movies/merged.mp4"
        )
    }

    func testSubtitleRenderPlannerKeepsVideoFilesOnSourceVideoWhenProbeMissesStream() {
        let mediaURL = URL(fileURLWithPath: "/tmp/source-video.mp4")
        let subtitleURL = URL(fileURLWithPath: "/tmp/subtitle.srt")
        let outputURL = URL(fileURLWithPath: "/tmp/output.mp4")
        let usesSourceVideo = SubtitleRenderPlanner.shouldUseSourceVideo(
            for: mediaURL,
            detectedHasVideoStream: false
        )
        let arguments = SubtitleRenderPlanner.renderArguments(
            mediaURL: mediaURL,
            subtitleURL: subtitleURL,
            outputURL: outputURL,
            usesSourceVideo: usesSourceVideo
        )

        XCTAssertTrue(usesSourceVideo)
        XCTAssertFalse(arguments.contains("color=c=black:s=1280x720:r=30"))
        XCTAssertTrue(arguments.contains("-map"))
        XCTAssertTrue(arguments.contains("0:v:0"))
        XCTAssertFalse(arguments.contains("1:a:0"))
    }

    func testSubtitleRenderPlannerUsesPreparedASSFilter() {
        let arguments = SubtitleRenderPlanner.renderArguments(
            mediaURL: URL(fileURLWithPath: "/tmp/source-video.mp4"),
            subtitleURL: URL(fileURLWithPath: "/tmp/rounded-subtitles.ass"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            usesSourceVideo: true
        )

        guard let filterIndex = arguments.firstIndex(of: "-vf"), arguments.indices.contains(filterIndex + 1) else {
            XCTFail("subtitle video filter argument is missing")
            return
        }

        let filter = arguments[filterIndex + 1]
        XCTAssertEqual(filter, "subtitles='/tmp/rounded-subtitles.ass'")
    }

    func testRoundedSubtitleASSContentUsesVectorBackgroundWithNarrowPadding() {
        let content = SubtitleVideoRoundedASSGenerator.makeSubtitleASSContent(
            cues: [SubtitleVideoRoundedCue(start: 0, end: 2, text: "Rounded subtitle")],
            fontSize: 16,
            backgroundOpacity: 0.45
        )

        XCTAssertTrue(content.contains("\\p1"))
        XCTAssertTrue(content.contains("\\an5\\pos("))
        XCTAssertTrue(content.contains("m -"))
        XCTAssertTrue(content.contains(" b "))
        XCTAssertFalse(content.contains("BorderStyle=3"))
    }

    func testSubtitlePreviewFontScaleUsesLarge288CoordinateSpace() {
        XCTAssertEqual(
            SubtitleVideoRenderMetrics.scaledFontSize(fontSize: 16, previewHeight: 360),
            20,
            accuracy: 0.001
        )

        let content = SubtitleVideoRoundedASSGenerator.makeSubtitleASSContent(
            cues: [SubtitleVideoRoundedCue(start: 0, end: 2, text: "Large subtitle")],
            fontSize: 16,
            backgroundOpacity: 0.45
        )

        XCTAssertTrue(content.contains("PlayResY: 720"))
        XCTAssertTrue(content.contains("Style: Subtitle,Arial,40"))
        XCTAssertTrue(content.contains("\\fs40"))
    }

    func testStreamURLResolverPreservesHLSQueryToken() {
        let input = "https://cdn.example.com/live/manifest.m3u8?token=abc%2F123&expires=1700000000"

        XCTAssertEqual(StreamURLResolver.normalizedInputURL(from: input), input)
        XCTAssertTrue(StreamURLResolver.isHLSURL(input))
    }

    func testWebVideoCandidateKeepsTokenAndRejectsLocalAddresses() {
        let stream = "https://cdn.example.com/live/master.m3u8?token=a%2Fb&expires=1700000000"
        XCTAssertEqual(WebVideoCandidate.normalizedURL(stream), stream)
        XCTAssertNil(WebVideoCandidate.normalizedURL("blob:https://example.com/123"))
        XCTAssertNil(WebVideoCandidate.normalizedURL("http://127.0.0.1/private.mp4"))
        XCTAssertNil(WebVideoCandidate.normalizedURL("https://player.local/stream.m3u8"))
    }

    func testWebpageQueryMentioningHLSIsNotAnHLSInput() {
        XCTAssertFalse(StreamURLResolver.isHLSURL("https://example.com/watch?next=manifest.m3u8"))
        XCTAssertFalse(StreamURLResolver.isHLSURL("https://example.com/player.html#https://cdn.example.com/a.m3u8"))
        XCTAssertTrue(StreamURLResolver.isHLSURL("https://cdn.example.com/a.m3u8?token=a%2Fb"))
    }

    func testStreamURLResolverExtractsHLSURLFromWhaleExtensionFragment() {
        let hlsURL = "https://cdn.example.com/live/manifest.m3u8?token=abc%2F123&expires=1700000000"
        let whaleURL = "whale-extension://player.example/player.html#\(hlsURL)"

        XCTAssertEqual(StreamURLResolver.normalizedInputURL(from: whaleURL), hlsURL)
    }

    func testStreamURLResolverExtractsHLSURLFromAnyPlayerFragment() {
        let hlsURL = "https://cdn.example.com/live/manifest.m3u8?token=abc%2F123&expires=1700000000"
        let extensionPlayerURL = "chrome-extension://player.example/player.html#\(hlsURL)"
        let webPlayerURL = "https://player.example/player.html#\(hlsURL)"

        XCTAssertEqual(StreamURLResolver.normalizedInputURL(from: extensionPlayerURL), hlsURL)
        XCTAssertEqual(StreamURLResolver.normalizedInputURL(from: webPlayerURL), hlsURL)
    }

    func testStreamURLResolverDecodesAnEncodedPlayerFragmentOnce() {
        let hlsURL = "https://cdn.example.com/live/manifest.m3u8?token=abc%2F123&expires=1700000000"
        let encodedHLSURL = "https%3A%2F%2Fcdn.example.com%2Flive%2Fmanifest.m3u8%3Ftoken%3Dabc%252F123%26expires%3D1700000000"
        let playerURL = "custom-player://player.example/player.html#\(encodedHLSURL)"

        XCTAssertEqual(StreamURLResolver.normalizedInputURL(from: playerURL), hlsURL)
    }

    func testRequestedDownloadNameKeepsOriginalExtension() {
        XCTAssertEqual(
            DownloadManager.sanitizedBaseName("새 영상.mkv", originalExtension: "mp4"),
            "새 영상"
        )
        XCTAssertEqual(
            DownloadManager.sanitizedBaseName("Part 1.2", originalExtension: "mp4"),
            "Part 1.2"
        )
        XCTAssertEqual(
            DownloadManager.sanitizedBaseName("  name/with:bad?chars.mp4  ", originalExtension: "mp4"),
            "name-with-bad-chars"
        )
    }

    func testCanceledDownloadRemovesOnlyItsNewFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("clip.mp4")
        let partial = URL(fileURLWithPath: output.path + ".part")
        let fragment = URL(fileURLWithPath: output.path + ".part-Frag1.part")
        let existing = directory.appendingPathComponent("existing.mp4")
        let unrelated = directory.appendingPathComponent("other.mp4.part")
        for file in [output, partial, fragment, existing, unrelated] {
            try Data("test".utf8).write(to: file)
        }

        let failures = DownloadManager.removeCanceledOutputFiles(
            in: directory,
            knownOutputs: [output, existing],
            initialFiles: [existing],
            temporaryOutput: nil
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fragment.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

}
