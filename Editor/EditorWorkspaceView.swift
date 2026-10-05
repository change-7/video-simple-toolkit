import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private let editorDefaultTimelinePixelsPerSecond: Double = 54
private let editorMinTimelinePixelsPerSecond: Double = 18
private let editorMaxTimelinePixelsPerSecond: Double = 180
private let editorTimelineHeaderWidth: CGFloat = 86
private let editorTimelinePlaybackInterval: TimeInterval = 1.0 / 24.0
private let editorTimelinePlayheadVisibilityInset: CGFloat = 14

struct EditorUndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct EditorRedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var editorUndoAction: (() -> Void)? {
        get { self[EditorUndoActionKey.self] }
        set { self[EditorUndoActionKey.self] = newValue }
    }

    var editorRedoAction: (() -> Void)? {
        get { self[EditorRedoActionKey.self] }
        set { self[EditorRedoActionKey.self] = newValue }
    }
}

struct EditorWorkspaceView: View {
    @EnvironmentObject private var toolManager: ToolManager
    @StateObject private var store = EditorTimelineStore()
    @StateObject private var exportManager = EditorExportManager()
    @StateObject private var mediaDownloadManager = DownloadManager()
    @AppStorage(SettingsKeys.defaultDownloadPreset) private var defaultDownloadPresetRaw: String = DownloadPreset.bestQualityMP4.rawValue
    @AppStorage(SettingsKeys.defaultFilenameConflictPolicy) private var defaultFilenameConflictPolicyRaw: String = FilenameConflictPolicy.autoRename.rawValue
    @AppStorage(SettingsKeys.hlsAutoReconnectEnabled) private var hlsAutoReconnectEnabled: Bool = true
    @AppStorage(SettingsKeys.hlsReconnectFailTimeoutSeconds) private var hlsReconnectFailTimeoutSeconds: Int = 90
    @AppStorage(SettingsKeys.editorAutoImportDownloadedMedia) private var autoImportDownloadedMedia: Bool = true
    @State private var outputDirectory: URL = EditorWorkspaceView.defaultOutputDirectory()
    @State private var outputBaseName = "edited-video"
    @State private var mediaDownloadURLText = ""
    @State private var lastImportedDownloadPath: String?
    @State private var renderWidth = 1920
    @State private var renderHeight = 1080
    @State private var selectedCanvasPreset: EditorCanvasPreset = .wide16x9
    @State private var selectedExportPreset: EditorExportPreset = .balanced
    @State private var selectedPerspectiveCorner: PerspectiveCorner = .topLeft
    @State private var isApplyingCanvasPreset = false
    @State private var isMediaDropTargeted = false
    @State private var isTimelineDropTargeted = false
    @State private var isProcessingFileDrop = false
    @State private var timelineKeyboardFocusToken = 0
    @State private var timelinePixelsPerSecond = editorDefaultTimelinePixelsPerSecond
    @State private var isTimelinePlaying = false
    @State private var lastPlaybackTick: Date?
    @State private var playheadDragStartTime: Double?
    @State private var timelinePlayheadVisibilityRequestID = 0
    private let timelinePlaybackTimer = Timer.publish(every: editorTimelinePlaybackInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HSplitView {
                mediaBin
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 420)

                VSplitView {
                    previewPanel
                        .frame(minHeight: 220, idealHeight: 500)
                    timelinePanel
                        .frame(minHeight: 180, idealHeight: 260, maxHeight: 520)
                }
                .frame(minWidth: 360)

                inspector
                    .frame(minWidth: 210, idealWidth: 280, maxWidth: 420)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(editorBackground)
        .onAppear {
            toolManager.refresh()
        }
        .onChange(of: mediaDownloadManager.phase) { phase in
            if phase == .completed {
                handleCompletedMediaDownload()
            }
        }
        .onChange(of: store.timelineDuration) { duration in
            if duration <= 0 {
                stopTimelinePlayback()
            } else if store.playheadTime > duration {
                store.setPlayhead(to: duration)
                requestTimelinePlayheadVisibility()
            }
        }
        .onReceive(timelinePlaybackTimer) { date in
            advanceTimelinePlayback(date)
        }
        .focusedSceneValue(\.editorUndoAction, store.canUndo ? undoEditorAction : nil)
        .focusedSceneValue(\.editorRedoAction, store.canRedo ? redoEditorAction : nil)
    }

    private var topBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "play.square.stack.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(accentMint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Video Simple Toolkit")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Editor")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 168, alignment: .leading)

                Button {
                    selectMediaFiles()
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    store.addTextClip()
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openProject()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open project")
                .buttonStyle(.borderless)

                Button {
                    saveProject()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save project")
                .buttonStyle(.borderless)

                Divider()
                    .frame(height: 20)

                Button {
                    undoEditorAction()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("작업 되돌리기 (Command-Z)")
                .buttonStyle(.borderless)
                .disabled(!store.canUndo)

                Button {
                    redoEditorAction()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("다시 실행 (Shift-Command-Z / Command-Y)")
                .buttonStyle(.borderless)
                .disabled(!store.canRedo)

                Divider()
                    .frame(height: 20)

                Button {
                    store.splitSelectedClip()
                } label: {
                    Image(systemName: "scissors")
                }
                .help("자르기 (B)")
                .buttonStyle(.borderless)
                .disabled(store.timelineDuration <= 0)

                Button(role: .destructive) {
                    store.deleteSelectedClip()
                } label: {
                    Image(systemName: "trash")
                }
                .help("지우기 (Delete)")
                .buttonStyle(.borderless)
                .disabled(store.selectedClip == nil)

                Spacer(minLength: 10)

                Text("Canvas")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("캔버스", selection: $selectedCanvasPreset) {
                    ForEach(EditorCanvasPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .frame(width: 120)
                .onChange(of: selectedCanvasPreset) { preset in
                    applyCanvasPreset(preset)
                }

                TextField("W", value: $renderWidth, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .onChange(of: renderWidth) { _ in
                        if !isApplyingCanvasPreset {
                            selectedCanvasPreset = .custom
                        }
                    }

                Text("x")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("H", value: $renderHeight, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .onChange(of: renderHeight) { _ in
                        if !isApplyingCanvasPreset {
                            selectedCanvasPreset = .custom
                        }
                    }

                Button {
                    selectOutputFolder()
                } label: {
                    Label(outputDirectory.lastPathComponent, systemImage: "folder")
                }

                TextField("파일 이름", text: $outputBaseName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Picker("출력 품질", selection: $selectedExportPreset) {
                    ForEach(EditorExportPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .frame(width: 130)

                if exportManager.isExporting {
                    Button {
                        exportManager.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        startExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accentMint)
                    .disabled(!toolManager.status.ffmpeg.isInstalled)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 54)
        .background(panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 1)
        }
    }

    private var mediaBin: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelTitle("Media")
                Spacer()
                Button {
                    selectMediaFiles()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            mediaURLInput

            if store.mediaAssets.isEmpty {
                Text("Import video, audio, image, or SRT subtitle files, then add them to the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.mediaAssets) { asset in
                            HStack(spacing: 8) {
                                Image(systemName: mediaIcon(for: asset.kind))
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.displayName)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(mediaDetail(for: asset))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.addClipToTimeline(assetID: asset.id)
                                } label: {
                                    Image(systemName: asset.kind == .subtitle ? "captions.bubble" : "plus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(asset.kind == .subtitle ? "SRT 자막을 텍스트 트랙에 추가" : "타임라인 끝에 붙이기")
                            }
                            .padding(8)
                            .background(store.selectedMediaAssetID == asset.id ? accentMint.opacity(0.18) : rowBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(store.selectedMediaAssetID == asset.id ? accentMint.opacity(0.7) : .clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectMediaAsset(asset.id)
                            }
                            .onDrag {
                                NSItemProvider(contentsOf: asset.url) ?? NSItemProvider(object: asset.url.absoluteString as NSString)
                            }
                        }
                    }
                }
            }

            Spacer()

            if !toolManager.status.ffmpeg.isInstalled {
                Text("출력은 ffmpeg가 필요합니다. Toolkit 탭의 설정에서 설치 상태를 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        .overlay {
            dropTargetOverlay(isTargeted: isMediaDropTargeted)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isMediaDropTargeted) { providers in
            handleFileDrop(providers: providers, addToTimeline: false)
        }
    }

    private var mediaURLInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(accentMint)
                Text("URL Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(selectedDownloadPreset.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextField("영상 URL 입력", text: $mediaDownloadURLText)
                .textFieldStyle(.roundedBorder)
                .disabled(mediaDownloadManager.isDownloading)
                .onSubmit {
                    startMediaURLDownload()
                }

            Toggle("다운로드 후 미디어에 자동 추가", isOn: $autoImportDownloadedMedia)
                .font(.caption2)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                if mediaDownloadManager.isDownloading {
                    Button {
                        mediaDownloadManager.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        startMediaURLDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accentMint)
                    .disabled(!canStartMediaDownload)
                }

                if mediaDownloadManager.phase == .completed,
                   mediaDownloadManager.outputFilePath != nil {
                    Button {
                        importCompletedMediaDownload(force: true)
                    } label: {
                        Label("미디어에 추가", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mediaDownloadManager.isDownloading)
                }

                Spacer()
            }

            ProgressView(value: mediaDownloadManager.progress, total: 1)
                .opacity(mediaDownloadManager.phase == .idle ? 0.35 : 1)

            Text(mediaDownloadStatusText)
                .font(.caption2)
                .foregroundStyle(mediaDownloadStatusColor)
                .lineLimit(2)

            if let warning = mediaDownloadToolWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .background(rowBackground)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(borderColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                panelTitle("Preview")
                Spacer()
                Text("\(safeRenderWidth)x\(safeRenderHeight)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(rowBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.96)

                    let visualClip = previewVisualClip

                    EditorTimelineAudioPreview(
                        items: activeAudioPreviewItems,
                        isPlaying: isTimelinePlaying && !isProcessingFileDrop && !isMediaDropTargeted && !isTimelineDropTargeted
                    )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                    if let clip = visualClip {
                        EditorClipPreview(
                            clip: clip,
                            previewTime: store.playheadTime,
                            isPlaying: isTimelinePlaying,
                            isMuted: store.isTrackMuted(for: clip.id),
                            suppressVideoPlayer: isProcessingFileDrop || isMediaDropTargeted || isTimelineDropTargeted
                        )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(x: clip.transform.scaleX, y: clip.transform.scaleY)
                            .rotationEffect(.degrees(clip.transform.rotationDegrees))
                            .offset(
                                x: clip.transform.positionX * geometry.size.width,
                                y: clip.transform.positionY * geometry.size.height
                            )
                            .opacity(clip.transform.opacity)

                        if clip.id == store.selectedClipID && (clip.kind == .video || clip.kind == .image) {
                            EditorCornerTransformOverlay(
                                quad: clip.transform.perspective,
                                selectedCorner: selectedPerspectiveCorner,
                                onSelect: { corner in
                                    selectedPerspectiveCorner = corner
                                },
                                onDrag: { corner, point in
                                    selectedPerspectiveCorner = corner
                                    store.updateSelectedPerspective(corner: corner, point: point)
                                },
                                onBeginDrag: {
                                    store.beginUndoGroup()
                                },
                                onEndDrag: {
                                    store.commitUndoGroup()
                                }
                            )
                        }
                    } else {
                        previewEmptyState
                    }

                    ForEach(store.visibleTextClips(at: store.playheadTime)) { textClip in
                        Text(textClip.text)
                            .font(.system(size: max(14, 34 * textClip.transform.scaleY), weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.black.opacity(textClip.transform.resolvedSubtitleBackgroundOpacity))
                            )
                            .offset(
                                x: textClip.transform.positionX * geometry.size.width,
                                y: textClip.transform.positionY * geometry.size.height
                            )
                            .opacity(textClip.transform.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .coordinateSpace(name: EditorCornerTransformOverlay.coordinateSpaceName)
            }
            .aspectRatio(currentCanvasAspectRatio, contentMode: .fit)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            previewToolbar
        }
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var previewToolbar: some View {
        HStack {
            Text(formattedTime(store.playheadTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                goToTimelineStart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .disabled(store.timelineDuration <= 0)
            .help("처음으로")

            Button {
                goToPreviousEditPoint()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(store.timelineDuration <= 0)
            .help("이전 컷으로")

            Button {
                toggleTimelinePlayback()
            } label: {
                Image(systemName: isTimelinePlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(store.timelineDuration <= 0)
            .help("재생/정지 (Space)")

            Button {
                goToNextEditPoint()
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(store.timelineDuration <= 0)
            .help("다음 컷으로")

            Button {
                goToTimelineEnd()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.borderless)
            .disabled(store.timelineDuration <= 0)
            .help("끝으로")

            Slider(
                value: Binding(
                    get: { store.playheadTime },
                    set: { scrubTimeline(to: $0) }
                ),
                in: 0...max(store.timelineDuration, 0.1)
            )
            .disabled(store.timelineDuration <= 0)

            Text(formattedTime(store.timelineDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(panelBackground.opacity(0.82))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 1)
        }
    }

    private var previewVisualClip: EditorClip? {
        if let activeClip = store.activeVisualClip(at: store.playheadTime) {
            return activeClip
        }

        return isTimelinePlaying ? nil : selectedVisualClip
    }

    private var activeAudioPreviewItems: [EditorAudioPreviewItem] {
        store.activeAudioClips(at: store.playheadTime).compactMap { clip in
            guard let url = clip.sourceURL else { return nil }
            return EditorAudioPreviewItem(
                id: clip.id,
                url: url,
                time: clip.localMediaTime(at: store.playheadTime)
            )
        }
    }

    private var selectedVisualClip: EditorClip? {
        guard let clip = store.selectedClip,
              clip.kind == .video || clip.kind == .image else {
            return nil
        }

        return clip
    }

    @ViewBuilder
    private var previewEmptyState: some View {
        if store.timelineDuration > 0 {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.16))
                Text("블랙 화면")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        } else {
            Text("타임라인에 미디어를 추가하세요.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var timelinePanel: some View {
        GeometryReader { geometry in
            let timelineDuration = max(store.timelineDuration, 12)
            let timelineViewportWidth = max(260, geometry.size.width - editorTimelineHeaderWidth - 76)
            let timelineWidth = max(
                timelineViewportWidth,
                CGFloat(timelineDuration * timelinePixelsPerSecond)
            )
            let timelineHeight = 34 + CGFloat(store.tracks.count) * 62
            let playheadX = editorTimelineHeaderWidth + CGFloat(store.playheadTime * timelinePixelsPerSecond)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        panelTitle("Timeline")
                        Spacer(minLength: 6)

                        Button {
                            goToPreviousEditPoint()
                        } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("이전 컷으로")

                        Button {
                            toggleTimelinePlayback()
                        } label: {
                            Image(systemName: isTimelinePlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("재생/정지 (Space)")

                        Button {
                            goToNextEditPoint()
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("다음 컷으로")

                        Divider()
                            .frame(height: 18)

                        Button {
                            focusTimelineKeyboard()
                            store.splitSelectedClip()
                        } label: {
                            Label("자르기", systemImage: "scissors")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("선택 클립 또는 플레이헤드 아래 클립 자르기 (B)")

                        Button {
                            focusTimelineKeyboard()
                            store.splitAllClipsAtPlayhead()
                        } label: {
                            Text("전체 컷")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("플레이헤드를 지나는 모든 트랙 자르기 (Shift+B)")

                        Button {
                            focusTimelineKeyboard()
                            store.trimSelectedClipStartToPlayhead()
                        } label: {
                            Text("앞->커서")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("선택 클립 앞부분을 플레이헤드까지 trim (Q)")

                        Button {
                            focusTimelineKeyboard()
                            store.trimSelectedClipEndToPlayhead()
                        } label: {
                            Text("뒤->커서")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.timelineDuration <= 0)
                        .help("선택 클립 뒷부분을 플레이헤드까지 trim (W)")

                        Button(role: .destructive) {
                            focusTimelineKeyboard()
                            store.deleteSelectedClip()
                        } label: {
                            Label("지우기", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.selectedClip == nil)
                        .help("선택 클립 삭제 (Delete)")

                        Button(role: .destructive) {
                            focusTimelineKeyboard()
                            store.rippleDeleteSelectedClip()
                        } label: {
                            Text("리플")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.selectedClip == nil)
                        .help("삭제 후 뒤 클립을 앞으로 당기기")

                        Button {
                            focusTimelineKeyboard()
                            store.closeGapsOnSelectedTrack()
                        } label: {
                            Text("간격")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.selectedClip == nil)
                        .help("선택 트랙의 빈 구간 닫기")

                        Button {
                            focusTimelineKeyboard()
                            store.duplicateSelectedClip()
                        } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.selectedClip == nil)
                        .help("선택 클립 복제")

                        Button {
                            focusTimelineKeyboard()
                            store.moveSelectedClipToPlayhead()
                        } label: {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.selectedClip == nil)
                        .help("선택 클립을 플레이헤드 위치로 이동 (M)")

                        Button {
                            focusTimelineKeyboard()
                            store.appendSelectedMediaToTimeline()
                        } label: {
                            Image(systemName: "plus.rectangle.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!store.canAppendSelectedMediaToTimeline)
                        .help("선택한 비디오, 오디오, 이미지, SRT를 재생헤드 위치에 삽입")

                        Button {
                            focusTimelineKeyboard()
                            store.nudgeSelectedClip(seconds: -0.5)
                        } label: {
                            Image(systemName: "arrow.left")
                        }
                        .disabled(store.selectedClip == nil)
                        .help("선택 클립 0.5초 앞으로")

                        Button {
                            focusTimelineKeyboard()
                            store.nudgeSelectedClip(seconds: 0.5)
                        } label: {
                            Image(systemName: "arrow.right")
                        }
                        .disabled(store.selectedClip == nil)
                        .help("선택 클립 0.5초 뒤로")

                        Divider()
                            .frame(height: 18)

                        Button {
                            zoomTimeline(by: 0.8)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .help("타임라인 축소")

                        Button {
                            fitTimelineToWidth(timelineViewportWidth, duration: timelineDuration)
                        } label: {
                            Text("맞춤")
                        }
                        .help("타임라인을 패널 너비에 맞추기")

                        Button {
                            zoomTimeline(by: 1.25)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .help("타임라인 확대")
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(borderColor)
                        .frame(height: 1)
                }

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            EditorTimelineRuler(
                                duration: timelineDuration,
                                width: timelineWidth,
                                pixelsPerSecond: timelinePixelsPerSecond
                            )
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        focusTimelineKeyboard()
                                        setPlayheadFromTimelineX(value.location.x)
                                    }
                            )

                            ForEach(store.tracks) { track in
                                EditorTimelineTrackRow(
                                    track: track,
                                    selectedClipID: store.selectedClipID,
                                    duration: timelineDuration,
                                    width: timelineWidth,
                                    pixelsPerSecond: timelinePixelsPerSecond,
                                    onSelect: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip)
                                    },
                                    onScrub: { time in
                                        focusTimelineKeyboard()
                                        scrubTimeline(to: time)
                                    },
                                    onBeginEditing: {
                                        focusTimelineKeyboard()
                                        store.beginUndoGroup()
                                    },
                                    onEndEditing: {
                                        store.commitUndoGroup()
                                        requestTimelinePlayheadVisibility()
                                    },
                                    onMove: { clipID, startTime, baselineClips in
                                        focusTimelineKeyboard()
                                        store.moveClip(id: clipID, toStartTime: startTime, baselineClips: baselineClips)
                                    },
                                    onTrimStart: { clipID, startTime in
                                        focusTimelineKeyboard()
                                        store.trimClipStart(id: clipID, toStartTime: startTime)
                                    },
                                    onTrimEnd: { clipID, endTime in
                                        focusTimelineKeyboard()
                                        store.trimClipEnd(id: clipID, toEndTime: endTime)
                                    },
                                    onFadeIn: { clipID, duration in
                                        focusTimelineKeyboard()
                                        store.setClipFade(id: clipID, fadeInDuration: duration)
                                    },
                                    onFadeOut: { clipID, duration in
                                        focusTimelineKeyboard()
                                        store.setClipFade(id: clipID, fadeOutDuration: duration)
                                    },
                                    onToggleMute: { trackID in
                                        focusTimelineKeyboard()
                                        store.toggleTrackMute(id: trackID)
                                    },
                                    onToggleHidden: { trackID in
                                        focusTimelineKeyboard()
                                        store.toggleTrackHidden(id: trackID)
                                    },
                                    onMoveToPlayhead: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip, movePlayhead: false)
                                        store.moveSelectedClipToPlayhead()
                                    },
                                    onSplit: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip, movePlayhead: false)
                                        store.splitSelectedClip()
                                    },
                                    onDuplicate: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip, movePlayhead: false)
                                        store.duplicateSelectedClip()
                                    },
                                    onRippleDelete: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip, movePlayhead: false)
                                        store.rippleDeleteSelectedClip()
                                    },
                                    onDelete: { clip in
                                        focusTimelineKeyboard()
                                        store.selectClip(clip, movePlayhead: false)
                                        store.deleteSelectedClip()
                                    }
                                )
                            }
                        }

                        EditorTimelinePlayhead(
                            x: playheadX,
                            height: timelineHeight,
                            onDrag: { translationX in
                                focusTimelineKeyboard()
                                dragPlayhead(translationX: translationX)
                            },
                            onDragEnded: {
                                playheadDragStartTime = nil
                            }
                        )

                        EditorTimelineHorizontalScrollAnchor(
                            requestID: timelinePlayheadVisibilityRequestID,
                            visibilityInset: editorTimelinePlayheadVisibilityInset
                        )
                        .frame(width: 1, height: 1)
                        .offset(x: playheadX - 0.5)
                        .allowsHitTesting(false)
                    }
                    .padding(12)
                    .padding(.trailing, 220)
                }
            }
        }
        .background(panelBackground)
        .background(
            EditorKeyboardCaptureView(
                focusToken: timelineKeyboardFocusToken,
                onKeyDown: handleTimelineKeyDown
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        .overlay {
            dropTargetOverlay(isTargeted: isTimelineDropTargeted)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTimelineDropTargeted) { providers in
            handleFileDrop(providers: providers, addToTimeline: true)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panelTitle("Inspector")

                inspectorSection(title: "Project") {
                    HStack(spacing: 8) {
                        projectMetric("길이", formattedTime(store.timelineDuration))
                        projectMetric("V", "\(visualClipCount)")
                        projectMetric("A", "\(audioClipCount)")
                        projectMetric("S", "\(subtitleClipCount)")
                    }

                    Text(projectWorkflowStatus)
                        .font(.caption2)
                        .foregroundStyle(projectWorkflowStatusColor)
                        .lineLimit(2)
                }

                if let clip = store.selectedClip {
                    inspectorSection {
                        Text(clip.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        Text("\(clip.kind.rawValue) | \(formattedTime(clip.duration))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if clip.kind == .text {
                        TextField(
                            "텍스트",
                            text: Binding(
                                get: { store.selectedClip?.text ?? "" },
                                set: { store.updateSelectedText($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    if clip.kind == .text || clip.kind == .subtitle {
                        inspectorSection(title: "Subtitle Sync") {
                            subtitleSyncControls
                        }

                        inspectorSection(title: "Subtitle Style") {
                            inspectorSlider(
                                "배경 불투명도",
                                value: subtitleBackgroundOpacityBinding,
                                range: 0...1,
                                valueText: { "\(Int(($0 * 100).rounded()))%" },
                                help: "자막 텍스트 뒤 검은색 배경의 불투명도입니다. 0%는 투명하고 100%는 불투명합니다."
                            )
                        }
                    }

                    inspectorSection(title: "Transform") {
                        inspectorSlider("X", value: transformBinding(\.positionX), range: -0.5...0.5)
                        inspectorSlider("Y", value: transformBinding(\.positionY), range: -0.5...0.5)
                        inspectorSlider("Scale X", value: transformBinding(\.scaleX), range: 0.1...3)
                        inspectorSlider("Scale Y", value: transformBinding(\.scaleY), range: 0.1...3)
                        inspectorSlider("회전", value: transformBinding(\.rotationDegrees), range: -180...180)
                        inspectorSlider("불투명도", value: transformBinding(\.opacity), range: 0...1)
                    }

                    inspectorSection(title: "Fade") {
                        inspectorSlider("In", value: fadeBinding(.fadeIn), range: 0...max(0.1, clip.duration / 2))
                        inspectorSlider("Out", value: fadeBinding(.fadeOut), range: 0...max(0.1, clip.duration / 2))
                    }

                    if clip.kind == .video || clip.kind == .image {
                        inspectorSection(title: "Perspective") {
                            perspectiveCorrectionSection(clip: clip)
                        }
                    }

                    HStack {
                        Button("앞 trim") {
                            store.trimSelectedClipStart(by: 0.25)
                        }
                        Button("뒤 trim") {
                            store.trimSelectedClipEnd(by: -0.25)
                        }
                        Button("확장") {
                            store.trimSelectedClipEnd(by: 0.25)
                        }
                    }
                    .font(.caption)

                    HStack {
                        Button("앞->커서") {
                            store.trimSelectedClipStartToPlayhead()
                        }
                        Button("뒤->커서") {
                            store.trimSelectedClipEndToPlayhead()
                        }
                        Button("커서로 이동") {
                            store.moveSelectedClipToPlayhead()
                        }
                    }
                    .font(.caption)

                    Button {
                        store.resetSelectedPerspective()
                    } label: {
                        Label("보정 포인트 초기화", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!(clip.kind == .video || clip.kind == .image))
                } else {
                    Text("클립을 선택하면 위치, 크기, 회전, 4코너 변형을 조절할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                inspectorSection(title: "Export") {
                    ProgressView(value: exportManager.progress, total: 1)
                    Text(exportManager.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = exportManager.userMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(exportManager.outputURL == nil && !message.hasSuffix(".mp4") ? .red : .secondary)
                    }
                    if let outputURL = exportManager.outputURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Label("Finder에서 보기", systemImage: "folder")
                        }
                    }
                }

                if let message = store.userMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var selectedDownloadPreset: DownloadPreset {
        DownloadPreset.userSelectableMode(rawValue: defaultDownloadPresetRaw)
    }

    private var selectedDownloadConflictPolicy: FilenameConflictPolicy {
        FilenameConflictPolicy(rawValue: defaultFilenameConflictPolicyRaw) ?? .autoRename
    }

    private var trimmedMediaDownloadURL: String {
        mediaDownloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidMediaDownloadURL: Bool {
        guard let components = URLComponents(string: trimmedMediaDownloadURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil
        else {
            return false
        }

        return true
    }

    private var mediaDownloadRequiresYtDlp: Bool {
        !isLikelyM3U8URL(trimmedMediaDownloadURL)
    }

    private var mediaDownloadToolsReady: Bool {
        guard toolManager.status.ffmpeg.isInstalled else { return false }
        if mediaDownloadRequiresYtDlp {
            return toolManager.status.ytDlp.isInstalled
        }
        return true
    }

    private var canStartMediaDownload: Bool {
        isValidMediaDownloadURL
            && mediaDownloadToolsReady
            && !mediaDownloadManager.isDownloading
    }

    private var mediaDownloadToolWarning: String? {
        guard isValidMediaDownloadURL else {
            return trimmedMediaDownloadURL.isEmpty ? nil : "http 또는 https 영상 URL을 입력해 주세요."
        }

        guard toolManager.status.ffmpeg.isInstalled else {
            return "다운로드에는 ffmpeg가 필요합니다. Toolkit 탭의 설정에서 설치 상태를 확인하세요."
        }

        if mediaDownloadRequiresYtDlp && !toolManager.status.ytDlp.isInstalled {
            return "일반 영상 URL 다운로드에는 yt-dlp가 필요합니다. Toolkit 탭의 설정에서 설치 상태를 확인하세요."
        }

        return nil
    }

    private var mediaDownloadStatusText: String {
        if let message = mediaDownloadManager.userMessage, !message.isEmpty {
            return message
        }

        if mediaDownloadManager.phase == .idle {
            return "URL을 다운로드하면 이 Media 패널에서 바로 사용할 수 있습니다."
        }

        return mediaDownloadManager.statusText
    }

    private var mediaDownloadStatusColor: Color {
        switch mediaDownloadManager.phase {
        case .failed:
            return .red
        case .canceled:
            return .orange
        case .completed:
            return .secondary
        default:
            return .secondary
        }
    }

    private var editorBackground: Color {
        Color(red: 0.055, green: 0.057, blue: 0.064)
    }

    private var panelBackground: Color {
        Color(red: 0.083, green: 0.086, blue: 0.096)
    }

    private var rowBackground: Color {
        Color.white.opacity(0.055)
    }

    private var borderColor: Color {
        Color.white.opacity(0.095)
    }

    private var accentMint: Color {
        Color(red: 0.365, green: 0.729, blue: 0.627)
    }

    private func panelTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
    }

    private func focusTimelineKeyboard() {
        timelineKeyboardFocusToken &+= 1
    }

    private func undoEditorAction() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.undo()
        requestTimelinePlayheadVisibility()
    }

    private func redoEditorAction() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.redo()
        requestTimelinePlayheadVisibility()
    }

    private func requestTimelinePlayheadVisibility() {
        timelinePlayheadVisibilityRequestID &+= 1
    }

    private func scrubTimeline(to time: Double) {
        stopTimelinePlayback()
        store.setPlayhead(to: time)
        requestTimelinePlayheadVisibility()
    }

    private func setPlayheadFromTimelineX(_ x: CGFloat) {
        let timelineX = max(x - editorTimelineHeaderWidth, 0)
        let seconds = Double(timelineX) / timelinePixelsPerSecond
        scrubTimeline(to: seconds)
    }

    private func dragPlayhead(translationX: CGFloat) {
        let startTime = playheadDragStartTime ?? store.playheadTime
        playheadDragStartTime = startTime
        stopTimelinePlayback()
        let seconds = startTime + Double(translationX) / timelinePixelsPerSecond
        store.setPlayhead(to: seconds)
        requestTimelinePlayheadVisibility()
    }

    private func toggleTimelinePlayback() {
        focusTimelineKeyboard()
        guard store.timelineDuration > 0 else { return }

        if isTimelinePlaying {
            stopTimelinePlayback()
            return
        }

        if store.playheadTime >= store.timelineDuration {
            store.movePlayheadToStart()
            requestTimelinePlayheadVisibility()
        }

        isTimelinePlaying = true
        lastPlaybackTick = nil
    }

    private func stopTimelinePlayback() {
        isTimelinePlaying = false
        lastPlaybackTick = nil
    }

    private func advanceTimelinePlayback(_ date: Date) {
        guard isTimelinePlaying else {
            lastPlaybackTick = nil
            return
        }

        let duration = store.timelineDuration
        guard duration > 0 else {
            stopTimelinePlayback()
            return
        }

        let previousTick = lastPlaybackTick ?? date
        lastPlaybackTick = date
        let delta = min(max(date.timeIntervalSince(previousTick), 0), 0.25)
        let nextTime = store.playheadTime + delta

        if nextTime >= duration {
            store.setPlayhead(to: duration)
            requestTimelinePlayheadVisibility()
            stopTimelinePlayback()
        } else {
            store.setPlayhead(to: nextTime)
            requestTimelinePlayheadVisibility()
        }
    }

    private func goToTimelineStart() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.movePlayheadToStart()
        requestTimelinePlayheadVisibility()
    }

    private func goToTimelineEnd() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.movePlayheadToEnd()
        requestTimelinePlayheadVisibility()
    }

    private func goToPreviousEditPoint() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.movePlayheadToPreviousEditPoint()
        requestTimelinePlayheadVisibility()
    }

    private func goToNextEditPoint() {
        stopTimelinePlayback()
        focusTimelineKeyboard()
        store.movePlayheadToNextEditPoint()
        requestTimelinePlayheadVisibility()
    }

    private func zoomTimeline(by multiplier: Double) {
        timelinePixelsPerSecond = clampedTimelineZoom(timelinePixelsPerSecond * multiplier)
        requestTimelinePlayheadVisibility()
    }

    private func fitTimelineToWidth(_ availableWidth: CGFloat, duration: Double) {
        let fitted = Double(max(availableWidth, 1)) / max(duration, 1)
        timelinePixelsPerSecond = clampedTimelineZoom(fitted)
        requestTimelinePlayheadVisibility()
    }

    private func clampedTimelineZoom(_ value: Double) -> Double {
        min(max(value, editorMinTimelinePixelsPerSecond), editorMaxTimelinePixelsPerSecond)
    }

    private func handleTimelineKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option) {
            if key == "z" {
                if flags.contains(.shift) {
                    redoEditorAction()
                } else {
                    undoEditorAction()
                }
                return true
            }

            if key == "y" {
                redoEditorAction()
                return true
            }

            return false
        }

        guard !flags.contains(.command), !flags.contains(.control) else {
            return false
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if flags.contains(.shift) {
                store.rippleDeleteSelectedClip()
            } else {
                store.deleteSelectedClip()
            }
            return true
        }

        if key == "b" {
            if flags.contains(.shift) {
                store.splitAllClipsAtPlayhead()
            } else {
                store.splitSelectedClip()
            }
            return true
        }

        if key == "q" {
            store.trimSelectedClipStartToPlayhead()
            return true
        }

        if key == "w" {
            store.trimSelectedClipEndToPlayhead()
            return true
        }

        if key == "m" {
            store.moveSelectedClipToPlayhead()
            return true
        }

        if event.keyCode == 49 {
            toggleTimelinePlayback()
            return true
        }

        switch event.keyCode {
        case 123:
            nudgeTimelineFromKeyboard(seconds: -keyboardNudgeStep(flags: flags))
            return true
        case 124:
            nudgeTimelineFromKeyboard(seconds: keyboardNudgeStep(flags: flags))
            return true
        case 115:
            goToTimelineStart()
            return true
        case 119:
            goToTimelineEnd()
            return true
        case 126:
            goToPreviousEditPoint()
            return true
        case 125:
            goToNextEditPoint()
            return true
        default:
            return false
        }
    }

    private func keyboardNudgeStep(flags: NSEvent.ModifierFlags) -> Double {
        if flags.contains(.shift) {
            return 1.0
        }

        if flags.contains(.option) {
            return 0.05
        }

        return 0.1
    }

    private func nudgeTimelineFromKeyboard(seconds: Double) {
        stopTimelinePlayback()
        if store.selectedClip != nil {
            store.nudgeSelectedClip(seconds: seconds)
        } else {
            store.setPlayhead(to: store.playheadTime + seconds)
            requestTimelinePlayheadVisibility()
        }
    }

    private var subtitleSyncControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            subtitleSyncButtonRow(title: "선택") { seconds in
                store.shiftSelectedTextGroup(seconds: seconds)
            }

            subtitleSyncButtonRow(title: "전체") { seconds in
                store.shiftAllTextClips(seconds: seconds)
            }
        }
    }

    private func subtitleSyncButtonRow(title: String, action: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 38), spacing: 5), count: 3),
                alignment: .leading,
                spacing: 5
            ) {
                ForEach([-1.0, -0.5, -0.1, 0.1, 0.5, 1.0], id: \.self) { seconds in
                    Button(shortSignedSeconds(seconds)) {
                        action(seconds)
                    }
                    .font(.caption2.monospacedDigit())
                    .controlSize(.small)
                }
            }
        }
    }

    private func shortSignedSeconds(_ seconds: Double) -> String {
        let sign = seconds > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", seconds))"
    }

    private var visualClipCount: Int {
        store.clips(for: .video).filter { $0.kind == .video || $0.kind == .image }.count
    }

    private var audioClipCount: Int {
        store.clips(for: .audio).filter { $0.kind == .audio }.count
    }

    private var subtitleClipCount: Int {
        store.clips(for: .text).filter { $0.kind == .text || $0.kind == .subtitle }.count
    }

    private var projectWorkflowStatus: String {
        if store.timelineDuration <= 0 {
            return "타임라인 대기 중"
        }

        if visualClipCount == 0 && (audioClipCount > 0 || subtitleClipCount > 0) {
            return "블랙 화면 + 오디오/자막 출력 구성"
        }

        if !toolManager.status.ffmpeg.isInstalled {
            return "ffmpeg 필요"
        }

        return "출력 가능"
    }

    private var projectWorkflowStatusColor: Color {
        if store.timelineDuration <= 0 {
            return .secondary
        }

        if !toolManager.status.ffmpeg.isInstalled {
            return .orange
        }

        return accentMint
    }

    private func projectMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func inspectorSection<Content: View>(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func perspectiveCorrectionSection(clip: EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("원근 보정 포인트")
                .font(.caption.weight(.semibold))

            Text("왜곡된 영상에서 실제 사각형의 네 꼭짓점을 찍으면 출력 캔버스 비율에 맞게 펴서 내보냅니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("좌표는 프리뷰 기준 %입니다. 0~100 밖의 값도 가장자리 밖 보정용으로 허용됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(PerspectiveCorner.allCases) { corner in
                    cornerCoordinateRow(corner)
                }
            }

            HStack(spacing: 6) {
                Button("전체") {
                    store.resetSelectedPerspective()
                }
                Button("중앙 1:1") {
                    applyCenteredSourceAspect(width: 1, height: 1)
                }
                Button("안전영역") {
                    applyCorrectionInset(x: 0.05, y: 0.05)
                }
            }
            .font(.caption)

            Text("현재 출력: \(safeRenderWidth)x\(safeRenderHeight) | \(formattedAspectRatio(width: safeRenderWidth, height: safeRenderHeight))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func cornerCoordinateRow(_ corner: PerspectiveCorner) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedPerspectiveCorner = corner
            } label: {
                Text(corner.title)
                    .font(.caption2.weight(.semibold))
                    .frame(width: 48)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(corner == selectedPerspectiveCorner ? .accentColor : nil)

            coordinateField(
                title: "X",
                value: perspectivePointBinding(corner: corner, axis: .x)
            )
            coordinateField(
                title: "Y",
                value: perspectivePointBinding(corner: corner, axis: .y)
            )
        }
    }

    private func coordinateField(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 64)
        }
    }

    private func inspectorSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: ((Double) -> String)? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText?(value.wrappedValue) ?? String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .help(help ?? "")
            Slider(
                value: value,
                in: range,
                onEditingChanged: { isEditing in
                    if isEditing {
                        store.beginUndoGroup()
                    } else {
                        store.commitUndoGroup()
                    }
                }
            )
        }
    }

    private func transformBinding(_ keyPath: WritableKeyPath<EditorTransform, Double>) -> Binding<Double> {
        Binding(
            get: { store.selectedClip?.transform[keyPath: keyPath] ?? EditorTransform.identity[keyPath: keyPath] },
            set: { newValue in
                var transform = store.selectedClip?.transform ?? .identity
                transform[keyPath: keyPath] = newValue
                store.updateSelectedTransform(transform)
            }
        )
    }

    private var subtitleBackgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { store.selectedClip?.transform.resolvedSubtitleBackgroundOpacity ?? 0.45 },
            set: { newValue in
                var transform = store.selectedClip?.transform ?? .identity
                transform.subtitleBackgroundOpacity = min(max(newValue, 0), 1)
                store.updateSelectedTransform(transform)
            }
        )
    }

    private func fadeBinding(_ edge: EditorFadeEdge) -> Binding<Double> {
        Binding(
            get: {
                switch edge {
                case .fadeIn:
                    return store.selectedClip?.fadeInDuration ?? 0
                case .fadeOut:
                    return store.selectedClip?.fadeOutDuration ?? 0
                }
            },
            set: { newValue in
                guard let clipID = store.selectedClipID else { return }
                switch edge {
                case .fadeIn:
                    store.setClipFade(id: clipID, fadeInDuration: newValue)
                case .fadeOut:
                    store.setClipFade(id: clipID, fadeOutDuration: newValue)
                }
            }
        )
    }

    private var safeRenderWidth: Int {
        evenDimension(renderWidth)
    }

    private var safeRenderHeight: Int {
        evenDimension(renderHeight)
    }

    private var currentCanvasAspectRatio: Double {
        Double(safeRenderWidth) / Double(safeRenderHeight)
    }

    private func applyCanvasPreset(_ preset: EditorCanvasPreset) {
        guard let size = preset.size else { return }
        isApplyingCanvasPreset = true
        renderWidth = size.width
        renderHeight = size.height

        DispatchQueue.main.async {
            isApplyingCanvasPreset = false
        }
    }

    private func perspectivePointBinding(corner: PerspectiveCorner, axis: PerspectiveAxis) -> Binding<Double> {
        Binding(
            get: {
                let point = store.selectedClip?.transform.perspective[corner] ?? PerspectiveQuad.unit[corner]
                switch axis {
                case .x: return Double(point.x * 100)
                case .y: return Double(point.y * 100)
                }
            },
            set: { newValue in
                var point = store.selectedClip?.transform.perspective[corner] ?? PerspectiveQuad.unit[corner]
                switch axis {
                case .x:
                    point.x = CGFloat(newValue / 100)
                case .y:
                    point.y = CGFloat(newValue / 100)
                }
                store.updateSelectedPerspective(corner: corner, point: point)
            }
        )
    }

    private func applyCorrectionInset(x: Double, y: Double) {
        setPerspectiveQuad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: 1 - x, y: y),
            bottomRight: CGPoint(x: 1 - x, y: 1 - y),
            bottomLeft: CGPoint(x: x, y: 1 - y)
        )
    }

    private func applyCenteredSourceAspect(width: Double, height: Double) {
        let targetAspect = max(width, 0.01) / max(height, 0.01)
        let canvasAspect = currentCanvasAspectRatio
        var normalizedWidth = 1.0
        var normalizedHeight = 1.0

        if targetAspect > canvasAspect {
            normalizedHeight = canvasAspect / targetAspect
        } else {
            normalizedWidth = targetAspect / canvasAspect
        }

        let x = (1 - normalizedWidth) / 2
        let y = (1 - normalizedHeight) / 2

        setPerspectiveQuad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + normalizedWidth, y: y),
            bottomRight: CGPoint(x: x + normalizedWidth, y: y + normalizedHeight),
            bottomLeft: CGPoint(x: x, y: y + normalizedHeight)
        )
    }

    private func setPerspectiveQuad(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) {
        store.updateSelectedPerspective(corner: .topLeft, point: topLeft)
        store.updateSelectedPerspective(corner: .topRight, point: topRight)
        store.updateSelectedPerspective(corner: .bottomRight, point: bottomRight)
        store.updateSelectedPerspective(corner: .bottomLeft, point: bottomLeft)
    }

    private func startMediaURLDownload() {
        let url = trimmedMediaDownloadURL
        guard isValidMediaDownloadURL else {
            mediaDownloadManager.userMessage = "http 또는 https 영상 URL을 입력해 주세요."
            return
        }

        guard let ffmpegPath = toolManager.status.ffmpeg.path else {
            mediaDownloadManager.userMessage = "ffmpeg를 찾을 수 없습니다."
            return
        }

        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)
        let ytDlpURL = toolManager.status.ytDlp.path.map { URL(fileURLWithPath: $0) }

        if mediaDownloadRequiresYtDlp && ytDlpURL == nil {
            mediaDownloadManager.userMessage = "yt-dlp를 찾을 수 없습니다."
            return
        }

        lastImportedDownloadPath = nil

        mediaDownloadManager.startDownload(
            url: url,
            outputDir: outputDirectory,
            toolPaths: ToolPaths(
                ytDlpPath: ytDlpURL ?? ffmpegURL,
                ffmpegPath: ffmpegURL,
                ffprobePath: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) }
            ),
            options: DownloadOptions(
                preset: selectedDownloadPreset,
                conflictPolicy: selectedDownloadConflictPolicy,
                filenameTemplate: "%(title)s.%(ext)s",
                forceDirectStreamCapture: false,
                hlsAutoReconnectEnabled: hlsAutoReconnectEnabled,
                hlsReconnectFailTimeoutSeconds: min(max(hlsReconnectFailTimeoutSeconds, 15), 1800)
            )
        )
    }

    private func handleCompletedMediaDownload() {
        guard autoImportDownloadedMedia else { return }
        importCompletedMediaDownload(force: false)
    }

    private func importCompletedMediaDownload(force: Bool) {
        guard let outputURL = mediaDownloadManager.outputFilePath?.standardizedFileURL else {
            store.userMessage = "가져올 다운로드 파일을 찾지 못했습니다."
            return
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            store.userMessage = "다운로드 파일이 아직 디스크에 없습니다."
            return
        }

        if !force, lastImportedDownloadPath == outputURL.path {
            return
        }

        store.importMedia(urls: [outputURL])
        lastImportedDownloadPath = outputURL.path
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

        return components.queryItems?.contains { item in
            let name = item.name.lowercased()
            let value = (item.value ?? "").lowercased()
            return name.contains("m3u8") || value.contains(".m3u8") || value == "m3u8"
        } ?? false
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.title = "프로젝트 저장"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [projectDocumentType]
        panel.nameFieldStringValue = "\(projectBaseName()).vstproject"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document = store.makeProjectDocument(
            renderWidth: safeRenderWidth,
            renderHeight: safeRenderHeight,
            outputBaseName: outputBaseName,
            canvasPresetRawValue: selectedCanvasPreset.rawValue,
            exportPresetRawValue: selectedExportPreset.rawValue
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            store.userMessage = "프로젝트를 저장했습니다."
        } catch {
            store.userMessage = "프로젝트 저장 실패: \(error.localizedDescription)"
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.title = "프로젝트 열기"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [projectDocumentType, .json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(EditorProjectDocument.self, from: data)
            store.loadProjectDocument(document)
            renderWidth = document.renderWidth
            renderHeight = document.renderHeight
            outputBaseName = document.outputBaseName
            selectedCanvasPreset = EditorCanvasPreset(rawValue: document.canvasPresetRawValue) ?? .custom
            selectedExportPreset = EditorExportPreset(rawValue: document.exportPresetRawValue) ?? .balanced
        } catch {
            store.userMessage = "프로젝트 열기 실패: \(error.localizedDescription)"
        }
    }

    private var projectDocumentType: UTType {
        UTType(filenameExtension: "vstproject") ?? .json
    }

    private func projectBaseName() -> String {
        let trimmed = outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "editor-project" : trimmed
    }

    private func selectMediaFiles() {
        let panel = NSOpenPanel()
        panel.title = "미디어 가져오기"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let subtitleType = UTType(filenameExtension: "srt") ?? .plainText
        panel.allowedContentTypes = [.video, .audio, .image, subtitleType]

        if panel.runModal() == .OK {
            store.importMedia(urls: panel.urls)
        }
    }

    private func handleFileDrop(providers: [NSItemProvider], addToTimeline: Bool) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        isProcessingFileDrop = true

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "video-simple-toolkit.editor.file-drop")
        var droppedURLs: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                guard let url = resolvedFileURL(from: item) else { return }
                resultQueue.async {
                    droppedURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let uniqueURLs = resultQueue.sync {
                var seenPaths = Set<String>()
                return droppedURLs.filter { url in
                    seenPaths.insert(url.path).inserted
                }
            }

            guard !uniqueURLs.isEmpty else {
                store.userMessage = addToTimeline
                    ? "타임라인에 추가할 로컬 파일을 찾지 못했습니다."
                    : "가져올 로컬 미디어 파일을 찾지 못했습니다."
                isProcessingFileDrop = false
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withTransaction(Transaction(animation: nil)) {
                    if addToTimeline {
                        store.importMediaAndAddToTimeline(urls: uniqueURLs, selectAddedClip: false)
                    } else {
                        store.importMedia(urls: uniqueURLs)
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isProcessingFileDrop = false
                }
            }
        }

        return true
    }

    private func resolvedFileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?

        if let itemURL = item as? URL {
            url = itemURL
        } else if let itemURL = item as? NSURL {
            url = itemURL as URL
        } else if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let string = item as? String {
            if let parsedURL = URL(string: string), parsedURL.isFileURL {
                url = parsedURL
            } else {
                url = URL(fileURLWithPath: string)
            }
        } else {
            url = nil
        }

        guard let url, url.isFileURL else { return nil }
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return nil }
        return standardizedURL
    }

    @ViewBuilder
    private func dropTargetOverlay(isTargeted: Bool) -> some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 6)
                .fill(accentMint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accentMint.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                )
                .overlay {
                    Label("파일 놓기", systemImage: "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .allowsHitTesting(false)
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "출력 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    private func startExport() {
        guard let ffmpegPath = toolManager.status.ffmpeg.path else {
            exportManager.userMessage = "ffmpeg를 찾을 수 없습니다."
            return
        }

        let request = store.makeExportRequest(
            outputDirectory: outputDirectory,
            outputBaseName: outputBaseName,
            renderSize: CGSize(width: safeRenderWidth, height: safeRenderHeight),
            preset: selectedExportPreset,
            ffmpegURL: URL(fileURLWithPath: ffmpegPath),
            ffprobeURL: toolManager.status.ffprobe?.path.map { URL(fileURLWithPath: $0) }
        )

        guard let request else { return }
        exportManager.startExport(request: request)
    }

    private func mediaIcon(for kind: EditorMediaKind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .subtitle: return "captions.bubble"
        }
    }

    private func mediaDetail(for asset: EditorMediaAsset) -> String {
        switch asset.kind {
        case .subtitle:
            return "\(asset.kind.title) | \(asset.subtitleCues.count) cues | \(formattedTime(asset.duration))"
        case .video, .audio, .image:
            return "\(asset.kind.title) | \(formattedTime(asset.duration))"
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(Int(seconds.rounded()), 0)
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private func formattedAspectRatio(width: Int, height: Int) -> String {
        let divisor = greatestCommonDivisor(max(width, 1), max(height, 1))
        return "\(width / divisor):\(height / divisor)"
    }

    private func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }

    private func evenDimension(_ value: Int) -> Int {
        let safeValue = max(value, 2)
        return safeValue.isMultiple(of: 2) ? safeValue : safeValue + 1
    }

    private static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

private struct EditorKeyboardCaptureView: NSViewRepresentable {
    let focusToken: Int
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> KeyboardCaptureNSView {
        let view = KeyboardCaptureNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyboardCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown

        guard focusToken > 0, context.coordinator.focusToken != focusToken else { return }
        context.coordinator.focusToken = focusToken

        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator {
        var focusToken = 0
    }
}

private final class KeyboardCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}

private struct EditorClipPreview: View {
    let clip: EditorClip
    let previewTime: Double
    let isPlaying: Bool
    let isMuted: Bool
    let suppressVideoPlayer: Bool

    var body: some View {
        ZStack {
            switch clip.kind {
            case .video:
                if let url = clip.sourceURL, !suppressVideoPlayer {
                    EditorVideoPreview(
                        url: url,
                        time: clip.localMediaTime(at: previewTime),
                        isPlaying: isPlaying,
                        isMuted: isMuted
                    )
                } else {
                    placeholder
                }
            case .image:
                if let url = clip.sourceURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    placeholder
                }
            case .audio:
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 44))
                    Text(clip.title)
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
            case .text:
                Text(clip.text)
                    .font(.system(size: max(14, 34 * clip.transform.scaleY), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(clip.transform.resolvedSubtitleBackgroundOpacity))
                    )
            case .subtitle:
                VStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 44))
                    Text(clip.title)
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var placeholder: some View {
        Text(clip.title)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
    }
}

private struct EditorAudioPreviewItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let time: Double
}

private struct EditorTimelineAudioPreview: NSViewRepresentable {
    let items: [EditorAudioPreviewItem]
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(items: items, isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopAll()
    }

    final class Coordinator {
        private var players: [UUID: AVPlayer] = [:]
        private var urls: [UUID: URL] = [:]
        private var lastSeekTimes: [UUID: Double] = [:]
        private var wasPlaying = false

        func update(items: [EditorAudioPreviewItem], isPlaying: Bool) {
            let activeIDs = Set(items.map(\.id))
            for id in Array(players.keys) where !activeIDs.contains(id) {
                players[id]?.pause()
                players[id] = nil
                urls[id] = nil
                lastSeekTimes[id] = nil
            }

            for item in items {
                let player: AVPlayer
                let forceSeek: Bool

                if let existingPlayer = players[item.id], urls[item.id] == item.url {
                    player = existingPlayer
                    forceSeek = !wasPlaying && isPlaying
                } else {
                    players[item.id]?.pause()
                    let newPlayer = AVPlayer(url: item.url)
                    newPlayer.actionAtItemEnd = .pause
                    newPlayer.isMuted = false
                    newPlayer.volume = 1
                    players[item.id] = newPlayer
                    urls[item.id] = item.url
                    player = newPlayer
                    forceSeek = true
                }

                sync(player: player, id: item.id, time: item.time, isPlaying: isPlaying, forceSeek: forceSeek)
            }

            if !isPlaying {
                for player in players.values {
                    player.pause()
                }
            }
            wasPlaying = isPlaying
        }

        func stopAll() {
            for player in players.values {
                player.pause()
            }
            players.removeAll()
            urls.removeAll()
            lastSeekTimes.removeAll()
            wasPlaying = false
        }

        private func sync(player: AVPlayer, id: UUID, time: Double, isPlaying: Bool, forceSeek: Bool) {
            let safeTime = max(time, 0)
            let targetTime = CMTime(seconds: safeTime, preferredTimescale: 600)

            if isPlaying {
                let currentTime = CMTimeGetSeconds(player.currentTime())
                let shouldSeek = forceSeek || !currentTime.isFinite || abs(currentTime - safeTime) > 0.35
                if shouldSeek {
                    lastSeekTimes[id] = safeTime
                    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if player.rate == 0 {
                    player.play()
                }
            } else {
                player.pause()
                if forceSeek || abs((lastSeekTimes[id] ?? -1) - safeTime) > 0.04 {
                    lastSeekTimes[id] = safeTime
                    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }
}

private struct EditorVideoPreview: NSViewRepresentable {
    let url: URL
    let time: Double
    let isPlaying: Bool
    let isMuted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        configure(playerView, coordinator: context.coordinator)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        configure(playerView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        playerView.player = nil
        coordinator.player = nil
        coordinator.url = nil
    }

    private func configure(_ playerView: AVPlayerView, coordinator: Coordinator) {
        guard coordinator.url != url else {
            playerView.player = coordinator.player
            coordinator.player?.isMuted = isMuted
            coordinator.sync(to: time, isPlaying: isPlaying)
            return
        }

        coordinator.player?.pause()
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        player.volume = 1
        player.actionAtItemEnd = .pause
        coordinator.url = url
        coordinator.player = player
        playerView.player = player
        coordinator.sync(to: time, isPlaying: isPlaying, force: true)
    }

    final class Coordinator {
        var url: URL?
        var player: AVPlayer?
        private var lastSeekTime: Double?
        private var wasPlaying = false

        func sync(to seconds: Double, isPlaying: Bool, force: Bool = false) {
            let safeSeconds = max(seconds, 0)
            let targetTime = CMTime(seconds: safeSeconds, preferredTimescale: 600)
            let forceSeek = force || (!wasPlaying && isPlaying)

            if isPlaying {
                let currentTime = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
                let shouldSeek = forceSeek || !currentTime.isFinite || abs(currentTime - safeSeconds) > 0.35
                if shouldSeek {
                    lastSeekTime = safeSeconds
                    player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                player?.play()
            } else {
                player?.pause()
                if forceSeek || lastSeekTime == nil || abs((lastSeekTime ?? -1) - safeSeconds) >= 0.04 {
                    lastSeekTime = safeSeconds
                    player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            wasPlaying = isPlaying
        }
    }
}

private extension EditorClip {
    func localMediaTime(at timelineTime: Double) -> Double {
        let localTime = min(max(timelineTime - startTime, 0), duration)
        return trimStart + localTime
    }
}

private struct EditorCornerTransformOverlay: View {
    static let coordinateSpaceName = "editorPreviewCanvas"

    let quad: PerspectiveQuad
    let selectedCorner: PerspectiveCorner
    let onSelect: (PerspectiveCorner) -> Void
    let onDrag: (PerspectiveCorner, CGPoint) -> Void
    let onBeginDrag: () -> Void
    let onEndDrag: () -> Void

    @State private var activeDragCorner: PerspectiveCorner?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuadShape(quad: quad)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .shadow(color: .black.opacity(0.6), radius: 2)

                ForEach(PerspectiveCorner.allCases) { corner in
                    Circle()
                        .fill(corner == selectedCorner ? Color.accentColor : Color.white)
                        .overlay(
                            Circle()
                                .stroke(corner == selectedCorner ? Color.white : Color.black.opacity(0.75), lineWidth: 1)
                        )
                        .overlay(
                            Text(corner.shortTitle)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(corner == selectedCorner ? .white : .black)
                        )
                        .frame(width: 20, height: 20)
                        .position(canvasPoint(for: quad[corner], size: geometry.size))
                        .onTapGesture {
                            onSelect(corner)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                                .onChanged { value in
                                    if activeDragCorner != corner {
                                        activeDragCorner = corner
                                        onBeginDrag()
                                    }

                                    let normalized = CGPoint(
                                        x: value.location.x / max(geometry.size.width, 1),
                                        y: value.location.y / max(geometry.size.height, 1)
                                    )
                                    onSelect(corner)
                                    onDrag(corner, normalized)
                                }
                                .onEnded { _ in
                                    activeDragCorner = nil
                                    onEndDrag()
                                }
                        )
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func canvasPoint(for point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

private enum EditorCanvasPreset: String, CaseIterable, Identifiable {
    case wide16x9
    case portrait3x4
    case square1x1
    case vertical9x16
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide16x9: return "16:9"
        case .portrait3x4: return "3:4"
        case .square1x1: return "1:1"
        case .vertical9x16: return "9:16"
        case .custom: return "직접"
        }
    }

    var size: (width: Int, height: Int)? {
        switch self {
        case .wide16x9:
            return (1920, 1080)
        case .portrait3x4:
            return (1440, 1920)
        case .square1x1:
            return (1080, 1080)
        case .vertical9x16:
            return (1080, 1920)
        case .custom:
            return nil
        }
    }
}

private enum PerspectiveAxis {
    case x
    case y
}

private struct QuadShape: Shape {
    let quad: PerspectiveQuad

    func path(in rect: CGRect) -> Path {
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + value.x * rect.width,
                y: rect.minY + value.y * rect.height
            )
        }

        var path = Path()
        path.move(to: point(quad.topLeft))
        path.addLine(to: point(quad.topRight))
        path.addLine(to: point(quad.bottomRight))
        path.addLine(to: point(quad.bottomLeft))
        path.closeSubpath()
        return path
    }
}

private struct EditorTimelineRuler: View {
    let duration: Double
    let width: CGFloat
    let pixelsPerSecond: Double

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Tracks")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: editorTimelineHeaderWidth, height: 28, alignment: .leading)
                .padding(.leading, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

            ZStack(alignment: .topLeading) {
                Color(nsColor: .controlBackgroundColor).opacity(0.35)

                ForEach(0...max(Int(ceil(duration)), 1), id: \.self) { second in
                    let isMajor = second.isMultiple(of: 5)

                    VStack(alignment: .leading, spacing: 2) {
                        Rectangle()
                            .fill(Color.white.opacity(isMajor ? 0.34 : 0.16))
                            .frame(width: 1, height: isMajor ? 13 : 8)

                        if isMajor {
                            Text(rulerLabel(for: second))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .offset(x: CGFloat(Double(second) * pixelsPerSecond))
                }
            }
            .frame(width: width, height: 28)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func rulerLabel(for seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }
}

private struct EditorTimelinePlayhead: View {
    let x: CGFloat
    let height: CGFloat
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 22, height: height + 10)

            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.95))
                    .frame(width: 12, height: 7)

                Rectangle()
                    .fill(Color.red.opacity(0.92))
                    .frame(width: 2, height: height)
            }
        }
        .offset(x: x - 11)
        .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDrag(value.translation.width)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .help("타임커서 드래그")
    }
}

private struct EditorTimelineHorizontalScrollAnchor: NSViewRepresentable {
    let requestID: Int
    let visibilityInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        guard requestID > 0 else { return }

        let requestedID = requestID
        let coordinator = context.coordinator

        DispatchQueue.main.async { [weak nsView] in
            guard coordinator.lastHandledRequestID != requestedID,
                  let nsView,
                  nsView.scrollHorizontallyToVisible(visibilityInset: visibilityInset) else {
                return
            }

            coordinator.lastHandledRequestID = requestedID
        }
    }

    final class Coordinator {
        var lastHandledRequestID = 0
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func scrollHorizontallyToVisible(visibilityInset: CGFloat) -> Bool {
            guard let scrollView = enclosingScrollView,
                  let documentView = scrollView.documentView else {
                return false
            }

            let visibleRect = scrollView.documentVisibleRect
            guard visibleRect.width > 1 else { return false }

            let anchorRect = convert(bounds, to: documentView)
            let anchorX = anchorRect.midX
            let inset = min(max(visibilityInset, 0), max(visibleRect.width / 2 - 1, 0))
            let leftVisibleX = visibleRect.minX + inset
            let rightVisibleX = visibleRect.maxX - inset

            var targetOriginX: CGFloat?
            if anchorX < leftVisibleX {
                targetOriginX = anchorX - inset
            } else if anchorX > rightVisibleX {
                targetOriginX = anchorX - visibleRect.width + inset
            }

            guard var originX = targetOriginX else { return true }

            let minOriginX = documentView.bounds.minX
            let maxOriginX = max(minOriginX, documentView.bounds.maxX - visibleRect.width)
            originX = min(max(originX, minOriginX), maxOriginX)

            guard abs(originX - visibleRect.origin.x) > 0.5 else { return true }

            let currentOrigin = scrollView.contentView.bounds.origin
            scrollView.contentView.scroll(to: NSPoint(x: originX, y: currentOrigin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        }
    }
}

private struct EditorTimelineLaneGrid: View {
    let duration: Double
    let pixelsPerSecond: Double

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(0...max(Int(ceil(duration)), 1), id: \.self) { second in
                Rectangle()
                    .fill(Color.white.opacity(second.isMultiple(of: 5) ? 0.09 : 0.035))
                    .frame(width: 1)
                    .offset(x: CGFloat(Double(second) * pixelsPerSecond))
            }
        }
    }
}

private struct EditorTimelineTrackRow: View {
    let track: EditorTrack
    let selectedClipID: UUID?
    let duration: Double
    let width: CGFloat
    let pixelsPerSecond: Double
    let onSelect: (EditorClip) -> Void
    let onScrub: (Double) -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    let onMove: (UUID, Double, [EditorClip]?) -> Void
    let onTrimStart: (UUID, Double) -> Void
    let onTrimEnd: (UUID, Double) -> Void
    let onFadeIn: (UUID, Double) -> Void
    let onFadeOut: (UUID, Double) -> Void
    let onToggleMute: (UUID) -> Void
    let onToggleHidden: (UUID) -> Void
    let onMoveToPlayhead: (EditorClip) -> Void
    let onSplit: (EditorClip) -> Void
    let onDuplicate: (EditorClip) -> Void
    let onRippleDelete: (EditorClip) -> Void
    let onDelete: (EditorClip) -> Void

    @State private var dragState: EditorTimelineClipDragState?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: trackIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)

                    Text("\(track.clips.count) clips")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(spacing: 3) {
                    Button {
                        onToggleHidden(track.id)
                    } label: {
                        Image(systemName: track.isHidden ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(track.isHidden ? Color.orange : Color.secondary)
                    .help(track.isHidden ? "트랙 표시" : "트랙 숨김")

                    Button {
                        onToggleMute(track.id)
                    } label: {
                        Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(track.isMuted ? Color.orange : Color.secondary)
                    .opacity(track.kind == .text ? 0.28 : 1)
                    .disabled(track.kind == .text)
                    .help(track.isMuted ? "트랙 음소거 해제" : "트랙 음소거")
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(width: editorTimelineHeaderWidth, height: 54)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))

                EditorTimelineLaneGrid(duration: duration, pixelsPerSecond: pixelsPerSecond)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let seconds = Double(max(value.location.x, 0)) / pixelsPerSecond
                                onScrub(seconds)
                            }
                    )

                ForEach(track.clips) { clip in
                    timelineClip(clip)
                        .offset(x: CGFloat(clip.startTime * pixelsPerSecond))
                }
            }
            .opacity(track.isHidden ? 0.48 : 1)
            .frame(width: width, height: 54)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func timelineClip(_ clip: EditorClip) -> some View {
        let width = CGFloat(max(64, clip.duration * pixelsPerSecond))
        let isSelected = selectedClipID == clip.id

        return ZStack {
            HStack(spacing: 4) {
                Image(systemName: icon(for: clip.kind))
                Text(clip.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 8)
            .frame(width: width, height: 36, alignment: .leading)
            .background(isSelected ? Color.accentColor : clipColor(for: clip.kind))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(clip)
            }
            .gesture(dragGesture(for: clip, mode: .move))
            .contextMenu {
                Button("선택") {
                    onSelect(clip)
                }
                Button("플레이헤드로 이동") {
                    onMoveToPlayhead(clip)
                }
                Button("플레이헤드에서 자르기") {
                    onSplit(clip)
                }
                Button("복제") {
                    onDuplicate(clip)
                }
                Divider()
                Button("리플 삭제", role: .destructive) {
                    onRippleDelete(clip)
                }
                Button("삭제", role: .destructive) {
                    onDelete(clip)
                }
            }

            HStack {
                trimHandle(edge: .leading, clip: clip)
                Spacer()
                trimHandle(edge: .trailing, clip: clip)
            }
            .frame(width: width, height: 36)

            fadeOverlay(for: clip, width: width, isSelected: isSelected)
        }
        .frame(width: width, height: 36)
    }

    private func fadeOverlay(for clip: EditorClip, width: CGFloat, isSelected: Bool) -> some View {
        let fadeInWidth = min(width, CGFloat((clip.fadeInDuration ?? 0) * pixelsPerSecond))
        let fadeOutWidth = min(width, CGFloat((clip.fadeOutDuration ?? 0) * pixelsPerSecond))
        let handleColor = isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.58)

        return ZStack(alignment: .topLeading) {
            if fadeInWidth > 0 {
                Rectangle()
                    .fill(Color.white.opacity(isSelected ? 0.16 : 0.08))
                    .frame(width: fadeInWidth, height: 4)
                    .offset(x: 0, y: 2)
            }

            if fadeOutWidth > 0 {
                Rectangle()
                    .fill(Color.white.opacity(isSelected ? 0.16 : 0.08))
                    .frame(width: fadeOutWidth, height: 4)
                    .offset(x: max(0, width - fadeOutWidth), y: 2)
            }

            fadeHandle(color: handleColor, help: "Fade in")
                .offset(x: max(0, min(width - 9, fadeInWidth - 4)), y: -1)
                .gesture(dragGesture(for: clip, mode: .fadeIn))

            fadeHandle(color: handleColor, help: "Fade out")
                .offset(x: max(0, min(width - 9, width - fadeOutWidth - 5)), y: -1)
                .gesture(dragGesture(for: clip, mode: .fadeOut))
        }
        .frame(width: width, height: 36, alignment: .topLeading)
        .allowsHitTesting(true)
    }

    private func fadeHandle(color: Color, help: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
            .help(help)
    }

    private func trimHandle(edge: HorizontalEdge, clip: EditorClip) -> some View {
        Capsule()
            .fill(selectedClipID == clip.id ? Color.white.opacity(0.82) : Color.white.opacity(0.45))
            .frame(width: 6, height: 24)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .help(edge == .leading ? "앞부분 trim" : "뒷부분 trim")
            .gesture(dragGesture(for: clip, mode: edge == .leading ? .trimStart : .trimEnd))
    }

    private func dragGesture(for clip: EditorClip, mode: EditorTimelineClipDragMode) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let state: EditorTimelineClipDragState
                if let dragState {
                    state = dragState
                } else {
                    onBeginEditing()
                    state = EditorTimelineClipDragState(
                        clipID: clip.id,
                        mode: mode,
                        startTime: clip.startTime,
                        duration: clip.duration,
                        trimStart: clip.trimStart,
                        fadeInDuration: clip.fadeInDuration ?? 0,
                        fadeOutDuration: clip.fadeOutDuration ?? 0,
                        baselineClips: track.clips
                    )
                }
                dragState = state

                let deltaSeconds = Double(value.translation.width) / pixelsPerSecond
                switch state.mode {
                case .move:
                    onMove(state.clipID, state.startTime + deltaSeconds, state.baselineClips)
                case .trimStart:
                    onTrimStart(state.clipID, state.startTime + deltaSeconds)
                case .trimEnd:
                    onTrimEnd(state.clipID, state.startTime + state.duration + deltaSeconds)
                case .fadeIn:
                    onFadeIn(state.clipID, state.fadeInDuration + deltaSeconds)
                case .fadeOut:
                    onFadeOut(state.clipID, state.fadeOutDuration - deltaSeconds)
                }
            }
            .onEnded { _ in
                dragState = nil
                onEndEditing()
            }
    }

    private var trackIcon: String {
        switch track.kind {
        case .video: return "film.stack"
        case .audio: return "waveform"
        case .text: return "captions.bubble"
        }
    }

    private func icon(for kind: EditorClipKind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .text: return "textformat"
        case .subtitle: return "captions.bubble"
        }
    }

    private func clipColor(for kind: EditorClipKind) -> Color {
        switch kind {
        case .video: return Color.blue.opacity(0.22)
        case .audio: return Color.green.opacity(0.22)
        case .image: return Color.purple.opacity(0.22)
        case .text: return Color.orange.opacity(0.24)
        case .subtitle: return Color.orange.opacity(0.30)
        }
    }
}

private enum EditorTimelineClipDragMode {
    case move
    case trimStart
    case trimEnd
    case fadeIn
    case fadeOut
}

private enum EditorFadeEdge {
    case fadeIn
    case fadeOut
}

private struct EditorTimelineClipDragState {
    let clipID: UUID
    let mode: EditorTimelineClipDragMode
    let startTime: Double
    let duration: Double
    let trimStart: Double
    let fadeInDuration: Double
    let fadeOutDuration: Double
    let baselineClips: [EditorClip]
}
