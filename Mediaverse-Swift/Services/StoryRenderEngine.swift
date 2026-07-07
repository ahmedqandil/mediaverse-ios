import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import UIKit

final class StoryRenderEngine {
    static let shared = StoryRenderEngine()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    func makeCanvasBuffer(canvas: CanvasSpec) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            canvas.width,
            canvas.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw StoryRenderError.pixelBufferCreationFailed
        }
        return pixelBuffer
    }

    func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    func render(_ image: CIImage, to pixelBuffer: CVPixelBuffer, bounds: CGRect) {
        ciContext.render(image, to: pixelBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

protocol FrameSource {
    func image(at time: CMTime) async throws -> CIImage?
    var naturalSize: CGSize { get async throws }
    var preferredTransform: CGAffineTransform { get async throws }
}

struct ImageFrameSource: FrameSource {
    let imageURL: URL

    func image(at time: CMTime) async throws -> CIImage? {
        CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true])
    }

    var naturalSize: CGSize {
        get async throws {
            guard let image = UIImage(contentsOfFile: imageURL.path) else { return .zero }
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
    }

    var preferredTransform: CGAffineTransform {
        get async throws { .identity }
    }
}

final class AssetReaderFrameSource: FrameSource {
    private let asset: AVAsset
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        self.asset = AVAsset(url: url)
        self.generator = AVAssetImageGenerator(asset: asset)
        self.generator.appliesPreferredTrackTransform = true
        self.generator.requestedTimeToleranceBefore = .zero
        self.generator.requestedTimeToleranceAfter = .zero
    }

    func image(at time: CMTime) async throws -> CIImage? {
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        return CIImage(cgImage: image)
    }

    var naturalSize: CGSize {
        get async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .zero }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = size.applying(transform)
            return CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }
    }

    var preferredTransform: CGAffineTransform {
        get async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .identity }
            return try await track.load(.preferredTransform)
        }
    }
}

struct RenderedOverlay {
    let image: CIImage
    let frame: CGRect
    let opacity: CGFloat
}

struct StoryEffectGraph {
    func render(sourceImage: CIImage, time: CMTime, clip: VideoClip, overlays: [RenderedOverlay], canvas: CanvasSpec) -> CIImage {
        var image = sourceImage
        image = applyColorAdjustments(clip.adjustments, to: image)
        image = applyTransform(clip.transform, crop: clip.cropRect, to: image, canvas: canvas)
        image = composite(overlays: overlays, over: image)
        return image
    }

    private func applyColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output = image

        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }

        if adjustments.warmth != 0, let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.setValue(output, forKey: kCIInputImageKey)
            temperature.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature.setValue(CIVector(x: 6500 + CGFloat(adjustments.warmth) * 1400, y: 0), forKey: "inputTargetNeutral")
            output = temperature.outputImage ?? output
        }

        if adjustments.vignette > 0, let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(output, forKey: kCIInputImageKey)
            vignette.setValue(adjustments.vignette, forKey: kCIInputIntensityKey)
            vignette.setValue(max(output.extent.width, output.extent.height) * 0.75, forKey: kCIInputRadiusKey)
            output = vignette.outputImage ?? output
        }

        return output
    }

    private func applyTransform(_ transform: Transform2D, crop: NormalizedRect?, to image: CIImage, canvas: CanvasSpec) -> CIImage {
        var working = image
        if let crop {
            let rect = CGRect(
                x: image.extent.minX + image.extent.width * crop.x,
                y: image.extent.minY + image.extent.height * crop.y,
                width: image.extent.width * crop.w,
                height: image.extent.height * crop.h
            )
            working = working.cropped(to: rect)
        }

        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        let scale = max(canvasSize.width / max(working.extent.width, 1), canvasSize.height / max(working.extent.height, 1)) * transform.scale
        var affine = CGAffineTransform(translationX: -working.extent.midX, y: -working.extent.midY)
        affine = affine.rotated(by: transform.rotation)
        affine = affine.scaledBy(x: scale, y: scale)
        affine = affine.translatedBy(
            x: (canvasSize.width / 2 + transform.tx) / max(scale, 0.0001),
            y: (canvasSize.height / 2 + transform.ty) / max(scale, 0.0001)
        )
        working = working.transformed(by: affine)
        return working.cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    private func composite(overlays: [RenderedOverlay], over image: CIImage) -> CIImage {
        overlays.reduce(image) { current, overlay in
            let overlayImage = overlay.image
                .transformed(by: CGAffineTransform(
                    translationX: overlay.frame.minX - overlay.image.extent.minX,
                    y: overlay.frame.minY - overlay.image.extent.minY
                ))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: overlay.opacity)
                ])
            return overlayImage.composited(over: current)
        }
    }
}

actor StoryCompositor {
    private let engine: StoryRenderEngine
    private let effectGraph: StoryEffectGraph

    init(engine: StoryRenderEngine = .shared, effectGraph: StoryEffectGraph = StoryEffectGraph()) {
        self.engine = engine
        self.effectGraph = effectGraph
    }

    func render(project: Project, assetStore: AssetStore, at timelineTime: CMTime) async throws -> CVPixelBuffer {
        guard let clip = activeClip(in: project, at: timelineTime) else {
            return try backgroundBuffer(for: project.canvas)
        }

        let sourceTime = sourceTime(for: clip, project: project, timelineTime: timelineTime)
        let source = frameSource(for: clip.assetRef, assetStore: assetStore)
        guard let sourceImage = try await source.image(at: sourceTime) else {
            return try backgroundBuffer(for: project.canvas)
        }

        let rendered = effectGraph.render(
            sourceImage: sourceImage,
            time: timelineTime,
            clip: clip,
            overlays: try await renderedOverlays(in: project, assetStore: assetStore, at: timelineTime),
            canvas: project.canvas
        )
        let output = try engine.makeCanvasBuffer(canvas: project.canvas)
        engine.render(rendered, to: output, bounds: CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height))
        return output
    }

    private func activeClip(in project: Project, at time: CMTime) -> VideoClip? {
        var cursor = CMTime.zero
        for clip in project.tracks.videoClips {
            let end = cursor + clip.timelineDuration
            if time >= cursor && time < end {
                return clip
            }
            cursor = end
        }
        return project.tracks.videoClips.last
    }

    private func sourceTime(for clip: VideoClip, project: Project, timelineTime: CMTime) -> CMTime {
        var cursor = CMTime.zero
        for candidate in project.tracks.videoClips {
            if candidate.id == clip.id { break }
            cursor = cursor + candidate.timelineDuration
        }
        let local = max((timelineTime - cursor).seconds, 0)
        let sourceSeconds = clip.sourceStartSeconds + (local * max(clip.speed, 0.01))
        if clip.reversed {
            let reversedSeconds = clip.sourceStartSeconds + max(clip.sourceDurationSeconds - (local * max(clip.speed, 0.01)), 0)
            return CMTime(seconds: reversedSeconds, preferredTimescale: projectTimeScale)
        }
        return CMTime(seconds: sourceSeconds, preferredTimescale: projectTimeScale)
    }

    private func frameSource(for assetRef: AssetRef, assetStore: AssetStore) -> FrameSource {
        let url = assetStore.absoluteURL(for: assetRef.relativePath)
        switch assetRef.kind {
        case .image:
            return ImageFrameSource(imageURL: url)
        case .video, .audio:
            return AssetReaderFrameSource(url: url)
        }
    }

    private func renderedOverlays(in project: Project, assetStore: AssetStore, at time: CMTime) async throws -> [RenderedOverlay] {
        var rendered: [RenderedOverlay] = []
        for overlay in project.tracks.overlays {
            switch overlay {
            case .text(let text):
                guard text.isActive(at: time), let image = makeTextOverlayImage(text) else { continue }
                rendered.append(positionedOverlay(image: image, transform: text.transform, canvas: project.canvas))
            case .sticker(let sticker):
                guard sticker.isActive(at: time), let image = try await makeStickerOverlayImage(sticker, assetStore: assetStore, at: time) else { continue }
                rendered.append(positionedOverlay(image: image, transform: sticker.transform, canvas: project.canvas))
            case .drawing(let drawing):
                guard drawing.isActive(at: time),
                      let image = CIImage(contentsOf: assetStore.absoluteURL(for: drawing.assetRef.relativePath)) else { continue }
                rendered.append(positionedOverlay(image: image, transform: drawing.transform, canvas: project.canvas))
            case .link(let link):
                guard link.isActive(at: time), let image = makeLinkOverlayImage(link) else { continue }
                rendered.append(positionedOverlay(image: image, transform: link.transform, canvas: project.canvas))
            case .interactive(let interactive):
                guard interactive.isActive(at: time), let image = makeInteractiveOverlayImage(interactive) else { continue }
                rendered.append(positionedOverlay(image: image, transform: interactive.transform, canvas: project.canvas))
            }
        }
        return rendered
    }

    private func positionedOverlay(image: CIImage, transform: Transform2D, canvas: CanvasSpec) -> RenderedOverlay {
        let canvasWidth = CGFloat(canvas.width)
        let canvasHeight = CGFloat(canvas.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale).rotated(by: transform.rotation))
        let size = scaled.extent.size
        let centerX = canvasWidth / 2 + transform.tx
        let centerY = canvasHeight / 2 - transform.ty
        return RenderedOverlay(
            image: scaled,
            frame: CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height),
            opacity: 1
        )
    }

    private func makeTextOverlayImage(_ overlay: TextOverlay) -> CIImage? {
        let font = overlay.style.fontName.flatMap { UIFont(name: $0, size: overlay.style.fontSize) }
            ?? UIFont.systemFont(ofSize: overlay.style.fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = overlay.style.nsAlignment
        let maxWidth: CGFloat = 860
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: overlay.style.color.uiColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: overlay.text, attributes: attributes)
        let textRect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let padding = CGSize(width: 34, height: 22)
        let imageSize = CGSize(width: min(maxWidth, textRect.width) + padding.width * 2, height: textRect.height + padding.height * 2)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: imageSize)
            if let background = overlay.style.backgroundColor {
                background.uiColor.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 18).fill()
            }
            if overlay.style.shadow {
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            }
            attributed.draw(in: CGRect(x: padding.width, y: padding.height, width: imageSize.width - padding.width * 2, height: imageSize.height - padding.height * 2))
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func makeLinkOverlayImage(_ overlay: LinkOverlay) -> CIImage? {
        let iconFont = UIFont.systemFont(ofSize: 42, weight: .bold)
        let textFont = UIFont.systemFont(ofSize: 44, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: UIColor.black
        ]
        let text = String(overlay.label.prefix(32))
        let textRect = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let width = min(max(textRect.width + 124, 260), 760)
        let size = CGSize(width: width, height: 104)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 52).fill()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: UIColor.black.withAlphaComponent(0.22).cgColor)
            let icon = NSAttributedString(string: "LINK", attributes: [.font: iconFont, .foregroundColor: UIColor.black])
            icon.draw(in: CGRect(x: 28, y: 29, width: 70, height: 48))
            NSAttributedString(string: text, attributes: attributes).draw(in: CGRect(x: 112, y: 26, width: width - 140, height: 56))
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func makeStickerOverlayImage(_ overlay: StickerOverlay, assetStore: AssetStore, at time: CMTime) async throws -> CIImage? {
        if let assetRef = overlay.assetRef {
            let url = assetStore.absoluteURL(for: assetRef.relativePath)
            switch assetRef.kind {
            case .image:
                return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            case .video:
                let localSeconds = max((time - overlay.timeRange.start.time).seconds, 0)
                let sourceTime = CMTime(seconds: min(localSeconds, max(assetRef.durationSeconds - 0.05, 0)), preferredTimescale: projectTimeScale)
                return try await AssetReaderFrameSource(url: url).image(at: sourceTime)
            case .audio:
                return nil
            }
        }

        guard let emoji = overlay.emoji, !emoji.isEmpty else { return nil }
        let font = UIFont.systemFont(ofSize: 150)
        let attributed = NSAttributedString(string: emoji, attributes: [.font: font])
        let rect = attributed.boundingRect(
            with: CGSize(width: 220, height: 220),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let size = CGSize(width: max(rect.width + 24, 176), height: max(rect.height + 24, 176))
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: UIColor.black.withAlphaComponent(0.38).cgColor)
            attributed.draw(in: CGRect(x: (size.width - rect.width) / 2, y: (size.height - rect.height) / 2, width: rect.width, height: rect.height))
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func makeInteractiveOverlayImage(_ overlay: StoryInteractiveOverlay) -> CIImage? {
        let titleFont = UIFont.systemFont(ofSize: 46, weight: .heavy)
        let bodyFont = UIFont.systemFont(ofSize: 34, weight: .bold)
        let title = overlay.title.isEmpty ? overlay.kind.rawValue.capitalized : overlay.title
        let subtitle = overlay.subtitle ?? interactiveSubtitle(for: overlay)
        let options = overlay.options.isEmpty ? defaultOptions(for: overlay.kind) : overlay.options

        let width: CGFloat = overlay.kind == .mention || overlay.kind == .location ? 520 : 700
        let optionHeight: CGFloat = options.isEmpty ? 0 : CGFloat(options.count) * 58 + 18
        let subtitleHeight: CGFloat = subtitle == nil ? 0 : 44
        let height = max(112, 116 + subtitleHeight + optionHeight)
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.withAlphaComponent(0.94).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 28).fill()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: UIColor.black.withAlphaComponent(0.22).cgColor)

            let tint = UIColor(red: 0, green: 0.9, blue: 0.46, alpha: 1)
            tint.setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 22, width: 7, height: height - 44), cornerRadius: 3.5).fill()

            let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.black]
            NSAttributedString(string: title, attributes: titleAttributes)
                .draw(in: CGRect(x: 48, y: 24, width: width - 76, height: 58))

            var cursorY: CGFloat = 82
            if let subtitle {
                let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.darkGray]
                NSAttributedString(string: subtitle, attributes: attributes)
                    .draw(in: CGRect(x: 48, y: cursorY, width: width - 76, height: 42))
                cursorY += 48
            }

            for option in options.prefix(4) {
                UIColor.black.withAlphaComponent(0.08).setFill()
                let optionRect = CGRect(x: 48, y: cursorY, width: width - 96, height: 44)
                UIBezierPath(roundedRect: optionRect, cornerRadius: 22).fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                NSAttributedString(string: option, attributes: attributes)
                    .draw(in: optionRect.insetBy(dx: 18, dy: 4))
                cursorY += 58
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func interactiveSubtitle(for overlay: StoryInteractiveOverlay) -> String? {
        switch overlay.kind {
        case .question: return "Reply with text"
        case .addYours: return "Join the prompt"
        case .countdown:
            guard let date = overlay.targetDate else { return "Countdown" }
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        default: return overlay.subtitle
        }
    }

    private func defaultOptions(for kind: StoryInteractiveStickerKind) -> [String] {
        switch kind {
        case .poll: return ["Yes", "No"]
        case .quiz: return ["A", "B", "C"]
        default: return []
        }
    }

    private func backgroundBuffer(for canvas: CanvasSpec) throws -> CVPixelBuffer {
        let output = try engine.makeCanvasBuffer(canvas: canvas)
        let color = CIColor(
            red: CGFloat(canvas.backgroundColor.r),
            green: CGFloat(canvas.backgroundColor.g),
            blue: CGFloat(canvas.backgroundColor.b),
            alpha: CGFloat(canvas.backgroundColor.a)
        )
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        engine.render(image, to: output, bounds: image.extent)
        return output
    }
}

private extension TextOverlay {
    func isActive(at time: CMTime) -> Bool {
        timeRange.contains(time)
    }
}

private extension StickerOverlay {
    func isActive(at time: CMTime) -> Bool {
        timeRange.contains(time)
    }
}

private extension DrawingOverlay {
    func isActive(at time: CMTime) -> Bool {
        timeRange.contains(time)
    }
}

private extension LinkOverlay {
    func isActive(at time: CMTime) -> Bool {
        timeRange.contains(time)
    }
}

private extension StoryInteractiveOverlay {
    func isActive(at time: CMTime) -> Bool {
        timeRange.contains(time)
    }
}

private extension TimelineRange {
    func contains(_ time: CMTime) -> Bool {
        let end = start.time + duration.time
        return time >= start.time && time <= end
    }
}

private extension TextOverlayStyle {
    var nsAlignment: NSTextAlignment {
        switch alignment.lowercased() {
        case "left": return .left
        case "right": return .right
        default: return .center
        }
    }
}

private extension RGBAColor {
    var uiColor: UIColor {
        UIColor(
            red: min(max(r, 0), 1),
            green: min(max(g, 0), 1),
            blue: min(max(b, 0), 1),
            alpha: min(max(a, 0), 1)
        )
    }
}

enum StoryRenderError: LocalizedError {
    case pixelBufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .pixelBufferCreationFailed:
            return "Could not create a render target for the story canvas."
        }
    }
}
