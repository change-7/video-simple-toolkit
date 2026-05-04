import Foundation

enum SettingsKeys {
    static let ytDlpPath = "settings.ytdlp.path"
    static let ffmpegPath = "settings.ffmpeg.path"
    static let ytDlpCheckUpdateOnLaunch = "settings.ytdlp.checkUpdateOnLaunch"
    static let defaultOutputDirectory = "settings.output.directory"
    static let defaultDownloadPreset = "settings.download.preset"
    static let defaultFilenameConflictPolicy = "settings.download.conflictPolicy"
    static let mergeBehavior = "settings.merge.behavior"
    static let hlsAutoReconnectEnabled = "settings.hls.autoReconnectEnabled"
    static let hlsReconnectFailTimeoutSeconds = "settings.hls.reconnectFailTimeoutSeconds"
}

enum DownloadPreset: String, CaseIterable, Identifiable {
    case macCompatibleMP4 = "mac_compatible_mp4"
    case bestQualityMP4 = "best_quality_mp4"
    case audioOnlyM4A = "audio_only_m4a"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macCompatibleMP4: return "맥 호환 MP4"
        case .bestQualityMP4: return "최고 화질 MP4"
        case .audioOnlyM4A: return "오디오만 (M4A)"
        }
    }

    var shortDescription: String {
        switch self {
        case .macCompatibleMP4:
            return "QuickTime/미리보기 호환 우선"
        case .bestQualityMP4:
            return "최고 화질 우선 (호환성 낮을 수 있음)"
        case .audioOnlyM4A:
            return "음원만 저장"
        }
    }
}

enum FilenameConflictPolicy: String, CaseIterable, Identifiable {
    case autoRename = "auto_rename"
    case overwrite = "overwrite"
    case skipExisting = "skip_existing"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoRename: return "자동 이름 변경"
        case .overwrite: return "덮어쓰기"
        case .skipExisting: return "기존 파일 건너뛰기"
        }
    }
}

enum MergeBehavior: String, CaseIterable, Identifiable {
    case preserveOriginal = "preserve_original"
    case compatibilityPreferred = "compatibility_preferred"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserveOriginal:
            return "원본 유지 우선"
        case .compatibilityPreferred:
            return "호환성 우선"
        }
    }

    var shortDescription: String {
        switch self {
        case .preserveOriginal:
            return "같은 영상 조건이면 비디오 원본 유지, 오디오만 다르면 오디오만 변환"
        case .compatibilityPreferred:
            return "안 맞는 파일도 최대한 병합, 필요 시 변환"
        }
    }
}

enum DownloadPhase: String {
    case idle
    case preparing
    case downloading
    case recording
    case paused
    case merging
    case postProcessing
    case verifying
    case completed
    case failed
    case canceled

    var displayName: String {
        switch self {
        case .idle: return "대기"
        case .preparing: return "준비 중"
        case .downloading: return "다운로드 중"
        case .recording: return "녹화 중"
        case .paused: return "일시정지"
        case .merging: return "병합 중"
        case .postProcessing: return "후처리 중"
        case .verifying: return "완료 검증 중"
        case .completed: return "완료"
        case .failed: return "실패"
        case .canceled: return "취소됨"
        }
    }
}

enum DownloadFailureCategory: String {
    case unknown
    case toolMissing
    case invalidURL
    case network
    case permission
    case diskFull
    case authOrGeo
    case ytdlpOutdatedLikely
    case ffmpeg
    case incompleteFile
    case execution
}

struct DownloadOptions {
    let preset: DownloadPreset
    let conflictPolicy: FilenameConflictPolicy
    let filenameTemplate: String
    let forceDirectStreamCapture: Bool
    let hlsAutoReconnectEnabled: Bool
    let hlsReconnectFailTimeoutSeconds: Int

    static let `default` = DownloadOptions(
        preset: .macCompatibleMP4,
        conflictPolicy: .autoRename,
        filenameTemplate: "%(title)s.%(ext)s",
        forceDirectStreamCapture: false,
        hlsAutoReconnectEnabled: true,
        hlsReconnectFailTimeoutSeconds: 90
    )
}

struct DownloadValidationSummary {
    let isValid: Bool
    let fileSizeBytes: Int64?
    let durationSeconds: Double?
    let message: String
}

struct ToolInfo {
    let name: String
    let isInstalled: Bool
    let path: String?
}

struct ToolPaths {
    let ytDlpPath: URL
    let ffmpegPath: URL
    let ffprobePath: URL?
}

struct ToolStatus {
    var ytDlp: ToolInfo
    var ffmpeg: ToolInfo
    var ffprobe: ToolInfo?

    var allRequiredInstalled: Bool {
        ytDlp.isInstalled && ffmpeg.isInstalled
    }

    static let empty = ToolStatus(
        ytDlp: ToolInfo(
            name: "yt-dlp",
            isInstalled: false,
            path: nil
        ),
        ffmpeg: ToolInfo(
            name: "ffmpeg",
            isInstalled: false,
            path: nil
        ),
        ffprobe: ToolInfo(
            name: "ffprobe",
            isInstalled: false,
            path: nil
        )
    )
}
