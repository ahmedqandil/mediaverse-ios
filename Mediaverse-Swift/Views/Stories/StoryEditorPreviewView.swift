import AVFoundation
import CoreImage
import CoreMedia
import CoreTransferable
import ImageIO
import MapKit
import PencilKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PickedStoryOverlayVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("story-overlay-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return PickedStoryOverlayVideo(url: destination)
        }
    }
}

private enum StoryEditorTool: String, Identifiable, Equatable {
    case clip
    case look
    case audio
    case stickers
    case music
    case timing

    var id: String { rawValue }
}

private enum StoryStickerTool: String, CaseIterable, Identifiable {
    case link
    case location
    case mention
    case poll
    case quiz
    case questions
    case countdown
    case gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: return "Link"
        case .location: return "Location"
        case .mention: return "Mention"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .questions: return "Questions"
        case .countdown: return "Countdown"
        case .gif: return "GIF"
        }
    }

    var icon: String {
        switch self {
        case .link: return "link"
        case .location: return "mappin.and.ellipse"
        case .mention: return "at"
        case .poll: return "chart.bar"
        case .quiz: return "checklist"
        case .questions: return "questionmark.bubble"
        case .countdown: return "timer"
        case .gif: return "sparkles"
        }
    }

    var defaultText: String {
        switch self {
        case .location: return "Add location"
        case .mention: return "@mention"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .questions: return "Ask me a question"
        case .countdown: return "Countdown"
        default: return title
        }
    }

    var defaultSubtitle: String? {
        switch self {
        case .location: return "City or place"
        case .mention: return "Placeholder"
        case .questions: return "Viewer replies"
        case .countdown: return "Tomorrow"
        default: return nil
        }
    }

    var defaultOptions: [String] {
        switch self {
        case .poll: return ["Yes", "No"]
        case .quiz: return ["A", "B", "C"]
        default: return []
        }
    }

    var interactiveKind: StoryInteractiveStickerKind? {
        switch self {
        case .link: return .link
        case .location: return .location
        case .mention: return .mention
        case .poll: return .poll
        case .quiz: return .quiz
        case .questions: return .question
        case .countdown: return .countdown
        default: return nil
        }
    }
}

private enum StoryStickerComposerKind: Identifiable, Equatable {
    case link
    case location
    case poll
    case quiz
    case question
    case countdown

    var id: String { title }

    var title: String {
        switch self {
        case .link: return "Link"
        case .location: return "Location"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .question: return "Question"
        case .countdown: return "Countdown"
        }
    }

    var primaryPlaceholder: String {
        switch self {
        case .link: return "Link label"
        case .location: return "City or place"
        case .poll: return "Ask a question"
        case .quiz: return "Quiz question"
        case .question: return "Prompt"
        case .countdown: return "Countdown name"
        }
    }

    var guideText: String {
        switch self {
        case .link: return "Add a tappable link sticker to your story."
        case .location: return "Add a place sticker that viewers can see on your story."
        case .poll: return "Add a poll question with two to four choices."
        case .quiz: return "Add a quiz question, choices, and the correct answer."
        case .question: return "Ask viewers to send a reply to your story."
        case .countdown: return "Add a countdown sticker with a future end time."
        }
    }
}

private struct StoryResolvedLocation: Equatable {
    let name: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double
}

@MainActor
private final class StoryLocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var completions: [MKLocalSearchCompletion] = []
    @Published private(set) var isResolving = false
    @Published private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private var resolveGeneration = 0

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        guard trimmed.count >= 2 else {
            completions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        resolveGeneration &+= 1
        completions = []
        errorMessage = nil
        isResolving = false
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.completions = results
            self.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let queryFragment = completer.queryFragment
        Task { @MainActor in
            guard !queryFragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.completions = []
            self.errorMessage = error.localizedDescription
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> StoryResolvedLocation? {
        resolveGeneration &+= 1
        let generation = resolveGeneration
        isResolving = true
        errorMessage = nil
        defer {
            if generation == resolveGeneration { isResolving = false }
        }

        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, generation == resolveGeneration else { return nil }
            guard let item = response.mapItems.first else {
                errorMessage = "No matching place found."
                return nil
            }
            let coordinate = item.placemark.coordinate
            let subtitle = item.placemark.title?.isEmpty == false ? item.placemark.title : completion.subtitle
            return StoryResolvedLocation(
                name: item.name ?? completion.title,
                subtitle: subtitle,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } catch {
            guard !Task.isCancelled, generation == resolveGeneration else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

private enum StoryDrawingStyle: String, CaseIterable, Identifiable {
    case pen
    case marker
    case pencil

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        }
    }
    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: return .pen
        case .marker: return .marker
        case .pencil: return .pencil
        }
    }
}

private enum StoryDrawingColor: String, CaseIterable, Identifiable {
    case white
    case green
    case red
    case yellow
    case blue
    case black

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .white: return .white
        case .green: return C.watch
        case .red: return .red
        case .yellow: return .yellow
        case .blue: return C.play
        case .black: return .black
        }
    }
    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .green: return UIColor(red: 0, green: 230/255, blue: 118/255, alpha: 1)
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .blue: return UIColor(red: 64/255, green: 196/255, blue: 1, alpha: 1)
        case .black: return .black
        }
    }
}

struct StoryEditorPreviewView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @StateObject private var editor: StoryTimelineEditor
    @StateObject private var locationSearch = StoryLocationSearchModel()
    let onProjectChange: (Project) -> Void
    let onClose: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var renderedImage: UIImage?
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var isRendering = false
    @State private var previewRenderNeedsRefresh = false
    @State private var renderError: String?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var filterHUDVisible = false
    @State private var filterHUDTask: Task<Void, Never>?
    @State private var filterThumbnailTask: Task<Void, Never>?
    @State private var filterThumbnails: [String: UIImage] = [:]
    @State private var clipThumbnailTask: Task<Void, Never>?
    @State private var clipThumbnails: [UUID: UIImage] = [:]
    @State private var isComparingOriginal = false
    @State private var previewPlayer: AVPlayer?
    @State private var previewPlayerURL: URL?
    @State private var previewPlayerSignature = ""
    @State private var previewPlayerTimeObserver: Any?
    @State private var previewPlayerEndObserver: NSObjectProtocol?
    @State private var previewPlayerStatusObserver: NSKeyValueObservation?
    @State private var previewPlaybackWatchdogTask: Task<Void, Never>?
    @State private var timedOverlayClockTask: Task<Void, Never>?
    @State private var musicImportTask: Task<Void, Never>?
    @State private var mediaOverlayImportTask: Task<Void, Never>?
    @State private var networkStickerTask: Task<Void, Never>?
    @State private var drawingImportTask: Task<Void, Never>?
    @State private var shouldResumePlaybackAfterToolPreview = false
    @State private var newOverlayText = ""
    @State private var newLinkLabel = ""
    @State private var newLinkURL = ""
    @State private var editingLinkLabel = ""
    @State private var editingLinkURL = ""
    @State private var selectedEmoji = "🔥"
    @State private var editingOverlayText = ""
    @State private var activeTool: StoryEditorTool?
    @State private var isImportingMusic = false
    @State private var isImportingMediaOverlay = false
    @State private var isShowingGiphyPicker = false
    @State private var mediaOverlaySelection: PhotosPickerItem?
    @State private var isDrawingPresented = false
    @State private var drawing = PKDrawing()
    @State private var drawingStyle: StoryDrawingStyle = .pen
    @State private var drawingColor: StoryDrawingColor = .white
    @State private var drawingWidth: Double = 10
    @State private var assetStore: AssetStore?
    @State private var basePreviewSignature = ""
    @State private var isTextComposerPresented = false
    @State private var isMentionComposerPresented = false
    @State private var stickerComposerKind: StoryStickerComposerKind?
    @State private var mentionSearchText = "@"
    @State private var stickerComposerTitle = ""
    @State private var stickerComposerSubtitle = ""
    @State private var stickerComposerOptions = ["", "", "", ""]
    @State private var stickerComposerCorrectIndex = 0
    @State private var stickerComposerDate = Date().addingTimeInterval(24 * 60 * 60)
    @State private var stickerLocationLatitude: Double?
    @State private var stickerLocationLongitude: Double?
    @State private var composerText = ""
    @State private var composerEditingOverlayID: UUID?
    @State private var composerStyle = TextOverlayStyle.default
    @State private var composerColorIndex = 0
    @State private var composerFontIndex = 0
    @State private var keyboardHeight: CGFloat = 0
    @State private var isOverlayInteracting = false
    @State private var measuredInteractiveStickerSizes: [UUID: CGSize] = [:]
    @State private var overlayAlignmentGuide = OverlayAlignmentGuide()
    @State private var clipBaselineClip: VideoClip?
    @State private var filterBaselineClip: VideoClip?
    @State private var lookSection: StoryLookSection = .filters
    @State private var filterCategory: StoryFilterCategory = .popular
    @State private var audioBaselineClip: VideoClip?
    @State private var musicBaselineClip: AudioClip?
    @State private var toolSheetDismissShouldCancel = true
    @State private var overlayTimingStart = 0.0
    @State private var overlayTimingDuration = 5.0
    @FocusState private var isTextComposerFocused: Bool
    @FocusState private var isMentionComposerFocused: Bool
    @FocusState private var isStickerComposerFocused: Bool

    private let compositor = StoryCompositor()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(
        project: Project,
        onProjectChange: @escaping (Project) -> Void = { _ in },
        onClose: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) {
        _editor = StateObject(wrappedValue: StoryTimelineEditor(project: project))
        self.onProjectChange = onProjectChange
        self.onClose = onClose
        self.onBack = onBack
        self.onNext = onNext
    }

    private var project: Project { editor.project }

    private var duration: Double {
        max(editor.project.totalDurationSeconds, 0.1)
    }

    private var saveStatusText: String {
        if editor.isSaving { return "Saving…" }
        if editor.persistenceErrorMessage != nil { return "Not saved" }
        return "Saved"
    }

    private var canShareStory: Bool {
        editor.project.totalDurationSeconds <= storyMaxDurationSeconds + 0.05
    }

    private var shouldShowAudioTool: Bool {
        editor.selectedClip?.assetRef.kind == .video || !editor.project.tracks.audioClips.isEmpty
    }

    private var usesRenderedToolPreview: Bool {
        activeTool != nil && !isTextComposerPresented && !isDrawingPresented
    }

    private var previewRenderDebounceDelay: UInt64 {
        usesRenderedToolPreview ? 70_000_000 : 0
    }

    private var videoPreviewClip: VideoClip? {
        editor.project.tracks.videoClips.first { $0.assetRef.kind == .video }
    }

    private var hasVideoPreviewClip: Bool {
        videoPreviewClip != nil
    }

    private var hasTimedMediaOverlay: Bool {
        project.tracks.overlays.contains { overlay in
            guard case .sticker(let sticker) = overlay, let assetRef = sticker.assetRef else { return false }
            if assetRef.kind == .video { return true }
            let ext = URL(fileURLWithPath: assetRef.relativePath).pathExtension.lowercased()
            return assetRef.kind == .image && (ext == "gif" || ext == "webp")
        }
    }

    private var videoPreviewURL: URL? {
        guard let assetStore, let videoPreviewClip else { return nil }
        return assetStore.absoluteURL(for: videoPreviewClip.assetRef.relativePath)
    }

    private var videoPreviewUsesRenderComposition: Bool {
        guard let videoPreviewClip else { return false }
        return shouldUseVideoComposition(for: videoPreviewClip)
    }

    private var videoPreviewColorGrade: ColorAdjust {
        videoPreviewUsesRenderComposition ? .neutral : (videoPreviewClip?.adjustments ?? .neutral)
    }

    private func shouldUseVideoComposition(for clip: VideoClip) -> Bool {
        StoryFrameFilterRenderer.hasActiveFilter(
            filterId: clip.filterId,
            intensity: clip.filterIntensity,
            adjustments: clip.adjustments
        )
    }

    private func previewPlayerSignature(url: URL, clip: VideoClip) -> String {
        let preset = StoryEffectCatalog.preset(id: clip.filterId)
        return [
            url.path,
            clip.filterId ?? "neutral",
            "\(clip.filterIntensity)",
            preset.renderEffect.rawValue,
            "\(clip.adjustments.brightness)",
            "\(clip.adjustments.contrast)",
            "\(clip.adjustments.saturation)",
            "\(clip.adjustments.warmth)",
            "\(clip.adjustments.vignette)",
            "\(clip.muted)",
            "\(clip.volume)",
            "\(isComparingOriginal)"
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            editablePreviewSurface

            if isDrawingPresented {
                drawingTopOverlay
                drawingBottomOverlay
            } else {
                storyTopOverlay
                if !isOverlayInteracting {
                    storyBottomToolbar
                    if editor.selectedOverlayID != nil, !isTextComposerPresented, activeTool == nil {
                        selectedOverlayCanvasMenu
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(3)
                    }
                }
            }

            if isTextComposerPresented {
                textComposerOverlay
                    .zIndex(5)
            }

            if isMentionComposerPresented {
                mentionComposerOverlay
                    .zIndex(6)
            }

            if stickerComposerKind != nil {
                stickerComposerOverlay
                    .zIndex(7)
            }
        }
        .animation(accessibilityReduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86), value: activeTool?.id)
        .task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            try? await ProjectStore.shared.pruneUnreferencedAssets(in: project)
            guard !Task.isCancelled else { return }
            assetStore = await ProjectStore.shared.assetStore(for: project.id)
            scheduleClipThumbnails()
            basePreviewSignature = basePreviewSignature(for: project)
            if hasVideoPreviewClip, !usesRenderedToolPreview {
                configureVideoPreviewPlayer()
            } else {
                destroyPreviewPlayer()
                schedulePreviewRender(after: 90_000_000)
                startTimedOverlayClockIfNeeded()
            }
            presentFilterHUD()
        }
        .onDisappear {
            previewRenderTask?.cancel()
            filterHUDTask?.cancel()
            filterThumbnailTask?.cancel()
            clipThumbnailTask?.cancel()
            musicImportTask?.cancel()
            mediaOverlayImportTask?.cancel()
            networkStickerTask?.cancel()
            drawingImportTask?.cancel()
            timedOverlayClockTask?.cancel()
            locationSearch.clear()
            filterHUDVisible = false
            shouldResumePlaybackAfterToolPreview = false
            destroyPreviewPlayer()
            Task { await compositor.clearCaches() }
        }
        .onChange(of: currentTime) { _, _ in
            guard !isPlaying else { return }
            schedulePreviewRender()
        }
        .onReceive(editor.$project) { project in
            onProjectChange(project)
            if project.tracks.videoClips.contains(where: { clipThumbnails[$0.id] == nil }) {
                scheduleClipThumbnails()
            }
            currentTime = min(currentTime, duration)
            let signature = basePreviewSignature(for: project)
            guard signature != basePreviewSignature else {
                if usesRenderedToolPreview {
                    destroyPreviewPlayer()
                    schedulePreviewRender()
                } else if hasVideoPreviewClip {
                    resumeVideoPreviewPlaybackIfNeeded()
                } else {
                    startTimedOverlayClockIfNeeded()
                }
                return
            }
            basePreviewSignature = signature
            if hasVideoPreviewClip, !usesRenderedToolPreview {
                configureVideoPreviewPlayer()
            } else {
                destroyPreviewPlayer()
                schedulePreviewRender()
                startTimedOverlayClockIfNeeded()
            }
        }
        .onChange(of: activeTool?.id) { oldValue, newValue in
            handleToolPreviewModeChange(from: oldValue, to: newValue)
            if newValue == StoryEditorTool.look.id {
                filterCategory = StoryFilterCategory.category(for: currentFilterPreset.id)
                scheduleFilterThumbnails()
            }
        }
        .onChange(of: editor.selectedClipID) { _, _ in
            filterThumbnails.removeAll(keepingCapacity: true)
            if activeTool == .look {
                scheduleFilterThumbnails()
            }
        }
        .onChange(of: isComparingOriginal) { _, _ in
            if hasVideoPreviewClip, !usesRenderedToolPreview {
                configureVideoPreviewPlayer()
            } else {
                schedulePreviewRender()
            }
        }
        .sheet(item: $activeTool, onDismiss: {
            if toolSheetDismissShouldCancel {
                cancelLiveToolPreview()
            } else {
                clearLiveToolBaselines()
                toolSheetDismissShouldCancel = true
            }
        }) { tool in
            toolSheet(tool)
                .presentationDetents([.height(toolSheetHeight(for: tool)), .medium])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $isImportingMusic, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                musicImportTask?.cancel()
                musicImportTask = Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard !Task.isCancelled else { return }
                    await editor.importMusic(from: url)
                }
            case .failure(let error):
                renderError = error.localizedDescription
            }
        }
        .photosPicker(
            isPresented: $isImportingMediaOverlay,
            selection: $mediaOverlaySelection,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .sheet(isPresented: $isShowingGiphyPicker) {
            GiphyStickerPickerView { sticker in
                isShowingGiphyPicker = false
                networkStickerTask?.cancel()
                networkStickerTask = Task { await addGiphySticker(sticker) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mediaOverlaySelection) { _, item in
            guard let item else { return }
            mediaOverlayImportTask?.cancel()
            mediaOverlayImportTask = Task { await handleMediaOverlaySelection(item) }
        }
    }

    private var editablePreviewSurface: some View {
        GeometryReader { proxy in
            previewSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private var storyTopOverlay: some View {
        GeometryReader { proxy in
            VStack {
                HStack(spacing: 10) {
                    Button {
                        stopPlayback()
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.34))
                            .clipShape(Circle())
                    }
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Close editor")

                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: currentTime, total: duration)
                            .tint(C.watch)
                        Text("\(formatTime(currentTime)) / \(formatTime(duration)) · \(isOverlayInteracting ? "Editing" : saveStatusText)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                            .accessibilityLabel("Playhead \(formatTime(currentTime)) of \(formatTime(duration)). \(isOverlayInteracting ? "Editing sticker." : saveStatusText).")
                    }
                    .frame(maxWidth: proxy.size.width < 380 ? 96 : 150)

                    Spacer(minLength: 8)

                    if let preset = activeFilterPreset {
                        Text(isCurrentLookEdited ? "\(preset.name) · Edited" : preset.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Color.black.opacity(0.42))
                            .clipShape(Capsule())
                    }

                    editorTopIconButton("Undo", systemImage: "arrow.uturn.backward", disabled: !editor.canUndo) {
                        await editor.undo()
                    }

                    editorTopIconButton("Redo", systemImage: "arrow.uturn.forward", disabled: !editor.canRedo) {
                        await editor.redo()
                    }
                }
                .padding(.horizontal, proxy.size.width < 380 ? 20 : 24)
                .padding(.top, 58)

                Spacer()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func editorTopIconButton(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            stopPlayback()
            Task { await action() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(disabled ? 0.18 : 0.34))
                .clipShape(Circle())
        }
        .foregroundStyle(.white.opacity(disabled ? 0.38 : 1))
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    private var storyBottomToolbar: some View {
        GeometryReader { proxy in
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    creationToolbarButton("Text", systemImage: "textformat") {
                        beginTextComposer()
                    }
                    creationToolbarButton("Stickers", systemImage: "face.smiling") {
                        openTool(.stickers)
                    }
                    creationToolbarButton("Look", systemImage: "camera.filters") {
                        openTool(.look)
                    }
                    creationToolbarButton("Music", systemImage: "music.note") {
                        openTool(.music)
                    }
                    creationToolbarButton("Draw", systemImage: "pencil.tip") {
                        beginDrawing()
                    }

                    Menu {
                        Button {
                            openTool(.clip)
                        } label: {
                            Label("Edit clips", systemImage: "film.stack")
                        }
                        if shouldShowAudioTool {
                            Button {
                                openTool(.audio)
                            } label: {
                                Label("Audio", systemImage: "speaker.wave.2")
                            }
                        }
                        Button {
                            stopPlayback()
                            activeTool = nil
                            isImportingMediaOverlay = true
                        } label: {
                            Label("Add photo or video", systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            stopPlayback()
                            onBack()
                        } label: {
                            Label("Retake story", systemImage: "camera.rotate")
                        }
                    } label: {
                        creationToolbarLabel("More", systemImage: "ellipsis")
                    }
                    .accessibilityLabel("More editing tools")

                    Spacer(minLength: 2)

                    Button(action: shareStory) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 46, height: 46)
                            .background(C.watch)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Continue to share settings")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial.opacity(0.94))
                .background(Color.black.opacity(0.44))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.11)))
                .shadow(color: .black.opacity(0.32), radius: 16, y: 7)
                .padding(.horizontal, 10)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 8, 14))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(activeTool == nil && !isTextComposerPresented && !isMentionComposerPresented && stickerComposerKind == nil)
        .opacity(activeTool == nil && !isTextComposerPresented && !isMentionComposerPresented && stickerComposerKind == nil ? 1 : 0)
    }

    private func creationToolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            creationToolbarLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func creationToolbarLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 34, height: 24)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(.white)
        .frame(width: 42, height: 48)
        .contentShape(Rectangle())
    }

    private func openTool(_ tool: StoryEditorTool) {
        stopPlayback()
        cancelLiveToolPreview()
        activeTool = tool
    }

    private func beginOverlayTiming() {
        guard let range = editor.selectedOverlay?.timeRange else { return }
        overlayTimingStart = range.start.time.seconds
        overlayTimingDuration = range.duration.time.seconds
        openTool(.timing)
    }

    private func shareStory() {
        guard canShareStory else {
            renderError = "Stories can be up to 10 seconds. Delete or adjust a clip before sharing."
            return
        }
        stopPlayback()
        onNext()
    }

    private var drawingTopOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    cancelDrawing()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.48))
                        .clipShape(Circle())
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Cancel drawing")

                Spacer()

                Button {
                    saveDrawing()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(drawing.bounds.isEmpty ? Color.white.opacity(0.34) : C.watch)
                        .clipShape(Capsule())
                }
                .disabled(drawing.bounds.isEmpty)
                .accessibilityLabel("Save drawing")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Spacer()
        }
    }

    private var textComposerOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { isTextComposerFocused = true }

            VStack {
                HStack {
                    Button {
                        cancelTextComposer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.48))
                            .clipShape(Circle())
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    Button("Done") {
                        saveTextComposer()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()

                TextField("", text: $composerText, prompt: Text("Type text").foregroundStyle(swiftUIColor(composerStyle.color).opacity(0.55)), axis: .vertical)
                    .focused($isTextComposerFocused)
                    .font(composerUIFont(size: composerStyle.fontSize * 0.72))
                    .multilineTextAlignment(composerTextAlignment)
                    .foregroundStyle(swiftUIColor(composerStyle.color))
                    .lineLimit(1...5)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(composerStyle.backgroundColor.map(swiftUIColor) ?? Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: composerStyle.shadow ? .black.opacity(0.35) : .clear, radius: 12, y: 4)
                    .padding(.horizontal, 34)
                    .onChange(of: composerText) { _, value in
                        if value.count > 80 { composerText = String(value.prefix(80)) }
                    }

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(storyTextFonts.enumerated()), id: \.offset) { index, font in
                            Button {
                                composerFontIndex = index
                                composerStyle.fontName = font.name
                            } label: {
                                Text(font.title)
                                    .font(font.previewFont)
                                    .foregroundStyle(index == composerFontIndex ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(index == composerFontIndex ? Color.white : Color.black.opacity(0.46))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.white.opacity(0.72))

                    Slider(value: $composerStyle.fontSize, in: 36...96, step: 2)
                        .tint(.white)
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(Int(composerStyle.fontSize)) points")

                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(composerPalette.enumerated()), id: \.offset) { index, color in
                            Button {
                                composerColorIndex = index
                                composerStyle.color = color
                            } label: {
                                Circle()
                                    .fill(swiftUIColor(color))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Circle()
                                            .stroke(.white, lineWidth: index == composerColorIndex ? 3 : 1)
                                            .padding(index == composerColorIndex ? -4 : 0)
                                    }
                                    .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Text color \(index + 1)")
                            .accessibilityAddTraits(index == composerColorIndex ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
                }
                .padding(.bottom, 8)

                HStack(spacing: 10) {
                    textComposerTool(icon: composerAlignmentIcon, selected: composerStyle.alignment != "center") {
                        cycleComposerAlignment()
                    }
                    textComposerTool(icon: composerStyle.backgroundColor == nil ? "square" : "inset.filled.rectangle", selected: composerStyle.backgroundColor != nil) {
                        toggleComposerBackground()
                    }
                    Spacer(minLength: 4)
                    Button {
                        saveTextComposer()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 58, height: 44)
                            .background(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.18) : C.watch)
                            .foregroundStyle(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.45) : .black)
                            .clipShape(Capsule())
                    }
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Done")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.48))
                .clipShape(Capsule())
                .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 12 : 18)
                .animation(.easeOut(duration: 0.22), value: keyboardHeight)
            }
        }
        .task { isTextComposerFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardHeight = keyboardOverlap(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    private var mentionComposerOverlay: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture { cancelMentionComposer() }

            VStack(spacing: 14) {
                HStack {
                    Button {
                        cancelMentionComposer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.52))
                            .clipShape(Circle())
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    Text("Mention")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    Spacer()

                    Color.clear.frame(width: 38, height: 38)
                }

                TextField("Search people, channels, shows", text: $mentionSearchText)
                    .focused($isMentionComposerFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.text)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: mentionSearchText) { _, value in
                        if !value.hasPrefix("@") {
                            mentionSearchText = "@\(value.replacingOccurrences(of: "@", with: ""))"
                        }
                    }

                Text("Type @ plus a name or handle, then choose a result to place the mention sticker.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)

                MentionAutocompletePanel(text: $mentionSearchText, limit: 8, minimumQueryLength: 1) { result in
                    Task { await addMentionSticker(result) }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
        }
        .task { isMentionComposerFocused = true }
    }

    private var stickerComposerOverlay: some View {
        VStack(spacing: 14) {
                HStack {
                    Button {
                        cancelStickerComposer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.52))
                            .clipShape(Circle())
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    Text(stickerComposerKind?.title ?? "Sticker")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    Spacer()

                    Button {
                        Task { await addConfiguredSticker() }
                    } label: {
                        Text("Done")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(stickerComposerCanSave ? .black : .white.opacity(0.45))
                            .frame(width: 58, height: 38)
                            .background(stickerComposerCanSave ? C.watch : Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .disabled(!stickerComposerCanSave)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let kind = stickerComposerKind {
                        Text(kind.guideText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))

                        if kind == .location {
                            stickerComposerTextField(
                                placeholder: kind.primaryPlaceholder,
                                text: locationComposerTitleBinding,
                                focused: true
                            )
                        } else {
                            stickerComposerTextField(
                                placeholder: kind.primaryPlaceholder,
                                text: $stickerComposerTitle,
                                focused: true
                            )
                        }

                        switch kind {
                        case .link:
                            stickerComposerTextField(
                                placeholder: "https://",
                                text: $stickerComposerSubtitle,
                                textInputAutocapitalization: .never,
                                keyboardType: .URL,
                                autocorrectionDisabled: true
                            )
                        case .location:
                            locationSearchPanel
                        case .poll:
                            stickerOptionsEditor(title: "Choices", showCorrectAnswer: false)
                        case .quiz:
                            stickerOptionsEditor(title: "Answers", showCorrectAnswer: true)
                        case .question:
                            EmptyView()
                        case .countdown:
                            DatePicker(
                                "Ends",
                                selection: $stickerComposerDate,
                                in: Date().addingTimeInterval(60)...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.compact)
                            .tint(C.watch)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.text)
                            .padding(12)
                            .background(C.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(14)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle, lineWidth: 1))

                Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { isStickerComposerFocused = true }
    }

    private func stickerComposerTextField(
        placeholder: String,
        text: Binding<String>,
        focused: Bool = false,
        textInputAutocapitalization: TextInputAutocapitalization = .sentences,
        keyboardType: UIKeyboardType = .default,
        autocorrectionDisabled: Bool = false
    ) -> some View {
        TextField(placeholder, text: text)
            .focused($isStickerComposerFocused, equals: focused)
            .textInputAutocapitalization(textInputAutocapitalization)
            .keyboardType(keyboardType)
            .autocorrectionDisabled(autocorrectionDisabled)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(C.text)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(C.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var locationComposerTitleBinding: Binding<String> {
        Binding(
            get: { stickerComposerTitle },
            set: { value in
                stickerComposerTitle = value
                stickerComposerSubtitle = ""
                stickerLocationLatitude = nil
                stickerLocationLongitude = nil
                locationSearch.update(query: value)
            }
        )
    }

    private var locationSearchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if locationSearch.isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(C.watch)
                    Text("Finding place...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                }
                .padding(.vertical, 4)
            }

            if stickerLocationLatitude != nil {
                locationComposerPillPreview
            }

            if stickerLocationLatitude == nil,
               !stickerComposerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               locationSearch.completions.isEmpty,
               locationSearch.errorMessage == nil,
               !locationSearch.isResolving {
                Text("Choose a result below so viewers can open this place in Maps.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
            }

            if stickerLocationLatitude == nil, let errorMessage = locationSearch.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.9))
            }

            ForEach(Array(locationSearch.completions.prefix(6).enumerated()), id: \.offset) { _, completion in
                Button {
                    Task { await selectLocationCompletion(completion) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(C.watch)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(C.text)
                                .lineLimit(1)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(C.textMuted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var locationComposerPillPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(C.watch)

            VStack(alignment: .leading, spacing: 3) {
                Text(stickerComposerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                if !stickerComposerSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(stickerComposerSubtitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else {
                    Text(stickerLocationLatitude == nil ? "Manual location" : "Selected place")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            Spacer(minLength: 0)

            if stickerLocationLatitude != nil {
                Button {
                    stickerComposerTitle = ""
                    stickerComposerSubtitle = ""
                    stickerLocationLatitude = nil
                    stickerLocationLongitude = nil
                    locationSearch.clear()
                    isStickerComposerFocused = true
                } label: {
                    Text("Change")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(C.watch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change selected location")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 62)
        .background(editorStickerBacking)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    private func stickerOptionsEditor(title: String, showCorrectAnswer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(C.textMuted)

            ForEach(0..<4, id: \.self) { index in
                stickerComposerTextField(
                    placeholder: index < 2 ? "Option \(index + 1)" : "Option \(index + 1) (optional)",
                    text: Binding(
                        get: { stickerComposerOptions[index] },
                        set: { stickerComposerOptions[index] = $0 }
                    )
                )
            }

            if showCorrectAnswer {
                Picker("Correct answer", selection: $stickerComposerCorrectIndex) {
                    ForEach(Array(configuredStickerOptions.enumerated()), id: \.offset) { index, option in
                        Text(option).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .tint(C.watch)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var configuredStickerOptions: [String] {
        stickerComposerOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var stickerComposerCanSave: Bool {
        guard let kind = stickerComposerKind else { return false }
        let title = stickerComposerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .link:
            return !title.isEmpty && normalizedStoryLinkURL(from: stickerComposerSubtitle) != nil
        case .location:
            return !title.isEmpty && stickerLocationLatitude != nil && stickerLocationLongitude != nil
        case .question:
            return !title.isEmpty
        case .poll:
            return !title.isEmpty && configuredStickerOptions.count >= 2
        case .quiz:
            return !title.isEmpty && configuredStickerOptions.count >= 2 && stickerComposerCorrectIndex < configuredStickerOptions.count
        case .countdown:
            return !title.isEmpty && stickerComposerDate > Date()
        }
    }

    private var composerTextAlignment: TextAlignment {
        switch composerStyle.alignment {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    private var composerAlignmentIcon: String {
        switch composerStyle.alignment {
        case "left": return "text.alignleft"
        case "right": return "text.alignright"
        default: return "text.aligncenter"
        }
    }

    private func textComposerTool(icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .frame(width: 46, height: 44)
                .background(selected ? Color.white : Color.clear)
                .foregroundStyle(selected ? .black : .white)
                .clipShape(Capsule())
        }
    }

    private func nearestComposerColorIndex(to color: RGBAColor) -> Int {
        composerPalette.enumerated().min { lhs, rhs in
            colorDistance(lhs.element, color) < colorDistance(rhs.element, color)
        }?.offset ?? 0
    }

    private func nearestComposerFontIndex(to fontName: String?) -> Int {
        storyTextFonts.firstIndex { $0.name == fontName } ?? 0
    }

    private func composerUIFont(size: Double) -> Font {
        if let fontName = composerStyle.fontName {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .bold)
    }

    private func colorDistance(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Double {
        abs(lhs.r - rhs.r) + abs(lhs.g - rhs.g) + abs(lhs.b - rhs.b) + abs(lhs.a - rhs.a)
    }

    private func cycleComposerSize() {
        let sizes: [Double] = [44, 56, 72, 88]
        let current = sizes.firstIndex { abs($0 - composerStyle.fontSize) < 0.1 } ?? 1
        composerStyle.fontSize = sizes[(current + 1) % sizes.count]
    }

    private func cycleComposerColor() {
        composerColorIndex = (composerColorIndex + 1) % composerPalette.count
        composerStyle.color = composerPalette[composerColorIndex]
    }

    private func cycleComposerAlignment() {
        switch composerStyle.alignment {
        case "center": composerStyle.alignment = "left"
        case "left": composerStyle.alignment = "right"
        default: composerStyle.alignment = "center"
        }
    }

    private func toggleComposerBackground() {
        composerStyle.backgroundColor = composerStyle.backgroundColor == nil
            ? RGBAColor(r: 0, g: 0, b: 0, a: 0.46)
            : nil
        composerStyle.shadow = composerStyle.backgroundColor == nil
    }

    private var composerPalette: [RGBAColor] {
        [
            RGBAColor(r: 1, g: 1, b: 1, a: 1),
            RGBAColor(r: 0, g: 0, b: 0, a: 1),
            RGBAColor(r: 0, g: 0.9, b: 0.46, a: 1),
            RGBAColor(r: 1, g: 0.86, b: 0.16, a: 1),
            RGBAColor(r: 1, g: 0.2, b: 0.36, a: 1),
            RGBAColor(r: 0.25, g: 0.77, b: 1, a: 1)
        ]
    }

    private var storyTextFonts: [StoryTextFont] {
        [
            StoryTextFont(title: "Classic", name: nil),
            StoryTextFont(title: "Modern", name: "AvenirNext-Bold"),
            StoryTextFont(title: "Neon", name: "HelveticaNeue-CondensedBlack"),
            StoryTextFont(title: "Type", name: "Courier-Bold"),
            StoryTextFont(title: "Serif", name: "Georgia-Bold"),
            StoryTextFont(title: "Poster", name: "Futura-CondensedExtraBold"),
            StoryTextFont(title: "Casual", name: "MarkerFelt-Wide"),
            StoryTextFont(title: "Note", name: "Noteworthy-Bold"),
            StoryTextFont(title: "Clean", name: "Verdana-Bold")
        ]
    }

    private func keyboardOverlap(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }
        let screenHeight = UIScreen.main.bounds.height
        return max(0, screenHeight - frame.minY)
    }

    private var drawingBottomOverlay: some View {
        VStack(spacing: 14) {
            Spacer()

            HStack(spacing: 10) {
                ForEach(StoryDrawingStyle.allCases) { style in
                    Button {
                        drawingStyle = style
                    } label: {
                        Image(systemName: style.icon)
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 42, height: 38)
                            .background(drawingStyle == style ? C.watch : Color.black.opacity(0.48))
                            .foregroundStyle(drawingStyle == style ? .black : .white)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel(style.rawValue.capitalized)
                }
            }

            HStack(spacing: 10) {
                ForEach(StoryDrawingColor.allCases) { swatch in
                    Button {
                        drawingColor = swatch
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white, lineWidth: drawingColor == swatch ? 3 : 1))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                    .accessibilityLabel(swatch.rawValue.capitalized)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 12, weight: .bold))
                Slider(value: $drawingWidth, in: 3...28)
                    .tint(C.watch)
                Circle()
                    .fill(drawingColor.color)
                    .frame(width: CGFloat(drawingWidth), height: CGFloat(drawingWidth))
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.48))
            .clipShape(Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: 210)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var drawingTool: PKTool {
        PKInkingTool(drawingStyle.inkType, color: drawingColor.uiColor, width: CGFloat(drawingWidth))
    }

    private var currentFilterPreset: StoryEffectPreset {
        StoryEffectCatalog.preset(id: editor.selectedClip?.filterId)
    }

    private var activeFilterPreset: StoryEffectPreset? {
        let preset = currentFilterPreset
        return preset.id == "neutral" ? nil : preset
    }

    private var isCurrentLookEdited: Bool {
        guard let clip = editor.selectedClip else { return false }
        let preset = StoryEffectCatalog.preset(id: clip.filterId)
        return clip.adjustments != preset.adjustments || abs(clip.filterIntensity - 1) > 0.001
    }

    private func presentFilterHUD() {
        filterHUDTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            filterHUDVisible = true
        }
        filterHUDTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeIn(duration: 0.22)) {
                filterHUDVisible = false
            }
        }
    }

    private var selectedOverlayCanvasMenu: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                if editor.selectedTextOverlay != nil {
                    canvasMenuButton("Edit", systemImage: "textformat") {
                        if let overlay = editor.project.tracks.overlays.first(where: { $0.id == editor.selectedOverlayID }) {
                            selectOverlayForEditing(overlay)
                        }
                    }
                }
                canvasMenuButton("Back", systemImage: "square.2.layers.3d.bottom.filled") {
                    Task { await editor.sendSelectedOverlayBackward() }
                }
                canvasMenuButton("Forward", systemImage: "square.2.layers.3d.top.filled") {
                    Task { await editor.bringSelectedOverlayForward() }
                }
                canvasMenuButton("Timing", systemImage: "timer") {
                    beginOverlayTiming()
                }
                canvasMenuButton("Duplicate", systemImage: "plus.square.on.square") {
                    Task { await editor.duplicateSelectedOverlay() }
                }
                canvasMenuButton("Delete", systemImage: "trash", destructive: true) {
                    Task { await editor.deleteSelectedOverlay() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 92)
        }
    }

    private func canvasMenuButton(_ title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 38, height: 34)
                .foregroundStyle(destructive ? .red : .white)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
        .accessibilityLabel(title)
    }

    private func cancelLiveToolPreview() {
        if let baseline = clipBaselineClip ?? filterBaselineClip ?? audioBaselineClip {
            editor.previewSelectedClip(baseline)
        }
        if let baseline = musicBaselineClip {
            editor.previewMusicVolume(baseline.volume)
        }
        clearLiveToolBaselines()
    }

    private func clearLiveToolBaselines() {
        clipBaselineClip = nil
        filterBaselineClip = nil
        audioBaselineClip = nil
        musicBaselineClip = nil
    }

    @ViewBuilder
    private func toolSheet(_ tool: StoryEditorTool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(toolDrawerTitle(tool))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    cancelLiveToolPreview()
                    activeTool = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .foregroundStyle(.white.opacity(0.86))
                .accessibilityLabel("Close tool")

                Button {
                    applyToolSheetAndDismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(C.watch)
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Apply tool")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    toolSheetControls(for: tool)
                }
                .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func toolSheetControls(for tool: StoryEditorTool) -> some View {
        switch tool {
        case .clip:
            if let clip = editor.selectedClip {
                clipInspectorControls(for: clip)
            }
        case .look:
            if let clip = editor.selectedClip {
                lookControls(for: clip)
            }
        case .audio:
            if let clip = editor.selectedClip, clip.assetRef.kind == .video {
                audioControls(for: clip)
            } else {
                musicControls
            }
        case .stickers:
            stickerTrayControls
        case .music:
            musicControls
        case .timing:
            overlayTimingControls
        }
    }

    private func toolSheetHeight(for tool: StoryEditorTool) -> CGFloat {
        switch tool {
        case .clip:
            return 360
        case .look:
            return 420
        case .audio, .music:
            return 260
        case .stickers:
            return 320
        case .timing:
            return 300
        }
    }

    private func toolDrawerTitle(_ tool: StoryEditorTool) -> String {
        switch tool {
        case .clip: return "Clip"
        case .look: return "Look"
        case .audio: return "Audio"
        case .stickers: return "Stickers"
        case .music: return "Music"
        case .timing: return "Timing"
        }
    }

    private func applyToolSheetAndDismiss() {
        Task {
            await commitLiveToolPreview()
            toolSheetDismissShouldCancel = false
            clearLiveToolBaselines()
            activeTool = nil
        }
    }

    private func commitLiveToolPreview() async {
        if let baseline = filterBaselineClip {
            await editor.commitSelectedClipLook(baselineClip: baseline)
        }
        if let baseline = audioBaselineClip, let clip = editor.selectedClip {
            await editor.commitSelectedClipAudio(volume: clip.volume, muted: clip.muted, baselineClip: baseline)
        }
        if let baseline = clipBaselineClip {
            await editor.commitSelectedClipPreview(baselineClip: baseline)
        }
        if let baseline = musicBaselineClip, let music = editor.project.tracks.audioClips.first {
            await editor.commitMusicVolume(music.volume, baselineClip: baseline)
        }
        if activeTool == .timing {
            await editor.updateSelectedOverlayTime(start: overlayTimingStart, duration: overlayTimingDuration)
        }
    }

    private func beginLookPreview(from clip: VideoClip) {
        filterBaselineClip = filterBaselineClip ?? clip
    }

    private var overlayTimingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose when this item appears in the story.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(C.textMuted)

            GeometryReader { proxy in
                let total = max(duration, 0.2)
                let startX = proxy.size.width * overlayTimingStart / total
                let width = proxy.size.width * overlayTimingDuration / total
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(C.elevated)
                    Capsule()
                        .fill(C.watch)
                        .frame(width: max(width, 8))
                        .offset(x: startX)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Starts")
                    Spacer()
                    Text(formatTime(overlayTimingStart))
                        .fontDesign(.monospaced)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textMuted)
                Slider(
                    value: Binding(
                        get: { overlayTimingStart },
                        set: { value in
                            overlayTimingStart = value
                            overlayTimingDuration = min(
                                overlayTimingDuration,
                                max(duration - value, 0.2)
                            )
                        }
                    ),
                    in: 0...max(duration - 0.2, 0.2)
                )
                .tint(C.watch)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Duration")
                    Spacer()
                    Text(formatTime(overlayTimingDuration))
                        .fontDesign(.monospaced)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textMuted)
                Slider(
                    value: $overlayTimingDuration,
                    in: 0.2...max(duration - overlayTimingStart, 0.2)
                )
                .tint(C.watch)
            }

            Button("Show for full story") {
                overlayTimingStart = 0
                overlayTimingDuration = duration
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(C.watch)
        }
        .padding(.vertical, 4)
    }

    private func lookControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Look controls", selection: $lookSection) {
                ForEach(StoryLookSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Hold the preview to compare with the original.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(C.textTertiary)
                Spacer()
                Button(isComparingOriginal ? "Show edit" : "Compare") {
                    isComparingOriginal.toggle()
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(C.watch)
                .accessibilityLabel(isComparingOriginal ? "Show edited look" : "Show original media")
            }

            switch lookSection {
            case .filters:
                filterControls(for: clip)
            case .beauty:
                beautyControls(for: clip)
            case .effects:
                creativeEffectControls(for: clip)
            case .adjust:
                adjustmentControls(for: clip)
            }
        }
    }

    private var timelineControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            clipStrip

            HStack(spacing: 8) {
                editorButton("Split", systemImage: "scissors") {
                    await editor.split(at: currentTime)
                }
                editorButton("Duplicate", systemImage: "plus.square.on.square") {
                    await editor.duplicateSelectedClip()
                }
            }

            HStack(spacing: 8) {
                editorButton("Left", systemImage: "arrow.left") {
                    await editor.moveSelectedClip(by: -1)
                }
                editorButton("Right", systemImage: "arrow.right") {
                    await editor.moveSelectedClip(by: 1)
                }
                editorButton("Delete", systemImage: "trash", role: .destructive) {
                    await editor.deleteSelectedClip()
                }
            }

            if let message = editor.errorMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func clipInspectorControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            clipStrip

            clipTrimControls(for: clip)

            HStack(spacing: 8) {
                editorButton("Split", systemImage: "scissors") {
                    await editor.split(at: currentTime)
                }
                editorButton("Duplicate", systemImage: "plus.square.on.square") {
                    await editor.duplicateSelectedClip()
                }
                editorButton("Left", systemImage: "arrow.left") {
                    await editor.moveSelectedClip(by: -1)
                }
                editorButton("Right", systemImage: "arrow.right") {
                    await editor.moveSelectedClip(by: 1)
                }
                editorButton("Delete", systemImage: "trash", role: .destructive, disabled: editor.project.tracks.videoClips.count <= 1) {
                    await editor.deleteSelectedClip()
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Speed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                    Spacer()
                    Text("\(String(format: "%.2gx", clip.speed))")
                        .font(.system(size: 11, weight: .bold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(C.textTertiary)
                }
                Slider(
                    value: Binding(
                        get: { clip.speed },
                        set: { speed in
                            clipBaselineClip = clipBaselineClip ?? clip
                            editor.previewSelectedClipSpeed(speed)
                        }
                    ),
                    in: 0.25...2,
                    step: 0.25,
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        Task {
                            await editor.commitSelectedClipSpeed(editor.selectedClip?.speed ?? clip.speed, baselineClip: clipBaselineClip)
                            clipBaselineClip = nil
                        }
                    }
                )
                .tint(C.watch)
            }

            Toggle("Reverse", isOn: Binding(
                get: { clip.reversed },
                set: { reversed in
                    clipBaselineClip = clipBaselineClip ?? clip
                    editor.previewSelectedClipReverse(reversed)
                    Task {
                        await editor.commitSelectedClipReverse(reversed, baselineClip: clipBaselineClip)
                        clipBaselineClip = nil
                    }
                }
            ))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(C.text)
            .tint(C.watch)

            if clip.assetRef.kind == .video {
                audioControls(for: clip)
            }

            if let message = editor.errorMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func clipTrimControls(for clip: VideoClip) -> some View {
        let assetDuration = max(clip.assetRef.durationSeconds, 0.2)
        let sourceEnd = min(clip.sourceStartSeconds + clip.sourceDurationSeconds, assetDuration)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Trim", systemImage: "timeline.selection")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(formatTime(clip.sourceStartSeconds)) – \(formatTime(sourceEnd))")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(C.watch)
            }
            .foregroundStyle(C.text)

            VStack(alignment: .leading, spacing: 4) {
                Text("Start")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                Slider(
                    value: Binding(
                        get: { clip.sourceStartSeconds },
                        set: { start in
                            clipBaselineClip = clipBaselineClip ?? clip
                            editor.previewSelectedClipRange(startSeconds: start, endSeconds: sourceEnd)
                        }
                    ),
                    in: 0...max(sourceEnd - 0.2, 0.001),
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        let current = editor.selectedClip ?? clip
                        Task {
                            await editor.commitSelectedClipRange(
                                startSeconds: current.sourceStartSeconds,
                                endSeconds: current.sourceStartSeconds + current.sourceDurationSeconds,
                                baselineClip: clipBaselineClip
                            )
                            clipBaselineClip = nil
                        }
                    }
                )
                .tint(C.watch)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("End")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                Slider(
                    value: Binding(
                        get: { sourceEnd },
                        set: { end in
                            clipBaselineClip = clipBaselineClip ?? clip
                            editor.previewSelectedClipRange(startSeconds: clip.sourceStartSeconds, endSeconds: end)
                        }
                    ),
                    in: min(clip.sourceStartSeconds + 0.2, assetDuration)...assetDuration,
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        let current = editor.selectedClip ?? clip
                        Task {
                            await editor.commitSelectedClipRange(
                                startSeconds: current.sourceStartSeconds,
                                endSeconds: current.sourceStartSeconds + current.sourceDurationSeconds,
                                baselineClip: clipBaselineClip
                            )
                            clipBaselineClip = nil
                        }
                    }
                )
                .tint(C.watch)
            }
        }
        .padding(12)
        .background(C.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clip trim controls")
    }

    private func filterControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StoryFilterCategory.allCases) { category in
                        Button(category.rawValue) {
                            filterCategory = category
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(filterCategory == category ? .black : C.textMuted)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(filterCategory == category ? C.watch : C.elevated)
                        .clipShape(Capsule())
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filterCategory.presets) { preset in
                        Button {
                            stopPlayback()
                            beginLookPreview(from: clip)
                            editor.previewEffectPreset(preset)
                            presentFilterHUD()
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 7)
                                    .frame(width: 54, height: 68)
                                    .overlay {
                                        if let thumbnail = filterThumbnails[preset.id] {
                                            Image(uiImage: thumbnail)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            filterSwatchGradient(for: preset)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay {
                                        if currentFilterPreset.id == preset.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(C.watch)
                                        }
                                    }
                                Text(preset.name)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(C.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if currentFilterPreset.id != "neutral" {
                adjustmentSlider(
                    "Intensity",
                    value: clip.filterIntensity,
                    range: 0...1,
                    displayValue: Int((clip.filterIntensity * 100).rounded())
                ) { value in
                    beginLookPreview(from: clip)
                    editor.previewSelectedClipFilterIntensity(value)
                }
            }

            Button {
                let neutral = StoryEffectCatalog.preset(id: "neutral")
                beginLookPreview(from: clip)
                editor.previewEffectPreset(neutral)
                editor.previewSelectedClipFilterIntensity(1)
                presentFilterHUD()
            } label: {
                Label("Remove filter", systemImage: "circle.slash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(C.textMuted)
        }
    }

    private func adjustmentControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            adjustmentSlider("Brightness", value: clip.adjustments.brightness, range: -0.35...0.35) { value in
                previewAdjustment(clip) { $0.brightness = value }
            }
            adjustmentSlider("Contrast", value: clip.adjustments.contrast, range: 0.65...1.45) { value in
                previewAdjustment(clip) { $0.contrast = value }
            }
            adjustmentSlider("Saturation", value: clip.adjustments.saturation, range: 0...1.8) { value in
                previewAdjustment(clip) { $0.saturation = value }
            }
            adjustmentSlider("Warmth", value: clip.adjustments.warmth, range: -1...1) { value in
                previewAdjustment(clip) { $0.warmth = value }
            }
            adjustmentSlider("Vignette", value: clip.adjustments.vignette, range: 0...0.65) { value in
                previewAdjustment(clip) { $0.vignette = value }
            }

            HStack(spacing: 8) {
                editorButton("Reset to \(currentFilterPreset.name)", systemImage: "arrow.counterclockwise") {
                    beginLookPreview(from: clip)
                    editor.previewSelectedClipAdjustments(currentFilterPreset.adjustments)
                }
            }
        }
    }

    private func beautyControls(for clip: VideoClip) -> some View {
        let beauty = clip.resolvedEffectStack.beauty
        return VStack(alignment: .leading, spacing: 12) {
            Text("Face-aware controls only affect detected faces. The editor preview is the final render.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(C.textTertiary)

            HStack(spacing: 8) {
                beautyPresetButton("Off", settings: .off, current: beauty)
                beautyPresetButton("Natural", settings: .natural, current: beauty)
                beautyPresetButton(
                    "Polished",
                    settings: StoryBeautySettings(
                        intensity: 0.72,
                        skinSmoothing: 0.52,
                        skinTone: 0.14,
                        brightness: 0.12
                    ),
                    current: beauty
                )
            }

            adjustmentSlider(
                "Beauty",
                value: beauty.intensity,
                range: 0...1,
                displayValue: Int((beauty.intensity * 100).rounded())
            ) { value in
                previewBeauty(clip) { $0.intensity = value }
            }
            adjustmentSlider(
                "Smooth",
                value: beauty.skinSmoothing,
                range: 0...1,
                displayValue: Int((beauty.skinSmoothing * 100).rounded())
            ) { value in
                previewBeauty(clip) { $0.skinSmoothing = value }
            }
            adjustmentSlider(
                "Skin tone",
                value: beauty.skinTone,
                range: -1...1
            ) { value in
                previewBeauty(clip) { $0.skinTone = value }
            }
            adjustmentSlider(
                "Face light",
                value: beauty.brightness,
                range: -1...1
            ) { value in
                previewBeauty(clip) { $0.brightness = value }
            }
        }
    }

    private func creativeEffectControls(for clip: VideoClip) -> some View {
        let stack = clip.resolvedEffectStack
        let selected = stack.creativeEffects.first ?? .none
        return VStack(alignment: .leading, spacing: 12) {
            Text("Creative effects are rendered identically in this preview and the published story.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(C.textTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(StoryCreativeEffectCatalog.presets) { preset in
                        Button {
                            beginLookPreview(from: clip)
                            editor.previewSelectedClipCreativeEffect(preset.effect)
                        } label: {
                            VStack(spacing: 7) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(selected == preset.effect ? C.watch : C.elevated)
                                        .frame(width: 58, height: 58)
                                    Image(systemName: preset.systemImage)
                                        .font(.system(size: 19, weight: .bold))
                                        .foregroundStyle(selected == preset.effect ? .black : C.text)
                                }
                                Text(preset.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(C.text)
                            }
                            .frame(width: 66)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if selected != .none {
                adjustmentSlider(
                    "Effect strength",
                    value: stack.creativeEffectIntensity,
                    range: 0...1,
                    displayValue: Int((stack.creativeEffectIntensity * 100).rounded())
                ) { value in
                    beginLookPreview(from: clip)
                    editor.previewSelectedClipCreativeEffect(selected, intensity: value)
                }
            }
        }
    }

    private func beautyPresetButton(
        _ title: String,
        settings: StoryBeautySettings,
        current: StoryBeautySettings
    ) -> some View {
        Button {
            guard let clip = editor.selectedClip else { return }
            beginLookPreview(from: clip)
            editor.previewSelectedClipBeauty(settings)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(current == settings ? .black : C.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(current == settings ? C.watch : C.elevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func previewBeauty(
        _ clip: VideoClip,
        update: (inout StoryBeautySettings) -> Void
    ) {
        beginLookPreview(from: clip)
        var beauty = clip.resolvedEffectStack.beauty
        update(&beauty)
        editor.previewSelectedClipBeauty(beauty)
    }

    private func adjustmentSlider(
        _ title: String,
        value: Float,
        range: ClosedRange<Float>,
        displayValue: Int? = nil,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                Spacer()
                Text(displayValue.map(String.init) ?? normalizedAdjustmentValue(title: title, value: value))
                    .font(.system(size: 10, weight: .bold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(C.textTertiary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: onChange
                ),
                in: range
            )
            .tint(C.watch)
            .accessibilityValue(displayValue.map { "\($0) percent" } ?? normalizedAdjustmentValue(title: title, value: value))
        }
    }

    private func previewAdjustment(_ clip: VideoClip, mutate: (inout ColorAdjust) -> Void) {
        beginLookPreview(from: clip)
        var adjustments = clip.adjustments
        mutate(&adjustments)
        editor.previewSelectedClipAdjustments(adjustments)
    }

    private func normalizedAdjustmentValue(title: String, value: Float) -> String {
        let normalized: Float
        switch title {
        case "Brightness":
            normalized = value / 0.35 * 100
        case "Contrast":
            normalized = (value - 1) / (value >= 1 ? 0.45 : 0.35) * 100
        case "Saturation":
            normalized = (value - 1) / (value >= 1 ? 0.8 : 1) * 100
        case "Warmth":
            normalized = value * 100
        case "Vignette":
            normalized = value / 0.65 * 100
        default:
            normalized = value * 100
        }
        return "\(Int(min(max(normalized, -100), 100).rounded()))"
    }

    private func filterSwatchGradient(for preset: StoryEffectPreset) -> LinearGradient {
        switch preset.id {
        case "smooth":
            return LinearGradient(colors: [.white.opacity(0.88), .pink.opacity(0.45), .orange.opacity(0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "warm", "vintage", "film", "golden", "sunset":
            return LinearGradient(colors: [.orange.opacity(0.85), .pink.opacity(0.58), .black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "rose":
            return LinearGradient(colors: [.pink.opacity(0.82), .purple.opacity(0.45), .black.opacity(0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "cool", "aqua", "teal":
            return LinearGradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.72), .black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "bw", "noir":
            return LinearGradient(colors: [.white.opacity(0.85), .gray.opacity(0.7), .black.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "vivid", "bright", "pop", "crisp":
            return LinearGradient(colors: [C.watch.opacity(0.85), .yellow.opacity(0.7), .blue.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "fade", "matte", "dream":
            return LinearGradient(colors: [.white.opacity(0.72), .mint.opacity(0.38), .gray.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "moody", "cinema":
            return LinearGradient(colors: [.purple.opacity(0.72), .black.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [.white.opacity(0.68), .gray.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func scheduleFilterThumbnails() {
        filterThumbnailTask?.cancel()
        guard let clip = editor.selectedClip, let assetStore else { return }
        filterThumbnailTask = Task { @MainActor in
            guard let source = await filterThumbnailSource(for: clip, assetStore: assetStore) else { return }
            var generated: [String: UIImage] = [:]
            for preset in StoryEffectCatalog.presets {
                guard !Task.isCancelled else { return }
                generated[preset.id] = StoryFrameFilterRenderer.renderImage(
                    source,
                    filterId: preset.id,
                    adjustments: preset.adjustments
                ).storyFilterThumbnail
                if generated.count.isMultiple(of: 4) {
                    filterThumbnails.merge(generated) { _, new in new }
                    generated.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }
            filterThumbnails.merge(generated) { _, new in new }
        }
    }

    private func scheduleClipThumbnails() {
        clipThumbnailTask?.cancel()
        guard let assetStore else { return }
        let clips = editor.project.tracks.videoClips.filter { clipThumbnails[$0.id] == nil }
        guard !clips.isEmpty else { return }
        clipThumbnailTask = Task { @MainActor in
            for clip in clips {
                guard !Task.isCancelled else { return }
                if let source = await filterThumbnailSource(for: clip, assetStore: assetStore) {
                    clipThumbnails[clip.id] = source.storyClipThumbnail
                }
                await Task.yield()
            }
            let validIDs = Set(editor.project.tracks.videoClips.map(\.id))
            clipThumbnails = clipThumbnails.filter { validIDs.contains($0.key) }
        }
    }

    private func filterThumbnailSource(for clip: VideoClip, assetStore: AssetStore) async -> UIImage? {
        let url = assetStore.absoluteURL(for: clip.assetRef.relativePath)
        if clip.assetRef.kind == .image {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 240)
        let sampleSeconds = clip.sourceStartSeconds + min(clip.sourceDurationSeconds * 0.35, 1)
        guard let result = try? await generator.image(at: CMTime(seconds: sampleSeconds, preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: result.image)
    }

    private func audioControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clip Audio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Toggle("Mute", isOn: Binding(
                get: { clip.muted },
                set: { muted in
                    audioBaselineClip = audioBaselineClip ?? clip
                    editor.previewSelectedClipAudio(volume: clip.volume, muted: muted)
                    Task {
                        await editor.commitSelectedClipAudio(volume: clip.volume, muted: muted, baselineClip: audioBaselineClip)
                        audioBaselineClip = nil
                    }
                }
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(C.text)
            .tint(C.watch)
            Slider(
                value: Binding(
                    get: { clip.volume },
                    set: { volume in
                        audioBaselineClip = audioBaselineClip ?? clip
                        editor.previewSelectedClipAudio(volume: volume, muted: clip.muted)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    Task {
                        let currentClip = editor.selectedClip ?? clip
                        await editor.commitSelectedClipAudio(volume: currentClip.volume, muted: currentClip.muted, baselineClip: audioBaselineClip)
                        audioBaselineClip = nil
                    }
                }
            )
            .disabled(clip.muted)
            .opacity(clip.muted ? 0.45 : 1)
            .tint(C.watch)
        }
    }

    private var clipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(editor.project.tracks.videoClips.enumerated()), id: \.element.id) { index, clip in
                    Button {
                        cancelLiveToolPreview()
                        editor.selectClip(clip.id)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            if let thumbnail = clipThumbnails[clip.id] {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(C.elevated)
                                    .overlay {
                                        Image(systemName: clip.assetRef.kind == .video ? "video.fill" : "photo.fill")
                                            .foregroundStyle(C.textTertiary)
                                    }
                            }

                            LinearGradient(
                                colors: [.clear, .black.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )

                            HStack {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold))
                                Spacer()
                                Text(formatTime(clip.timelineDuration.seconds))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(6)
                        }
                        .frame(width: 82, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(editor.selectedClipID == clip.id ? C.watch : Color.white.opacity(0.12), lineWidth: editor.selectedClipID == clip.id ? 3 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clip \(index + 1), \(formatTime(clip.timelineDuration.seconds))")
                    .draggable(clip.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let rawID = items.first,
                              let sourceID = UUID(uuidString: rawID),
                              let sourceIndex = editor.project.tracks.videoClips.firstIndex(where: { $0.id == sourceID }),
                              sourceIndex != index else {
                            return false
                        }
                        editor.selectClip(sourceID)
                        Task { await editor.moveSelectedClip(by: index - sourceIndex) }
                        return true
                    }
                }
            }
        }
    }

    private var musicControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(C.watch)
                    .frame(width: 30, height: 30)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(editor.project.tracks.audioClips.first?.assetRef.relativePath.split(separator: "/").last.map(String.init) ?? "No music selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    isImportingMusic = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .accessibilityLabel("Import music")
            }

            if let music = editor.project.tracks.audioClips.first {
                HStack(spacing: 8) {
                    Text("Volume")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(C.textTertiary)
                        .frame(width: 62, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { music.volume },
                            set: { value in
                                musicBaselineClip = musicBaselineClip ?? music
                                editor.previewMusicVolume(value)
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing else { return }
                            let baseline = musicBaselineClip
                            musicBaselineClip = nil
                            Task {
                                await editor.commitMusicVolume(
                                    editor.project.tracks.audioClips.first?.volume ?? music.volume,
                                    baselineClip: baseline
                                )
                            }
                        }
                    )
                    .tint(C.watch)
                    editorButton("Remove Music", systemImage: "trash", role: .destructive) {
                        await editor.removeMusic()
                    }
                }
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private var stickerTrayControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick stickers")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.textMuted)
            stickerPicker

            Text("Interactive")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.textMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(StoryStickerTool.allCases) { tool in
                    Button {
                        handleStickerTool(tool)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 15, weight: .bold))
                            Text(tool.title)
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                }
            }

            if !editor.project.tracks.overlays.isEmpty {
                Text("On this story")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.textMuted)
                overlayStrip
            }
        }
    }

    private func handleStickerTool(_ tool: StoryStickerTool) {
        stopPlayback()
        switch tool {
        case .link:
            beginStickerComposer(.link)
        case .gif:
            activeTool = nil
            isShowingGiphyPicker = true
        case .mention:
            activeTool = nil
            beginMentionComposer()
        case .location:
            beginStickerComposer(.location)
        case .poll:
            beginStickerComposer(.poll)
        case .quiz:
            beginStickerComposer(.quiz)
        case .questions:
            beginStickerComposer(.question)
        case .countdown:
            beginStickerComposer(.countdown)
        }
    }

    private func addInteractiveStorySticker(_ tool: StoryStickerTool) async {
        guard let kind = tool.interactiveKind else { return }
        await editor.addInteractiveOverlay(
            kind: kind,
            title: tool.defaultText,
            subtitle: tool.defaultSubtitle,
            options: tool.defaultOptions,
            targetDate: tool == .countdown ? Date().addingTimeInterval(24 * 60 * 60) : nil,
            at: currentTime
        )
        activeTool = nil
        resumeVideoPreviewPlaybackIfNeeded()
    }

    private func beginStickerComposer(_ kind: StoryStickerComposerKind) {
        stopPlayback()
        activeTool = nil
        stickerComposerKind = kind
        stickerComposerTitle = defaultStickerComposerTitle(for: kind)
        stickerComposerSubtitle = ""
        stickerComposerOptions = defaultStickerComposerOptions(for: kind)
        stickerComposerCorrectIndex = 0
        stickerComposerDate = Date().addingTimeInterval(24 * 60 * 60)
        stickerLocationLatitude = nil
        stickerLocationLongitude = nil
        locationSearch.clear()
        isStickerComposerFocused = true
    }

    private func cancelStickerComposer() {
        stickerComposerKind = nil
        stickerComposerTitle = ""
        stickerComposerSubtitle = ""
        stickerComposerOptions = ["", "", "", ""]
        stickerComposerCorrectIndex = 0
        stickerComposerDate = Date().addingTimeInterval(24 * 60 * 60)
        stickerLocationLatitude = nil
        stickerLocationLongitude = nil
        locationSearch.clear()
        isStickerComposerFocused = false
        resumeVideoPreviewPlaybackIfNeeded()
    }

    private func addConfiguredSticker() async {
        guard let kind = stickerComposerKind, stickerComposerCanSave else { return }
        let title = stickerComposerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = configuredStickerOptions

        switch kind {
        case .link:
            guard let url = normalizedStoryLinkURL(from: stickerComposerSubtitle) else { return }
            await editor.addInteractiveOverlay(kind: .link, title: title, subtitle: nil, options: ["url=\(url)"], targetDate: nil, at: currentTime)
        case .location:
            var metadata: [String] = []
            if let stickerLocationLatitude, let stickerLocationLongitude {
                metadata.append("lat=\(stickerLocationLatitude)")
                metadata.append("lng=\(stickerLocationLongitude)")
            }
            let subtitle = stickerComposerSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            await editor.addInteractiveOverlay(
                kind: .location,
                title: title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                options: metadata,
                targetDate: nil,
                at: currentTime
            )
        case .poll:
            await editor.addInteractiveOverlay(kind: .poll, title: title, subtitle: nil, options: options, targetDate: nil, at: currentTime)
        case .quiz:
            let correctIndex = min(stickerComposerCorrectIndex, max(options.count - 1, 0))
            await editor.addInteractiveOverlay(
                kind: .quiz,
                title: title,
                subtitle: nil,
                options: options + ["correctIndex=\(correctIndex)"],
                targetDate: nil,
                at: currentTime
            )
        case .question:
            await editor.addInteractiveOverlay(kind: .question, title: title, subtitle: "Viewer replies", options: [], targetDate: nil, at: currentTime)
        case .countdown:
            await editor.addInteractiveOverlay(
                kind: .countdown,
                title: title,
                subtitle: countdownSubtitle(for: stickerComposerDate),
                options: [],
                targetDate: stickerComposerDate,
                at: currentTime
            )
        }

        await MainActor.run {
            cancelStickerComposer()
            activeTool = nil
            resumeVideoPreviewPlaybackIfNeeded()
        }
    }

    private func selectLocationCompletion(_ completion: MKLocalSearchCompletion) async {
        guard let location = await locationSearch.resolve(completion) else { return }
        stickerComposerTitle = location.name
        stickerComposerSubtitle = location.subtitle ?? ""
        stickerLocationLatitude = location.latitude
        stickerLocationLongitude = location.longitude
        locationSearch.clear()
    }

    private func defaultStickerComposerTitle(for kind: StoryStickerComposerKind) -> String {
        switch kind {
        case .link: return ""
        case .location: return ""
        case .poll: return ""
        case .quiz: return ""
        case .question: return "Ask me a question"
        case .countdown: return "Countdown"
        }
    }

    private func defaultStickerComposerOptions(for kind: StoryStickerComposerKind) -> [String] {
        switch kind {
        case .poll:
            return ["Yes", "No", "", ""]
        case .quiz:
            return ["A", "B", "C", ""]
        case .link, .location, .question, .countdown:
            return ["", "", "", ""]
        }
    }

    private func normalizedStoryLinkURL(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "westreem"),
              url.host?.isEmpty == false || scheme == "westreem" else {
            return nil
        }
        return candidate
    }

    private func countdownSubtitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func beginMentionComposer() {
        stopPlayback()
        mentionSearchText = "@"
        isMentionComposerPresented = true
        isMentionComposerFocused = true
    }

    private func cancelMentionComposer() {
        isMentionComposerPresented = false
        isMentionComposerFocused = false
        mentionSearchText = "@"
        resumeVideoPreviewPlaybackIfNeeded()
    }

    private func addMentionSticker(_ result: MentionSearchResult) async {
        await editor.addInteractiveOverlay(
            kind: .mention,
            title: result.displayName,
            subtitle: "@\(result.handle)",
            options: ["type=\(result.type)", "entityId=\(result.id)", "handle=\(result.handle)"],
            targetDate: nil,
            at: currentTime
        )
        await MainActor.run {
            cancelMentionComposer()
            activeTool = nil
            resumeVideoPreviewPlaybackIfNeeded()
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkCreatorControls
            stickerPicker

            Button {
                stopPlayback()
                isDrawingPresented = true
            } label: {
                Label("Draw", systemImage: "pencil.tip")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(C.watch)
            .accessibilityLabel("Add drawing overlay")

            if !editor.project.tracks.overlays.isEmpty {
                overlayStrip
            }

            if let overlay = editor.selectedTextOverlay {
                selectedTextControls(overlay)
            } else if let sticker = editor.selectedStickerOverlay {
                selectedStickerControls(sticker)
            } else if let drawing = editor.selectedDrawingOverlay {
                selectedDrawingControls(drawing)
            } else if let link = editor.selectedLinkOverlay {
                selectedLinkControls(link)
            } else if let interactive = editor.selectedInteractiveOverlay {
                selectedInteractiveControls(interactive)
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private var linkCreatorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Link label", text: $newLinkLabel)
                .textInputAutocapitalization(.words)
                .storyEditorFieldStyle()
            HStack(spacing: 8) {
                TextField("https://", text: $newLinkURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .storyEditorFieldStyle()
                Button {
                    stopPlayback()
                    let label = newLinkLabel
                    let url = newLinkURL
                    newLinkLabel = ""
                    newLinkURL = ""
                    Task { await editor.addLinkOverlay(label: label, url: url, at: currentTime) }
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(newLinkLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add link")
            }
        }
    }

    private var stickerPicker: some View {
        HStack(spacing: 8) {
            ForEach(["🔥", "😂", "❤️", "⭐", "👏", "👀"], id: \.self) { emoji in
                Button {
                    selectedEmoji = emoji
                } label: {
                    Text(emoji)
                        .font(.system(size: 18))
                        .frame(width: 34, height: 32)
                        .background(selectedEmoji == emoji ? C.watch.opacity(0.85) : C.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(emoji) sticker")
            }
            Button {
                stopPlayback()
                Task { await editor.addStickerOverlay(emoji: selectedEmoji, at: currentTime) }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
            .accessibilityLabel("Add sticker")
        }
    }

    private var overlayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(editor.project.tracks.overlays, id: \.id) { overlay in
                    overlayChip(overlay)
                }
            }
        }
    }

    private func overlayChip(_ overlay: Overlay) -> some View {
        let title: String = {
            switch overlay {
            case .text(let text): return text.text
            case .sticker(let sticker): return sticker.emoji ?? (sticker.assetRef?.kind == .video ? "Video" : "Image")
            case .drawing: return "Drawing"
            case .link(let link): return link.label
            case .interactive(let interactive): return interactive.title
            }
        }()
        return Button {
            selectOverlayForEditing(overlay)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(editor.selectedOverlayID == overlay.id ? .black : C.text)
                .frame(width: 108, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(editor.selectedOverlayID == overlay.id ? C.watch : C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func selectedTextControls(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Edit text", text: Binding(
                get: { editingOverlayText.isEmpty ? overlay.text : editingOverlayText },
                set: { editingOverlayText = String($0.prefix(80)) }
            ))
            .storyEditorFieldStyle()
            .onSubmit {
                let text = editingOverlayText.isEmpty ? overlay.text : editingOverlayText
                Task { await editor.updateSelectedText(text) }
            }

            HStack(spacing: 8) {
                editorButton("Apply", systemImage: "checkmark") {
                    await editor.updateSelectedText(editingOverlayText.isEmpty ? overlay.text : editingOverlayText)
                }
                editorButton("Delete Text", systemImage: "trash", role: .destructive) {
                    await editor.deleteSelectedOverlay()
                }
            }
        }
    }

    private func selectedStickerControls(_ overlay: StickerOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overlay.emoji != nil ? "Sticker \(overlay.emoji ?? "")" : (overlay.assetRef?.kind == .video ? "Video Overlay" : "Image Overlay"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            editorButton("Delete Sticker", systemImage: "trash", role: .destructive) {
                await editor.deleteSelectedOverlay()
            }
        }
    }

    private func selectedDrawingControls(_ overlay: DrawingOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drawing")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            editorButton("Delete Drawing", systemImage: "trash", role: .destructive) {
                await editor.deleteSelectedOverlay()
            }
        }
    }

    private func selectedLinkControls(_ overlay: LinkOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Link label", text: Binding(
                get: { editingLinkLabel.isEmpty ? overlay.label : editingLinkLabel },
                set: { editingLinkLabel = $0 }
            ))
            .textInputAutocapitalization(.words)
            .storyEditorFieldStyle()

            TextField("https://", text: Binding(
                get: { editingLinkURL.isEmpty ? overlay.url : editingLinkURL },
                set: { editingLinkURL = $0 }
            ))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .storyEditorFieldStyle()

            HStack(spacing: 8) {
                editorButton("Apply Link", systemImage: "checkmark") {
                    await editor.updateSelectedLink(
                        label: editingLinkLabel.isEmpty ? overlay.label : editingLinkLabel,
                        url: editingLinkURL.isEmpty ? overlay.url : editingLinkURL
                    )
                }
                editorButton("Delete Link", systemImage: "trash", role: .destructive) {
                    await editor.deleteSelectedOverlay()
                }
            }
        }
    }

    private func selectedInteractiveControls(_ overlay: StoryInteractiveOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overlay.kind.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text(overlay.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(C.text)
                .lineLimit(2)

            Text("Keep the complete sticker inside the dashed safe area so viewer controls never cover it.")
                .font(.system(size: 10))
                .foregroundStyle(C.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                editorButton("Center Sticker", systemImage: "scope") {
                    await applyInteractiveTransform(
                        overlay,
                        Transform2D(
                            scale: overlay.transform.scale,
                            rotation: overlay.transform.rotation,
                            tx: 0,
                            ty: 0
                        )
                    )
                }
                editorButton("Reset Sticker Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                    await applyInteractiveTransform(
                        overlay,
                        Transform2D(
                            scale: 1,
                            rotation: overlay.transform.rotation,
                            tx: overlay.transform.tx,
                            ty: overlay.transform.ty
                        )
                    )
                }
                editorButton("Reset Sticker Rotation", systemImage: "rotate.left") {
                    await applyInteractiveTransform(
                        overlay,
                        Transform2D(
                            scale: overlay.transform.scale,
                            rotation: 0,
                            tx: overlay.transform.tx,
                            ty: overlay.transform.ty
                        )
                    )
                }
                editorButton("Delete Sticker", systemImage: "trash", role: .destructive) {
                    await editor.deleteSelectedOverlay()
                }
            }
        }
    }

    private func applyInteractiveTransform(_ overlay: StoryInteractiveOverlay, _ transform: Transform2D) async {
        let viewport = CGSize(width: 390, height: 844)
        let constrained = StoryOverlayLayout.clampedInteractiveTransform(
            transform,
            stickerSize: StoryOverlayLayout.estimatedStickerSize(for: overlay),
            canvas: project.canvas,
            viewportSize: viewport
        )
        editor.setOverlayTransformLive(id: overlay.id, transform: constrained)
        await editor.persistInteractiveOverlayEdits()
    }

    private var interactiveOverlayLayer: some View {
        GeometryReader { proxy in
            let canvasSize = CGSize(
                width: max(1, CGFloat(project.canvas.width)),
                height: max(1, CGFloat(project.canvas.height))
            )
            let previewScale = min(
                proxy.size.width / canvasSize.width,
                proxy.size.height / canvasSize.height
            )
            let fittedSize = CGSize(
                width: canvasSize.width * previewScale,
                height: canvasSize.height * previewScale
            )
            let previewFrame = CGRect(
                x: (proxy.size.width - fittedSize.width) / 2,
                y: (proxy.size.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            let interactiveScale = StoryOverlayLayout.viewportScale(for: project.canvas, in: proxy.size)
            let interactiveStickerScale = StoryOverlayLayout.stickerPresentationScale(for: project.canvas, in: proxy.size)
            let visibleOverlays = Array(editor.project.tracks.overlays.enumerated())
            let targets = overlayGestureTargets(
                from: visibleOverlays,
                previewScale: previewScale,
                interactiveScale: interactiveScale,
                interactiveStickerScale: interactiveStickerScale,
                measuredInteractiveStickerSizes: measuredInteractiveStickerSizes,
                viewportSize: proxy.size,
                in: previewFrame
            )

            ZStack {
                ForEach(visibleOverlays, id: \.element.id) { index, overlay in
                    let isInteractive = {
                        if case .interactive = overlay { return true }
                        return false
                    }()
                    liveOverlayView(overlay, previewScale: previewScale, interactiveScale: interactiveScale, interactiveStickerScale: interactiveStickerScale)
                        .position(
                            x: isInteractive ? StoryOverlayLayout.position(for: interactionState(for: overlay).transform, canvas: project.canvas, in: proxy.size).x : previewFrame.midX,
                            y: isInteractive ? StoryOverlayLayout.position(for: interactionState(for: overlay).transform, canvas: project.canvas, in: proxy.size).y : previewFrame.midY
                        )
                        .zIndex(editor.selectedOverlayID == overlay.id ? 10_000 : Double(index))
                }

                if isOverlayInteracting, overlayAlignmentGuide.hasVisibleGuide {
                    overlayAlignmentGuideView(overlayAlignmentGuide, in: previewFrame)
                        .allowsHitTesting(false)
                        .zIndex(19_000)
                }

                if isOverlayInteracting {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(C.watch.opacity(0.72), style: StrokeStyle(lineWidth: 1.25, dash: [7, 5]))
                        .frame(
                            width: StoryOverlayLayout.safeFrame(for: project.canvas, in: proxy.size).width,
                            height: StoryOverlayLayout.safeFrame(for: project.canvas, in: proxy.size).height
                        )
                        .position(
                            x: StoryOverlayLayout.safeFrame(for: project.canvas, in: proxy.size).midX,
                            y: StoryOverlayLayout.safeFrame(for: project.canvas, in: proxy.size).midY
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(18_000)
                }

                OverlayCanvasGestureLayer(
                    targets: targets,
                    selectedOverlayID: editor.selectedOverlayID,
                    previewScale: previewScale,
                    onTap: { overlay in
                        if let overlay {
                            handleOverlayTap(overlay)
                        } else {
                            editor.selectOverlay(nil)
                        }
                    },
                    onBegin: { overlay in
                        isOverlayInteracting = true
                        selectOverlayForGesture(overlay)
                    },
                    onChange: { id, transform in
                        let overlay = visibleOverlays.first(where: { $0.element.id == id })?.element
                        let constrainedTransform: Transform2D
                        if let overlay, case .interactive = overlay {
                            let stickerSize = measuredInteractiveStickerSizes[id] ?? interactiveViewerStickerHitSize(for: overlay)
                            constrainedTransform = StoryOverlayLayout.clampedInteractiveTransform(
                                transform,
                                stickerSize: stickerSize,
                                canvas: project.canvas,
                                viewportSize: proxy.size
                            )
                        } else {
                            constrainedTransform = transform
                        }
                        let snapped = snappedOverlayTransform(constrainedTransform, previewScale: previewScale)
                        if snapped.guide.hasVisibleGuide, !overlayAlignmentGuide.hasVisibleGuide {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        editor.setOverlayTransformLive(id: id, transform: snapped.transform)
                        overlayAlignmentGuide = snapped.guide
                    },
                    onEnd: {
                        isOverlayInteracting = false
                        overlayAlignmentGuide = OverlayAlignmentGuide()
                        Task { await editor.persistInteractiveOverlayEdits() }
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .zIndex(20_000)
            }
            .onPreferenceChange(InteractiveStickerSizePreferenceKey.self) { sizes in
                measuredInteractiveStickerSizes.merge(sizes) { _, new in new }
            }
        }
    }

    private func snappedOverlayTransform(
        _ transform: Transform2D,
        previewScale: CGFloat
    ) -> (transform: Transform2D, guide: OverlayAlignmentGuide) {
        let threshold: CGFloat = 8
        var updated = transform
        let snapX = abs(CGFloat(transform.tx) * previewScale) <= threshold
        let snapY = abs(CGFloat(transform.ty) * previewScale) <= threshold

        if snapX {
            updated = Transform2D(scale: updated.scale, rotation: updated.rotation, tx: 0, ty: updated.ty)
        }
        if snapY {
            updated = Transform2D(scale: updated.scale, rotation: updated.rotation, tx: updated.tx, ty: 0)
        }

        return (updated, OverlayAlignmentGuide(showVerticalCenter: snapX, showHorizontalCenter: snapY))
    }

    private func overlayAlignmentGuideView(_ guide: OverlayAlignmentGuide, in previewFrame: CGRect) -> some View {
        ZStack {
            if guide.showVerticalCenter {
                Rectangle()
                    .fill(C.watch.opacity(0.9))
                    .frame(width: 1.5, height: previewFrame.height)
                    .position(x: previewFrame.midX, y: previewFrame.midY)
            }

            if guide.showHorizontalCenter {
                Rectangle()
                    .fill(C.watch.opacity(0.9))
                    .frame(width: previewFrame.width, height: 1.5)
                    .position(x: previewFrame.midX, y: previewFrame.midY)
            }
        }
    }

    private func liveOverlayView(_ overlay: Overlay, previewScale: CGFloat, interactiveScale: CGSize, interactiveStickerScale: CGFloat) -> AnyView {
        let state = interactionState(for: overlay)
        let selected = editor.selectedOverlayID == overlay.id

        if case .interactive(let interactive) = overlay {
            let previewOverlay = StoryOverlay.editorPreview(from: interactive, canvas: project.canvas)
            return AnyView(
                StoryOverlayStickerView(overlay: previewOverlay, isInteractive: false)
                    .fixedSize(horizontal: true, vertical: true)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selected ? C.watch : Color.clear, lineWidth: 1.5)
                    )
                    .padding(16)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: InteractiveStickerSizePreferenceKey.self,
                                value: [overlay.id: geometry.size]
                            )
                        }
                    )
                    .scaleEffect(state.transform.scale * interactiveStickerScale)
                    .rotationEffect(.radians(state.transform.rotation))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Story overlay")
            )
        }

        return AnyView(
            overlayVisual(for: overlay, state: state, previewScale: previewScale)
                .overlay(
                    RoundedRectangle(cornerRadius: state.cornerRadius)
                        .stroke(selected ? C.watch : Color.clear, lineWidth: 1.5)
                )
                .padding(16)
                .rotationEffect(.radians(state.transform.rotation))
                .offset(x: CGFloat(state.transform.tx) * previewScale, y: -CGFloat(state.transform.ty) * previewScale)
                .allowsHitTesting(false)
                .accessibilityLabel("Story overlay")
        )
    }

    private func overlayGestureTargets(
        from overlays: [(offset: Int, element: Overlay)],
        previewScale: CGFloat,
        interactiveScale: CGSize,
        interactiveStickerScale: CGFloat,
        measuredInteractiveStickerSizes: [UUID: CGSize],
        viewportSize: CGSize,
        in previewFrame: CGRect
    ) -> [OverlayGestureTarget] {
        overlays.map { index, overlay in
            let state = interactionState(for: overlay)
            let scaledWidth: CGFloat
            let scaledHeight: CGFloat
            let center: CGPoint
            let translationScale: CGSize
            if case .interactive = overlay {
                let hitSize = measuredInteractiveStickerSizes[overlay.id] ?? interactiveViewerStickerHitSize(for: overlay)
                scaledWidth = max(44, hitSize.width * state.transform.scale * interactiveStickerScale)
                scaledHeight = max(44, hitSize.height * state.transform.scale * interactiveStickerScale)
                center = StoryOverlayLayout.position(for: state.transform, canvas: project.canvas, in: viewportSize)
                translationScale = interactiveScale
            } else {
                scaledWidth = max(44, state.canvasSize.width * previewScale * state.transform.scale)
                scaledHeight = max(44, state.canvasSize.height * previewScale * state.transform.scale)
                center = CGPoint(
                    x: previewFrame.midX + CGFloat(state.transform.tx) * previewScale,
                    y: previewFrame.midY - CGFloat(state.transform.ty) * previewScale
                )
                translationScale = CGSize(width: previewScale, height: previewScale)
            }
            return OverlayGestureTarget(
                id: overlay.id,
                overlay: overlay,
                center: center,
                size: CGSize(width: scaledWidth + 44, height: scaledHeight + 44),
                transform: state.transform,
                translationScale: translationScale,
                zIndex: editor.selectedOverlayID == overlay.id ? 10_000 + index : index
            )
        }
    }

    private func interactiveViewerStickerHitSize(for overlay: Overlay) -> CGSize {
        guard case .interactive(let interactive) = overlay else { return .zero }
        return StoryOverlayLayout.estimatedStickerSize(for: interactive)
    }

    private func overlayVisual(for overlay: Overlay, state: OverlayInteractionState, previewScale: CGFloat) -> AnyView {
        let width = max(44, state.canvasSize.width * previewScale * state.transform.scale)
        let height = max(44, state.canvasSize.height * previewScale * state.transform.scale)
        switch overlay {
        case .text(let text):
            let background = text.style.backgroundColor.map(swiftUIColor) ?? Color.clear
            return AnyView(
                Text(text.text)
                    .font(storyFont(for: text.style, size: max(10, text.style.fontSize * previewScale * state.transform.scale)))
                    .foregroundStyle(swiftUIColor(text.style.color))
                    .multilineTextAlignment(text.style.alignment == "left" ? .leading : (text.style.alignment == "right" ? .trailing : .center))
                    .lineLimit(5)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(width: width, height: height)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius))
                    .shadow(color: text.style.shadow ? .black.opacity(0.45) : .clear, radius: 8, y: 3)
            )
        case .sticker(let sticker):
            if let assetRef = sticker.assetRef, let assetStore {
                return AnyView(
                    StoryAssetOverlayImageView(
                        url: assetStore.absoluteURL(for: assetRef.relativePath),
                        kind: assetRef.kind,
                        time: overlayPlaybackTime(for: sticker)
                    )
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius))
                )
            }
            return AnyView(
                Text(sticker.emoji ?? "")
                    .font(.system(size: min(width, height) * 0.82))
                    .frame(width: width, height: height)
                    .shadow(color: .black.opacity(0.38), radius: 8, y: 4)
            )
        case .drawing(let drawing):
            if let assetStore {
                return AnyView(
                    StoryAssetOverlayImageView(
                        url: assetStore.absoluteURL(for: drawing.assetRef.relativePath),
                        kind: drawing.assetRef.kind,
                        time: 0
                    )
                    .frame(width: width, height: height)
                )
            }
            return AnyView(Color.clear.frame(width: width, height: height))
        case .link(let link):
            return AnyView(
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: max(12, 18 * previewScale * state.transform.scale), weight: .bold))
                    Text(link.label)
                        .font(.system(size: max(12, 20 * previewScale * state.transform.scale), weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(width: width, height: height)
                .background(Color.white)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            )
        case .interactive(let interactive):
            return AnyView(
                interactiveStickerVisual(interactive, width: width, height: height)
            )
        }
    }

    private func interactionState(for overlay: Overlay) -> OverlayInteractionState {
        switch overlay {
        case .text(let text):
            return OverlayInteractionState(transform: text.transform, canvasSize: textOverlayCanvasSize(text), cornerRadius: 18)
        case .sticker(let sticker):
            if let assetRef = sticker.assetRef {
                return OverlayInteractionState(
                    transform: sticker.transform,
                    canvasSize: CGSize(width: max(assetRef.naturalWidth, 96), height: max(assetRef.naturalHeight, 96)),
                    cornerRadius: 8
                )
            }
            return OverlayInteractionState(transform: sticker.transform, canvasSize: CGSize(width: 180, height: 180), cornerRadius: 8)
        case .drawing(let drawing):
            return OverlayInteractionState(
                transform: drawing.transform,
                canvasSize: CGSize(width: max(drawing.assetRef.naturalWidth, 96), height: max(drawing.assetRef.naturalHeight, 96)),
                cornerRadius: 8
            )
        case .link(let link):
            let width = max(280, min(760, Double(link.label.count) * 34 + 180))
            return OverlayInteractionState(transform: link.transform, canvasSize: CGSize(width: width, height: 104), cornerRadius: 52)
        case .interactive(let interactive):
            if interactive.kind == .link {
                let metadata = editorInteractiveMetadata(interactive.options)
                let labelWidth = Double(interactive.title.count) * 26
                let urlWidth = Double((metadata["url"] ?? interactive.subtitle ?? "").count) * 10
                let width = max(240, min(620, max(labelWidth, urlWidth) + 120))
                return OverlayInteractionState(
                    transform: interactive.transform,
                    canvasSize: CGSize(width: width, height: 72),
                    cornerRadius: 36
                )
            }
            if interactive.kind == .mention {
                let titleWidth = Double(interactive.title.count) * 26
                let handleWidth = Double((interactive.subtitle ?? "").count) * 18
                let width = max(320, min(680, max(titleWidth, handleWidth) + 150))
                return OverlayInteractionState(
                    transform: interactive.transform,
                    canvasSize: CGSize(width: width, height: 124),
                    cornerRadius: 62
                )
            }
            if interactive.kind == .location {
                let width = max(220, min(520, Double(interactive.title.count) * 22 + 120))
                let height = 72.0
                return OverlayInteractionState(
                    transform: interactive.transform,
                    canvasSize: CGSize(width: width, height: height),
                    cornerRadius: height / 2
                )
            }
            if interactive.kind == .countdown {
                return OverlayInteractionState(
                    transform: interactive.transform,
                    canvasSize: CGSize(width: 260, height: 130),
                    cornerRadius: 22
                )
            }
            let width: Double = 560
            let visibleOptions = visibleInteractiveOptions(interactive.options)
            let optionHeight = visibleOptions.isEmpty ? 0.0 : Double(visibleOptions.count) * 52.0 + 12.0
            let subtitleHeight = interactive.subtitle == nil ? 0.0 : 28.0
            return OverlayInteractionState(
                transform: interactive.transform,
                canvasSize: CGSize(width: width, height: max(116.0, 92.0 + subtitleHeight + optionHeight)),
                cornerRadius: 24
            )
        }
    }

    private func overlayPlaybackTime(for overlay: StickerOverlay) -> Double {
        let elapsed = max(currentTime - overlay.timeRange.start.time.seconds, 0)
        guard let duration = overlay.assetRef?.durationSeconds, duration > 0 else { return elapsed }
        return storyLoopedMediaTime(elapsed: elapsed, duration: duration)
    }

    private func textOverlayCanvasSize(_ overlay: TextOverlay) -> CGSize {
        let maxWidth: CGFloat = 760
        let minWidth: CGFloat = 180
        let padding = CGSize(width: 68, height: 44)
        let font = overlay.style.fontName.flatMap { UIFont(name: $0, size: overlay.style.fontSize) }
            ?? UIFont.systemFont(ofSize: overlay.style.fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        switch overlay.style.alignment.lowercased() {
        case "left":
            paragraph.alignment = .left
        case "right":
            paragraph.alignment = .right
        default:
            paragraph.alignment = .center
        }
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: overlay.text,
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        let rect = attributed.boundingRect(
            with: CGSize(width: maxWidth - padding.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        return CGSize(
            width: max(minWidth, min(maxWidth, rect.width + padding.width)),
            height: max(92, min(360, rect.height + padding.height))
        )
    }

    @ViewBuilder
    private func editorViewerStyleInteractiveSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        switch overlay.kind {
        case .link:
            editorViewerLinkSticker(overlay)
        case .mention:
            editorViewerMentionSticker(overlay)
        case .location:
            editorViewerLocationSticker(overlay)
        case .poll:
            editorViewerPollSticker(overlay)
        case .quiz:
            editorViewerQuizSticker(overlay)
        case .question:
            editorViewerQuestionSticker(overlay)
        case .countdown:
            editorViewerCountdownSticker(overlay)
        case .addYours, .avatar:
            editorViewerGenericSticker(overlay)
        }
    }

    private func editorViewerLinkSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        let metadata = editorInteractiveMetadata(overlay.options)
        let urlText = shortenedHost(from: metadata["url"] ?? overlay.subtitle)
        return HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.watch)
            VStack(alignment: .leading, spacing: 1) {
                Text(overlay.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let urlText {
                    Text(urlText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerMentionSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        let metadata = editorInteractiveMetadata(overlay.options)
        let handle = metadata["handle"] ?? overlay.subtitle?.replacingOccurrences(of: "@", with: "") ?? overlay.title
        return HStack(spacing: 6) {
            Circle()
                .fill(C.watch)
                .frame(width: 22, height: 22)
                .overlay {
                    Text(String(overlay.title.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                }
            Text("@\(handle)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerLocationSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "location.fill")
                .font(.system(size: 11))
                .foregroundStyle(C.watch)
            Text(overlay.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerPollSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        let options = visibleInteractiveOptions(overlay.options)
        return VStack(alignment: .leading, spacing: 8) {
            Text(overlay.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { _, option in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(C.watch.opacity(0.18))
                    Text(option)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                }
                .frame(height: 38)
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerQuizSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        let options = visibleInteractiveOptions(overlay.options)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(C.watch)
                    .font(.system(size: 12))
                Text("QUIZ")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(C.watch)
            }

            Text(overlay.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { _, option in
                HStack {
                    Text(option)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(C.watch.opacity(0.18))
                )
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerQuestionSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(C.watch)
                Text("ASK ME")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(C.watch)
            }

            Text(overlay.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 240)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerCountdownSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        VStack(spacing: 2) {
            Text(overlay.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)

            Text(countdownPreviewText(for: overlay.targetDate))
                .font(.system(size: 22, weight: .black).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(editorViewerStickerBacking)
    }

    private func editorViewerGenericSticker(_ overlay: StoryInteractiveOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: overlay.kind.iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                Text(editorInteractiveLabel(for: overlay.kind))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(C.watch)
            }
            Text(overlay.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 240)
        .background(editorViewerStickerBacking)
    }

    private var editorViewerStickerBacking: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.86))
            .shadow(color: C.watch.opacity(0.16), radius: 12, y: 4)
    }

    private func editorInteractiveMetadata(_ options: [String]) -> [String: String] {
        options.reduce(into: [:]) { result, option in
            guard let separator = option.firstIndex(of: "=") else { return }
            let key = String(option[..<separator])
            let value = String(option[option.index(after: separator)...])
            result[key] = value
        }
    }

    private func shortenedHost(from value: String?) -> String? {
        guard let value, let host = URL(string: value)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    @ViewBuilder
    private func interactiveStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        if overlay.kind == .link {
            linkStickerVisual(overlay, width: width, height: height)
        } else if overlay.kind == .mention {
            mentionStickerVisual(overlay, width: width, height: height)
        } else if overlay.kind == .location {
            locationStickerVisual(overlay, width: width, height: height)
        } else if overlay.kind == .countdown {
            countdownStickerVisual(overlay, width: width, height: height)
        } else {
            genericInteractiveStickerVisual(overlay, width: width, height: height)
        }
    }

    private func linkStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        let metadata = editorInteractiveMetadata(overlay.options)
        return HStack(spacing: max(6, width * 0.025)) {
            Image(systemName: "link")
                .font(.system(size: max(10, height * 0.22), weight: .bold))
                .foregroundStyle(C.watch)
            VStack(alignment: .leading, spacing: 1) {
                Text(overlay.title)
                    .font(.system(size: max(12, height * 0.23), weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let host = shortenedHost(from: metadata["url"] ?? overlay.subtitle) {
                    Text(host)
                        .font(.system(size: max(9, height * 0.16), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, max(10, width * 0.04))
        .frame(width: width, height: height)
        .background(editorStickerBacking)
        .clipShape(Capsule())
    }

    private func locationStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: max(6, width * 0.025)) {
            Image(systemName: "location.fill")
                .font(.system(size: max(10, height * 0.22), weight: .bold))
                .foregroundStyle(C.watch)
            Text(overlay.title)
                .font(.system(size: max(12, height * 0.23), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .padding(.horizontal, max(10, width * 0.04))
        .frame(width: width, height: height)
        .background(editorStickerBacking)
        .clipShape(Capsule())
    }

    private func countdownStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(overlay.title)
                .font(.system(size: max(10, height * 0.11), weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)

            Text(countdownPreviewText(for: overlay.targetDate))
                .font(.system(size: max(20, height * 0.25), weight: .black).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: height)
        .background(editorStickerBacking)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func genericInteractiveStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        let options = visibleInteractiveOptions(overlay.options)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: overlay.kind.iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(editorInteractiveAccent(for: overlay.kind))
                Text(editorInteractiveLabel(for: overlay.kind))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(editorInteractiveAccent(for: overlay.kind))
            }

            Text(overlay.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            if let subtitle = overlay.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { _, option in
                Text(option)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(C.watch.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .frame(width: width, height: height, alignment: .leading)
        .background(editorStickerBacking)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var editorStickerBacking: some ShapeStyle {
        LinearGradient(
            colors: [Color.black.opacity(0.90), Color.black.opacity(0.78), C.watch.opacity(0.30)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func editorInteractiveLabel(for kind: StoryInteractiveStickerKind) -> String {
        switch kind {
        case .link: return "LINK"
        case .question: return "ASK ME"
        case .quiz: return "QUIZ"
        case .poll: return "POLL"
        case .addYours: return "ADD YOURS"
        case .avatar: return "AVATAR"
        case .location, .mention, .countdown: return kind.title.uppercased()
        }
    }

    private func editorInteractiveAccent(for kind: StoryInteractiveStickerKind) -> Color {
        C.watch
    }

    private func countdownPreviewText(for targetDate: Date?) -> String {
        guard let targetDate else { return "00:00" }
        let remaining = max(targetDate.timeIntervalSince(Date()), 0)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func visibleInteractiveOptions(_ options: [String]) -> [String] {
        options.filter { option in
            !option.contains("=")
        }
    }

    private func mentionStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: max(8, width * 0.03)) {
            Image(systemName: "at")
                .font(.system(size: max(15, width * 0.08), weight: .black))
                .foregroundStyle(.black)
                .frame(width: max(34, height * 0.56), height: max(34, height * 0.56))
                .background(C.watch)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.title)
                    .font(.system(size: max(14, width * 0.075), weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                if let subtitle = overlay.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: max(11, width * 0.045), weight: .bold))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, max(14, width * 0.055))
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.black.opacity(0.76))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
    }

    private func storyFont(for style: TextOverlayStyle, size: Double) -> Font {
        if let fontName = style.fontName {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .bold)
    }

    private func swiftUIColor(_ color: RGBAColor) -> Color {
        Color(red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }


    private func selectOverlayForEditing(_ overlay: Overlay) {
        editor.selectOverlay(overlay.id)
        if case .text(let text) = overlay {
            editingOverlayText = text.text
            composerText = text.text
            composerStyle = text.style
            composerColorIndex = nearestComposerColorIndex(to: text.style.color)
            composerFontIndex = nearestComposerFontIndex(to: text.style.fontName)
            composerEditingOverlayID = text.id
            activeTool = nil
            isTextComposerPresented = true
            isTextComposerFocused = true
        }
        if case .link(let link) = overlay {
            editingLinkLabel = link.label
            editingLinkURL = link.url
        }
    }

    private func handleOverlayTap(_ overlay: Overlay) {
        let wasSelected = editor.selectedOverlayID == overlay.id
        if wasSelected, case .text = overlay {
            selectOverlayForEditing(overlay)
        } else {
            selectOverlayForGesture(overlay)
        }
    }

    private func selectOverlayForGesture(_ overlay: Overlay) {
        editor.selectOverlay(overlay.id)
        switch overlay {
        case .text(let text):
            editingOverlayText = text.text
            composerText = text.text
            composerStyle = text.style
            composerColorIndex = nearestComposerColorIndex(to: text.style.color)
            composerFontIndex = nearestComposerFontIndex(to: text.style.fontName)
            composerEditingOverlayID = text.id
        case .link(let link):
            editingLinkLabel = link.label
            editingLinkURL = link.url
        default:
            break
        }
    }

    private func editorButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        Button(role: role) {
            stopPlayback()
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .labelStyle(.iconOnly)
                .frame(width: 38, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(role == .destructive ? .red : C.watch)
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    private var filterStatusHUD: some View {
        VStack(spacing: 6) {
            Text(currentFilterPreset.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(currentFilterPreset.id == "neutral" ? .white : .black)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(currentFilterPreset.id == "neutral" ? Color.black.opacity(0.48) : C.watch)
                .clipShape(Capsule())

            Text("Selected before capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.black.opacity(0.36))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 108)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var previewSurface: some View {
        ZStack {
            Color.black

            if usesRenderedToolPreview, let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFill()
            } else if let previewPlayer {
                StoryEditorPlayerView(player: previewPlayer)
                    .onAppear {
                        previewPlayer.play()
                        isPlaying = true
                    }
                    .storyPreviewColorGrade(videoPreviewColorGrade)
            } else if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFill()
            } else if isRendering {
                ProgressView()
                    .tint(C.watch)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                    Text("Preview unavailable")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(C.textMuted)
            }

            if isDrawingPresented {
                StoryDrawingCanvas(
                    drawing: $drawing,
                    canvasSize: CGSize(width: project.canvas.width, height: project.canvas.height),
                    tool: drawingTool
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(2)
            }

            if isRendering, renderedImage != nil {
                ProgressView()
                    .tint(C.watch)
                    .padding(10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }

            if !isDrawingPresented {
                interactiveOverlayLayer
            }

            if filterHUDVisible, !isDrawingPresented, !isTextComposerPresented, activeTool == nil {
                filterStatusHUD
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let renderError {
                Text(renderError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.red.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard activeTool == .look, editor.selectedOverlayID == nil else { return }
                    if !isComparingOriginal {
                        isComparingOriginal = true
                    }
                }
                .onEnded { _ in
                    isComparingOriginal = false
                }
        )
        .overlay(alignment: .top) {
            if isComparingOriginal {
                Text("Original")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.52))
                    .clipShape(Capsule())
                    .padding(.top, 116)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Story editor preview")
    }

    private func previewRenderProject(from project: Project) -> Project {
        var previewProject = project
        if isComparingOriginal {
            previewProject.tracks.videoClips = previewProject.tracks.videoClips.map { clip in
                var originalClip = clip
                originalClip.filterId = "neutral"
                originalClip.filterIntensity = 0
                originalClip.adjustments = .neutral
                return originalClip
            }
        }
        return previewProject
    }

    private func basePreviewSignature(for project: Project) -> String {
        project.tracks.videoClips.map { clip in
            [
                clip.id.uuidString,
                clip.assetRef.id.uuidString,
                clip.assetRef.relativePath,
                "\(clip.sourceStart.value)",
                "\(clip.sourceDuration.value)",
                "\(clip.speed)",
                "\(clip.reversed)",
                clip.filterId ?? "neutral",
                "\(clip.filterIntensity)",
                "\(clip.adjustments.brightness)",
                "\(clip.adjustments.contrast)",
                "\(clip.adjustments.saturation)",
                "\(clip.adjustments.warmth)",
                "\(clip.adjustments.vignette)",
                "\(clip.transform.scale)",
                "\(clip.transform.rotation)",
                "\(clip.transform.tx)",
                "\(clip.transform.ty)"
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    @MainActor
    private func schedulePreviewRender(after delay: UInt64? = nil) {
        let effectiveDelay = delay ?? previewRenderDebounceDelay
        previewRenderTask?.cancel()
        previewRenderTask = Task { @MainActor in
            if effectiveDelay > 0 {
                try? await Task.sleep(nanoseconds: effectiveDelay)
            }
            guard !Task.isCancelled else { return }
            await renderCurrentFrame()
        }
    }

    @MainActor
    private func renderCurrentFrame() async {
        guard !isRendering else {
            previewRenderNeedsRefresh = true
            return
        }
        isRendering = true
        defer {
            isRendering = false
            if previewRenderNeedsRefresh {
                previewRenderNeedsRefresh = false
                schedulePreviewRender()
            }
        }

        do {
            let store: AssetStore
            if let assetStore {
                store = assetStore
            } else {
                store = await ProjectStore.shared.assetStore(for: project.id)
                self.assetStore = store
            }
            guard !Task.isCancelled else { return }
            let baseProject = previewRenderProject(from: project)
            let buffer = try await compositor.render(
                project: baseProject,
                assetStore: store,
                at: CMTime(seconds: min(currentTime, duration), preferredTimescale: projectTimeScale),
                quality: .interactivePreview
            )
            guard !Task.isCancelled else { return }
            let image = try makeUIImage(from: buffer)
            guard !Task.isCancelled else { return }
            renderedImage = image
            renderError = nil
        } catch {
            guard !Task.isCancelled else { return }
            renderError = error.localizedDescription
        }
    }

    private func addGiphySticker(_ sticker: GiphySticker) async {
        do {
            let asset = sticker.overlayAsset
            guard let url = URL(string: asset.url) else {
                throw StoryEditorPreviewError.mediaOverlayImportFailed
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            let fileExtension = url.pathExtension.isEmpty ? asset.fallbackExtension : url.pathExtension
            await editor.addStickerImageOverlay(
                imageData: data,
                fileExtension: fileExtension,
                width: asset.width,
                height: asset.height,
                label: "Add GIPHY Sticker",
                at: currentTime
            )
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                renderError = error.localizedDescription
            }
        }
    }

    private func handleMediaOverlaySelection(_ item: PhotosPickerItem) async {
        do {
            if let video = try await item.loadTransferable(type: PickedStoryOverlayVideo.self) {
                try Task.checkCancellation()
                await MainActor.run { mediaOverlaySelection = nil }
                await editor.addVideoOverlay(from: video.url, at: currentTime)
                return
            }

            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw StoryEditorPreviewError.mediaOverlayImportFailed
            }
            try Task.checkCancellation()
            let normalized = image.normalizedForStoryMedia
            guard let jpeg = normalized.jpegData(compressionQuality: 0.98) else {
                throw StoryEditorPreviewError.mediaOverlayImportFailed
            }
            let width = normalized.cgImage?.width ?? Int(normalized.size.width * normalized.scale)
            let height = normalized.cgImage?.height ?? Int(normalized.size.height * normalized.scale)
            await MainActor.run { mediaOverlaySelection = nil }
            await editor.addImageOverlay(imageData: jpeg, width: width, height: height, at: currentTime)
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                mediaOverlaySelection = nil
                renderError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func handleToolPreviewModeChange(from oldToolID: String?, to newToolID: String?) {
        switch (oldToolID, newToolID) {
        case (nil, .some):
            beginRenderedToolPreviewMode()
        case (.some, nil):
            endRenderedToolPreviewMode()
        case (.some, .some):
            schedulePreviewRender()
        default:
            break
        }
    }

    @MainActor
    private func beginRenderedToolPreviewMode() {
        shouldResumePlaybackAfterToolPreview = isPlaying || (previewPlayer?.rate ?? 0) != 0
        stopPlayback()
        destroyPreviewPlayer()
        schedulePreviewRender()
    }

    @MainActor
    private func endRenderedToolPreviewMode() {
        let shouldAutoplay = shouldResumePlaybackAfterToolPreview
        shouldResumePlaybackAfterToolPreview = false
        guard shouldRestorePlayerAfterToolPreview else { return }
        if hasVideoPreviewClip {
            configureVideoPreviewPlayer(autoplay: shouldAutoplay)
        } else {
            schedulePreviewRender()
        }
    }

    private var shouldRestorePlayerAfterToolPreview: Bool {
        !isTextComposerPresented
            && !isDrawingPresented
            && !isMentionComposerPresented
            && stickerComposerKind == nil
            && !isShowingGiphyPicker
            && !isImportingMediaOverlay
    }

    @MainActor
    private func resumeVideoPreviewPlaybackIfNeeded() {
        guard hasVideoPreviewClip else {
            startTimedOverlayClockIfNeeded()
            return
        }
        guard let previewPlayer else {
            configureVideoPreviewPlayer(autoplay: true)
            return
        }
        previewPlayer.play()
        isPlaying = true
    }

    @MainActor
    private func configureVideoPreviewPlayer(autoplay: Bool = true) {
        guard let url = videoPreviewURL, let clip = videoPreviewClip else {
            destroyPreviewPlayer()
            return
        }

        let signature = previewPlayerSignature(url: url, clip: clip)
        if previewPlayerURL == url, previewPlayerSignature == signature, let previewPlayer {
            previewPlayer.isMuted = clip.muted
            previewPlayer.volume = clip.volume
            if autoplay {
                previewPlayer.play()
                isPlaying = true
            } else {
                previewPlayer.pause()
                isPlaying = false
            }
            return
        }

        destroyPreviewPlayer()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["tracks", "duration", "playable"]
        )
        if shouldUseVideoComposition(for: clip), !isComparingOriginal {
            item.videoComposition = AVVideoComposition(asset: asset) { request in
                guard let output = StoryFrameFilterRenderer.realtimePreviewCIImage(
                    request.sourceImage,
                    filterId: clip.filterId,
                    intensity: clip.filterIntensity,
                    adjustments: clip.adjustments
                ) else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                request.finish(with: output, context: nil)
            }
        }
        item.preferredForwardBufferDuration = 0
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = clip.muted
        player.volume = clip.volume
        previewPlayer = player
        previewPlayerURL = url
        previewPlayerSignature = signature
        renderedImage = nil
        isPlaying = autoplay

        previewPlayerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard duration > 0 else {
                currentTime = 0
                return
            }
            let boundedTime = min(max(time.seconds, 0), duration)
            let nearLoopBoundary = boundedTime < 0.05 || boundedTime >= max(duration - 0.08, 0)
            guard nearLoopBoundary || abs(boundedTime - currentTime) >= 0.12 else { return }
            currentTime = boundedTime
        }

        previewPlayerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                guard finished, isPlaying else { return }
                player.play()
            }
        }

        previewPlayerStatusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Task { @MainActor in
                guard previewPlayerURL == url else { return }
                if item.status == .readyToPlay {
                    if autoplay {
                        player.play()
                        isPlaying = true
                    } else {
                        player.pause()
                        isPlaying = false
                    }
                } else if item.status == .failed {
                    renderError = item.error?.localizedDescription ?? "Could not play captured video."
                    isPlaying = false
                }
            }
        }

        startPreviewPlaybackWatchdog(for: player, url: url, signature: signature)
        if autoplay {
            player.play()
        } else {
            player.pause()
        }
    }

    @MainActor
    private func startPreviewPlaybackWatchdog(for player: AVPlayer, url: URL, signature: String) {
        previewPlaybackWatchdogTask?.cancel()
        previewPlaybackWatchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard previewPlayer === player,
                      previewPlayerURL == url,
                      previewPlayerSignature == signature,
                      isPlaying,
                      player.currentItem?.status == .readyToPlay else { continue }

                let currentSeconds = player.currentTime().seconds
                let nearEnd = currentSeconds >= max(duration - 0.08, 0)
                if !nearEnd && (player.timeControlStatus != .playing || player.rate == 0) {
                    player.play()
                }
            }
        }
    }

    private func stopPlayback() {
        previewPlayer?.pause()
        timedOverlayClockTask?.cancel()
        timedOverlayClockTask = nil
        isPlaying = false
    }

    @MainActor
    private func startTimedOverlayClockIfNeeded() {
        guard !hasVideoPreviewClip, hasTimedMediaOverlay, timedOverlayClockTask == nil else { return }
        isPlaying = true
        timedOverlayClockTask = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 83_333_333)
                guard !Task.isCancelled else { break }
                let now = ContinuousClock.now
                let elapsed = previous.duration(to: now)
                previous = now
                let components = elapsed.components
                let seconds = Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
                currentTime = duration > 0
                    ? (currentTime + max(seconds, 0)).truncatingRemainder(dividingBy: duration)
                    : 0
            }
        }
    }

    private func destroyPreviewPlayer() {
        if let previewPlayerTimeObserver, let previewPlayer {
            previewPlayer.removeTimeObserver(previewPlayerTimeObserver)
        }
        previewPlayerTimeObserver = nil

        if let previewPlayerEndObserver {
            NotificationCenter.default.removeObserver(previewPlayerEndObserver)
        }
        previewPlayerEndObserver = nil
        previewPlayerStatusObserver?.invalidate()
        previewPlayerStatusObserver = nil
        previewPlaybackWatchdogTask?.cancel()
        previewPlaybackWatchdogTask = nil
        timedOverlayClockTask?.cancel()
        timedOverlayClockTask = nil

        previewPlayer?.pause()
        previewPlayer = nil
        previewPlayerURL = nil
        previewPlayerSignature = ""
        isPlaying = false
    }

    private func beginTextComposer() {
        stopPlayback()
        activeTool = nil
        composerText = ""
        composerStyle = TextOverlayStyle.default
        composerColorIndex = 0
        composerFontIndex = 0
        composerEditingOverlayID = nil
        isTextComposerPresented = true
        isTextComposerFocused = true
    }

    private func cancelTextComposer() {
        composerText = ""
        composerEditingOverlayID = nil
        isTextComposerPresented = false
        isTextComposerFocused = false
        resumeVideoPreviewPlaybackIfNeeded()
    }

    private func saveTextComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let editingID = composerEditingOverlayID
        let style = composerStyle
        cancelTextComposer()
        if let editingID {
            editor.selectOverlay(editingID)
            Task { await editor.updateSelectedText(text, style: style) }
        } else {
            Task { await editor.addTextOverlay(text: text, style: style, at: currentTime) }
        }
    }

    private func beginDrawing() {
        stopPlayback()
        activeTool = nil
        drawing = PKDrawing()
        isDrawingPresented = true
    }

    private func cancelDrawing() {
        drawing = PKDrawing()
        isDrawingPresented = false
    }

    private func saveDrawing() {
        let canvasSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let paddedBounds = drawing.bounds
            .insetBy(dx: -24, dy: -24)
            .intersection(canvasRect)
        guard !paddedBounds.isEmpty else {
            cancelDrawing()
            return
        }
        let image = drawing.image(from: paddedBounds, scale: 1)
        guard let data = image.pngData(), let cgImage = image.cgImage else {
            cancelDrawing()
            return
        }
        let tx = paddedBounds.midX - canvasSize.width / 2
        let ty = canvasSize.height / 2 - paddedBounds.midY
        let savedTime = currentTime
        drawing = PKDrawing()
        isDrawingPresented = false
        drawingImportTask?.cancel()
        drawingImportTask = Task {
            await editor.addDrawingOverlay(
                imageData: data,
                width: cgImage.width,
                height: cgImage.height,
                tx: tx,
                ty: ty,
                at: savedTime
            )
        }
    }

    private func makeUIImage(from pixelBuffer: CVPixelBuffer) throws -> UIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw StoryEditorPreviewError.imageConversionFailed
        }
        return UIImage(cgImage: cgImage)
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = max(Int(value.rounded(.down)), 0)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private enum StoryLookSection: String, CaseIterable, Identifiable {
    case filters = "Filters"
    case beauty = "Beauty"
    case effects = "Effects"
    case adjust = "Adjust"

    var id: String { rawValue }
}

private enum StoryFilterCategory: String, CaseIterable, Identifiable {
    case popular = "Popular"
    case portrait = "Portrait"
    case warm = "Warm"
    case cool = "Cool"
    case film = "Film"
    case mono = "B&W"

    var id: String { rawValue }

    var presetIDs: [String] {
        switch self {
        case .popular:
            return ["neutral", "smooth", "warm", "cinema", "vivid", "crisp", "fade", "moody"]
        case .portrait:
            return ["neutral", "rose", "bright", "warm", "dream"]
        case .warm:
            return ["neutral", "warm", "golden", "sunset", "rose", "vintage"]
        case .cool:
            return ["neutral", "cool", "aqua", "teal", "cinema", "crisp"]
        case .film:
            return ["neutral", "film", "cinema", "fade", "matte", "dream", "moody", "vintage"]
        case .mono:
            return ["neutral", "bw", "noir"]
        }
    }

    var presets: [StoryEffectPreset] {
        presetIDs.map { StoryEffectCatalog.preset(id: $0) }
    }

    static func category(for presetID: String) -> StoryFilterCategory {
        switch presetID {
        case "smooth", "rose", "bright": return .portrait
        case "golden", "sunset", "warm": return .warm
        case "cool", "aqua", "teal": return .cool
        case "film", "cinema", "fade", "matte", "dream", "moody", "vintage": return .film
        case "bw", "noir": return .mono
        default: return .popular
        }
    }
}

private struct StoryTextFont {
    let title: String
    let name: String?

    var previewFont: Font {
        if let name {
            return .custom(name, size: 13)
        }
        return .system(size: 13, weight: .bold)
    }
}

private extension StoryInteractiveStickerKind {
    var title: String {
        switch self {
        case .link: return "Link"
        case .location: return "Location"
        case .mention: return "Mention"
        case .addYours: return "Add Yours"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .question: return "Questions"
        case .countdown: return "Countdown"
        case .avatar: return "Avatar"
        }
    }

    var iconName: String {
        switch self {
        case .link: return "link"
        case .location: return "mappin.and.ellipse"
        case .mention: return "at"
        case .addYours: return "plus.bubble"
        case .poll: return "chart.bar"
        case .quiz: return "checklist"
        case .question: return "questionmark.bubble"
        case .countdown: return "timer"
        case .avatar: return "person.crop.circle"
        }
    }
}

private struct OverlayInteractionState {
    let transform: Transform2D
    let canvasSize: CGSize
    let cornerRadius: CGFloat
}

private struct OverlayAlignmentGuide {
    var showVerticalCenter = false
    var showHorizontalCenter = false

    var hasVisibleGuide: Bool {
        showVerticalCenter || showHorizontalCenter
    }
}

private struct OverlayGestureTarget {
    let id: UUID
    let overlay: Overlay
    let center: CGPoint
    let size: CGSize
    let transform: Transform2D
    let translationScale: CGSize
    let zIndex: Int
}

private struct InteractiveStickerSizePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGSize] = [:]

    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct OverlayCanvasGestureLayer: UIViewRepresentable {
    let targets: [OverlayGestureTarget]
    let selectedOverlayID: UUID?
    let previewScale: CGFloat
    let onTap: (Overlay?) -> Void
    let onBegin: (Overlay) -> Void
    let onChange: (UUID, Transform2D) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onBegin: onBegin, onChange: onChange, onEnd: onEnd)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTransform(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTransform(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTransform(_:)))

        tap.delegate = context.coordinator
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        rotation.delegate = context.coordinator

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(rotation)

        context.coordinator.pan = pan
        context.coordinator.pinch = pinch
        context.coordinator.rotation = rotation
        context.coordinator.targets = targets
        context.coordinator.selectedOverlayID = selectedOverlayID
        context.coordinator.previewScale = previewScale

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.targets = targets
        context.coordinator.selectedOverlayID = selectedOverlayID
        context.coordinator.onTap = onTap
        context.coordinator.onBegin = onBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.previewScale = previewScale
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var targets: [OverlayGestureTarget] = []
        var selectedOverlayID: UUID?
        var onTap: (Overlay?) -> Void
        var onBegin: (Overlay) -> Void
        var onChange: (UUID, Transform2D) -> Void
        var onEnd: () -> Void
        var previewScale: CGFloat = 1
        var startTransform: Transform2D?
        var activeTarget: OverlayGestureTarget?
        var lastMagnification: Double = 1
        var lastRotation: Double = 0
        weak var pan: UIPanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        weak var rotation: UIRotationGestureRecognizer?

        init(
            onTap: @escaping (Overlay?) -> Void,
            onBegin: @escaping (Overlay) -> Void,
            onChange: @escaping (UUID, Transform2D) -> Void,
            onEnd: @escaping () -> Void
        ) {
            self.onTap = onTap
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap(target(at: recognizer.location(in: recognizer.view))?.overlay)
        }

        @objc func handleTransform(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began, startTransform == nil {
                let location = recognizer.location(in: recognizer.view)
                guard let target = targetForInteraction(at: location) else { return }
                activeTarget = target
                startTransform = target.transform
                lastMagnification = 1
                lastRotation = 0
                onBegin(target.overlay)
            }

            guard let activeTarget, let startTransform else { return }
            let safeScaleX = max(activeTarget.translationScale.width, 0.0001)
            let safeScaleY = max(activeTarget.translationScale.height, 0.0001)
            let translation = pan?.translation(in: recognizer.view) ?? .zero
            let magnification = resolvedMagnification
            let rotationDelta = resolvedRotation
            let updated = Transform2D(
                scale: startTransform.scale * magnification,
                rotation: startTransform.rotation + rotationDelta,
                tx: startTransform.tx + Double(translation.x / safeScaleX),
                ty: startTransform.ty - Double(translation.y / safeScaleY)
            )
            onChange(activeTarget.id, updated)

            if interactionsEnded {
                self.startTransform = nil
                self.activeTarget = nil
                self.lastMagnification = 1
                self.lastRotation = 0
                onEnd()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !(gestureRecognizer is UITapGestureRecognizer) && !(otherGestureRecognizer is UITapGestureRecognizer)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !(gestureRecognizer is UITapGestureRecognizer) else { return true }
            return targetForInteraction(at: gestureRecognizer.location(in: gestureRecognizer.view)) != nil
        }

        private func targetForInteraction(at point: CGPoint) -> OverlayGestureTarget? {
            if let selectedOverlayID,
               let selected = targets.first(where: { $0.id == selectedOverlayID }),
               contains(point, in: selected) {
                return selected
            }
            return target(at: point)
        }

        private func target(at point: CGPoint) -> OverlayGestureTarget? {
            targets
                .sorted { $0.zIndex > $1.zIndex }
                .first { contains(point, in: $0) }
        }

        private func contains(_ point: CGPoint, in target: OverlayGestureTarget) -> Bool {
            let dx = point.x - target.center.x
            let dy = point.y - target.center.y
            let cosA = cos(-target.transform.rotation)
            let sinA = sin(-target.transform.rotation)
            let rotatedX = dx * cosA - dy * sinA
            let rotatedY = dx * sinA + dy * cosA
            return abs(rotatedX) <= target.size.width / 2 && abs(rotatedY) <= target.size.height / 2
        }

        private var resolvedMagnification: Double {
            guard let pinch else { return lastMagnification }
            switch pinch.state {
            case .began, .changed:
                lastMagnification = Double(pinch.scale)
            default:
                break
            }
            return lastMagnification
        }

        private var resolvedRotation: Double {
            guard let rotation else { return lastRotation }
            switch rotation.state {
            case .began, .changed:
                lastRotation = Double(rotation.rotation)
            default:
                break
            }
            return lastRotation
        }

        private var interactionsEnded: Bool {
            [pan, pinch, rotation].compactMap { $0 }.allSatisfy { recognizer in
                switch recognizer.state {
                case .possible, .ended, .cancelled, .failed:
                    return true
                case .began, .changed:
                    return false
                @unknown default:
                    return true
                }
            }
        }
    }
}

private struct StoryAssetOverlayImageView: View {
    let url: URL
    let kind: AssetKind
    let time: Double

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: reloadID) {
            image = await loadImage()
        }
    }

    private var reloadID: String {
        switch kind {
        case .video:
            return "\(url.path)-\(Int(max(time, 0) * 12))"
        case .image where isAnimatedImage:
            return "\(url.path)-\(Int(max(time, 0) * 12))"
        case .image, .audio:
            return url.path
        }
    }

    private var isAnimatedImage: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "gif" || ext == "webp"
    }

    private func loadImage() async -> UIImage? {
        switch kind {
        case .image:
            return loadImageFrame()
        case .video:
            return await loadVideoFrame()
        case .audio:
            return nil
        }
    }

    private func loadImageFrame() -> UIImage? {
        if let frame = StoryAnimatedImage.frame(at: time, from: url) {
            return UIImage(cgImage: frame)
        }
        if let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func loadVideoFrame() async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
            let requested = CMTime(seconds: max(time, 0.05), preferredTimescale: projectTimeScale)
            guard let cgImage = try? generator.copyCGImage(at: requested, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private struct GiphyStickerPickerView: View {
    let onSelect: (GiphySticker) -> Void

    @State private var query = ""
    @State private var stickers: [GiphySticker] = []
    @State private var offset = 0
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var loadGeneration = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("GIF stickers")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Spacer()
                Text("Powered by GIPHY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.textMuted)

                TextField("Search GIF stickers", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(C.text)
                    .tint(C.watch)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(C.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear GIF search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)

            HStack {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Trending"
                     : "Results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(C.watch)
                }
            }
            .padding(.horizontal, 16)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                if stickers.isEmpty, !isLoading {
                    ContentUnavailableView(
                        query.isEmpty ? "No trending GIFs" : "No GIFs found",
                        systemImage: "sparkles",
                        description: Text(query.isEmpty ? "Try again in a moment." : "Try a shorter or different search.")
                    )
                    .foregroundStyle(C.textMuted)
                    .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(stickers) { sticker in
                            Button {
                                onSelect(sticker)
                            } label: {
                                GiphyStickerCell(sticker: sticker)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sticker.title.isEmpty ? "GIF sticker" : sticker.title)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if stickers.count < totalCount || (!stickers.isEmpty && totalCount == 0) {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        Text(isLoading ? "Loading" : "Load more")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(C.watch)
                    .disabled(isLoading)
                    .padding(16)
                }
            }

        }
        .background(C.bg.ignoresSafeArea())
        .task { await load(reset: true) }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            loadGeneration &+= 1
            isLoading = false
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await load(reset: true)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            loadGeneration &+= 1
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard reset || !isLoading else { return }
        if reset { loadGeneration &+= 1 }
        let generation = loadGeneration
        let requestedQuery = query
        let nextOffset = reset ? 0 : offset
        isLoading = true
        errorText = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let response = try await GiphyStickerService.shared.fetchStickers(query: requestedQuery, limit: 24, offset: nextOffset)
            guard generation == loadGeneration, query == requestedQuery else { return }
            stickers = reset ? response.stickers : stickers + response.stickers
            offset = nextOffset + response.pagination.count
            totalCount = response.pagination.totalCount
        } catch {
            guard generation == loadGeneration, query == requestedQuery else { return }
            errorText = "Stickers are unavailable right now."
        }
    }
}

private struct GiphyStickerCell: View {
    let sticker: GiphySticker

    var body: some View {
        AnimatedRemoteStickerView(url: URL(string: sticker.preview.url))
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AnimatedRemoteStickerView: View {
    let url: URL?

    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let data {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { context in
                    if let frame = StoryAnimatedImage.frame(
                        at: context.date.timeIntervalSinceReferenceDate,
                        from: data
                    ) {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.clear
                    }
                }
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(C.textMuted)
            } else {
                ProgressView()
                    .tint(C.watch)
            }
        }
        .task(id: url) {
            guard let url else {
                failed = true
                return
            }
            do {
                let (downloaded, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    failed = true
                    return
                }
                data = downloaded
                failed = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

private actor GiphyStickerService {
    static let shared = GiphyStickerService()

    private let decoder = JSONDecoder()

    func fetchStickers(query: String, limit: Int, offset: Int) async throws -> GiphyStickerResponse {
        guard var components = URLComponents(string: C.baseURL + "/api/giphy/stickers") else {
            throw StoryEditorPreviewError.mediaOverlayImportFailed
        }
        var items = [
            URLQueryItem(name: "limit", value: "\(min(max(limit, 1), 50))"),
            URLQueryItem(name: "offset", value: "\(max(offset, 0))")
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw StoryEditorPreviewError.mediaOverlayImportFailed
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw StoryEditorPreviewError.mediaOverlayImportFailed
        }
        return try decoder.decode(GiphyStickerResponse.self, from: data)
    }
}

private struct GiphyStickerResponse: Decodable {
    let stickers: [GiphySticker]
    let pagination: GiphyPagination
}

private struct GiphyPagination: Decodable {
    let totalCount: Int
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case count
    }
}

private struct GiphySticker: Decodable, Identifiable {
    let id: String
    let title: String
    let preview: GiphyStickerAsset
    let webp: GiphyStickerAsset?
    let original: GiphyStickerAsset?

    var overlayAsset: GiphyStickerAsset {
        original ?? webp ?? preview
    }
}

private struct GiphyStickerAsset: Decodable {
    let url: String
    let width: Int
    let height: Int

    var fallbackExtension: String {
        url.lowercased().contains(".gif") ? "gif" : "webp"
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        width = Self.decodeFlexibleInt(from: container, forKey: .width) ?? 240
        height = Self.decodeFlexibleInt(from: container, forKey: .height) ?? 240
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let string = try? container.decode(String.self, forKey: key) { return Int(string) }
        return nil
    }
}

private struct StoryEditorPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> StoryEditorPlayerLayerView {
        let view = StoryEditorPlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: StoryEditorPlayerLayerView, context: Context) {
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
    }
}

private final class StoryEditorPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct StoryDrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let canvasSize: CGSize
    let tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = tool
        canvas.contentSize = canvasSize
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        canvas.tool = tool
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing

        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}

private struct StoryPreviewColorGradeModifier: ViewModifier {
    let adjustments: ColorAdjust

    func body(content: Content) -> some View {
        content
            .brightness(Double(adjustments.brightness))
            .contrast(Double(adjustments.contrast))
            .saturation(Double(adjustments.saturation))
            .overlay {
                warmthTint
                    .blendMode(.overlay)
                    .opacity(min(Double(abs(adjustments.warmth)) * 0.20, 0.18))
            }
            .overlay {
                if adjustments.vignette > 0 {
                    RadialGradient(
                        colors: [.clear, .black.opacity(min(Double(adjustments.vignette) * 0.85, 0.45))],
                        center: .center,
                        startRadius: 80,
                        endRadius: 420
                    )
                    .blendMode(.multiply)
                }
            }
    }

    private var warmthTint: Color {
        adjustments.warmth >= 0 ? Color.orange : Color.blue
    }
}

private extension View {
    func storyEditorFieldStyle() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .foregroundStyle(C.text)
            .background(C.elevated)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    func storyPreviewColorGrade(_ adjustments: ColorAdjust) -> some View {
        modifier(StoryPreviewColorGradeModifier(adjustments: adjustments))
    }
}

private enum StoryEditorPreviewError: LocalizedError {
    case imageConversionFailed
    case mediaOverlayImportFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Could not display the rendered story frame."
        case .mediaOverlayImportFailed:
            return "Could not add that photo or video overlay. Choose another item."
        }
    }
}

private extension UIImage {
    var storyFilterThumbnail: UIImage {
        let target = CGSize(width: 108, height: 136)
        let widthScale = target.width / max(size.width, 1)
        let heightScale = target.height / max(size.height, 1)
        let scale = max(widthScale, heightScale)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: (target.width - drawSize.width) / 2,
            y: (target.height - drawSize.height) / 2
        )
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    var storyClipThumbnail: UIImage {
        let target = CGSize(width: 164, height: 124)
        let widthScale = target.width / max(size.width, 1)
        let heightScale = target.height / max(size.height, 1)
        let scale = max(widthScale, heightScale)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: (target.width - drawSize.width) / 2,
            y: (target.height - drawSize.height) / 2
        )
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
