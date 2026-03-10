import XCTest
@testable import YouTubeDownloader

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
}
