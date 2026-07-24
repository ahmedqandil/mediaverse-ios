@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CryptoKit
import Foundation
import UIKit

struct StoryExportResult {
    let url: URL
    let mimeType: String
    let mediaType: String
    let duration: Int
    let isCacheHit: Bool

    init(url: URL, mimeType: String, mediaType: String, duration: Int, isCacheHit: Bool = false) {
        self.url = url
        self.mimeType = mimeType
        self.mediaType = mediaType
        self.duration = duration
        self.isCacheHit = isCacheHit
    }
}

func storyProjectRequiresAnimatedExport(_ project: Project) -> Bool {
    if project.tracks.videoClips.contains(where: { $0.assetRef.kind == .video }) {
        return true
    }
    return project.tracks.overlays.contains { overlay in
        guard case .sticker(let sticker) = overlay, let assetRef = sticker.assetRef else { return false }
        if assetRef.kind == .video { return true }
        guard assetRef.kind == .image else { return false }
        let ext = URL(fileURLWithPath: assetRef.relativePath).pathExtension.lowercased()
        return ext == "gif" || ext == "webp"
    }
}

actor StoryExportService {
    private let compositor: StoryCompositor
    private let ciContext: CIContext
    private let cacheKeyEncoder: JSONEncoder

    init(compositor: StoryCompositor = StoryCompositor()) {
        self.compositor = compositor
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
        self.cacheKeyEncoder = JSONEncoder()
        self.cacheKeyEncoder.outputFormatting = [.sortedKeys]
    }

    func export(
        project: Project,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryExportResult {
        let mediaProject = mediaRenderProject(from: project)
        let store = await ProjectStore.shared.assetStore(for: project.id)
        let cacheKey = try exportCacheKey(for: mediaProject, assetStore: store)
        if let cached = try await StoryExportCache.shared.cachedResult(for: cacheKey) {
            progress(1)
            return cached
        }

        let result: StoryExportResult
        if isImageOnly(mediaProject) {
            result = try await exportImage(project: mediaProject, assetStore: store, progress: progress)
        } else if let nativeExport = try await exportSimpleVideoIfPossible(project: mediaProject, assetStore: store, progress: progress) {
            result = nativeExport
        } else {
            result = try await exportVideo(project: mediaProject, assetStore: store, progress: progress)
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        return try await StoryExportCache.shared.store(result, for: cacheKey)
    }

    private func mediaRenderProject(from project: Project) -> Project {
        var mediaProject = project
        mediaProject.tracks.overlays = project.tracks.overlays.filter { overlay in
            if case .interactive = overlay {
                return false
            }
            return true
        }
        extendPhotoStoryToMaxDuration(&mediaProject)
        return mediaProject
    }

    private struct ExportCacheInput: Codable {
        let schemaVersion: Int
        let project: Project
        let codec: String
        let nativePreset: String
        let videoBitrate: Int
        let sourceAssets: [SourceAssetDigest]
    }

    private struct SourceAssetDigest: Codable {
        let relativePath: String
        let byteCount: Int
        let sha256: String
    }

    private func exportCacheKey(for project: Project, assetStore: AssetStore) throws -> String {
        let input = ExportCacheInput(
            schemaVersion: 3,
            project: project,
            codec: "h264",
            nativePreset: AVAssetExportPresetHighestQuality,
            videoBitrate: targetVideoBitrate(width: project.canvas.width, height: project.canvas.height, fps: max(project.canvas.fps, 1)),
            sourceAssets: try sourceAssetDigests(for: project, assetStore: assetStore)
        )
        let data = try cacheKeyEncoder.encode(input)
        return Self.sha256Hex(data)
    }

    private func sourceAssetDigests(for project: Project, assetStore: AssetStore) throws -> [SourceAssetDigest] {
        try assetRefs(in: project)
            .reduce(into: [String: AssetRef]()) { refsByPath, ref in
                refsByPath[ref.relativePath] = ref
            }
            .keys
            .sorted()
            .map { relativePath in
                let url = assetStore.absoluteURL(for: relativePath)
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return SourceAssetDigest(
                    relativePath: relativePath,
                    byteCount: fileSize,
                    sha256: try fileSHA256Hex(url)
                )
            }
    }

    private func assetRefs(in project: Project) -> [AssetRef] {
        var refs = project.tracks.videoClips.map(\.assetRef)
        refs.append(contentsOf: project.tracks.audioClips.map(\.assetRef))
        for overlay in project.tracks.overlays {
            switch overlay {
            case .sticker(let sticker):
                if let assetRef = sticker.assetRef {
                    refs.append(assetRef)
                }
            case .drawing(let drawing):
                refs.append(drawing.assetRef)
            case .text, .link, .interactive:
                break
            }
        }
        return refs
    }

    private func fileSHA256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return Self.hexString(hasher.finalize())
    }

    private static func sha256Hex<D: DataProtocol>(_ data: D) -> String {
        hexString(SHA256.hash(data: data))
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isImageOnly(_ project: Project) -> Bool {
        !project.tracks.videoClips.isEmpty
            && project.tracks.videoClips.allSatisfy { $0.assetRef.kind == .image }
            && !storyProjectRequiresAnimatedExport(project)
    }

    private func exportSimpleVideoIfPossible(
        project: Project,
        assetStore: AssetStore,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryExportResult? {
        guard project.tracks.videoClips.count == 1,
              project.tracks.overlays.isEmpty,
              project.tracks.audioClips.isEmpty,
              let clip = project.tracks.videoClips.first,
              clip.assetRef.kind == .video,
              !clip.reversed,
              abs(clip.speed - 1) < 0.001,
              clip.transform == .identity,
              clip.cropRect == nil,
              clip.filterId == nil || clip.filterId == "neutral",
              clip.adjustments == .neutral else {
            return nil
        }

        let sourceURL = assetStore.absoluteURL(for: clip.assetRef.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw StoryExportError.sourceMediaMissing
        }

        progress(0.1)
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let durationSeconds = min(max(clip.timelineDuration.seconds, 0.1), storyMaxDurationSeconds)
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: clip.sourceStartSeconds, preferredTimescale: projectTimeScale),
            duration: CMTime(seconds: min(clip.sourceDurationSeconds, durationSeconds), preferredTimescale: projectTimeScale)
        )

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = .identity

        if !clip.muted,
           clip.volume > 0,
           let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        let canvasSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(project.canvas.fps, 1)))
        videoComposition.instructions = [try await nativeVideoInstruction(
            track: compositionVideoTrack,
            sourceTrack: sourceVideoTrack,
            canvasSize: canvasSize,
            duration: sourceRange.duration
        )]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-export-native-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        progress(0.35)
        try await exportSession.export(to: outputURL, as: .mp4)
        progress(1)

        return StoryExportResult(
            url: outputURL,
            mimeType: "video/mp4",
            mediaType: "video",
            duration: max(1, Int(ceil(durationSeconds)))
        )
    }

    private func nativeVideoInstruction(
        track: AVCompositionTrack,
        sourceTrack: AVAssetTrack,
        canvasSize: CGSize,
        duration: CMTime
    ) async throws -> AVMutableVideoCompositionInstruction {
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let safeDisplayWidth = max(displaySize.width, 1)
        let safeDisplayHeight = max(displaySize.height, 1)
        let scale = min(canvasSize.width / safeDisplayWidth, canvasSize.height / safeDisplayHeight)
        let scaledSize = CGSize(width: safeDisplayWidth * scale, height: safeDisplayHeight * scale)
        let normalized = preferredTransform.concatenating(CGAffineTransform(
            translationX: -transformedRect.minX,
            y: -transformedRect.minY
        ))
        let transform = normalized
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (canvasSize.width - scaledSize.width) / 2,
                y: (canvasSize.height - scaledSize.height) / 2
            ))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        return instruction
    }

    private func exportImage(
        project: Project,
        assetStore: AssetStore,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryExportResult {
        progress(0.15)
        let buffer = try await compositor.render(project: project, assetStore: assetStore, at: .zero)
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw StoryExportError.imageConversionFailed
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.92) else {
            throw StoryExportError.imageEncodingFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-export-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: url, options: [.atomic])
        progress(1)
        return StoryExportResult(
            url: url,
            mimeType: "image/jpeg",
            mediaType: "image",
            duration: Int(storyMaxDurationSeconds)
        )
    }

    private func exportVideo(
        project: Project,
        assetStore: AssetStore,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryExportResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-export-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        var shouldRemoveRenderedVideo = true
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            if shouldRemoveRenderedVideo {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let fps = max(project.canvas.fps, 1)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: project.canvas.width,
            AVVideoHeightKey: project.canvas.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetVideoBitrate(
                    width: project.canvas.width,
                    height: project.canvas.height,
                    fps: fps
                ),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: project.canvas.width,
                kCVPixelBufferHeightKey as String: project.canvas.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(input) else {
            throw StoryExportError.writerSetupFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StoryExportError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw StoryExportError.writerSetupFailed
        }

        let durationSeconds = min(max(project.totalDurationSeconds, 0.1), storyMaxDurationSeconds)
        let frameCount = max(Int(ceil(durationSeconds * Double(fps))), 1)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            var pooledBuffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pooledBuffer)
            guard poolStatus == kCVReturnSuccess, let buffer = pooledBuffer else {
                throw StoryRenderError.pixelBufferCreationFailed
            }
            try await compositor.render(project: project, assetStore: assetStore, at: presentationTime, into: buffer)
            try autoreleasepool {
                guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                    throw writer.error ?? StoryExportError.frameAppendFailed
                }
            }
            progress(Double(frameIndex + 1) / Double(frameCount) * 0.88)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? StoryExportError.writerFinishFailed
        }

        progress(0.90)
        let finalURL = try await muxOriginalAudioIfNeeded(
            renderedVideoURL: outputURL,
            project: project,
            assetStore: assetStore,
            durationSeconds: durationSeconds
        )
        shouldRemoveRenderedVideo = finalURL != outputURL
        progress(1)

        return StoryExportResult(
            url: finalURL,
            mimeType: "video/mp4",
            mediaType: "video",
            duration: max(1, Int(ceil(durationSeconds)))
        )
    }

    private func targetVideoBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixelsPerSecond = Double(max(width, 1) * max(height, 1) * max(fps, 1))
        let target = Int(pixelsPerSecond * 0.1)
        return min(max(target, 2_500_000), 12_000_000)
    }

    private func muxOriginalAudioIfNeeded(
        renderedVideoURL: URL,
        project: Project,
        assetStore: AssetStore,
        durationSeconds: Double
    ) async throws -> URL {
        let audibleVideoClips = project.tracks.videoClips.filter { clip in
            clip.assetRef.kind == .video && !clip.muted && clip.volume > 0
        }
        let musicClips = project.tracks.audioClips.filter { $0.volume > 0 }
        guard !audibleVideoClips.isEmpty || !musicClips.isEmpty else { return renderedVideoURL }

        let composition = AVMutableComposition()
        let renderedAsset = AVURLAsset(url: renderedVideoURL)
        guard let renderedVideoTrack = try await renderedAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return renderedVideoURL
        }

        let renderDuration = CMTime(seconds: durationSeconds, preferredTimescale: projectTimeScale)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: renderDuration),
            of: renderedVideoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = .identity

        var mixParameters: [AVAudioMixInputParameters] = []
        var cursor = CMTime.zero
        for clip in project.tracks.videoClips {
            defer { cursor = cursor + clip.timelineDuration }
            guard clip.assetRef.kind == .video, !clip.muted, clip.volume > 0 else { continue }

            let sourceURL = assetStore.absoluteURL(for: clip.assetRef.relativePath)
            let sourceAsset = AVURLAsset(url: sourceURL)
            guard let sourceAudioTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first,
                  let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStartSeconds, preferredTimescale: projectTimeScale),
                duration: CMTime(seconds: clip.sourceDurationSeconds, preferredTimescale: projectTimeScale)
            )
            try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: cursor)
            if abs(clip.speed - 1) > 0.001 {
                compositionAudioTrack.scaleTimeRange(
                    CMTimeRange(start: cursor, duration: sourceRange.duration),
                    toDuration: clip.timelineDuration
                )
            }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            parameters.setVolume(clip.volume, at: cursor)
            mixParameters.append(parameters)
        }

        for clip in musicClips {
            let sourceURL = assetStore.absoluteURL(for: clip.assetRef.relativePath)
            let sourceAsset = AVURLAsset(url: sourceURL)
            guard let sourceAudioTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first,
                  let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }

            let sourceDuration = CMTime(seconds: max(clip.assetRef.durationSeconds - clip.sourceStart.time.seconds, 0.1), preferredTimescale: projectTimeScale)
            let clipStart = clip.startOnTimeline.time
            let clipDuration = min(clip.duration.time, renderDuration - clipStart)
            var inserted = CMTime.zero
            while inserted < clipDuration {
                let remaining = clipDuration - inserted
                let segmentDuration = min(sourceDuration, remaining)
                let sourceRange = CMTimeRange(start: clip.sourceStart.time, duration: segmentDuration)
                try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: clipStart + inserted)
                inserted = inserted + segmentDuration
            }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            parameters.setVolume(0, at: clipStart)
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: clip.volume,
                timeRange: CMTimeRange(start: clipStart, duration: min(clip.fadeIn.time, clipDuration))
            )
            parameters.setVolumeRamp(
                fromStartVolume: clip.volume,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: max(clipStart, clipStart + clipDuration - clip.fadeOut.time), duration: min(clip.fadeOut.time, clipDuration))
            )
            mixParameters.append(parameters)
        }

        guard !mixParameters.isEmpty else { return renderedVideoURL }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-export-audio-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return renderedVideoURL
        }
        exportSession.audioMix = audioMix
        exportSession.shouldOptimizeForNetworkUse = true
        try await exportSession.export(to: outputURL, as: .mp4)
        return outputURL
    }
}

enum StoryExportError: LocalizedError {
    case imageConversionFailed
    case imageEncodingFailed
    case sourceMediaMissing
    case writerSetupFailed
    case frameAppendFailed
    case writerFinishFailed
    case audioMuxFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Could not render the story image."
        case .imageEncodingFailed:
            return "Could not encode the story image."
        case .sourceMediaMissing:
            return "Could not find the story video file. Go back and capture it again."
        case .writerSetupFailed:
            return "Could not start story video export."
        case .frameAppendFailed:
            return "Could not write a story video frame."
        case .writerFinishFailed:
            return "Could not finish story video export."
        case .audioMuxFailed:
            return "Could not add audio to the story video."
        }
    }
}
