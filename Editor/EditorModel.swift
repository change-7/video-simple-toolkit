import AppKit
import AVFoundation
import Foundation

enum EditorMediaKind: String, Codable, CaseIterable, Identifiable {
    case video
    case audio
    case image
    case subtitle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "비디오"
        case .audio: return "오디오"
        case .image: return "이미지"
        case .subtitle: return "자막"
        }
    }
}

enum EditorTrackKind: String, Codable, CaseIterable, Identifiable {
    case video
    case audio
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "비디오"
        case .audio: return "오디오"
        case .text: return "텍스트"
        }
    }
}

enum EditorClipKind: String, Codable, CaseIterable, Identifiable {
    case video
    case audio
    case image
    case text
    case subtitle

    var id: String { rawValue }
}

enum PerspectiveCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "좌상단"
        case .topRight: return "우상단"
        case .bottomRight: return "우하단"
        case .bottomLeft: return "좌하단"
        }
    }

    var shortTitle: String {
        switch self {
        case .topLeft: return "TL"
        case .topRight: return "TR"
        case .bottomRight: return "BR"
        case .bottomLeft: return "BL"
        }
    }
}

struct PerspectiveQuad: Codable, Hashable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let unit = PerspectiveQuad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    subscript(corner: PerspectiveCorner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }
}

struct EditorTransform: Codable, Hashable {
    var positionX: Double
    var positionY: Double
    var scaleX: Double
    var scaleY: Double
    var rotationDegrees: Double
    var opacity: Double
    /// Normalized source points used for perspective correction. The four
    /// picked points are mapped to the full export canvas.
    var perspective: PerspectiveQuad

    static let identity = EditorTransform(
        positionX: 0,
        positionY: 0,
        scaleX: 1,
        scaleY: 1,
        rotationDegrees: 0,
        opacity: 1,
        perspective: .unit
    )
}

struct EditorMediaAsset: Identifiable, Hashable, Codable {
    let id: UUID
    let url: URL
    let kind: EditorMediaKind
    let duration: Double
    let naturalSize: CGSize
    let hasAudio: Bool
    let subtitleCues: [SubtitleCue]

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

struct SubtitleCue: Codable, Hashable {
    let startTime: Double
    let endTime: Double
    let text: String

    var duration: Double {
        max(endTime - startTime, 0.2)
    }
}

struct EditorClip: Identifiable, Hashable, Codable {
    var id: UUID
    var mediaID: UUID?
    var sourceURL: URL?
    var kind: EditorClipKind
    var title: String
    var startTime: Double
    var duration: Double
    var trimStart: Double
    var sourceDuration: Double
    var transform: EditorTransform
    var text: String
    var hasAudio: Bool
    var fadeInDuration: Double? = nil
    var fadeOutDuration: Double? = nil

    var endTime: Double {
        startTime + duration
    }
}

struct EditorTrack: Identifiable, Hashable, Codable {
    var id: UUID
    var kind: EditorTrackKind
    var name: String
    var clips: [EditorClip]
    var isMuted: Bool
    var isHidden: Bool
}

struct EditorProjectDocument: Codable {
    var version: Int
    var mediaAssets: [EditorMediaAsset]
    var tracks: [EditorTrack]
    var renderWidth: Int
    var renderHeight: Int
    var outputBaseName: String
    var canvasPresetRawValue: String
    var exportPresetRawValue: String

    init(
        version: Int,
        mediaAssets: [EditorMediaAsset],
        tracks: [EditorTrack],
        renderWidth: Int,
        renderHeight: Int,
        outputBaseName: String,
        canvasPresetRawValue: String,
        exportPresetRawValue: String
    ) {
        self.version = version
        self.mediaAssets = mediaAssets
        self.tracks = tracks
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.outputBaseName = outputBaseName
        self.canvasPresetRawValue = canvasPresetRawValue
        self.exportPresetRawValue = exportPresetRawValue
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case mediaAssets
        case tracks
        case renderWidth
        case renderHeight
        case outputBaseName
        case canvasPresetRawValue
        case exportPresetRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        mediaAssets = try container.decodeIfPresent([EditorMediaAsset].self, forKey: .mediaAssets) ?? []
        tracks = try container.decodeIfPresent([EditorTrack].self, forKey: .tracks) ?? []
        renderWidth = try container.decodeIfPresent(Int.self, forKey: .renderWidth) ?? 1920
        renderHeight = try container.decodeIfPresent(Int.self, forKey: .renderHeight) ?? 1080
        outputBaseName = try container.decodeIfPresent(String.self, forKey: .outputBaseName) ?? "edited-video"
        canvasPresetRawValue = try container.decodeIfPresent(String.self, forKey: .canvasPresetRawValue) ?? "custom"
        exportPresetRawValue = try container.decodeIfPresent(String.self, forKey: .exportPresetRawValue) ?? EditorExportPreset.balanced.rawValue
    }
}

@MainActor
final class EditorTimelineStore: ObservableObject {
    @Published private(set) var mediaAssets: [EditorMediaAsset] = []
    @Published private(set) var tracks: [EditorTrack] = EditorTimelineStore.makeDefaultTracks()
    @Published var selectedClipID: UUID?
    @Published var selectedMediaAssetID: UUID?
    @Published var playheadTime: Double = 0
    @Published var userMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm"]
    private let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "flac"]
    private let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tiff"]
    private let supportedSubtitleExtensions: Set<String> = ["srt"]
    private let maximumUndoHistoryCount = 100

    private var undoStack: [TimelineSnapshot] = []
    private var redoStack: [TimelineSnapshot] = []
    private var undoGroupDepth = 0
    private var undoGroupStartSnapshot: TimelineSnapshot?
    private var undoRecordingDepth = 0

    private struct TimelineSnapshot: Equatable {
        let mediaAssets: [EditorMediaAsset]
        let tracks: [EditorTrack]
        let selectedClipID: UUID?
        let selectedMediaAssetID: UUID?
    }

    var timelineDuration: Double {
        tracks
            .flatMap(\.clips)
            .map(\.endTime)
            .max() ?? 0
    }

    var selectedClip: EditorClip? {
        guard let selectedClipID else { return nil }
        return tracks.lazy.flatMap(\.clips).first { $0.id == selectedClipID }
    }

    var selectedMediaAsset: EditorMediaAsset? {
        if let selectedMediaAssetID,
           let asset = mediaAssets.first(where: { $0.id == selectedMediaAssetID }) {
            return asset
        }

        guard let mediaID = selectedClip?.mediaID else { return nil }
        return mediaAssets.first { $0.id == mediaID }
    }

    var canAppendSelectedMediaToTimeline: Bool {
        guard let kind = selectedMediaAsset?.kind else { return false }
        return kind == .video || kind == .audio || kind == .image || kind == .subtitle
    }

    func undo() {
        guard undoGroupDepth == 0,
              let previousSnapshot = undoStack.popLast()
        else { return }

        redoStack.append(makeTimelineSnapshot())
        restoreTimelineSnapshot(previousSnapshot, userMessage: "실행 취소했습니다.")
        refreshUndoRedoAvailability()
    }

    func redo() {
        guard undoGroupDepth == 0,
              let nextSnapshot = redoStack.popLast()
        else { return }

        undoStack.append(makeTimelineSnapshot())
        trimUndoHistoryIfNeeded()
        restoreTimelineSnapshot(nextSnapshot, userMessage: "다시 실행했습니다.")
        refreshUndoRedoAvailability()
    }

    func beginUndoGroup() {
        if undoGroupDepth == 0 {
            undoGroupStartSnapshot = makeTimelineSnapshot()
        }
        undoGroupDepth += 1
    }

    func commitUndoGroup() {
        guard undoGroupDepth > 0 else { return }

        undoGroupDepth -= 1
        guard undoGroupDepth == 0 else { return }

        if let undoGroupStartSnapshot {
            registerUndoSnapshotIfNeeded(undoGroupStartSnapshot)
        }
        self.undoGroupStartSnapshot = nil
    }

    func cancelUndoGroup() {
        undoGroupDepth = 0
        undoGroupStartSnapshot = nil
    }

    @discardableResult
    func performUndoable(_ updates: () -> Void) -> Bool {
        let shouldRecordIndividually = undoRecordingDepth == 0 && undoGroupDepth == 0
        let snapshot = shouldRecordIndividually ? makeTimelineSnapshot() : nil

        undoRecordingDepth += 1
        updates()
        undoRecordingDepth -= 1

        guard let snapshot else { return false }
        return registerUndoSnapshotIfNeeded(snapshot)
    }

    func importMedia(urls: [URL]) {
        let normalized = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }

        guard !normalized.isEmpty else {
            userMessage = "가져올 로컬 미디어 파일을 찾지 못했습니다."
            return
        }

        performUndoable {
            var importedAssets: [EditorMediaAsset] = []
            var importedCount = 0
            var unsupportedCount = 0

            for url in normalized {
                if mediaAssets.contains(where: { $0.url == url }) {
                    continue
                }

                guard let kind = mediaKind(for: url) else {
                    unsupportedCount += 1
                    continue
                }

                let asset = readAsset(url: url, kind: kind)
                mediaAssets.append(asset)
                importedAssets.append(asset)
                importedCount += 1
            }

            var autoAddedSubtitleCount = 0
            for asset in importedAssets where asset.kind == .subtitle {
                autoAddedSubtitleCount += addSubtitleAssetToTimeline(asset, selectInsertedClip: false)
            }

            if importedCount > 0 {
                if autoAddedSubtitleCount > 0 {
                    userMessage = "\(importedCount)개 미디어/SRT를 가져왔고 \(autoAddedSubtitleCount)개 자막을 타임라인에 올렸습니다."
                } else {
                    userMessage = "\(importedCount)개 미디어/SRT를 가져왔습니다."
                }
            } else if unsupportedCount > 0 {
                userMessage = "지원하는 비디오, 오디오, 이미지, SRT 파일을 선택해 주세요."
            }
        }
    }

    func importMediaAndAddToTimeline(urls: [URL], selectAddedClip: Bool = true) {
        let normalized = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }

        guard !normalized.isEmpty else {
            userMessage = "타임라인에 추가할 로컬 파일을 찾지 못했습니다."
            return
        }

        performUndoable {
            let existingSubtitleURLs = Set(mediaAssets.filter { $0.kind == .subtitle }.map(\.url))
            importMedia(urls: normalized)

            var addedCount = 0
            for url in normalized {
                guard let asset = mediaAssets.first(where: { $0.url == url }) else { continue }
                if asset.kind == .subtitle {
                    if existingSubtitleURLs.contains(asset.url) {
                        addClipToTimeline(assetID: asset.id, selectInsertedClip: selectAddedClip)
                        addedCount += 1
                    }
                    continue
                }
                addClipToTimeline(assetID: asset.id, selectInsertedClip: selectAddedClip)
                addedCount += 1
            }

            if addedCount > 0 {
                userMessage = "\(addedCount)개 파일을 타임라인에 추가했습니다."
            }
        }
    }

    func selectMediaAsset(_ assetID: UUID) {
        selectedMediaAssetID = assetID
    }

    func selectClip(_ clip: EditorClip, movePlayhead: Bool = true) {
        selectedClipID = clip.id
        selectedMediaAssetID = clip.mediaID
        if movePlayhead {
            setPlayhead(to: clip.startTime)
        }
    }

    func appendSelectedMediaToTimeline() {
        guard let asset = selectedMediaAsset else {
            userMessage = "붙일 미디어를 먼저 선택해 주세요."
            return
        }

        guard canAppendSelectedMediaToTimeline else {
            userMessage = "타임라인 붙이기는 비디오, 오디오, 이미지, SRT 자막에서 사용할 수 있습니다."
            return
        }

        addClipToTimeline(assetID: asset.id)
    }

    func addClipToTimeline(assetID: UUID, selectInsertedClip: Bool = true) {
        guard let asset = mediaAssets.first(where: { $0.id == assetID }) else { return }

        performUndoable {
            if asset.kind == .subtitle {
                let addedCount = addSubtitleAssetToTimeline(asset, selectInsertedClip: selectInsertedClip)
                if addedCount > 0 {
                    selectedMediaAssetID = assetID
                }
                return
            }

            selectedMediaAssetID = assetID

            let clipKind: EditorClipKind
            let trackKind: EditorTrackKind

            switch asset.kind {
            case .video:
                clipKind = .video
                trackKind = .video
            case .audio:
                clipKind = .audio
                trackKind = .audio
            case .image:
                clipKind = .image
                trackKind = .video
            case .subtitle:
                return
            }

            let duration = defaultDuration(for: asset)
            let startTime = insertionStartTime(for: trackKind)
            let clip = EditorClip(
                id: UUID(),
                mediaID: asset.id,
                sourceURL: asset.url,
                kind: clipKind,
                title: asset.displayName,
                startTime: startTime,
                duration: duration,
                trimStart: 0,
                sourceDuration: max(asset.duration, duration),
                transform: .identity,
                text: "",
                hasAudio: asset.hasAudio
            )

            appendClip(clip, to: trackKind)
            if selectInsertedClip {
                selectedClipID = clip.id
                playheadTime = clip.startTime
            }
            userMessage = "\(asset.displayName)을 타임라인에 추가했습니다."
        }
    }

    func addTextClip() {
        performUndoable {
            let startTime = playheadTime > 0 ? playheadTime : nextStartTime(for: .text)
            let clip = EditorClip(
                id: UUID(),
                mediaID: nil,
                sourceURL: nil,
                kind: .text,
                title: "Text",
                startTime: startTime,
                duration: 4,
                trimStart: 0,
                sourceDuration: 4,
                transform: defaultSubtitleTransform(),
                text: "새 자막",
                hasAudio: false
            )

            appendClip(clip, to: .text)
            selectedClipID = clip.id
            selectedMediaAssetID = nil
        }
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
              clipLocation(for: selectedClipID) != nil else {
            userMessage = "지울 클립을 선택해 주세요."
            return
        }

        performUndoable {
            for trackIndex in tracks.indices {
                tracks[trackIndex].clips.removeAll { $0.id == selectedClipID }
            }
            self.selectedClipID = nil
            userMessage = "선택한 클립을 삭제했습니다."
        }
    }

    func duplicateSelectedClip() {
        guard let location = selectedClipLocation() else {
            userMessage = "복제할 클립을 선택해 주세요."
            return
        }

        performUndoable {
            let original = tracks[location.trackIndex].clips[location.clipIndex]
            var duplicate = original
            duplicate.id = UUID()
            duplicate.title = "\(original.title) copy"
            duplicate.startTime = original.endTime

            appendClip(duplicate, to: tracks[location.trackIndex].kind)
            selectedClipID = duplicate.id
            selectedMediaAssetID = duplicate.mediaID

            if let updatedLocation = clipLocation(for: duplicate.id) {
                playheadTime = tracks[updatedLocation.trackIndex].clips[updatedLocation.clipIndex].startTime
            }

            userMessage = "\(original.title)을 복제했습니다."
        }
    }

    func moveSelectedClipToPlayhead() {
        guard let selectedClip else {
            userMessage = "이동할 클립을 선택해 주세요."
            return
        }

        moveClip(id: selectedClip.id, toStartTime: playheadTime, snapping: false)
        userMessage = "선택 클립을 플레이헤드 위치로 이동했습니다."
    }

    func rippleDeleteSelectedClip() {
        guard let clipID = selectedClipID,
              let location = clipLocation(for: clipID) else {
            userMessage = "리플 삭제할 클립을 선택해 주세요."
            return
        }

        performUndoable {
            let removedClip = tracks[location.trackIndex].clips[location.clipIndex]
            tracks[location.trackIndex].clips.remove(at: location.clipIndex)

            for clipIndex in tracks[location.trackIndex].clips.indices
            where tracks[location.trackIndex].clips[clipIndex].startTime >= removedClip.endTime {
                tracks[location.trackIndex].clips[clipIndex].startTime = max(
                    0,
                    tracks[location.trackIndex].clips[clipIndex].startTime - removedClip.duration
                )
            }

            tracks[location.trackIndex].clips.sort { $0.startTime < $1.startTime }
            self.selectedClipID = tracks[location.trackIndex].clips
                .first { $0.startTime >= removedClip.startTime }?.id
                ?? tracks[location.trackIndex].clips.last?.id
            playheadTime = removedClip.startTime
            userMessage = "선택한 클립을 삭제하고 뒤 클립을 앞으로 당겼습니다."
        }
    }

    func closeGapsOnSelectedTrack() {
        guard let location = selectedClipLocation() else {
            userMessage = "간격을 닫을 트랙의 클립을 선택해 주세요."
            return
        }

        performUndoable {
            tracks[location.trackIndex].clips.sort { $0.startTime < $1.startTime }

            var cursor = 0.0
            for clipIndex in tracks[location.trackIndex].clips.indices {
                tracks[location.trackIndex].clips[clipIndex].startTime = cursor
                cursor += tracks[location.trackIndex].clips[clipIndex].duration
            }

            if let selectedClipID,
               let updatedLocation = clipLocation(for: selectedClipID) {
                playheadTime = tracks[updatedLocation.trackIndex].clips[updatedLocation.clipIndex].startTime
            } else {
                playheadTime = 0
            }

            userMessage = "선택 트랙의 빈 간격을 닫았습니다."
        }
    }

    func splitSelectedClip() {
        guard let location = selectedClipLocation() ?? clipLocationForSplit(at: playheadTime) else {
            userMessage = "자를 클립을 선택해 주세요."
            return
        }

        let clip = tracks[location.trackIndex].clips[location.clipIndex]
        guard clip.duration > 0.4 else {
            userMessage = "자를 수 있을 만큼 긴 클립을 선택해 주세요."
            return
        }

        let localSplit = playheadTime - clip.startTime
        guard localSplit > 0.2 && localSplit < clip.duration - 0.2 else {
            userMessage = "플레이헤드를 선택 클립 안쪽으로 이동한 뒤 잘라 주세요."
            return
        }

        performUndoable {
            var leftClip = clip
            leftClip.duration = localSplit

            var rightClip = clip
            rightClip.id = UUID()
            rightClip.startTime = clip.startTime + localSplit
            rightClip.trimStart = clip.trimStart + localSplit
            rightClip.duration = clip.duration - localSplit
            rightClip.title = "\(clip.title) split"

            tracks[location.trackIndex].clips[location.clipIndex] = leftClip
            tracks[location.trackIndex].clips.insert(rightClip, at: location.clipIndex + 1)
            selectedClipID = rightClip.id
            playheadTime = rightClip.startTime
            userMessage = "\(clip.title)을 플레이헤드에서 잘랐습니다."
        }
    }

    func splitAllClipsAtPlayhead() {
        let locations = clipLocationsForSplit(at: playheadTime)
        guard !locations.isEmpty else {
            userMessage = "플레이헤드 아래에 자를 클립이 없습니다."
            return
        }

        performUndoable {
            var firstRightClipID: UUID?

            for location in locations.sorted(by: { lhs, rhs in
                if lhs.trackIndex == rhs.trackIndex {
                    return lhs.clipIndex > rhs.clipIndex
                }
                return lhs.trackIndex > rhs.trackIndex
            }) {
                guard tracks.indices.contains(location.trackIndex),
                      tracks[location.trackIndex].clips.indices.contains(location.clipIndex)
                else { continue }

                let clip = tracks[location.trackIndex].clips[location.clipIndex]
                let localSplit = playheadTime - clip.startTime
                guard localSplit > 0.2 && localSplit < clip.duration - 0.2 else { continue }

                var leftClip = clip
                leftClip.duration = localSplit

                var rightClip = clip
                rightClip.id = UUID()
                rightClip.startTime = clip.startTime + localSplit
                rightClip.trimStart = clip.trimStart + localSplit
                rightClip.duration = clip.duration - localSplit
                rightClip.title = "\(clip.title) split"

                tracks[location.trackIndex].clips[location.clipIndex] = leftClip
                tracks[location.trackIndex].clips.insert(rightClip, at: location.clipIndex + 1)
                firstRightClipID = firstRightClipID ?? rightClip.id
            }

            selectedClipID = firstRightClipID
            userMessage = "\(locations.count)개 클립을 플레이헤드에서 잘랐습니다."
        }
    }

    func nudgeSelectedClip(seconds: Double, snapping: Bool = false) {
        guard let selectedClip else { return }
        moveClip(id: selectedClip.id, toStartTime: selectedClip.startTime + seconds, snapping: snapping)
    }

    func trimSelectedClipStart(by seconds: Double) {
        guard let selectedClip else { return }
        trimClipStart(id: selectedClip.id, toStartTime: selectedClip.startTime + seconds)
    }

    func trimSelectedClipEnd(by seconds: Double) {
        guard let selectedClip else { return }
        trimClipEnd(id: selectedClip.id, toEndTime: selectedClip.endTime + seconds)
    }

    func trimSelectedClipStartToPlayhead() {
        let location = selectedClipLocation() ?? clipLocationForSplit(at: playheadTime)
        guard let location else {
            userMessage = "앞부분을 자를 클립을 선택하거나 플레이헤드를 클립 위에 놓아 주세요."
            return
        }

        let clip = tracks[location.trackIndex].clips[location.clipIndex]
        guard playheadTime > clip.startTime + 0.05 && playheadTime < clip.endTime - 0.05 else {
            userMessage = "플레이헤드를 클립 안쪽에 놓아 주세요."
            return
        }

        trimClipStart(id: clip.id, toStartTime: playheadTime)
    }

    func trimSelectedClipEndToPlayhead() {
        let location = selectedClipLocation() ?? clipLocationForSplit(at: playheadTime)
        guard let location else {
            userMessage = "뒷부분을 자를 클립을 선택하거나 플레이헤드를 클립 위에 놓아 주세요."
            return
        }

        let clip = tracks[location.trackIndex].clips[location.clipIndex]
        guard playheadTime > clip.startTime + 0.05 && playheadTime < clip.endTime - 0.05 else {
            userMessage = "플레이헤드를 클립 안쪽에 놓아 주세요."
            return
        }

        trimClipEnd(id: clip.id, toEndTime: playheadTime)
    }

    func moveClip(
        id: UUID,
        toStartTime startTime: Double,
        snapping: Bool = true,
        baselineClips: [EditorClip]? = nil
    ) {
        guard let location = clipLocation(for: id) else { return }

        performUndoable {
            if let baselineClips,
               baselineClips.contains(where: { $0.id == id }) {
                tracks[location.trackIndex].clips = baselineClips
            }

            guard let updatedLocation = clipLocation(for: id) else { return }
            var clip = tracks[updatedLocation.trackIndex].clips.remove(at: updatedLocation.clipIndex)
            var candidateStart = max(0, startTime)
            if snapping {
                candidateStart = snappedTime(candidateStart, excluding: id)
            }

            let candidateEnd = candidateStart + clip.duration
            if snapping {
                let snappedEnd = snappedTime(candidateEnd, excluding: id)
                if abs(snappedEnd - candidateEnd) <= snapTolerance {
                    candidateStart = max(0, snappedEnd - clip.duration)
                }
            }

            clip.startTime = candidateStart
            tracks[updatedLocation.trackIndex].clips.append(clip)
            resolveOverlaps(in: updatedLocation.trackIndex, priorityClipID: id)

            selectedClipID = id
            if let updatedLocation = clipLocation(for: id) {
                playheadTime = tracks[updatedLocation.trackIndex].clips[updatedLocation.clipIndex].startTime
            } else {
                playheadTime = candidateStart
            }
        }
    }

    func trimClipStart(id: UUID, toStartTime startTime: Double) {
        guard let location = clipLocation(for: id) else { return }

        performUndoable {
            let clip = tracks[location.trackIndex].clips[location.clipIndex]
            let bounds = neighborBounds(for: id, in: location.trackIndex)
            let upper = max(clip.endTime - 0.2, 0)
            let snappedStart = snappedTime(startTime, excluding: id)
            let sourceLower = max(0, clip.startTime - clip.trimStart)
            let lowerStart = max(sourceLower, bounds.previousEnd)
            let newStart = clamped(snappedStart, lower: lowerStart, upper: max(lowerStart, upper))
            let delta = newStart - clip.startTime

            tracks[location.trackIndex].clips[location.clipIndex].startTime = newStart
            tracks[location.trackIndex].clips[location.clipIndex].trimStart = max(0, clip.trimStart + delta)
            tracks[location.trackIndex].clips[location.clipIndex].duration = max(0.2, clip.duration - delta)
            normalizeFadeDurations(at: location)
            tracks[location.trackIndex].clips.sort { $0.startTime < $1.startTime }
            selectedClipID = id
            playheadTime = newStart
        }
    }

    func trimClipEnd(id: UUID, toEndTime endTime: Double) {
        guard let location = clipLocation(for: id) else { return }

        performUndoable {
            let clip = tracks[location.trackIndex].clips[location.clipIndex]
            let bounds = neighborBounds(for: id, in: location.trackIndex)
            let maxEnd = clip.startTime + max(0.2, clip.sourceDuration - clip.trimStart)
            let snappedEnd = snappedTime(endTime, excluding: id)
            let lowerEnd = clip.startTime + 0.2
            let constrainedMaxEnd = bounds.nextStart.map { min(maxEnd, $0) } ?? maxEnd
            let newEnd = clamped(snappedEnd, lower: lowerEnd, upper: max(lowerEnd, constrainedMaxEnd))

            tracks[location.trackIndex].clips[location.clipIndex].duration = max(0.2, newEnd - clip.startTime)
            normalizeFadeDurations(at: location)
            tracks[location.trackIndex].clips.sort { $0.startTime < $1.startTime }
            selectedClipID = id
        }
    }

    func shiftSelectedTextGroup(seconds: Double) {
        guard let selectedClip,
              selectedClip.kind == .text || selectedClip.kind == .subtitle else {
            userMessage = "자막 또는 텍스트 클립을 선택해 주세요."
            return
        }

        performUndoable {
            shiftTextClips(seconds: seconds) { clip in
                if let mediaID = selectedClip.mediaID {
                    return clip.mediaID == mediaID
                }
                return clip.id == selectedClip.id
            }

            userMessage = "선택 자막 싱크를 \(formattedSignedSeconds(seconds)) 이동했습니다."
        }
    }

    func shiftAllTextClips(seconds: Double) {
        performUndoable {
            shiftTextClips(seconds: seconds) { $0.kind == .text || $0.kind == .subtitle }
            userMessage = "전체 자막 싱크를 \(formattedSignedSeconds(seconds)) 이동했습니다."
        }
    }

    func updateSelectedText(_ text: String) {
        performUndoable {
            mutateSelectedClip { clip in
                clip.text = text
                clip.title = text.isEmpty ? "Text" : text
            }
        }
    }

    func updateSelectedTransform(_ transform: EditorTransform) {
        performUndoable {
            mutateSelectedClip { clip in
                clip.transform = transform
            }
        }
    }

    func setClipFade(id: UUID, fadeInDuration: Double? = nil, fadeOutDuration: Double? = nil) {
        guard fadeInDuration != nil || fadeOutDuration != nil else { return }
        guard let location = clipLocation(for: id) else { return }

        performUndoable {
            let clipDuration = tracks[location.trackIndex].clips[location.clipIndex].duration
            if let fadeInDuration {
                tracks[location.trackIndex].clips[location.clipIndex].fadeInDuration = clampedFadeDuration(fadeInDuration, clipDuration: clipDuration)
            }
            if let fadeOutDuration {
                tracks[location.trackIndex].clips[location.clipIndex].fadeOutDuration = clampedFadeDuration(fadeOutDuration, clipDuration: clipDuration)
            }
            selectedClipID = id
        }
    }

    private func normalizeFadeDurations(at location: (trackIndex: Int, clipIndex: Int)) {
        let clipDuration = tracks[location.trackIndex].clips[location.clipIndex].duration
        let fadeIn = tracks[location.trackIndex].clips[location.clipIndex].fadeInDuration ?? 0
        let fadeOut = tracks[location.trackIndex].clips[location.clipIndex].fadeOutDuration ?? 0
        tracks[location.trackIndex].clips[location.clipIndex].fadeInDuration = clampedFadeDuration(fadeIn, clipDuration: clipDuration)
        tracks[location.trackIndex].clips[location.clipIndex].fadeOutDuration = clampedFadeDuration(fadeOut, clipDuration: clipDuration)
    }

    func updateSelectedPerspective(corner: PerspectiveCorner, point: CGPoint) {
        performUndoable {
            mutateSelectedClip { clip in
                let normalized = CGPoint(
                    x: clamped(point.x, lower: -0.35, upper: 1.35),
                    y: clamped(point.y, lower: -0.35, upper: 1.35)
                )
                clip.transform.perspective[corner] = normalized
            }
        }
    }

    func resetSelectedPerspective() {
        performUndoable {
            mutateSelectedClip { clip in
                clip.transform.perspective = .unit
            }
        }
    }

    func toggleTrackMute(id: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == id }) else { return }

        performUndoable {
            tracks[trackIndex].isMuted.toggle()
            let state = tracks[trackIndex].isMuted ? "음소거" : "음소거 해제"
            userMessage = "\(tracks[trackIndex].name) 트랙을 \(state)했습니다."
        }
    }

    func toggleTrackHidden(id: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == id }) else { return }

        performUndoable {
            tracks[trackIndex].isHidden.toggle()
            let state = tracks[trackIndex].isHidden ? "숨김" : "표시"
            userMessage = "\(tracks[trackIndex].name) 트랙을 \(state)했습니다."
        }
    }

    func setPlayhead(to time: Double) {
        playheadTime = clamped(time, lower: 0, upper: max(timelineDuration, 0))
    }

    func makeExportRequest(
        outputDirectory: URL,
        outputBaseName: String,
        renderSize: CGSize,
        preset: EditorExportPreset,
        ffmpegURL: URL,
        ffprobeURL: URL?
    ) -> EditorExportRequest? {
        var visualClips: [EditorClip] = []
        var audioClips: [EditorClip] = []

        for track in tracks {
            switch track.kind {
            case .video:
                guard !track.isHidden else { continue }
                for clip in track.clips where clip.kind == .video || clip.kind == .image {
                    var exportClip = clip
                    if track.isMuted {
                        exportClip.hasAudio = false
                    }
                    visualClips.append(exportClip)
                }
            case .audio:
                guard !track.isMuted && !track.isHidden else { continue }
                audioClips.append(contentsOf: track.clips.filter { $0.kind == .audio })
            case .text:
                continue
            }
        }

        visualClips.sort { $0.startTime < $1.startTime }
        audioClips.sort { $0.startTime < $1.startTime }

        let textClips = exportTextClips()

        guard !visualClips.isEmpty || !audioClips.isEmpty || !textClips.isEmpty else {
            userMessage = "출력할 클립을 타임라인에 추가해 주세요."
            return nil
        }

        return EditorExportRequest(
            visualClips: visualClips.map(EditorExportClip.init),
            audioClips: audioClips.map(EditorExportClip.init),
            textOverlays: textClips.map(EditorExportText.init),
            outputDirectory: outputDirectory,
            outputBaseName: outputBaseName,
            renderSize: CGSize(
                width: max(renderSize.width.rounded(), 2),
                height: max(renderSize.height.rounded(), 2)
            ),
            frameRate: 30,
            preset: preset,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
        )
    }

    func visibleTextClips(at time: Double) -> [EditorClip] {
        tracks
            .filter { $0.kind == .text && !$0.isHidden }
            .flatMap(\.clips)
            .compactMap { clip in
            switch clip.kind {
            case .text:
                guard clip.startTime <= time && time <= clip.endTime else { return nil }
                return clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clip
            case .subtitle:
                return activeSubtitleTextClip(for: clip, at: time)
            case .video, .audio, .image:
                return nil
            }
        }
    }

    func activeVisualClip(at time: Double) -> EditorClip? {
        let visualClips = tracks
            .filter { $0.kind == .video && !$0.isHidden }
            .flatMap(\.clips)
            .filter { $0.kind == .video || $0.kind == .image }

        return visualClips.first { clip in
            clip.startTime <= time && time < clip.endTime
        } ?? visualClips.last { clip in
            abs(clip.endTime - time) < 0.0001
        }
    }

    func activeAudioClips(at time: Double) -> [EditorClip] {
        tracks
            .filter { $0.kind == .audio && !$0.isMuted && !$0.isHidden }
            .flatMap(\.clips)
            .filter { clip in
                clip.kind == .audio && clip.startTime <= time && time < clip.endTime
            }
    }

    func isTrackMuted(for clipID: UUID) -> Bool {
        guard let location = clipLocation(for: clipID) else { return false }
        return tracks[location.trackIndex].isMuted
    }

    func movePlayheadToStart() {
        setPlayhead(to: 0)
    }

    func movePlayheadToEnd() {
        setPlayhead(to: timelineDuration)
    }

    func movePlayheadToPreviousEditPoint() {
        let target = sortedEditPoints().last { $0 < playheadTime - 0.05 } ?? 0
        setPlayhead(to: target)
    }

    func movePlayheadToNextEditPoint() {
        let target = sortedEditPoints().first { $0 > playheadTime + 0.05 } ?? timelineDuration
        setPlayhead(to: target)
    }

    func clips(for kind: EditorTrackKind) -> [EditorClip] {
        tracks.first(where: { $0.kind == kind })?.clips ?? []
    }

    private func exportTextClips() -> [EditorClip] {
        tracks
            .filter { $0.kind == .text && !$0.isHidden }
            .flatMap(\.clips)
            .flatMap { clip -> [EditorClip] in
            switch clip.kind {
            case .text:
                return clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [clip]
            case .subtitle:
                return subtitleTextClips(for: clip)
            case .video, .audio, .image:
                return []
            }
        }
    }

    private func activeSubtitleTextClip(for clip: EditorClip, at timelineTime: Double) -> EditorClip? {
        guard clip.kind == .subtitle,
              clip.startTime <= timelineTime,
              timelineTime <= clip.endTime,
              let asset = subtitleAsset(for: clip)
        else { return nil }

        let localTime = clip.trimStart + timelineTime - clip.startTime
        guard let cue = asset.subtitleCues.first(where: { cue in
            cue.startTime <= localTime && localTime <= cue.endTime
        }) else { return nil }

        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var subtitleClip = clip
        subtitleClip.kind = .subtitle
        subtitleClip.title = subtitleClipTitle(text: text, fallback: clip.title)
        subtitleClip.text = text
        subtitleClip.startTime = timelineTime
        subtitleClip.duration = cue.duration
        return subtitleClip
    }

    private func subtitleTextClips(for clip: EditorClip) -> [EditorClip] {
        guard clip.kind == .subtitle,
              let asset = subtitleAsset(for: clip)
        else { return [] }

        let visibleStart = clip.trimStart
        let visibleEnd = clip.trimStart + clip.duration

        return asset.subtitleCues.compactMap { cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let cueStart = max(cue.startTime, visibleStart)
            let cueEnd = min(cue.endTime, visibleEnd)
            guard cueEnd > cueStart else { return nil }

            var textClip = clip
            textClip.id = UUID()
            textClip.kind = .text
            textClip.title = subtitleClipTitle(text: text, fallback: clip.title)
            textClip.startTime = clip.startTime + cueStart - clip.trimStart
            textClip.duration = max(cueEnd - cueStart, 0.05)
            textClip.trimStart = 0
            textClip.sourceDuration = textClip.duration
            textClip.text = text
            return textClip
        }
    }

    private func subtitleAsset(for clip: EditorClip) -> EditorMediaAsset? {
        guard let mediaID = clip.mediaID else { return nil }
        return mediaAssets.first { $0.id == mediaID && $0.kind == .subtitle }
    }

    func makeProjectDocument(
        renderWidth: Int,
        renderHeight: Int,
        outputBaseName: String,
        canvasPresetRawValue: String,
        exportPresetRawValue: String
    ) -> EditorProjectDocument {
        EditorProjectDocument(
            version: 1,
            mediaAssets: mediaAssets,
            tracks: tracks,
            renderWidth: renderWidth,
            renderHeight: renderHeight,
            outputBaseName: outputBaseName,
            canvasPresetRawValue: canvasPresetRawValue,
            exportPresetRawValue: exportPresetRawValue
        )
    }

    func loadProjectDocument(_ document: EditorProjectDocument) {
        performUndoable {
            mediaAssets = document.mediaAssets
            tracks = normalizedTracks(document.tracks)
            selectedClipID = nil
            selectedMediaAssetID = nil
            playheadTime = 0
            userMessage = "프로젝트를 불러왔습니다."
        }
    }

    private func makeTimelineSnapshot() -> TimelineSnapshot {
        TimelineSnapshot(
            mediaAssets: mediaAssets,
            tracks: tracks,
            selectedClipID: selectedClipID,
            selectedMediaAssetID: selectedMediaAssetID
        )
    }

    private func restoreTimelineSnapshot(_ snapshot: TimelineSnapshot, userMessage: String) {
        mediaAssets = snapshot.mediaAssets
        tracks = snapshot.tracks
        selectedClipID = snapshot.selectedClipID
        selectedMediaAssetID = snapshot.selectedMediaAssetID
        playheadTime = clamped(playheadTime, lower: 0, upper: max(timelineDuration, 0))
        self.userMessage = userMessage
    }

    @discardableResult
    private func registerUndoSnapshotIfNeeded(_ snapshot: TimelineSnapshot) -> Bool {
        guard snapshot != makeTimelineSnapshot() else { return false }

        undoStack.append(snapshot)
        trimUndoHistoryIfNeeded()
        redoStack.removeAll()
        refreshUndoRedoAvailability()
        return true
    }

    private func trimUndoHistoryIfNeeded() {
        guard undoStack.count > maximumUndoHistoryCount else { return }
        undoStack.removeFirst(undoStack.count - maximumUndoHistoryCount)
    }

    private func refreshUndoRedoAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func appendClip(_ clip: EditorClip, to trackKind: EditorTrackKind) {
        let trackIndex = ensureTrack(for: trackKind)
        tracks[trackIndex].clips.append(clip)
        resolveOverlaps(in: trackIndex, priorityClipID: clip.id)
    }

    private func sortClips(in trackIndex: Int, priorityClipID: UUID? = nil) {
        tracks[trackIndex].clips.sort { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                if lhs.id == priorityClipID { return true }
                if rhs.id == priorityClipID { return false }
                return lhs.title < rhs.title
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func resolveOverlaps(in trackIndex: Int, priorityClipID: UUID? = nil) {
        guard tracks.indices.contains(trackIndex) else { return }

        sortClips(in: trackIndex, priorityClipID: priorityClipID)

        var cursor = 0.0
        for clipIndex in tracks[trackIndex].clips.indices {
            if tracks[trackIndex].clips[clipIndex].startTime < cursor {
                tracks[trackIndex].clips[clipIndex].startTime = cursor
            }
            cursor = tracks[trackIndex].clips[clipIndex].endTime
        }
    }

    private func ensureTrack(for kind: EditorTrackKind) -> Int {
        if let existingIndex = tracks.firstIndex(where: { $0.kind == kind }) {
            return existingIndex
        }

        tracks.append(EditorTrack(id: UUID(), kind: kind, name: defaultTrackName(for: kind), clips: [], isMuted: false, isHidden: false))
        sortTracksByDisplayOrder()
        return tracks.firstIndex(where: { $0.kind == kind }) ?? tracks.indices.last!
    }

    private func mutateSelectedClip(_ mutate: (inout EditorClip) -> Void) {
        guard let location = selectedClipLocation() else { return }
        mutate(&tracks[location.trackIndex].clips[location.clipIndex])
        tracks[location.trackIndex].clips.sort { $0.startTime < $1.startTime }
    }

    private func selectedClipLocation() -> (trackIndex: Int, clipIndex: Int)? {
        guard let selectedClipID else { return nil }
        return clipLocation(for: selectedClipID)
    }

    private func clipLocation(for clipID: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for trackIndex in tracks.indices {
            if let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                return (trackIndex, clipIndex)
            }
        }

        return nil
    }

    private func clipLocationForSplit(at time: Double) -> (trackIndex: Int, clipIndex: Int)? {
        clipLocationsForSplit(at: time).first
    }

    private func clipLocationsForSplit(at time: Double) -> [(trackIndex: Int, clipIndex: Int)] {
        var locations: [(trackIndex: Int, clipIndex: Int)] = []
        for trackIndex in tracks.indices {
            let sortedClipIndexes = tracks[trackIndex].clips.indices.sorted {
                tracks[trackIndex].clips[$0].startTime < tracks[trackIndex].clips[$1].startTime
            }

            for clipIndex in sortedClipIndexes {
                let clip = tracks[trackIndex].clips[clipIndex]
                let localTime = time - clip.startTime
                if localTime > 0.2 && localTime < clip.duration - 0.2 {
                    locations.append((trackIndex, clipIndex))
                    break
                }
            }
        }

        return locations
    }

    private func neighborBounds(for clipID: UUID, in trackIndex: Int) -> (previousEnd: Double, nextStart: Double?) {
        let sortedClips = tracks[trackIndex].clips.sorted {
            if $0.startTime == $1.startTime {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startTime < $1.startTime
        }

        guard let sortedIndex = sortedClips.firstIndex(where: { $0.id == clipID }) else {
            return (0, nil)
        }

        let previousEnd = sortedIndex > 0 ? sortedClips[sortedIndex - 1].endTime : 0
        let nextStart = sortedIndex < sortedClips.index(before: sortedClips.endIndex)
            ? sortedClips[sortedIndex + 1].startTime
            : nil
        return (previousEnd, nextStart)
    }

    private var snapTolerance: Double {
        0.12
    }

    private func snappedTime(_ time: Double, excluding clipID: UUID?) -> Double {
        let candidate = max(0, time)
        let nearest = snapPoints(excluding: clipID)
            .min { abs($0 - candidate) < abs($1 - candidate) }

        guard let nearest, abs(nearest - candidate) <= snapTolerance else {
            return candidate
        }

        return max(0, nearest)
    }

    private func snapPoints(excluding clipID: UUID?) -> [Double] {
        var points: [Double] = [0, playheadTime]

        for clip in tracks.flatMap(\.clips) where clip.id != clipID {
            points.append(clip.startTime)
            points.append(clip.endTime)
        }

        return points
    }

    private func sortedEditPoints() -> [Double] {
        var points = Set<Double>()
        points.insert(0)
        points.insert(timelineDuration)

        for clip in tracks.flatMap(\.clips) {
            points.insert(max(0, clip.startTime))
            points.insert(max(0, clip.endTime))
        }

        return points
            .filter { $0.isFinite }
            .sorted()
    }

    private func nextStartTime(for trackKind: EditorTrackKind) -> Double {
        clips(for: trackKind).map(\.endTime).max() ?? 0
    }

    private func insertionStartTime(for trackKind: EditorTrackKind) -> Double {
        if playheadTime > 0 {
            return playheadTime
        }

        return nextStartTime(for: trackKind)
    }

    private func shiftTextClips(seconds: Double, where shouldShift: (EditorClip) -> Bool) {
        guard let trackIndex = tracks.firstIndex(where: { $0.kind == .text }) else { return }
        for clipIndex in tracks[trackIndex].clips.indices where shouldShift(tracks[trackIndex].clips[clipIndex]) {
            tracks[trackIndex].clips[clipIndex].startTime = max(0, tracks[trackIndex].clips[clipIndex].startTime + seconds)
        }
        tracks[trackIndex].clips.sort { $0.startTime < $1.startTime }
    }

    private static func makeDefaultTracks() -> [EditorTrack] {
        [
            EditorTrack(id: UUID(), kind: .video, name: "Video", clips: [], isMuted: false, isHidden: false),
            EditorTrack(id: UUID(), kind: .audio, name: "Audio", clips: [], isMuted: false, isHidden: false)
        ]
    }

    private func normalizedTracks(_ importedTracks: [EditorTrack]) -> [EditorTrack] {
        var normalized: [EditorTrack] = []

        for kind in [EditorTrackKind.video, .text, .audio] {
            let defaultTrack = EditorTrack(id: UUID(), kind: kind, name: defaultTrackName(for: kind), clips: [], isMuted: false, isHidden: false)
            var track = importedTracks.first { $0.kind == kind } ?? defaultTrack
            track.clips = nonOverlappingClips(track.clips)

            if kind == .text && track.clips.isEmpty {
                continue
            }

            if track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                track.name = defaultTrack.name
            }
            normalized.append(track)
        }

        return normalized.isEmpty ? Self.makeDefaultTracks() : normalized
    }

    private func nonOverlappingClips(_ clips: [EditorClip]) -> [EditorClip] {
        var cursor = 0.0
        return clips
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.startTime < $1.startTime
            }
            .map { clip in
                var normalized = clip
                normalized.startTime = max(normalized.startTime, cursor)
                normalized.trimStart = max(0, normalized.trimStart)
                normalized.duration = clamped(
                    normalized.duration,
                    lower: 0.2,
                    upper: max(0.2, normalized.sourceDuration - normalized.trimStart)
                )
                normalized.fadeInDuration = clampedFadeDuration(normalized.fadeInDuration ?? 0, clipDuration: normalized.duration)
                normalized.fadeOutDuration = clampedFadeDuration(normalized.fadeOutDuration ?? 0, clipDuration: normalized.duration)
                cursor = normalized.endTime
                return normalized
            }
    }

    private func formattedSignedSeconds(_ seconds: Double) -> String {
        let sign = seconds >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", seconds))초"
    }

    private func defaultDuration(for asset: EditorMediaAsset) -> Double {
        switch asset.kind {
        case .image:
            return 4
        case .subtitle:
            return asset.duration > 0 ? asset.duration : 4
        case .audio, .video:
            return asset.duration > 0 ? asset.duration : 4
        }
    }

    private func readAsset(url: URL, kind: EditorMediaKind) -> EditorMediaAsset {
        if kind == .subtitle {
            let cues = parseSubtitleCues(from: readSubtitleText(url: url) ?? "")
            return EditorMediaAsset(
                id: UUID(),
                url: url,
                kind: kind,
                duration: cues.map(\.endTime).max() ?? 0,
                naturalSize: .zero,
                hasAudio: false,
                subtitleCues: cues
            )
        }

        guard kind != .image else {
            let image = NSImage(contentsOf: url)
            return EditorMediaAsset(
                id: UUID(),
                url: url,
                kind: kind,
                duration: 4,
                naturalSize: image?.size ?? CGSize(width: 1280, height: 720),
                hasAudio: false,
                subtitleCues: []
            )
        }

        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let videoTrack = asset.tracks(withMediaType: .video).first
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
        let naturalSize = videoTrack?.naturalSize.applying(videoTrack?.preferredTransform ?? .identity) ?? .zero

        return EditorMediaAsset(
            id: UUID(),
            url: url,
            kind: kind,
            duration: durationSeconds.isFinite ? max(durationSeconds, 0) : 0,
            naturalSize: CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height)),
            hasAudio: hasAudio,
            subtitleCues: []
        )
    }

    private func mediaKind(for url: URL) -> EditorMediaKind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedAudioExtensions.contains(ext) { return .audio }
        if supportedImageExtensions.contains(ext) { return .image }
        if supportedSubtitleExtensions.contains(ext) { return .subtitle }
        return nil
    }

    @discardableResult
    private func addSubtitleAssetToTimeline(_ asset: EditorMediaAsset, selectInsertedClip: Bool = true) -> Int {
        let cues = asset.subtitleCues.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard !cues.isEmpty else {
            userMessage = "SRT 자막을 읽지 못했습니다."
            return 0
        }

        let baseStartTime = insertionStartTime(for: .text)
        let duration = max(asset.duration, cues.map(\.endTime).max() ?? 0, 0.2)
        let clip = EditorClip(
            id: UUID(),
            mediaID: asset.id,
            sourceURL: asset.url,
            kind: .subtitle,
            title: asset.displayName,
            startTime: baseStartTime,
            duration: duration,
            trimStart: 0,
            sourceDuration: duration,
            transform: defaultSubtitleTransform(),
            text: "",
            hasAudio: false
        )

        appendClip(clip, to: .text)
        if selectInsertedClip {
            selectedClipID = clip.id
            playheadTime = baseStartTime
        }
        userMessage = "SRT 자막을 한 개 클립으로 타임라인에 추가했습니다."
        return 1
    }

    private static func defaultTrackName(for kind: EditorTrackKind) -> String {
        switch kind {
        case .video: return "Video"
        case .audio: return "Audio"
        case .text: return "Subtitles"
        }
    }

    private func defaultTrackName(for kind: EditorTrackKind) -> String {
        Self.defaultTrackName(for: kind)
    }

    private func sortTracksByDisplayOrder() {
        tracks.sort { lhs, rhs in
            trackDisplayOrder(lhs.kind) < trackDisplayOrder(rhs.kind)
        }
    }

    private func trackDisplayOrder(_ kind: EditorTrackKind) -> Int {
        switch kind {
        case .video: return 0
        case .text: return 1
        case .audio: return 2
        }
    }

    private func clampedFadeDuration(_ value: Double, clipDuration: Double) -> Double {
        clamped(value, lower: 0, upper: max(0, clipDuration / 2))
    }

    private func defaultSubtitleTransform() -> EditorTransform {
        EditorTransform(
            positionX: 0,
            positionY: 0.32,
            scaleX: 1,
            scaleY: 1,
            rotationDegrees: 0,
            opacity: 1,
            perspective: .unit
        )
    }

    private func subtitleClipTitle(text: String, fallback: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !flattened.isEmpty else { return fallback }
        return flattened.count > 28 ? "\(flattened.prefix(28))..." : flattened
    }

    private func readSubtitleText(url: URL) -> String? {
        let koreanDOS = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            )
        )
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            koreanDOS,
            .isoLatin1,
            .macOSRoman
        ]

        for encoding in encodings {
            if let value = try? String(contentsOf: url, encoding: encoding), !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func parseSubtitleCues(from rawText: String) -> [SubtitleCue] {
        let lines = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var index = 0
        var cues: [SubtitleCue] = []

        while index < lines.count {
            while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
            }

            guard index < lines.count else { break }

            if !lines[index].contains("-->") {
                index += 1
            }

            guard index < lines.count, lines[index].contains("-->") else {
                continue
            }

            let timingLine = lines[index]
            index += 1

            let timingParts = timingLine.components(separatedBy: "-->")
            guard timingParts.count >= 2,
                  let start = parseSubtitleTimestamp(timingParts[0]),
                  let end = parseSubtitleTimestamp(timingParts[1])
            else {
                continue
            }

            var textLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                textLines.append(line)
                index += 1
            }

            let text = cleanSubtitleText(textLines)
            if end > start, !text.isEmpty {
                cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
            }
        }

        return cues
    }

    private func parseSubtitleTimestamp(_ rawValue: String) -> Double? {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == " " || $0 == "\t" }
            .first
            .map(String.init)?
            .replacingOccurrences(of: ",", with: ".")

        guard let token else { return nil }
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds
    }

    private func cleanSubtitleText(_ lines: [String]) -> String {
        lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\.*?\\}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func clamped<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    min(max(value, lower), upper)
}
