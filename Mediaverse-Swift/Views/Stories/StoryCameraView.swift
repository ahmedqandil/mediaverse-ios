@preconcurrency import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit

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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraPreview

            if controller.showGrid {
                storyCameraGrid
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let countdownValue {
                    Text("\(countdownValue)")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
        .task {
            let granted = await controller.prepare()
            if !granted { showPermissionAlert = true }
        }
        .onDisappear {
            shutterPressTask?.cancel()
            countdownTask?.cancel()
            controller.stopSession()
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
            CameraPreviewView(session: controller.session)
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

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            controlButton(icon: "photo.on.rectangle.angled") {
                isPickingLibrary = true
            }
            .disabled(controller.isRecording)
            .opacity(controller.isRecording ? 0.35 : 1)

            controlButton(icon: controller.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3") {
                controller.showGrid.toggle()
            }
            controlButton(icon: controller.torchMode == .off ? "bolt.slash" : "bolt.fill") {
                controller.toggleTorch()
            }
            controlButton(icon: "arrow.triangle.2.circlepath.camera") {
                Task { await controller.flipCamera() }
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
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

            HStack(alignment: .center) {
                if controller.segments.isEmpty {
                    Button {
                        isPickingLibrary = true
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.42))
                            .clipShape(Circle())
                    }
                    .disabled(controller.isRecording)
                    .opacity(controller.isRecording ? 0.35 : 1)
                    .accessibilityLabel("Choose from library")
                } else {
                    Button {
                        controller.deleteLastSegment()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.42))
                            .clipShape(Circle())
                    }
                    .disabled(controller.isRecording)
                    .opacity(controller.isRecording ? 0.35 : 1)
                    .accessibilityLabel("Delete last segment")
                }

                Spacer()

                shutterButton
                    .disabled(countdownValue != nil || remainingDuration <= 0)
                    .opacity(remainingDuration <= 0 ? 0.5 : 1)

                Spacer()

                Button {
                    onComplete(controller.segments)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 52, height: 52)
                        .background(controller.segments.isEmpty ? Color.white.opacity(0.14) : C.watch)
                        .foregroundStyle(controller.segments.isEmpty ? .white.opacity(0.55) : .black)
                        .clipShape(Circle())
                }
                .disabled(controller.segments.isEmpty || controller.isRecording)
            }
            .foregroundStyle(.white)
        }
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

    private var shutterButton: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 5)
                    .frame(width: 92, height: 92)
                Circle()
                    .trim(from: 0, to: shutterProgress)
                    .stroke(C.watch, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 92, height: 92)
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(controller.isRecording ? Color.red : Color.white)
                    .frame(width: controller.isRecording ? 42 : 62, height: controller.isRecording ? 42 : 62)
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

    private func controlButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
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
                onPhoto(photo.data, photo.image)
            case .failure(let error):
                controller.errorText = error.localizedDescription
            }
        }
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
        controller.startRecording(maxDuration: remainingDuration, speed: 1)
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

final class StoryCameraController: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var isRecording = false
    @Published private(set) var segments: [StoryCapturedSegment] = []
    @Published private(set) var exposureBias: Float = 0
    @Published var showGrid = false
    @Published var errorText: String?
    @Published private(set) var torchMode: AVCaptureDevice.TorchMode = .off

    private let sessionQueue = DispatchQueue(label: "com.westreem.story.camera.session")
    private let writerQueue = DispatchQueue(label: "com.westreem.story.camera.writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var baseZoomFactor: CGFloat = 1

    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startTime: CMTime?
    private var segmentTimer: Task<Void, Never>?
    private var currentSegmentMaxDuration: Double = 0
    private var currentSegmentSpeed: Double = 1
    private var pendingPhotoCompletion: ((Result<(data: Data, image: UIImage), Error>) -> Void)?

    var totalRecordedDuration: Double {
        segments.reduce(0) { $0 + $1.duration } + currentRecordingDuration
    }

    private var currentRecordingDuration: Double = 0 {
        didSet { objectWillChange.send() }
    }

    func prepare() async -> Bool {
        let cameraGranted = await requestAccess(for: .video)
        let microphoneGranted = await requestAccess(for: .audio)
        guard cameraGranted, microphoneGranted else { return false }
        await configureSession()
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

    func capturePhoto(
        completion: @escaping (Result<(data: Data, image: UIImage), Error>) -> Void
    ) {
        guard !isRecording else { return }
        errorText = nil
        pendingPhotoCompletion = completion
        let settings = AVCapturePhotoSettings()
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
        startTime = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-camera-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        outputURL = url

        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1080,
                    AVVideoHeightKey: 1920,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: 128_000
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true

                if writer.canAdd(videoInput) { writer.add(videoInput) }
                if writer.canAdd(audioInput) { writer.add(audioInput) }
                self.writer = writer
                self.writerVideoInput = videoInput
                self.writerAudioInput = audioInput
                writer.startWriting()
            } catch {
                Task { @MainActor in self.isRecording = false }
            }
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
        let duration = min(max(currentRecordingDuration, 0.1), currentSegmentMaxDuration)
        let speed = currentSegmentSpeed
        currentRecordingDuration = 0

        writerQueue.async { [weak self] in
            guard let self else { return }
            let writer = self.writer
            let outputURL = self.outputURL
            self.writerVideoInput?.markAsFinished()
            self.writerAudioInput?.markAsFinished()
            self.writer = nil
            self.writerVideoInput = nil
            self.writerAudioInput = nil
            self.outputURL = nil
            self.startTime = nil
            writer?.finishWriting {
                guard writer?.status == .completed, let outputURL else { return }
                Task { @MainActor in
                    self.segments.append(StoryCapturedSegment(
                        url: outputURL,
                        duration: duration,
                        speed: speed,
                        filterId: nil,
                        adjustments: .neutral
                    ))
                }
            }
        }
    }

    func deleteLastSegment() {
        guard !isRecording, let segment = segments.popLast() else { return }
        try? FileManager.default.removeItem(at: segment.url)
    }

    func flipCamera() async {
        guard !isRecording else { return }
        currentPosition = currentPosition == .back ? .front : .back
        exposureBias = 0
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
                self.session.sessionPreset = .hd1920x1080
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }

                if let videoDevice = Self.captureDevice(position: self.currentPosition),
                   let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
                   self.session.canAddInput(videoInput) {
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
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.writerQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
                if let connection = self.videoOutput.connection(with: .video) {
                    connection.setStoryPortraitOrientation()
                    connection.isVideoMirrored = self.currentPosition == .front && connection.isVideoMirroringSupported
                }

                self.audioOutput.setSampleBufferDelegate(self, queue: self.writerQueue)
                if self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutput(self.audioOutput)
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
                if let connection = self.photoOutput.connection(with: .video) {
                    connection.setStoryPortraitOrientation()
                    connection.isVideoMirrored = self.currentPosition == .front && connection.isVideoMirroringSupported
                }
                self.session.commitConfiguration()
                continuation.resume()
            }
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

extension StoryCameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let mediaType: AVMediaType = output is AVCaptureAudioDataOutput ? .audio : .video
        if mediaType == .video {
            connection.setStoryPortraitOrientation()
            connection.isVideoMirrored = currentPosition == .front && connection.isVideoMirroringSupported
        }
        append(sampleBuffer: sampleBuffer, mediaType: mediaType)
    }

    private func append(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard isRecording,
              let writer,
              writer.status != .failed,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
        }

        if mediaType == .video,
           let input = writerVideoInput,
           input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if mediaType == .audio,
                  let input = writerAudioInput,
                  input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
