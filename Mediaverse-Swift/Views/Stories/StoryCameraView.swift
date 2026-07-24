@preconcurrency import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
#if canImport(MetalPetal)
import MetalPetal
#endif

private struct PickedStoryCameraVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("story-camera-library-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return PickedStoryCameraVideo(url: destination)
        }
    }
}

struct StoryCapturedSegment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let duration: Double
    let speed: Double
    let filterId: String?
    let adjustments: ColorAdjust
}

struct StoryCameraView: View {
    let maxDuration: Double
    let onCancel: () -> Void
    let onPhoto: (Data, UIImage) -> Void
    let onLibraryVideo: (URL) -> Void
    let onComplete: ([StoryCapturedSegment]) -> Void

    @StateObject private var controller = StoryCameraController()
    @State private var countdownValue: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var shutterPressTask: Task<Void, Never>?
    @State private var shutterPressActive = false
    @State private var shutterLongPressStarted = false
    @State private var isPickingLibrary = false
    @State private var librarySelection: PhotosPickerItem?
    @State private var showPermissionAlert = false
    @State private var capturePreviewPlayer: AVQueuePlayer?
    @State private var capturePreviewLooper: AVPlayerLooper?
    @State private var capturePreviewAdjustments: ColorAdjust = .neutral

    private var remainingDuration: Double {
        max(0, maxDuration - controller.totalRecordedDuration)
    }

    private var shutterProgress: Double {
        guard maxDuration > 0 else { return 0 }
        return min(max(controller.totalRecordedDuration / maxDuration, 0), 1)
    }

    private var shutterHelpText: String {
        controller.isRecording ? "Release to stop" : "Tap photo · hold video"
    }

    private var windowBounds: CGRect {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .bounds ?? UIScreen.main.bounds
    }

    private var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = windowBounds.size == .zero ? proxy.size : windowBounds.size
            let safeInsets = windowSafeAreaInsets
            let compact = viewport.height < 720
            let horizontalPadding: CGFloat = viewport.width < 380 ? 12 : 18
            let topPadding = max(safeInsets.top + 6, compact ? 10 : 12)
            let bottomPadding = max(safeInsets.bottom + (compact ? 8 : 14), compact ? 14 : 22)

            ZStack {
                Color.black.ignoresSafeArea()
                if let capturePreviewPlayer, !controller.isRecording {
                    StoryCameraLoopingVideoLayer(player: capturePreviewPlayer)
                        .storyCameraColorGrade(capturePreviewAdjustments)
                        .ignoresSafeArea()
                        .zIndex(0)
                } else {
                    cameraPreview
                        .zIndex(0)
                }

                if controller.showGrid {
                    storyCameraGrid
                        .allowsHitTesting(false)
                        .zIndex(1)
                }

                VStack(spacing: 0) {
                    topBar(compact: compact)
                    Spacer(minLength: compact ? 18 : 28)
                    if let countdownValue {
                        Text("\(countdownValue)")
                            .font(.system(size: compact ? 60 : 72, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: compact ? 18 : 28)
                    bottomControls(compact: compact)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .frame(width: viewport.width, height: viewport.height)
                .zIndex(2)
            }
            .frame(width: viewport.width, height: viewport.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .ignoresSafeArea()
        .task {
            let granted = await controller.prepare()
            if !granted { showPermissionAlert = true }
        }
        .onDisappear {
            shutterPressTask?.cancel()
            countdownTask?.cancel()
            clearCapturePreview()
            controller.stopSession()
        }
        .onChange(of: controller.lastCapturedPreviewSegment) { _, segment in
            showCapturePreview(segment)
        }
        .alert("Camera access needed", isPresented: $showPermissionAlert) {
            Button("Settings") { controller.openSettings() }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text("Enable camera and microphone permissions to record a story.")
        }
        .photosPicker(
            isPresented: $isPickingLibrary,
            selection: $librarySelection,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            Task { await handleLibrarySelection(item) }
        }
    }

    private var cameraPreview: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(session: controller.session)
                if controller.isLiveFilterActive {
                    MetalPetalCameraPreviewView(controller: controller)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let normalized = CGPoint(
                            x: min(max(value.location.x / max(proxy.size.width, 1), 0), 1),
                            y: min(max(value.location.y / max(proxy.size.height, 1), 0), 1)
                        )
                        controller.focus(at: normalized)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { controller.setZoom(scale: $0) }
                    .onEnded { _ in controller.commitZoom() }
            )
        }
        .ignoresSafeArea()
    }

    private func topBar(compact: Bool) -> some View {
        let buttonSize: CGFloat = compact ? 36 : 38
        let spacing: CGFloat = compact ? 10 : 12

        return HStack(spacing: spacing) {
            Button(action: closeCamera) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            controlButton(icon: "photo.on.rectangle.angled", size: buttonSize) {
                isPickingLibrary = true
            }
            .disabled(controller.isRecording)
            .opacity(controller.isRecording ? 0.35 : 1)

            controlButton(icon: controller.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3", size: buttonSize) {
                controller.showGrid.toggle()
            }
            controlButton(icon: controller.torchMode == .off ? "bolt.slash" : "bolt.fill", size: buttonSize) {
                controller.toggleTorch()
            }
            controlButton(icon: "arrow.triangle.2.circlepath.camera", size: buttonSize) {
                Task { await controller.flipCamera() }
            }
        }
    }

    private func bottomControls(compact: Bool) -> some View {
        let buttonSize: CGFloat = compact ? 48 : 52

        return VStack(spacing: compact ? 12 : 16) {
            if let errorText = controller.errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.72))
                    .clipShape(Capsule())
            }

            cameraFilterPicker(compact: compact)
                .disabled(controller.isRecording)
                .opacity(controller.isRecording ? 0.45 : 1)

            HStack(alignment: .center) {
                if controller.segments.isEmpty {
                    Button {
                        isPickingLibrary = true
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: buttonSize, height: buttonSize)
                            .background(.black.opacity(0.42))
                            .clipShape(Circle())
                    }
                    .disabled(controller.isRecording)
                    .opacity(controller.isRecording ? 0.35 : 1)
                    .accessibilityLabel("Choose from library")
                } else {
                    Button {
                        controller.deleteLastSegment()
                        showCapturePreview(controller.lastCapturedPreviewSegment)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: buttonSize, height: buttonSize)
                            .background(.black.opacity(0.42))
                            .clipShape(Circle())
                    }
                    .disabled(controller.isRecording)
                    .opacity(controller.isRecording ? 0.35 : 1)
                    .accessibilityLabel("Delete last segment")
                }

                Spacer()

                shutterButton(compact: compact)
                    .disabled(countdownValue != nil || remainingDuration <= 0)
                    .opacity(remainingDuration <= 0 ? 0.5 : 1)

                Spacer()

                Button {
                    onComplete(controller.segments)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: buttonSize, height: buttonSize)
                        .background(controller.segments.isEmpty ? Color.white.opacity(0.14) : C.watch)
                        .foregroundStyle(controller.segments.isEmpty ? .white.opacity(0.55) : .black)
                        .clipShape(Circle())
                }
                .disabled(controller.segments.isEmpty || controller.isRecording)
            }
            .foregroundStyle(.white)
        }
    }

    private func cameraFilterPicker(compact: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 7 : 9) {
                ForEach(StoryEffectCatalog.presets) { preset in
                    Button {
                        controller.selectFilter(preset)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: compact ? 11 : 12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(controller.selectedFilterId == preset.id ? .black : .white)
                            .padding(.horizontal, compact ? 10 : 12)
                            .frame(height: compact ? 30 : 34)
                            .background(controller.selectedFilterId == preset.id ? C.watch : Color.black.opacity(0.42))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(preset.name) filter")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: compact ? 32 : 36)
    }

    private var storyCameraGrid: some View {
        GeometryReader { proxy in
            Path { path in
                let thirdWidth = proxy.size.width / 3
                let thirdHeight = proxy.size.height / 3
                for index in 1...2 {
                    path.move(to: CGPoint(x: thirdWidth * CGFloat(index), y: 0))
                    path.addLine(to: CGPoint(x: thirdWidth * CGFloat(index), y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: thirdHeight * CGFloat(index)))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: thirdHeight * CGFloat(index)))
                }
            }
            .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private func shutterButton(compact: Bool) -> some View {
        let outerSize: CGFloat = compact ? 84 : 92
        let ringSize: CGFloat = compact ? 70 : 78
        let idleSize: CGFloat = compact ? 56 : 62
        let recordingSize: CGFloat = compact ? 38 : 42

        return VStack(spacing: compact ? 5 : 7) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 5)
                    .frame(width: outerSize, height: outerSize)
                Circle()
                    .trim(from: 0, to: shutterProgress)
                    .stroke(C.watch, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: outerSize, height: outerSize)
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: ringSize, height: ringSize)
                Circle()
                    .fill(controller.isRecording ? Color.red : Color.white)
                    .frame(
                        width: controller.isRecording ? recordingSize : idleSize,
                        height: controller.isRecording ? recordingSize : idleSize
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.72), value: controller.isRecording)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginShutterPressIfNeeded() }
                    .onEnded { _ in endShutterPress() }
            )
            .accessibilityLabel("Story shutter")

            Text(shutterHelpText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 132)
        }
    }

    private func controlButton(icon: String, size: CGFloat = 38, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.42))
                .clipShape(Circle())
        }
        .foregroundStyle(.white)
    }

    private func beginShutterPressIfNeeded() {
        guard !shutterPressActive, countdownValue == nil, remainingDuration > 0 else { return }
        shutterPressActive = true
        shutterLongPressStarted = false
        shutterPressTask?.cancel()
        shutterPressTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard shutterPressActive, !controller.isRecording, remainingDuration > 0 else { return }
                shutterLongPressStarted = true
                startRecordingFromShutter()
            }
        }
    }

    private func endShutterPress() {
        shutterPressTask?.cancel()
        if shutterLongPressStarted || controller.isRecording || countdownValue != nil {
            countdownTask?.cancel()
            countdownValue = nil
            if controller.isRecording {
                controller.stopRecording()
            }
        } else {
            capturePhotoFromShutter()
        }
        shutterPressActive = false
        shutterLongPressStarted = false
    }

    private func capturePhotoFromShutter() {
        guard !controller.isRecording, remainingDuration > 0 else { return }
        controller.capturePhoto { result in
            switch result {
            case .success(let photo):
                let filteredImage = StoryFrameFilterRenderer.renderImage(
                    photo.image,
                    filterId: controller.selectedFilterId,
                    adjustments: controller.selectedAdjustments
                )
                let filteredData = filteredImage.jpegData(compressionQuality: 0.92) ?? photo.data
                onPhoto(filteredData, filteredImage)
            case .failure(let error):
                controller.errorText = error.localizedDescription
            }
        }
    }

    private func closeCamera() {
        shutterPressTask?.cancel()
        countdownTask?.cancel()
        shutterPressActive = false
        shutterLongPressStarted = false
        clearCapturePreview()
        controller.stopSession()
        onCancel()
    }

    private func handleLibrarySelection(_ item: PhotosPickerItem) async {
        do {
            if let video = try await item.loadTransferable(type: PickedStoryCameraVideo.self) {
                await MainActor.run {
                    librarySelection = nil
                    onLibraryVideo(video.url)
                }
                return
            }

            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw StoryCameraError.libraryImportFailed
            }
            let normalized = image.storyPortraitNormalized
            guard let jpeg = normalized.jpegData(compressionQuality: 0.92) else {
                throw StoryCameraError.libraryImportFailed
            }
            await MainActor.run {
                librarySelection = nil
                onPhoto(jpeg, normalized)
            }
        } catch {
            await MainActor.run {
                librarySelection = nil
                controller.errorText = error.localizedDescription
            }
        }
    }

    private func startRecordingFromShutter() {
        guard !controller.isRecording, remainingDuration > 0 else { return }
        clearCapturePreview()
        controller.startRecording(maxDuration: remainingDuration, speed: 1)
    }

    private func showCapturePreview(_ segment: StoryCapturedSegment?) {
        guard let segment else {
            clearCapturePreview()
            return
        }
        let asset = AVURLAsset(url: segment.url)
        let item = AVPlayerItem(asset: asset)
        if StoryFrameFilterRenderer.hasActiveFilter(filterId: segment.filterId, adjustments: segment.adjustments) {
            item.videoComposition = AVVideoComposition(asset: asset) { request in
                let output = StoryFrameFilterRenderer.filteredCIImage(
                    request.sourceImage,
                    filterId: segment.filterId,
                    adjustments: segment.adjustments
                ) ?? request.sourceImage
                request.finish(with: output, context: nil)
            }
        }
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        player.isMuted = true
        capturePreviewAdjustments = .neutral
        capturePreviewLooper = AVPlayerLooper(player: player, templateItem: item)
        capturePreviewPlayer = player
        player.play()
    }

    private func clearCapturePreview() {
        capturePreviewPlayer?.pause()
        capturePreviewLooper = nil
        capturePreviewPlayer = nil
        capturePreviewAdjustments = .neutral
    }

}

private extension AVCaptureConnection {
    func setStoryPortraitOrientation() {
        if #available(iOS 17.0, *), isVideoRotationAngleSupported(90) {
            videoRotationAngle = 90
        } else if responds(to: NSSelectorFromString("setVideoOrientation:")) {
            setValue(1, forKey: "videoOrientation")
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        if let connection = view.videoPreviewLayer.connection {
            connection.setStoryPortraitOrientation()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct StoryCameraLoopingVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct StoryCameraColorGradeModifier: ViewModifier {
    let adjustments: ColorAdjust

    func body(content: Content) -> some View {
        content
            .brightness(Double(adjustments.brightness))
            .contrast(Double(adjustments.contrast))
            .saturation(Double(adjustments.saturation))
            .overlay {
                if adjustments.warmth != 0 {
                    let warmColor = adjustments.warmth > 0 ? Color.orange : Color.blue
                    warmColor
                        .opacity(min(abs(Double(adjustments.warmth)) * 0.18, 0.22))
                        .blendMode(.softLight)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if adjustments.vignette > 0 {
                    RadialGradient(
                        colors: [.clear, .black.opacity(min(Double(adjustments.vignette) * 0.85, 0.5))],
                        center: .center,
                        startRadius: 120,
                        endRadius: 520
                    )
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func storyCameraColorGrade(_ adjustments: ColorAdjust) -> some View {
        modifier(StoryCameraColorGradeModifier(adjustments: adjustments))
    }
}

#if canImport(MetalPetal)
private struct MetalPetalCameraPreviewView: UIViewRepresentable {
    let controller: StoryCameraController

    func makeUIView(context: Context) -> MTIThreadSafeImageView {
        let view = MTIThreadSafeImageView(frame: .zero)
        view.automaticallyCreatesContext = true
        view.contentMode = .scaleAspectFill
        view.isOpaque = true
        controller.setFilteredPreviewView(view)
        return view
    }

    func updateUIView(_ uiView: MTIThreadSafeImageView, context: Context) {
        controller.setFilteredPreviewView(uiView)
    }

    static func dismantleUIView(_ uiView: MTIThreadSafeImageView, coordinator: ()) {
        uiView.image = nil
    }
}
#else
private struct MetalPetalCameraPreviewView: View {
    let controller: StoryCameraController
    var body: some View { EmptyView() }
}
#endif

final class StoryCameraController: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var isRecording = false
    @Published private(set) var segments: [StoryCapturedSegment] = []
    @Published private(set) var lastCapturedPreviewSegment: StoryCapturedSegment?
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var selectedFilterId: String? = StoryEffectCatalog.presets.first?.id
    @Published private(set) var selectedAdjustments: ColorAdjust = StoryEffectCatalog.presets.first?.adjustments ?? .neutral
    @Published var showGrid = false
    @Published var errorText: String?
    @Published private(set) var torchMode: AVCaptureDevice.TorchMode = .off

    private let sessionQueue = DispatchQueue(label: "com.westreem.story.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.westreem.story.camera.video-output", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    #if canImport(MetalPetal)
    private weak var filteredPreviewView: MTIThreadSafeImageView?
    #endif
    private var currentPosition: AVCaptureDevice.Position = .back
    private var baseZoomFactor: CGFloat = 1

    private var outputURL: URL?
    private var pendingSegmentDuration: Double = 0
    private var pendingSegmentSpeed: Double = 1
    private var pendingSegmentFilterId: String?
    private var pendingSegmentAdjustments: ColorAdjust = .neutral
    private var segmentTimer: Task<Void, Never>?
    private var currentSegmentMaxDuration: Double = 0
    private var currentSegmentSpeed: Double = 1
    private var pendingPhotoCompletion: ((Result<(data: Data, image: UIImage), Error>) -> Void)?
    private var isSessionConfigured = false
    private var isVideoOutputAttached = false
    private var lastFilteredPreviewUpdateTime: TimeInterval = 0
    private let preferredFilteredPreviewFrameRate: Double = 30

    var totalRecordedDuration: Double {
        segments.reduce(0) { $0 + $1.duration } + currentRecordingDuration
    }

    var isLiveFilterActive: Bool {
        selectedFilterId != StoryEffectCatalog.presets.first?.id || selectedAdjustments != .neutral
    }

    private var currentRecordingDuration: Double = 0 {
        didSet { objectWillChange.send() }
    }

    func prepare() async -> Bool {
        let cameraGranted = await requestAccess(for: .video)
        let microphoneGranted = await requestAccess(for: .audio)
        guard cameraGranted, microphoneGranted else { return false }
        if !isSessionConfigured {
            await configureSession()
        }
        startSession()
        return true
    }

    func startSession() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stopSession() {
        stopRecording()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    #if canImport(MetalPetal)
    func setFilteredPreviewView(_ view: MTIThreadSafeImageView) {
        filteredPreviewView = view
    }
    #endif

    func selectFilter(_ preset: StoryEffectPreset) {
        guard !isRecording else { return }
        selectedFilterId = preset.id
        selectedAdjustments = preset.adjustments
        let shouldEnableLivePreview = isLiveFilterActive
        setFilteredPreviewOutputEnabled(shouldEnableLivePreview)
        if !shouldEnableLivePreview {
            clearFilteredPreview()
        }
    }

    func capturePhoto(
        completion: @escaping (Result<(data: Data, image: UIImage), Error>) -> Void
    ) {
        guard !isRecording else { return }
        errorText = nil
        pendingPhotoCompletion = completion
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        if let connection = photoOutput.connection(with: .video) {
            connection.setStoryPortraitOrientation()
            connection.isVideoMirrored = currentPosition == .front && connection.isVideoMirroringSupported
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func startRecording(maxDuration: Double, speed: Double) {
        guard !isRecording, maxDuration > 0 else { return }
        isRecording = true
        currentRecordingDuration = 0
        currentSegmentMaxDuration = maxDuration
        currentSegmentSpeed = min(max(speed, 0.5), 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-camera-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        outputURL = url

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            guard self.session.isRunning, !self.movieOutput.isRecording else {
                Task { @MainActor in
                    self.isRecording = false
                    self.errorText = "Camera is not ready yet. Try again."
                }
                return
            }
            if let connection = self.movieOutput.connection(with: .video) {
                connection.setStoryPortraitOrientation()
                connection.isVideoMirrored = self.currentPosition == .front && connection.isVideoMirroringSupported
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }

        segmentTimer?.cancel()
        segmentTimer = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let elapsed = Date().timeIntervalSince(startedAt)
                let timelineElapsed = elapsed / self.currentSegmentSpeed
                await MainActor.run {
                    self.currentRecordingDuration = min(timelineElapsed, maxDuration)
                    if timelineElapsed >= maxDuration {
                        self.stopRecording()
                    }
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        segmentTimer?.cancel()
        segmentTimer = nil
        pendingSegmentDuration = min(max(currentRecordingDuration, 0.1), currentSegmentMaxDuration)
        pendingSegmentSpeed = currentSegmentSpeed
        pendingSegmentFilterId = selectedFilterId
        pendingSegmentAdjustments = selectedAdjustments
        currentRecordingDuration = 0

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    func deleteLastSegment() {
        guard !isRecording, let segment = segments.popLast() else { return }
        try? FileManager.default.removeItem(at: segment.url)
        lastCapturedPreviewSegment = segments.last
    }

    func flipCamera() async {
        guard !isRecording else { return }
        currentPosition = currentPosition == .back ? .front : .back
        exposureBias = 0
        isSessionConfigured = false
        await configureSession()
    }

    func toggleTorch() {
        guard let device = videoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            let next: AVCaptureDevice.TorchMode = torchMode == .off ? .on : .off
            if device.isTorchModeSupported(next) {
                device.torchMode = next
                torchMode = next
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func setExposureBias(_ value: Float) {
        guard let device = videoInput?.device else { return }
        let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
        exposureBias = clamped
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()
        } catch {}
    }

    func focus(at point: CGPoint) {
        guard let device = videoInput?.device else { return }
        let focusPoint = CGPoint(
            x: currentPosition == .front ? 1 - point.x : point.x,
            y: point.y
        )
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = focusPoint
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = focusPoint
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func setZoom(scale: CGFloat) {
        guard let device = videoInput?.device else { return }
        let factor = min(max(baseZoomFactor * scale, 1), min(device.activeFormat.videoMaxZoomFactor, 6))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        } catch {}
    }

    func commitZoom() {
        baseZoomFactor = videoInput?.device.videoZoomFactor ?? 1
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func clearFilteredPreview() {
        #if canImport(MetalPetal)
        filteredPreviewView?.image = nil
        #endif
    }

    private func updateFilteredPreviewIfNeeded(sampleBuffer: CMSampleBuffer) {
        guard isLiveFilterActive else {
            clearFilteredPreview()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let minimumInterval = 1.0 / preferredFilteredPreviewFrameRate
        guard now - lastFilteredPreviewUpdateTime >= minimumInterval else { return }
        lastFilteredPreviewUpdateTime = now
        updateFilteredPreview(sampleBuffer: sampleBuffer)
    }

    private func updateFilteredPreview(sampleBuffer: CMSampleBuffer) {
        #if canImport(MetalPetal)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = MetalPetalStoryFilterProcessor.shared.livePreviewImage(
                from: pixelBuffer,
                filterId: selectedFilterId,
                adjustments: selectedAdjustments
              ) else {
            clearFilteredPreview()
            return
        }
        filteredPreviewView?.image = image
        #endif
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    private func configureSession() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.hd1280x720) {
                    self.session.sessionPreset = .hd1280x720
                } else {
                    self.session.sessionPreset = .high
                }
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }

                if let videoDevice = Self.captureDevice(position: self.currentPosition),
                   let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
                   self.session.canAddInput(videoInput) {
                    Self.configurePreferredFrameRate(on: videoDevice, frameRate: 30)
                    self.session.addInput(videoInput)
                    self.videoInput = videoInput
                }

                if let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   self.session.canAddInput(audioInput) {
                    self.session.addInput(audioInput)
                    self.audioInput = audioInput
                }

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                self.isVideoOutputAttached = false

                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                    self.movieOutput.movieFragmentInterval = .invalid
                    self.movieOutput.maxRecordedDuration = .invalid
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .speed
                }
                if let connection = self.photoOutput.connection(with: .video) {
                    connection.setStoryPortraitOrientation()
                    connection.isVideoMirrored = self.currentPosition == .front && connection.isVideoMirroringSupported
                }
                self.session.commitConfiguration()
                self.isSessionConfigured = true
                continuation.resume()
            }
        }
    }

    private func setFilteredPreviewOutputEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.isSessionConfigured else { return }
            guard enabled != self.isVideoOutputAttached else { return }
            self.session.beginConfiguration()
            if enabled {
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    self.isVideoOutputAttached = true
                    if let connection = self.videoOutput.connection(with: .video) {
                        connection.setStoryPortraitOrientation()
                        connection.isVideoMirrored = self.currentPosition == .front && connection.isVideoMirroringSupported
                    }
                }
            } else {
                if self.isVideoOutputAttached {
                    self.session.removeOutput(self.videoOutput)
                    self.isVideoOutputAttached = false
                }
            }
            self.session.commitConfiguration()
        }
    }

    private static func captureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private static func configurePreferredFrameRate(on device: AVCaptureDevice, frameRate: Double) {
        do {
            try device.lockForConfiguration()
            let targetDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            let supportsTargetFrameRate = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= frameRate && frameRate <= range.maxFrameRate
            }
            if supportsTargetFrameRate {
                device.activeVideoMinFrameDuration = targetDuration
                device.activeVideoMaxFrameDuration = targetDuration
            }
            device.unlockForConfiguration()
        } catch {}
    }
}

extension StoryCameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finishPhotoCapture(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            finishPhotoCapture(.failure(StoryCameraError.photoEncodingFailed))
            return
        }

        let normalized = image.normalizedForStoryMedia
        guard let jpeg = normalized.jpegData(compressionQuality: 0.92) else {
            finishPhotoCapture(.failure(StoryCameraError.photoEncodingFailed))
            return
        }
        finishPhotoCapture(.success((jpeg, normalized)))
    }

    private func finishPhotoCapture(_ result: Result<(data: Data, image: UIImage), Error>) {
        let completion = pendingPhotoCompletion
        pendingPhotoCompletion = nil
        Task { @MainActor in
            completion?(result)
        }
    }
}

private enum StoryCameraError: LocalizedError {
    case photoEncodingFailed
    case libraryImportFailed

    var errorDescription: String? {
        switch self {
        case .photoEncodingFailed:
            return "Could not prepare the captured photo. Try again."
        case .libraryImportFailed:
            return "Could not import that photo or video. Choose another item."
        }
    }
}

extension StoryCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        connection.setStoryPortraitOrientation()
        connection.isVideoMirrored = currentPosition == .front && connection.isVideoMirroringSupported
        updateFilteredPreviewIfNeeded(sampleBuffer: sampleBuffer)
    }
}

extension StoryCameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let duration = pendingSegmentDuration
        let speed = pendingSegmentSpeed
        let filterId = pendingSegmentFilterId
        let adjustments = pendingSegmentAdjustments
        outputURL = nil
        pendingSegmentDuration = 0
        pendingSegmentSpeed = 1
        pendingSegmentFilterId = nil
        pendingSegmentAdjustments = .neutral

        if let error {
            try? FileManager.default.removeItem(at: outputFileURL)
            Task { @MainActor in
                self.errorText = error.localizedDescription
            }
            return
        }

        Task { @MainActor in
            let segment = StoryCapturedSegment(
                url: outputFileURL,
                duration: duration,
                speed: speed,
                filterId: filterId,
                adjustments: adjustments
            )
            self.segments.append(segment)
            self.lastCapturedPreviewSegment = segment
        }
    }
}
