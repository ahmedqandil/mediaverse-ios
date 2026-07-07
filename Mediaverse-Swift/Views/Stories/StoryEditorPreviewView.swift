import AVFoundation
import CoreImage
import CoreImage
import CoreImage
import CoreMedia
import CoreTransferable
import ImageIO
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
    case filters
    case audio
    case stickers
    case media
    case effects
    case music

    var id: String { rawValue }
}

private enum StoryStickerTool: String, CaseIterable, Identifiable {
    case link
    case location
    case mention
    case addYours
    case poll
    case quiz
    case questions
    case countdown
    case music
    case avatar
    case gif
    case photo
    case cutout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: return "Link"
        case .location: return "Location"
        case .mention: return "Mention"
        case .addYours: return "Add Yours"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .questions: return "Questions"
        case .countdown: return "Countdown"
        case .music: return "Music"
        case .avatar: return "Avatar"
        case .gif: return "GIF"
        case .photo: return "Photo"
        case .cutout: return "Cutout"
        }
    }

    var icon: String {
        switch self {
        case .link: return "link"
        case .location: return "mappin.and.ellipse"
        case .mention: return "at"
        case .addYours: return "plus.bubble"
        case .poll: return "chart.bar"
        case .quiz: return "checklist"
        case .questions: return "questionmark.bubble"
        case .countdown: return "timer"
        case .music: return "music.note"
        case .avatar: return "person.crop.circle"
        case .gif: return "sparkles"
        case .photo: return "photo.on.rectangle.angled"
        case .cutout: return "scissors"
        }
    }

    var defaultText: String {
        switch self {
        case .location: return "Add location"
        case .mention: return "@mention"
        case .addYours: return "Add yours"
        case .poll: return "Poll"
        case .quiz: return "Quiz"
        case .questions: return "Ask me a question"
        case .countdown: return "Countdown"
        case .avatar: return "Avatar"
        case .cutout: return "Cutout"
        default: return title
        }
    }

    var defaultSubtitle: String? {
        switch self {
        case .location: return "City or place"
        case .mention: return "Placeholder"
        case .addYours: return "Start a prompt chain"
        case .questions: return "Viewer replies"
        case .countdown: return "Tomorrow"
        case .avatar: return "Character sticker"
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
        case .location: return .location
        case .mention: return .mention
        case .addYours: return .addYours
        case .poll: return .poll
        case .quiz: return .quiz
        case .questions: return .question
        case .countdown: return .countdown
        case .avatar: return .avatar
        default: return nil
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
    @StateObject private var editor: StoryTimelineEditor
    let onProjectChange: (Project) -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var renderedImage: UIImage?
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var isRendering = false
    @State private var renderError: String?
    @State private var playbackTask: Task<Void, Never>?
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
    @State private var composerText = ""
    @State private var composerEditingOverlayID: UUID?
    @State private var composerStyle = TextOverlayStyle.default
    @State private var composerColorIndex = 0
    @State private var composerFontIndex = 0
    @State private var keyboardHeight: CGFloat = 0
    @State private var isOverlayInteracting = false
    @State private var overlayAlignmentGuide = OverlayAlignmentGuide()
    @FocusState private var isTextComposerFocused: Bool

    private let compositor = StoryCompositor()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(project: Project, onProjectChange: @escaping (Project) -> Void = { _ in }, onBack: @escaping () -> Void, onNext: @escaping () -> Void) {
        _editor = StateObject(wrappedValue: StoryTimelineEditor(project: project))
        self.onProjectChange = onProjectChange
        self.onBack = onBack
        self.onNext = onNext
    }

    private var project: Project { editor.project }

    private var duration: Double {
        max(editor.project.totalDurationSeconds, 0.1)
    }

    private var shouldShowAudioTool: Bool {
        editor.selectedClip?.assetRef.kind == .video || !editor.project.tracks.audioClips.isEmpty
    }

    private var shouldAutoPlayPreview: Bool {
        editor.project.tracks.videoClips.contains { $0.assetRef.kind == .video }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            previewSurface
                .ignoresSafeArea()

            if isDrawingPresented {
                drawingTopOverlay
                drawingBottomOverlay
            } else {
                storyTopOverlay
                if !isOverlayInteracting {
                    storySideTools
                    if editor.selectedOverlayID != nil, !isTextComposerPresented, activeTool == nil {
                        selectedOverlayCanvasMenu
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(3)
                    }
                }
            }

            if !isDrawingPresented, let activeTool, !isTextComposerPresented {
                toolDrawer(activeTool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
            }

            if isTextComposerPresented {
                textComposerOverlay
                    .zIndex(5)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.86), value: activeTool?.id)
        .onAppear {
            Task {
                assetStore = await ProjectStore.shared.assetStore(for: project.id)
                basePreviewSignature = basePreviewSignature(for: project)
                await renderCurrentFrame()
                if shouldAutoPlayPreview {
                    startPlayback()
                }
            }
        }
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: currentTime) { _, _ in
            guard !isPlaying else { return }
            Task { await renderCurrentFrame() }
        }
        .onReceive(editor.$project) { project in
            onProjectChange(project)
            currentTime = min(currentTime, duration)
            if shouldAutoPlayPreview {
                startPlayback()
            } else {
                stopPlayback()
                currentTime = 0
            }
            let signature = basePreviewSignature(for: project)
            guard signature != basePreviewSignature else { return }
            basePreviewSignature = signature
            Task { await renderCurrentFrame() }
        }
        .fileImporter(isPresented: $isImportingMusic, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
                Task { await addGiphySticker(sticker) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mediaOverlaySelection) { _, item in
            guard let item else { return }
            Task { await handleMediaOverlaySelection(item) }
        }
    }

    private var storyTopOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    stopPlayback()
                    onBack()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.44))
                        .clipShape(Circle())
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Back")

                ProgressView(value: currentTime, total: duration)
                    .tint(C.watch)
                    .frame(width: 150)

                Spacer()

                if let preset = activeFilterPreset {
                    Text(preset.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.black.opacity(0.42))
                        .clipShape(Capsule())
                }

                Button {
                    stopPlayback()
                    onNext()
                } label: {
                    Label("Share", systemImage: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(C.watch)
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Share story")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Spacer()
        }
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
                    .lineLimit(1...3)
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

                HStack(spacing: 10) {
                    textComposerTool(icon: "textformat.size", selected: composerStyle.fontSize > 68) {
                        cycleComposerSize()
                    }
                    textComposerTool(icon: "paintpalette.fill", selected: false) {
                        cycleComposerColor()
                    }
                    textComposerTool(icon: composerAlignmentIcon, selected: composerStyle.alignment != "center") {
                        cycleComposerAlignment()
                    }
                    textComposerTool(icon: composerStyle.backgroundColor == nil ? "square" : "inset.filled.rectangle", selected: composerStyle.backgroundColor != nil) {
                        toggleComposerBackground()
                    }
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
                .padding(.horizontal, 8)
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

    private var activeFilterPreset: StoryEffectPreset? {
        guard activeTool == .filters, let clip = editor.selectedClip else { return nil }
        return StoryEffectCatalog.preset(id: clip.filterId)
    }

    private var storySideTools: some View {
        GeometryReader { proxy in
            let buttonCount = shouldShowAudioTool ? 8.0 : 7.0
            let contentHeight = buttonCount * 42 + (buttonCount - 1) * 10
            let availableHeight = max(220, proxy.size.height - 250)
            let railScale = min(1, max(0.66, availableHeight / contentHeight))

            VStack(spacing: 0) {
                Spacer(minLength: 96)
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        storyToolButton(.filters, icon: "camera.filters")
                        if shouldShowAudioTool {
                            storyToolButton(.audio, icon: editor.selectedClip?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        Button {
                            beginTextComposer()
                        } label: {
                            Text("Aa")
                                .font(.system(size: 17, weight: .bold))
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.44))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Add text")
                        storyToolButton(.stickers, icon: "square.grid.3x3")
                        Button {
                            stopPlayback()
                            activeTool = nil
                            isShowingGiphyPicker = true
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.44))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Add GIPHY sticker")
                        storyToolButton(.media, icon: "photo.on.rectangle.angled")
                        storyToolButton(.effects, icon: "wand.and.stars")
                        storyToolButton(.music, icon: "music.note")
                        Button {
                            beginDrawing()
                        } label: {
                            Image(systemName: "pencil.tip")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.44))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Draw")
                    }
                    .scaleEffect(railScale, anchor: .trailing)
                    .padding(.trailing, 12)
                }
                Spacer(minLength: 142)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var selectedOverlayCanvasMenu: some View {
        VStack {
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
            .padding(.top, 68)
            Spacer()
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

    private func storyToolButton(_ tool: StoryEditorTool, icon: String) -> some View {
        Button {
            activeTool = activeTool == tool ? nil : tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 42, height: 42)
                .background(activeTool == tool ? C.watch : Color.black.opacity(0.44))
                .foregroundStyle(activeTool == tool ? .black : .white)
                .clipShape(Circle())
        }
        .accessibilityLabel(tool.rawValue.capitalized)
    }

    @ViewBuilder
    private func toolDrawer(_ tool: StoryEditorTool) -> some View {
        GeometryReader { proxy in
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(toolDrawerTitle(tool))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            activeTool = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityLabel("Close tool")
                    }

                    switch tool {
                    case .filters:
                        if let clip = editor.selectedClip {
                            filterControls(for: clip)
                            adjustmentControls(for: clip)
                        }
                    case .audio:
                        if let clip = editor.selectedClip, clip.assetRef.kind == .video {
                            audioControls(for: clip)
                        } else {
                            musicControls
                        }
                    case .stickers:
                        stickerTrayControls
                    case .media:
                        mediaAndLayoutControls
                    case .effects:
                        effectsControls
                    case .music:
                        musicControls
                    }
                }
                .padding(14)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: max(180, proxy.size.height - 150), alignment: .bottom)
                .clipped()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 92)
            }
        }
    }

    private func toolDrawerTitle(_ tool: StoryEditorTool) -> String {
        switch tool {
        case .filters: return "Filters"
        case .audio: return "Audio"
        case .stickers: return "Stickers"
        case .media: return "Media"
        case .effects: return "Effects"
        case .music: return "Music"
        }
    }

    private var timelineControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            clipStrip

            HStack(spacing: 8) {
                editorButton("Undo", systemImage: "arrow.uturn.backward", disabled: !editor.canUndo) {
                    await editor.undo()
                }
                editorButton("Redo", systemImage: "arrow.uturn.forward", disabled: !editor.canRedo) {
                    await editor.redo()
                }
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

    private func speedControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Playback")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0], id: \.self) { speed in
                    Button {
                        Task { await editor.updateSelectedClipSpeed(speed) }
                    } label: {
                        Text(speed == 1 ? "1x" : String(format: "%.1fx", speed))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(abs(clip.speed - speed) < 0.001 ? .black : C.text)
                            .frame(width: 54, height: 30)
                            .background(abs(clip.speed - speed) < 0.001 ? C.watch : C.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await editor.toggleSelectedClipReverse() }
                } label: {
                    Label("Reverse", systemImage: "backward.end.fill")
                        .font(.system(size: 11, weight: .bold))
                        .labelStyle(.iconOnly)
                        .foregroundStyle(clip.reversed ? .black : C.text)
                        .frame(width: 42, height: 30)
                        .background(clip.reversed ? C.watch : C.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reverse clip")
            }
        }
    }

    private func filterControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Filters")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StoryEffectCatalog.presets) { preset in
                        Button {
                            Task { await editor.applyEffectPreset(preset) }
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle((clip.filterId ?? "neutral") == preset.id ? .black : C.text)
                                .frame(width: 72, height: 32)
                                .background((clip.filterId ?? "neutral") == preset.id ? C.watch : C.elevated)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func adjustmentControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adjust")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            adjustmentSlider("Brightness", value: clip.adjustments.brightness, range: -0.2...0.2) { value in
                var next = clip.adjustments
                next.brightness = value
                await editor.updateSelectedClipAdjustments(next)
            }
            adjustmentSlider("Contrast", value: clip.adjustments.contrast, range: 0.6...1.6) { value in
                var next = clip.adjustments
                next.contrast = value
                await editor.updateSelectedClipAdjustments(next)
            }
            adjustmentSlider("Saturation", value: clip.adjustments.saturation, range: 0...1.8) { value in
                var next = clip.adjustments
                next.saturation = value
                await editor.updateSelectedClipAdjustments(next)
            }
        }
    }

    private func adjustmentSlider(
        _ title: String,
        value: Float,
        range: ClosedRange<Float>,
        update: @escaping (Float) async -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(C.textTertiary)
                .frame(width: 72, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in Task { await update(newValue) } }
                ),
                in: range
            )
            .tint(C.watch)
        }
    }

    private func audioControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clip Audio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Toggle("Mute", isOn: Binding(
                get: { clip.muted },
                set: { muted in Task { await editor.updateSelectedClipAudio(volume: clip.volume, muted: muted) } }
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(C.text)
            .tint(C.watch)
            Slider(
                value: Binding(
                    get: { clip.volume },
                    set: { volume in Task { await editor.updateSelectedClipAudio(volume: volume, muted: clip.muted) } }
                ),
                in: 0...1
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
                        editor.selectClip(clip.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clip \(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                            Text(formatTime(clip.timelineDuration.seconds))
                                .font(.system(size: 10, weight: .medium))
                                .fontDesign(.monospaced)
                        }
                        .foregroundStyle(editor.selectedClipID == clip.id ? .black : C.text)
                        .frame(width: 78, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(editor.selectedClipID == clip.id ? C.watch : C.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
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
                            set: { value in Task { await editor.updateMusicVolume(value) } }
                        ),
                        in: 0...1
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
            linkCreatorControls

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
                overlayStrip
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func handleStickerTool(_ tool: StoryStickerTool) {
        stopPlayback()
        switch tool {
        case .link:
            activeTool = .stickers
        case .gif:
            activeTool = nil
            isShowingGiphyPicker = true
        case .photo:
            activeTool = nil
            isImportingMediaOverlay = true
        case .music:
            activeTool = .music
        case .location, .mention, .addYours, .poll, .quiz, .questions, .countdown, .avatar:
            Task { await addInteractiveStorySticker(tool) }
        case .cutout:
            renderError = "Cutouts need subject segmentation before they can become stickers."
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
    }

    private var mediaAndLayoutControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    stopPlayback()
                    activeTool = nil
                    isImportingMediaOverlay = true
                } label: {
                    Label("Photo/Video", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)

                Button {
                    renderError = "Layout grid needs multi-select media import next."
                } label: {
                    Label("Layout", systemImage: "rectangle.split.2x2")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(C.watch)
            }

            if let clip = editor.selectedClip {
                speedControls(for: clip)
                trimControls(for: clip)
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private var effectsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            effectAction("AI Restyle", icon: "wand.and.stars") {
                renderError = "AI restyle needs a prompt service before export can match preview."
            }
            effectAction("Background", icon: "person.crop.rectangle") {
                renderError = "Background replacement needs segmentation or an AI background service."
            }
            effectAction("Cutout", icon: "scissors") {
                renderError = "Cutouts need subject segmentation before they can become stickers."
            }
            effectAction("Color Fill", icon: "paintbucket") {
                renderError = "Color fill needs a canvas background layer model."
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func effectAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 38)
        }
        .buttonStyle(.bordered)
        .tint(C.watch)
    }

    private func trimControls(for clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Trim")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Slider(
                value: Binding(
                    get: { clip.sourceDurationSeconds },
                    set: { value in Task { await editor.trimSelectedClip(to: value) } }
                ),
                in: 0.5...max(0.5, clip.assetRef.durationSeconds)
            )
            .tint(C.watch)
            Text(formatTime(clip.timelineDuration.seconds))
                .font(.system(size: 10, weight: .medium))
                .fontDesign(.monospaced)
                .foregroundStyle(C.textTertiary)
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
                set: { editingOverlayText = $0 }
            ))
            .storyEditorFieldStyle()
            .onSubmit {
                let text = editingOverlayText
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
            editorButton("Delete Sticker", systemImage: "trash", role: .destructive) {
                await editor.deleteSelectedOverlay()
            }
        }
    }

    private var interactiveOverlayLayer: some View {
        GeometryReader { proxy in
            let previewScale = max(
                proxy.size.width / CGFloat(project.canvas.width),
                proxy.size.height / CGFloat(project.canvas.height)
            )
            let visibleOverlays = Array(editor.project.tracks.overlays.filter(overlayIsVisible).enumerated())
            let targets = overlayGestureTargets(
                from: visibleOverlays,
                previewScale: previewScale,
                in: proxy.size
            )

            ZStack {
                ForEach(visibleOverlays, id: \.element.id) { index, overlay in
                    liveOverlayView(overlay, previewScale: previewScale)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .zIndex(editor.selectedOverlayID == overlay.id ? 10_000 : Double(index))
                }

                if isOverlayInteracting, overlayAlignmentGuide.hasVisibleGuide {
                    overlayAlignmentGuideView(overlayAlignmentGuide)
                        .allowsHitTesting(false)
                        .zIndex(19_000)
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
                        let snapped = snappedOverlayTransform(transform, previewScale: previewScale)
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

    private func overlayAlignmentGuideView(_ guide: OverlayAlignmentGuide) -> some View {
        GeometryReader { proxy in
            ZStack {
                if guide.showVerticalCenter {
                    Rectangle()
                        .fill(C.watch.opacity(0.9))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }

                if guide.showHorizontalCenter {
                    Rectangle()
                        .fill(C.watch.opacity(0.9))
                        .frame(height: 1.5)
                        .frame(maxWidth: .infinity)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }

    private func liveOverlayView(_ overlay: Overlay, previewScale: CGFloat) -> some View {
        let state = interactionState(for: overlay)
        let selected = editor.selectedOverlayID == overlay.id
        return overlayVisual(for: overlay, state: state, previewScale: previewScale)
            .overlay(
                RoundedRectangle(cornerRadius: state.cornerRadius)
                    .stroke(selected ? C.watch : Color.clear, lineWidth: 1.5)
            )
            .padding(16)
            .rotationEffect(.radians(state.transform.rotation))
            .offset(x: CGFloat(state.transform.tx) * previewScale, y: -CGFloat(state.transform.ty) * previewScale)
            .allowsHitTesting(false)
            .accessibilityLabel("Story overlay")
    }

    private func overlayGestureTargets(
        from overlays: [(offset: Int, element: Overlay)],
        previewScale: CGFloat,
        in size: CGSize
    ) -> [OverlayGestureTarget] {
        overlays.map { index, overlay in
            let state = interactionState(for: overlay)
            let scaledWidth = max(44, state.canvasSize.width * previewScale * state.transform.scale)
            let scaledHeight = max(44, state.canvasSize.height * previewScale * state.transform.scale)
            return OverlayGestureTarget(
                id: overlay.id,
                overlay: overlay,
                center: CGPoint(
                    x: size.width / 2 + CGFloat(state.transform.tx) * previewScale,
                    y: size.height / 2 - CGFloat(state.transform.ty) * previewScale
                ),
                size: CGSize(width: scaledWidth + 44, height: scaledHeight + 44),
                transform: state.transform,
                zIndex: editor.selectedOverlayID == overlay.id ? 10_000 + index : index
            )
        }
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
                    .lineLimit(3)
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
                        time: currentTime - sticker.timeRange.start.time.seconds
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
            let characterWidth = max(180, min(860, Double(text.text.count) * 28 + 68))
            return OverlayInteractionState(transform: text.transform, canvasSize: CGSize(width: characterWidth, height: 104), cornerRadius: 18)
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
            let width: Double = interactive.kind == .mention || interactive.kind == .location ? 520 : 700
            let optionHeight = interactive.options.isEmpty ? 0.0 : Double(interactive.options.count) * 58.0 + 18.0
            let subtitleHeight = interactive.subtitle == nil ? 0.0 : 44.0
            return OverlayInteractionState(
                transform: interactive.transform,
                canvasSize: CGSize(width: width, height: max(112.0, 116.0 + subtitleHeight + optionHeight)),
                cornerRadius: 28
            )
        }
    }

    private func interactiveStickerVisual(_ overlay: StoryInteractiveOverlay, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: overlay.kind.iconName)
                    .font(.system(size: max(12, 20 * width / 700), weight: .bold))
                    .foregroundStyle(C.watch)
                Text(overlay.title)
                    .font(.system(size: max(13, 28 * width / 700), weight: .heavy))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
            }

            if let subtitle = overlay.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: max(11, 18 * width / 700), weight: .bold))
                    .foregroundStyle(.black.opacity(0.62))
                    .lineLimit(1)
            }

            ForEach(Array(overlay.options.prefix(4).enumerated()), id: \.offset) { _, option in
                Text(option)
                    .font(.system(size: max(11, 18 * width / 700), weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(28, 44 * width / 700))
                    .background(Color.black.opacity(0.08))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, max(14, 28 * width / 700))
        .padding(.vertical, max(10, 20 * width / 700))
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
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

    private func overlayIsVisible(_ overlay: Overlay) -> Bool {
        let range: TimelineRange
        switch overlay {
        case .text(let text): range = text.timeRange
        case .sticker(let sticker): range = sticker.timeRange
        case .drawing(let drawing): range = drawing.timeRange
        case .link(let link): range = link.timeRange
        case .interactive(let interactive): range = interactive.timeRange
        }
        let start = range.start.time.seconds
        let end = start + range.duration.time.seconds
        return currentTime >= start && currentTime <= end
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

    private var previewSurface: some View {
        ZStack {
            Color.black

            if let renderedImage {
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
        .accessibilityLabel("Story editor preview")
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
                "\(clip.transform.scale)",
                "\(clip.transform.rotation)",
                "\(clip.transform.tx)",
                "\(clip.transform.ty)",
                clip.filterId ?? "",
                "\(clip.filterIntensity)",
                "\(clip.adjustments.brightness)",
                "\(clip.adjustments.contrast)",
                "\(clip.adjustments.saturation)",
                "\(clip.adjustments.warmth)",
                "\(clip.adjustments.vignette)"
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    @MainActor
    private func renderCurrentFrame() async {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }

        do {
            let store = await ProjectStore.shared.assetStore(for: project.id)
            var baseProject = project
            baseProject.tracks.overlays = []
            let buffer = try await compositor.render(
                project: baseProject,
                assetStore: store,
                at: CMTime(seconds: min(currentTime, duration), preferredTimescale: projectTimeScale)
            )
            renderedImage = try makeUIImage(from: buffer)
            renderError = nil
        } catch {
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
            await MainActor.run {
                renderError = error.localizedDescription
            }
        }
    }

    private func handleMediaOverlaySelection(_ item: PhotosPickerItem) async {
        do {
            if let video = try await item.loadTransferable(type: PickedStoryOverlayVideo.self) {
                await MainActor.run { mediaOverlaySelection = nil }
                await editor.addVideoOverlay(from: video.url, at: currentTime)
                return
            }

            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw StoryEditorPreviewError.mediaOverlayImportFailed
            }
            let normalized = image.normalizedForStoryMedia
            guard let jpeg = normalized.jpegData(compressionQuality: 0.92) else {
                throw StoryEditorPreviewError.mediaOverlayImportFailed
            }
            let width = normalized.cgImage?.width ?? Int(normalized.size.width * normalized.scale)
            let height = normalized.cgImage?.height ?? Int(normalized.size.height * normalized.scale)
            await MainActor.run { mediaOverlaySelection = nil }
            await editor.addImageOverlay(imageData: jpeg, width: width, height: height, at: currentTime)
        } catch {
            await MainActor.run {
                mediaOverlaySelection = nil
                renderError = error.localizedDescription
            }
        }
    }

    private func startPlayback() {
        guard shouldAutoPlayPreview, !isPlaying else { return }
        isPlaying = true
        playbackTask = Task { @MainActor in
            let frameInterval = 1.0 / Double(max(project.canvas.fps, 1))
            while !Task.isCancelled {
                let next = currentTime + frameInterval
                currentTime = next >= duration ? 0 : next
                await renderCurrentFrame()
                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
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
        Task {
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
    let zIndex: Int
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
            let safePreviewScale = max(previewScale, 0.0001)
            let translation = pan?.translation(in: recognizer.view) ?? .zero
            let magnification = resolvedMagnification
            let rotationDelta = resolvedRotation
            let updated = Transform2D(
                scale: startTransform.scale * magnification,
                rotation: startTransform.rotation + rotationDelta,
                tx: startTransform.tx + Double(translation.x / safePreviewScale),
                ty: startTransform.ty - Double(translation.y / safePreviewScale)
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
            return "\(url.path)-\(Int(max(time, 0) * 2))"
        case .image, .audio:
            return url.path
        }
    }

    private func loadImage() async -> UIImage? {
        switch kind {
        case .image:
            return loadStaticImage()
        case .video:
            return await loadVideoFrame()
        case .audio:
            return nil
        }
    }

    private func loadStaticImage() -> UIImage? {
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
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let requested = CMTime(seconds: max(time, 0), preferredTimescale: projectTimeScale)
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 12) {
            TextField("", text: $query, prompt: Text("Search stickers").foregroundStyle(C.textMuted))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(C.text)
                .tint(C.watch)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(C.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.borderSubtle, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 14)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(stickers) { sticker in
                        Button {
                            onSelect(sticker)
                        } label: {
                            GiphyStickerCell(sticker: sticker)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

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

            Text("Powered by GIPHY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.textMuted)
                .padding(.bottom, 10)
        }
        .background(C.bg.ignoresSafeArea())
        .task { await load(reset: true) }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await load(reset: true)
            }
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let nextOffset = reset ? 0 : offset
            let response = try await GiphyStickerService.shared.fetchStickers(query: query, limit: 24, offset: nextOffset)
            stickers = reset ? response.stickers : stickers + response.stickers
            offset = nextOffset + response.pagination.count
            totalCount = response.pagination.totalCount
        } catch {
            errorText = "Stickers are unavailable right now."
        }
    }
}

private struct GiphyStickerCell: View {
    let sticker: GiphySticker

    var body: some View {
        AsyncImage(url: URL(string: sticker.preview.url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(C.textMuted)
            case .empty:
                ProgressView()
                    .tint(C.watch)
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        webp ?? original ?? preview
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
