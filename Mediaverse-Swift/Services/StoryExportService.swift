@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import UIKit

struct StoryExportResult {
    let url: URL
    let mimeType: String
    let mediaType: String
    let duration: Int
}

actor StoryExportService {
    private let compositor: StoryCompositor
    private let ciContext: CIContext

    init(compositor: StoryCompositor = StoryCompositor()) {
        self.compositor = compositor
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    func export(
        project: Project,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryExportResult {
        let store = await ProjectStore.shared.assetStore(for: project.id)
        if isImageOnly(project) {
            return try await exportImage(project: project, assetStore: store, progress: progress)
        }
        return try await exportVideo(project: project, assetStore: store, progress: progress)
    }

    private func isImageOnly(_ project: Project) -> Bool {
        !project.tracks.videoClips.isEmpty && project.tracks.videoClips.allSatisfy { $0.assetRef.kind == .image }
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
            duration: max(2, min(30, Int(ceil(project.totalDurationSeconds))))
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
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: project.canvas.width,
            AVVideoHeightKey: project.canvas.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
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

        let fps = max(project.canvas.fps, 1)
        let durationSeconds = min(max(project.totalDurationSeconds, 0.1), storyMaxDurationSeconds)
        let frameCount = max(Int(ceil(durationSeconds * Double(fps))), 1)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            let buffer = try await compositor.render(project: project, assetStore: assetStore, at: presentationTime)
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? StoryExportError.frameAppendFailed
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
        progress(1)

        return StoryExportResult(
            url: finalURL,
            mimeType: "video/mp4",
            mediaType: "video",
            duration: max(1, Int(ceil(durationSeconds)))
        )
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

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
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
