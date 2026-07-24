import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Metal
import UIKit
#if canImport(MetalPetal)
import MetalPetal
#endif

enum StoryAnimatedImage {
    static func frame(at seconds: Double, from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return frame(at: seconds, source: source)
    }

    static func frame(at seconds: Double, from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return frame(at: seconds, source: source)
    }

    private static func frame(at seconds: Double, source: CGImageSource) -> CGImage? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        let durations = (0..<count).map { frameDuration(source: source, index: $0) }
        let totalDuration = durations.reduce(0, +)
        guard totalDuration > 0 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }

        var cursor = max(seconds, 0).truncatingRemainder(dividingBy: totalDuration)
        for (index, duration) in durations.enumerated() {
            if cursor < duration {
                return CGImageSourceCreateImageAtIndex(source, index, [
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            cursor -= duration
        }
        return CGImageSourceCreateImageAtIndex(source, count - 1, nil)
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? 0.1, 0.02)
    }
}

func storyLoopedMediaTime(elapsed: Double, duration: Double) -> Double {
    guard elapsed.isFinite, duration.isFinite, duration > 0 else { return 0 }
    return max(elapsed, 0).truncatingRemainder(dividingBy: duration)
}

private extension StoryRenderEffect {
    var usesCoreImagePipeline: Bool {
        switch self {
        case .skinSmooth, .glow, .comic, .edges, .crystallize, .kaleidoscope:
            return true
        default:
            return false
        }
    }

    var usesTimelineAnimation: Bool {
        switch self {
        case .vhs, .lightLeak, .chromatic:
            return true
        default:
            return false
        }
    }
}

#if canImport(MetalPetal)
final class MetalPetalStoryFilterProcessor {
    static let shared = MetalPetalStoryFilterProcessor()

    private let device: MTLDevice?
    private let context: MTIContext?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            context = nil
            return
        }
        self.device = device
        context = try? MTIContext(device: device)
    }

    func applyBasicColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage? {
        guard let context else { return nil }

        var output = MTIImage(ciImage: image, isOpaque: true)
        if adjustments.brightness != 0 {
            output = output.adjusting(brightness: adjustments.brightness)
        }
        if abs(adjustments.contrast - 1) > 0.001 {
            output = output.adjusting(contrast: adjustments.contrast)
        }
        if abs(adjustments.saturation - 1) > 0.001 {
            output = output.adjusting(saturation: adjustments.saturation)
        }
        if adjustments.saturation > 1.001 {
            output = output.adjusting(vibrance: min((adjustments.saturation - 1) * 0.55, 1))
        }

        return try? context.makeCIImage(from: output)
    }

    func applyRenderEffect(_ effect: StoryRenderEffect, to image: CIImage) -> CIImage? {
        guard let context else { return nil }
        let input = MTIImage(ciImage: image, isOpaque: true)
        guard let output = applyRenderEffect(effect, to: input) else { return nil }
        return try? context.makeCIImage(from: output)
    }

    func livePreviewImage(
        from pixelBuffer: CVPixelBuffer,
        filterId: String?,
        adjustments: ColorAdjust,
        effectStack: StoryEffectStack? = nil
    ) -> MTIImage? {
        guard let context else { return nil }
        let preset = StoryEffectCatalog.preset(id: filterId)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let stack = effectStack
        let lookInput: CIImage
        if let stack,
           stack.version >= StoryEffectStack.currentVersion,
           let lut = preset.lut {
            lookInput = StoryColorLUT.apply(lut, to: source)
        } else {
            lookInput = source
        }
        var output = MTIImage(ciImage: lookInput, isOpaque: true)
        if adjustments.brightness != 0 {
            output = output.adjusting(brightness: adjustments.brightness)
        }
        if abs(adjustments.contrast - 1) > 0.001 {
            output = output.adjusting(contrast: adjustments.contrast)
        }
        if abs(adjustments.saturation - 1) > 0.001 {
            output = output.adjusting(saturation: adjustments.saturation)
        }
        if adjustments.saturation > 1.001 {
            output = output.adjusting(vibrance: min((adjustments.saturation - 1) * 0.55, 1))
        }
        if preset.renderEffect.usesCoreImagePipeline,
           let ciOutput = try? context.makeCIImage(from: output) {
            let filtered = StoryCoreImageEffects.smoothSkin(ciOutput)
            return MTIImage(ciImage: filtered, isOpaque: true)
        }
        guard var rendered = applyRenderEffect(preset.renderEffect, to: output) else { return nil }
        if let stack, stack.beauty.isEnabled,
           let ciOutput = try? context.makeCIImage(from: rendered) {
            rendered = MTIImage(
                ciImage: StoryCoreImageEffects.faceAwareBeauty(ciOutput, settings: stack.beauty),
                isOpaque: true
            )
        }
        for effect in stack?.creativeEffects ?? [] where effect != .none && effect != .skinSmooth {
            guard let effectOutput = applyRenderEffect(effect, to: rendered) else { continue }
            if let base = try? context.makeCIImage(from: rendered),
               let target = try? context.makeCIImage(from: effectOutput) {
                let amount = min(max(stack?.creativeEffectIntensity ?? 1, 0), 1)
                let mask = CIImage(
                    color: CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount), alpha: 1)
                ).cropped(to: base.extent)
                let blended = target.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: mask
                ])
                rendered = MTIImage(ciImage: blended, isOpaque: true)
            } else {
                rendered = effectOutput
            }
        }
        return rendered
    }

    private func applyRenderEffect(_ effect: StoryRenderEffect, to input: MTIImage) -> MTIImage? {
        let output: MTIImage?

        switch effect {
        case .none:
            output = input
        case .clarify:
            let filter = MTICLAHEFilter()
            filter.inputImage = input
            filter.clipLimit = 2.0
            filter.tileGridSize = MTICLAHESize(width: 8, height: 8)
            output = filter.outputImage
        case .softBlur:
            let filter = MTIMPSGaussianBlurFilter()
            filter.inputImage = input
            filter.radius = 4
            output = filter.outputImage
        case .pixel:
            let filter = MTIPixellateFilter()
            filter.inputImage = input
            filter.scale = CGSize(width: 18, height: 18)
            output = filter.outputImage
        case .dotScreen:
            let filter = MTIDotScreenFilter()
            filter.inputImage = input
            filter.angle = 0.35
            filter.scale = 6
            output = filter.outputImage
        case .halftone:
            let filter = MTIColorHalftoneFilter()
            filter.inputImage = input
            filter.scale = 8
            filter.angles = SIMD4<Float>(0.35, 0.75, 1.15, 0)
            output = filter.outputImage
        case .sharpen:
            let filter = MTIMPSUnsharpMaskFilter()
            filter.inputImage = input
            filter.radius = 2.2
            filter.scale = 0.55
            filter.threshold = 0.02
            output = filter.outputImage
        case .skinSmooth:
            if let device, MTIHighPassSkinSmoothingFilter.isSupported(on: device) {
                let filter = MTIHighPassSkinSmoothingFilter()
                filter.inputImage = input
                filter.amount = 0.82
                filter.radius = 10
                output = filter.outputImage
            } else {
                output = input
            }
        case .glow, .comic, .edges, .crystallize, .kaleidoscope, .vhs, .lightLeak, .chromatic:
            output = input
        }

        return output
    }
}
#endif

private struct StoryDetectedFace {
    let bounds: CGRect
    let leftEyePosition: CGPoint?
    let rightEyePosition: CGPoint?
    let mouthPosition: CGPoint?
}

private final class StoryFaceAnalyzer: @unchecked Sendable {
    private let detector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyLow]
    )
    private let lock = NSLock()
    private let maximumAnalysisSide: CGFloat = 360

    func faces(in image: CIImage) -> [StoryDetectedFace] {
        guard let detector else { return [] }
        let extent = image.extent
        let longestSide = max(extent.width, extent.height)
        guard longestSide > 0 else { return [] }

        let scale = min(maximumAnalysisSide / longestSide, 1)
        let analysisImage = image
            .transformed(by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        lock.lock()
        let features = detector.features(in: analysisImage).compactMap { $0 as? CIFaceFeature }
        lock.unlock()

        func fullResolutionPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x / scale + extent.minX,
                y: point.y / scale + extent.minY
            )
        }

        return features.map { feature in
            StoryDetectedFace(
                bounds: CGRect(
                    x: feature.bounds.minX / scale + extent.minX,
                    y: feature.bounds.minY / scale + extent.minY,
                    width: feature.bounds.width / scale,
                    height: feature.bounds.height / scale
                ),
                leftEyePosition: feature.hasLeftEyePosition
                    ? fullResolutionPoint(feature.leftEyePosition)
                    : nil,
                rightEyePosition: feature.hasRightEyePosition
                    ? fullResolutionPoint(feature.rightEyePosition)
                    : nil,
                mouthPosition: feature.hasMouthPosition
                    ? fullResolutionPoint(feature.mouthPosition)
                    : nil
            )
        }
    }
}

private enum StoryCoreImageEffects {
    private static let faceAnalyzer = StoryFaceAnalyzer()

    static func smoothSkin(_ image: CIImage, smoothness: Float = 8.0, intensity: Float = 0.6) -> CIImage {
        blendedSkinSmoothing(image, smoothness: smoothness, intensity: intensity)
    }

    static func faceAwareBeauty(_ image: CIImage, settings: StoryBeautySettings) -> CIImage {
        let settings = settings.clamped()
        guard settings.isEnabled else { return image }
        let faces = faceAnalyzer.faces(in: image)
        guard !faces.isEmpty else {
            return fallbackBeauty(image, settings: settings)
        }

        let smoothing = max(settings.skinSmoothing * settings.intensity, 0)
        var target = smoothing > 0.001
            ? blendedSkinSmoothing(
                image,
                smoothness: 6 + smoothing * 16,
                intensity: min(0.30 + smoothing * 0.90, 0.93)
            )
            : image

        let brightness = settings.brightness * settings.intensity * 0.16
        if abs(brightness) > 0.001 {
            target = target.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness
            ])
        }

        let tone = settings.skinTone * settings.intensity
        if abs(tone) > 0.001 {
            target = target.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + CGFloat(tone) * 650, y: 0)
            ])
        }

        guard let mask = faceMask(for: faces, extent: image.extent, intensity: settings.intensity) else {
            return image
        }
        var result = target.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
        result = applyFeatureBeauty(
            to: result,
            faces: faces,
            settings: settings
        )
        return result
    }

    private static func fallbackBeauty(
        _ image: CIImage,
        settings: StoryBeautySettings
    ) -> CIImage {
        let settings = settings.clamped()
        let smoothing = settings.skinSmoothing * settings.intensity
        var output = image
        if smoothing > 0.001 {
            output = blendedSkinSmoothing(
                output,
                smoothness: 6 + smoothing * 14,
                intensity: min(0.24 + smoothing * 0.72, 0.82)
            )
        }

        let brightness = settings.brightness * settings.intensity * 0.10
        if abs(brightness) > 0.001 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness
            ])
        }

        let tone = settings.skinTone * settings.intensity
        if abs(tone) > 0.001 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + CGFloat(tone) * 420, y: 0)
            ])
        }
        return output.cropped(to: image.extent)
    }

    private static func applyFeatureBeauty(
        to image: CIImage,
        faces: [StoryDetectedFace],
        settings: StoryBeautySettings
    ) -> CIImage {
        var result = image
        let master = settings.intensity

        for face in faces {
            let unit = max(min(face.bounds.width, face.bounds.height), 1)

            if settings.eyeBrightening > 0.001 {
                let target = result
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputBrightnessKey: 0.10 * settings.eyeBrightening * master,
                        kCIInputSaturationKey: 1 + 0.08 * settings.eyeBrightening * master
                    ])
                    .applyingFilter("CISharpenLuminance", parameters: [
                        kCIInputSharpnessKey: 0.22 * settings.eyeBrightening * master
                    ])
                for position in eyePositions(face) {
                    let mask = radialMask(
                        center: position,
                        radius: unit * 0.115,
                        extent: image.extent,
                        intensity: settings.eyeBrightening * master
                    )
                    result = blend(base: result, target: target, mask: mask)
                }
            }

            if settings.underEye > 0.001 {
                let target = result.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.075 * settings.underEye * master,
                    kCIInputContrastKey: 0.98
                ])
                for position in eyePositions(face) {
                    let underEyeCenter = CGPoint(x: position.x, y: position.y - unit * 0.055)
                    let mask = radialMask(
                        center: underEyeCenter,
                        radius: unit * 0.13,
                        extent: image.extent,
                        intensity: settings.underEye * master
                    )
                    result = blend(base: result, target: target, mask: mask)
                }
            }

            if let mouthPosition = face.mouthPosition, settings.teethWhitening > 0.001 {
                let target = result.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.12 * settings.teethWhitening * master,
                    kCIInputSaturationKey: max(1 - 0.72 * settings.teethWhitening * master, 0)
                ])
                let center = CGPoint(x: mouthPosition.x, y: mouthPosition.y + unit * 0.012)
                let mask = radialMask(
                    center: center,
                    radius: unit * 0.085,
                    extent: image.extent,
                    intensity: settings.teethWhitening * master
                )
                result = blend(base: result, target: target, mask: mask)
            }

            if let mouthPosition = face.mouthPosition, abs(settings.lipColor) > 0.001 {
                let amount = settings.lipColor * master
                let target = result
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: 1 + abs(amount) * 0.38
                    ])
                    .applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: 6500, y: 0),
                        "inputTargetNeutral": CIVector(x: 6500 + CGFloat(amount) * 900, y: 0)
                    ])
                let mask = radialMask(
                    center: mouthPosition,
                    radius: unit * 0.105,
                    extent: image.extent,
                    intensity: abs(amount)
                )
                result = blend(base: result, target: target, mask: mask)
            }

            if settings.contour > 0.001 {
                let amount = settings.contour * master
                let uncontoured = result
                let darkened = uncontoured.applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: -0.34 * amount
                ])
                let outer = radialMask(
                    center: CGPoint(x: face.bounds.midX, y: face.bounds.midY),
                    radius: unit * 0.58,
                    extent: image.extent,
                    intensity: amount
                )
                result = blend(base: result, target: darkened, mask: outer)
                let inner = radialMask(
                    center: CGPoint(x: face.bounds.midX, y: face.bounds.midY),
                    radius: unit * 0.36,
                    extent: image.extent,
                    intensity: amount
                )
                result = blend(base: result, target: uncontoured, mask: inner)
            }
        }
        return result.cropped(to: image.extent)
    }

    private static func eyePositions(_ face: StoryDetectedFace) -> [CGPoint] {
        [face.leftEyePosition, face.rightEyePosition].compactMap { $0 }
    }

    private static func radialMask(
        center: CGPoint,
        radius: CGFloat,
        extent: CGRect,
        intensity: Float
    ) -> CIImage {
        let amount = CGFloat(min(max(intensity, 0), 1))
        let mask = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": CIVector(cgPoint: center),
                "inputRadius0": radius * 0.38,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: amount, green: amount, blue: amount, alpha: amount),
                "inputColor1": CIColor.clear
            ]
        )?.outputImage
        return (mask ?? CIImage.empty()).cropped(to: extent)
    }

    private static func blend(base: CIImage, target: CIImage, mask: CIImage) -> CIImage {
        target.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: mask
        ]).cropped(to: base.extent)
    }

    private static func faceMask(
        for faces: [StoryDetectedFace],
        extent: CGRect,
        intensity: Float
    ) -> CIImage? {
        var combined: CIImage?
        for face in faces {
            let bounds = face.bounds.insetBy(
                dx: -face.bounds.width * 0.12,
                dy: -face.bounds.height * 0.16
            )
            let radius = max(bounds.width, bounds.height) * 0.58
            let gradient = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(x: bounds.midX, y: bounds.midY),
                    "inputRadius0": radius * 0.62,
                    "inputRadius1": radius,
                    "inputColor0": CIColor.white,
                    "inputColor1": CIColor.clear
                ]
            )?.outputImage?.cropped(to: extent)
            guard let gradient else { continue }
            combined = combined.map {
                gradient.applyingFilter("CIMaximumCompositing", parameters: [
                    kCIInputBackgroundImageKey: $0
                ])
            } ?? gradient
        }
        guard let combined else { return nil }
        let amount = CGFloat(min(max(intensity, 0), 1))
        return combined.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
        ]).cropped(to: extent)
    }

    private static func blendedSkinSmoothing(_ image: CIImage, smoothness: Float, intensity: Float) -> CIImage {
        guard let bilateralFilter = CIFilter(name: "CIBilateralFilter") else {
            return gaussianSmoothFallback(image)
        }
        bilateralFilter.setValue(image, forKey: kCIInputImageKey)
        if bilateralFilter.inputKeys.contains("inputDistance") {
            bilateralFilter.setValue(smoothness, forKey: "inputDistance")
        }
        if bilateralFilter.inputKeys.contains("inputSigmaR") {
            bilateralFilter.setValue(0.03, forKey: "inputSigmaR")
        }
        guard let smoothedImage = bilateralFilter.outputImage?.cropped(to: image.extent) else {
            return gaussianSmoothFallback(image)
        }

        return mix(base: image, target: smoothedImage, amount: intensity)
    }

    private static func mix(base: CIImage, target: CIImage, amount: Float) -> CIImage {
        guard let blendFilter = CIFilter(name: "CIMix") else {
            return target
        }
        blendFilter.setValue(base, forKey: kCIInputImageKey)
        if blendFilter.inputKeys.contains("inputTargetImage") {
            blendFilter.setValue(target, forKey: "inputTargetImage")
        } else if blendFilter.inputKeys.contains(kCIInputBackgroundImageKey) {
            blendFilter.setValue(target, forKey: kCIInputBackgroundImageKey)
        } else {
            return target
        }
        if blendFilter.inputKeys.contains("inputAmount") {
            blendFilter.setValue(amount, forKey: "inputAmount")
        }
        return blendFilter.outputImage?.cropped(to: base.extent) ?? target
    }

    private static func gaussianSmoothFallback(_ image: CIImage) -> CIImage {
        let smoothed = image.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 1.8
        ]).cropped(to: image.extent)
        return mix(base: image, target: smoothed, amount: 0.45)
    }
}

enum StoryFrameFilterRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func renderPreviewImage(from pixelBuffer: CVPixelBuffer, filterId: String?, intensity: Float = 1, adjustments: ColorAdjust) -> UIImage? {
        guard hasActiveFilter(filterId: filterId, intensity: intensity, adjustments: adjustments) else { return nil }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let longestSide = max(source.extent.width, source.extent.height)
        let scale = min(1, 1080 / max(longestSide, 1))
        let previewInput = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let output = filteredCIImage(previewInput, filterId: filterId, intensity: intensity, adjustments: adjustments),
              let cgImage = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
    }

    static func renderImage(_ image: UIImage, filterId: String?, intensity: Float = 1, adjustments: ColorAdjust) -> UIImage {
        guard hasActiveFilter(filterId: filterId, intensity: intensity, adjustments: adjustments),
              let input = CIImage(image: image),
              let output = filteredCIImage(input, filterId: filterId, intensity: intensity, adjustments: adjustments),
              let cgImage = ciContext.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    static func hasActiveFilter(filterId: String?, intensity: Float = 1, adjustments: ColorAdjust) -> Bool {
        guard intensity > 0.001 else { return false }
        guard let filterId else { return adjustments != .neutral }
        return filterId != StoryEffectCatalog.presets.first?.id || adjustments != .neutral
    }

    static func filteredCIImage(_ image: CIImage, filterId: String?, intensity: Float = 1, adjustments: ColorAdjust) -> CIImage? {
        let preset = StoryEffectCatalog.preset(id: filterId)
        var output = applyColorAdjustments(adjustments, to: image)
        output = applyRenderEffect(preset.renderEffect, to: output)
        return blend(source: image, filtered: output, intensity: intensity)
    }

    static func realtimePreviewCIImage(
        _ image: CIImage,
        filterId: String?,
        intensity: Float = 1,
        adjustments: ColorAdjust,
        effectStack: StoryEffectStack? = nil,
        time: Double = 0
    ) -> CIImage? {
        let stack: StoryEffectStack = {
            if let effectStack { return effectStack }
            var legacy = StoryEffectStack.none
            legacy.version = 0
            legacy.lookId = filterId
            legacy.lookIntensity = intensity
            return legacy
        }()
        let preset = StoryEffectCatalog.preset(id: stack.lookId)
        var lookInput = image
        if stack.version >= StoryEffectStack.currentVersion, let lut = preset.lut {
            lookInput = StoryColorLUT.apply(lut, to: lookInput)
        }
        var output = applyCoreImageBasicColorAdjustments(adjustments, to: lookInput)
        output = applyCoreImageFinishingAdjustments(adjustments, to: output)
        output = applyCoreImageFallbackEffect(preset.renderEffect, to: output)
        output = blend(source: image, filtered: output, intensity: stack.lookIntensity)
        if stack.beauty.isEnabled {
            output = StoryCoreImageEffects.faceAwareBeauty(output, settings: stack.beauty)
        }
        for effect in stack.creativeEffects where effect != .none && effect != .skinSmooth {
            let target = effect.usesTimelineAnimation
                ? StoryAnimatedEffects.apply(effect, to: output, time: time)
                : applyCoreImageFallbackEffect(effect, to: output)
            output = blend(
                source: output,
                filtered: target,
                intensity: stack.creativeEffectIntensity
            )
        }
        return output.cropped(to: image.extent)
    }

    private static func blend(source: CIImage, filtered: CIImage, intensity: Float) -> CIImage {
        let amount = min(max(intensity, 0), 1)
        guard amount < 0.999 else { return filtered.cropped(to: source.extent) }
        guard amount > 0.001 else { return source }
        return filtered
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: CIImage(
                    color: CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount), alpha: 1)
                ).cropped(to: source.extent)
            ])
            .cropped(to: source.extent)
    }

    private static func applyColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output: CIImage
        #if canImport(MetalPetal)
        output = MetalPetalStoryFilterProcessor.shared.applyBasicColorAdjustments(adjustments, to: image) ?? image
        #else
        output = applyCoreImageBasicColorAdjustments(adjustments, to: image)
        #endif
        output = applyCoreImageFinishingAdjustments(adjustments, to: output)
        return output
    }

    private static func applyCoreImageBasicColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output = image
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        return output
    }

    private static func applyCoreImageFinishingAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output = image
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

    private static func applyRenderEffect(_ effect: StoryRenderEffect, to image: CIImage) -> CIImage {
        guard effect != .none else { return image }
        if effect.usesCoreImagePipeline {
            return applyCoreImageFallbackEffect(effect, to: image)
        }
        #if canImport(MetalPetal)
        if let output = MetalPetalStoryFilterProcessor.shared.applyRenderEffect(effect, to: image) {
            return output
        }
        #endif
        return applyCoreImageFallbackEffect(effect, to: image)
    }

    private static func applyCoreImageFallbackEffect(_ effect: StoryRenderEffect, to image: CIImage) -> CIImage {
        switch effect {
        case .none:
            return image
        case .clarify, .sharpen:
            return image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: effect == .clarify ? 0.35 : 0.65
            ])
        case .softBlur:
            return image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 4
            ]).cropped(to: image.extent)
        case .pixel:
            return image.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: 18
            ]).cropped(to: image.extent)
        case .dotScreen:
            return image.applyingFilter("CIDotScreen", parameters: [
                kCIInputAngleKey: 0.35,
                kCIInputWidthKey: 6,
                kCIInputSharpnessKey: 0.7
            ]).cropped(to: image.extent)
        case .halftone:
            return image.applyingFilter("CIColorPosterize", parameters: [
                "inputLevels": 8
            ])
        case .skinSmooth:
            return StoryCoreImageEffects.smoothSkin(image)
        case .glow:
            return image.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: 12,
                kCIInputIntensityKey: 0.75
            ]).cropped(to: image.extent)
        case .comic:
            return image.applyingFilter("CIComicEffect").cropped(to: image.extent)
        case .edges:
            return image.applyingFilter("CIEdges", parameters: [
                kCIInputIntensityKey: 2.2
            ]).cropped(to: image.extent)
        case .crystallize:
            return image.applyingFilter("CICrystallize", parameters: [
                kCIInputRadiusKey: 24
            ]).cropped(to: image.extent)
        case .kaleidoscope:
            return image.applyingFilter("CIKaleidoscope", parameters: [
                "inputCount": 8,
                "inputAngle": 0
            ]).cropped(to: image.extent)
        case .vhs, .lightLeak, .chromatic:
            return image
        }
    }
}

final class StoryRenderEngine {
    static let shared = StoryRenderEngine()
    static let deviceRGB = CGColorSpaceCreateDeviceRGB()

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
        ciContext.render(image, to: pixelBuffer, bounds: bounds, colorSpace: Self.deviceRGB)
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
    private var generatorConfigurationTask: Task<Void, Error>?

    init(url: URL) {
        self.asset = AVAsset(url: url)
        self.generator = AVAssetImageGenerator(asset: asset)
        self.generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        self.generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.generator.apertureMode = .encodedPixels
    }

    func image(at time: CMTime) async throws -> CIImage? {
        try await configureGeneratorIfNeeded()
        let safeTime = max(time.seconds, 0.05)
        return try autoreleasepool {
            let image = try generator.copyCGImage(
                at: CMTime(seconds: safeTime, preferredTimescale: projectTimeScale),
                actualTime: nil
            )
            return CIImage(cgImage: image)
        }
    }

    var naturalSize: CGSize {
        get async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .zero }
            return try await Self.presentationGeometry(for: track).size
        }
    }

    var preferredTransform: CGAffineTransform {
        get async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .identity }
            return try await Self.presentationGeometry(for: track).transform
        }
    }

    private func configureGeneratorIfNeeded() async throws {
        if let task = generatorConfigurationTask {
            try await task.value
            return
        }

        let task = Task { [asset, generator] in
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                generator.appliesPreferredTrackTransform = true
                return
            }

            let presentation = try await Self.presentationGeometry(for: track)
            if presentation.size != .zero {
                let frameRate = try await track.load(.nominalFrameRate)
                let duration = try await asset.load(.duration)
                let composition = AVMutableVideoComposition()
                composition.renderSize = presentation.size
                composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(Int(round(frameRate)), 30)))

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layerInstruction.setTransform(presentation.transform, at: .zero)
                instruction.layerInstructions = [layerInstruction]
                composition.instructions = [instruction]

                generator.videoComposition = composition
                generator.maximumSize = presentation.size
            } else {
                generator.appliesPreferredTrackTransform = true
            }
        }
        generatorConfigurationTask = task
        try await task.value
    }

    private static func presentationGeometry(for track: AVAssetTrack) async throws -> (size: CGSize, transform: CGAffineTransform) {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(
            width: abs(transformedRect.width).rounded(.toNearestOrAwayFromZero),
            height: abs(transformedRect.height).rounded(.toNearestOrAwayFromZero)
        )
        guard displaySize.width > 0, displaySize.height > 0 else {
            return (.zero, preferredTransform)
        }

        let normalizedTransform = preferredTransform.concatenating(CGAffineTransform(
            translationX: -transformedRect.minX,
            y: -transformedRect.minY
        ))
        return (displaySize, normalizedTransform)
    }
}

struct RenderedOverlay {
    let image: CIImage
    let frame: CGRect
    let opacity: CGFloat
}

struct StoryEffectGraph {
    func render(sourceImage: CIImage, time: CMTime, clip: VideoClip, overlays: [RenderedOverlay], canvas: CanvasSpec, useMetalPetal: Bool = true) -> CIImage {
        let sourceExtent = sourceImage.extent
        let stack = clip.resolvedEffectStack
        let preset = StoryEffectCatalog.preset(id: stack.lookId)
        var lookInput = sourceImage
        if stack.version >= StoryEffectStack.currentVersion, let lut = preset.lut {
            lookInput = StoryColorLUT.apply(lut, to: lookInput)
        }
        var filtered = applyColorAdjustments(clip.adjustments, to: lookInput, useMetalPetal: useMetalPetal).cropped(to: sourceExtent)
        filtered = applyRenderEffect(preset.renderEffect, to: filtered, useMetalPetal: useMetalPetal).cropped(to: sourceExtent)
        var image = blend(source: sourceImage, filtered: filtered, intensity: stack.lookIntensity)
        if stack.beauty.isEnabled {
            image = StoryCoreImageEffects.faceAwareBeauty(image, settings: stack.beauty).cropped(to: sourceExtent)
        }
        for effect in stack.creativeEffects where effect != .none && effect != .skinSmooth {
            let effectOutput = effect.usesTimelineAnimation
                ? StoryAnimatedEffects.apply(effect, to: image, time: time.seconds)
                : applyRenderEffect(effect, to: image, useMetalPetal: useMetalPetal)
            image = blend(source: image, filtered: effectOutput, intensity: stack.creativeEffectIntensity)
        }
        image = applyTransform(clip.transform, crop: clip.cropRect, to: image, canvas: canvas)
        image = composite(overlays: overlays, over: image)
        return image
    }

    private func blend(source: CIImage, filtered: CIImage, intensity: Float) -> CIImage {
        let amount = min(max(intensity, 0), 1)
        guard amount < 0.999 else { return filtered.cropped(to: source.extent) }
        guard amount > 0.001 else { return source }
        let mask = CIImage(
            color: CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount), alpha: 1)
        ).cropped(to: source.extent)
        return filtered
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: mask
            ])
            .cropped(to: source.extent)
    }

    private func applyColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage, useMetalPetal: Bool) -> CIImage {
        var output: CIImage

        #if canImport(MetalPetal)
        output = useMetalPetal ? (MetalPetalStoryFilterProcessor.shared.applyBasicColorAdjustments(adjustments, to: image) ?? image) : applyCoreImageBasicColorAdjustments(adjustments, to: image)
        #else
        output = applyCoreImageBasicColorAdjustments(adjustments, to: image)
        #endif

        output = applyCoreImageFinishingAdjustments(adjustments, to: output)
        return output
    }

    private func applyCoreImageBasicColorAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output = image
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        return output
    }

    private func applyCoreImageFinishingAdjustments(_ adjustments: ColorAdjust, to image: CIImage) -> CIImage {
        var output = image
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

    private func applyRenderEffect(_ effect: StoryRenderEffect, to image: CIImage, useMetalPetal: Bool) -> CIImage {
        guard effect != .none else { return image }
        if effect.usesCoreImagePipeline {
            return applyCoreImageFallbackEffect(effect, to: image)
        }
        #if canImport(MetalPetal)
        if useMetalPetal, let output = MetalPetalStoryFilterProcessor.shared.applyRenderEffect(effect, to: image) {
            return output
        }
        #endif
        return applyCoreImageFallbackEffect(effect, to: image)
    }

    private func applyCoreImageFallbackEffect(_ effect: StoryRenderEffect, to image: CIImage) -> CIImage {
        switch effect {
        case .none:
            return image
        case .clarify, .sharpen:
            return image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: effect == .clarify ? 0.35 : 0.65
            ])
        case .softBlur:
            return image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 4
            ]).cropped(to: image.extent)
        case .pixel:
            return image.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: 18
            ]).cropped(to: image.extent)
        case .dotScreen:
            return image.applyingFilter("CIDotScreen", parameters: [
                kCIInputAngleKey: 0.35,
                kCIInputWidthKey: 6,
                kCIInputSharpnessKey: 0.7
            ]).cropped(to: image.extent)
        case .halftone:
            return image.applyingFilter("CIColorPosterize", parameters: [
                "inputLevels": 8
            ])
        case .skinSmooth:
            return StoryCoreImageEffects.smoothSkin(image)
        case .glow:
            return image.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: 12,
                kCIInputIntensityKey: 0.75
            ]).cropped(to: image.extent)
        case .comic:
            return image.applyingFilter("CIComicEffect").cropped(to: image.extent)
        case .edges:
            return image.applyingFilter("CIEdges", parameters: [
                kCIInputIntensityKey: 2.2
            ]).cropped(to: image.extent)
        case .crystallize:
            return image.applyingFilter("CICrystallize", parameters: [
                kCIInputRadiusKey: 24
            ]).cropped(to: image.extent)
        case .kaleidoscope:
            return image.applyingFilter("CIKaleidoscope", parameters: [
                "inputCount": 8,
                "inputAngle": 0
            ]).cropped(to: image.extent)
        case .vhs, .lightLeak, .chromatic:
            return image
        }
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
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let sourceExtent = working.extent
        let sourceWidth = max(sourceExtent.width, 1)
        let sourceHeight = max(sourceExtent.height, 1)
        let baseScale = max(canvasSize.width / sourceWidth, canvasSize.height / sourceHeight)
        let finalScale = max(baseScale * transform.scale, 0.0001)

        working = working.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.midX,
            y: -sourceExtent.midY
        ))
        working = working.transformed(by: CGAffineTransform(rotationAngle: transform.rotation))
        working = working.transformed(by: CGAffineTransform(scaleX: finalScale, y: finalScale))

        let centeredExtent = working.extent
        working = working.transformed(by: CGAffineTransform(
            translationX: canvasSize.width / 2 + transform.tx - centeredExtent.midX,
            y: canvasSize.height / 2 + transform.ty - centeredExtent.midY
        ))

        let background = CIImage(color: CIColor(
            red: CGFloat(canvas.backgroundColor.r),
            green: CGFloat(canvas.backgroundColor.g),
            blue: CGFloat(canvas.backgroundColor.b),
            alpha: CGFloat(canvas.backgroundColor.a)
        )).cropped(to: canvasRect)
        return working.composited(over: background).cropped(to: canvasRect)
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

private enum StoryColorLUT {
    private static let dimension = 24
    private static let dataByProfile = Dictionary(
        uniqueKeysWithValues: StoryLUTProfile.allProfiles.map { ($0, makeCube(for: $0)) }
    )

    static func apply(_ profile: StoryLUTProfile, to image: CIImage) -> CIImage {
        guard let data = dataByProfile[profile] else { return image }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data
        ]).cropped(to: image.extent)
    }

    private static func makeCube(for profile: StoryLUTProfile) -> Data {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let denominator = Float(dimension - 1)

        for blueIndex in 0..<dimension {
            for greenIndex in 0..<dimension {
                for redIndex in 0..<dimension {
                    let input = SIMD3<Float>(
                        Float(redIndex) / denominator,
                        Float(greenIndex) / denominator,
                        Float(blueIndex) / denominator
                    )
                    let output = grade(input, profile: profile)
                    values.append(contentsOf: [
                        min(max(output.x, 0), 1),
                        min(max(output.y, 0), 1),
                        min(max(output.z, 0), 1),
                        1
                    ])
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func grade(_ color: SIMD3<Float>, profile: StoryLUTProfile) -> SIMD3<Float> {
        let luma = color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
        switch profile {
        case .portrait:
            return SIMD3(color.x * 1.035 + 0.018, color.y * 1.01 + 0.008, color.z * 0.975)
        case .golden:
            return SIMD3(color.x * 1.08 + 0.015, color.y * 1.025 + 0.008, color.z * 0.91)
        case .cinema:
            let shadows = 1 - smoothstep(0.18, 0.62, luma)
            let highlights = smoothstep(0.42, 0.9, luma)
            return SIMD3(
                color.x + highlights * 0.035 - shadows * 0.025,
                color.y + shadows * 0.025,
                color.z + shadows * 0.06 - highlights * 0.025
            )
        case .film:
            let lifted = color * 0.93 + SIMD3(repeating: 0.035)
            return SIMD3(lifted.x * 1.025, lifted.y, lifted.z * 0.965)
        case .vivid:
            let saturated = SIMD3<Float>(repeating: luma) + (color - SIMD3<Float>(repeating: luma)) * 1.16
            return saturated
        case .vintage:
            let faded = color * 0.86 + SIMD3<Float>(repeating: 0.075)
            return SIMD3(faded.x * 1.07, faded.y * 1.015, faded.z * 0.88)
        }
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return x * x * (3 - 2 * x)
    }
}

private extension StoryLUTProfile {
    static let allProfiles: [StoryLUTProfile] = [
        .portrait, .golden, .cinema, .film, .vivid, .vintage
    ]
}

private enum StoryAnimatedEffects {
    static func apply(_ effect: StoryRenderEffect, to image: CIImage, time: Double) -> CIImage {
        switch effect {
        case .vhs:
            return vhs(image, time: time)
        case .lightLeak:
            return lightLeak(image, time: time)
        case .chromatic:
            return chromaticSplit(image, time: time)
        default:
            return image
        }
    }

    private static func vhs(_ image: CIImage, time: Double) -> CIImage {
        let extent = image.extent
        let jitter = CGFloat(sin(time * 17.0) * 3.5)
        let shifted = image
            .transformed(by: CGAffineTransform(translationX: jitter, y: 0))
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.88,
                kCIInputContrastKey: 1.08
            ])
        let phase = CGFloat((time * 70).truncatingRemainder(dividingBy: 8))
        let cellExtent = CGRect(x: 0, y: 0, width: extent.width, height: 8)
        let line = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.12)
        )
        .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: 1.4))
        let cell = line.composited(over: CIImage(color: .clear).cropped(to: cellExtent))
        let scanlines = cell
            .applyingFilter("CIAffineTile", parameters: [
                kCIInputTransformKey: CGAffineTransform.identity
            ])
            .transformed(by: CGAffineTransform(
                translationX: extent.minX,
                y: extent.minY - 8 + phase
            ))
            .cropped(to: extent)
        return scanlines.composited(over: shifted).cropped(to: extent)
    }

    private static func lightLeak(_ image: CIImage, time: Double) -> CIImage {
        let extent = image.extent
        let travel = CGFloat((sin(time * 0.9) + 1) * 0.5)
        let center = CIVector(
            x: extent.minX + extent.width * (-0.05 + travel * 1.1),
            y: extent.minY + extent.height * (0.72 + CGFloat(sin(time * 0.47)) * 0.12)
        )
        let radius = max(extent.width, extent.height) * 0.48
        let leak = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": center,
                "inputRadius0": radius * 0.04,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 0.28, blue: 0.04, alpha: 0.72),
                "inputColor1": CIColor.clear
            ]
        )?.outputImage?.cropped(to: extent) ?? image
        return leak.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: extent)
    }

    private static func chromaticSplit(_ image: CIImage, time: Double) -> CIImage {
        let extent = image.extent
        let distance = CGFloat(3.5 + abs(sin(time * 2.2)) * 4)
        let red = channel(image, vector: CIVector(x: 1, y: 0, z: 0, w: 0))
            .transformed(by: CGAffineTransform(translationX: distance, y: 0))
        let green = channel(image, vector: CIVector(x: 0, y: 1, z: 0, w: 0))
        let blue = channel(image, vector: CIVector(x: 0, y: 0, z: 1, w: 0))
            .transformed(by: CGAffineTransform(translationX: -distance, y: 0))
        return red
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }

    private static func channel(_ image: CIImage, vector: CIVector) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: vector.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: vector.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: vector.z, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }
}

enum StoryRenderQuality {
    case full
    case interactivePreview

    var usesMetalPetal: Bool {
        switch self {
        case .full: return true
        case .interactivePreview: return false
        }
    }

    var includesOverlays: Bool {
        switch self {
        case .full: return true
        case .interactivePreview: return false
        }
    }
}

actor StoryCompositor {
    private struct OverlayCacheKey: Hashable {
        let projectId: UUID
        let updatedAt: Date
        let overlaySignature: String
    }

    private let engine: StoryRenderEngine
    private let effectGraph: StoryEffectGraph
    private let maxFrameSourceCacheCount = 8
    private let overlayDiskCacheVersion = "v2"
    private let overlayDiskCacheMetricsNamespace = "story.overlay"
    private let overlayDiskCacheMaxBytes: UInt64 = 120 * 1024 * 1024
    private let overlayDiskCacheRootURL: URL
    private let overlayDiskCacheEncoder: JSONEncoder
    private var overlayCache = [OverlayCacheKey: [RenderedOverlay]]()
    private var frameSourceCache = [String: FrameSource]()
    private var frameSourceCacheOrder: [String] = []

    init(engine: StoryRenderEngine = .shared, effectGraph: StoryEffectGraph = StoryEffectGraph()) {
        self.engine = engine
        self.effectGraph = effectGraph
        self.overlayDiskCacheEncoder = JSONEncoder()
        self.overlayDiskCacheEncoder.outputFormatting = [.sortedKeys]

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.overlayDiskCacheRootURL = caches.appendingPathComponent("MediaverseStoryOverlayCache", isDirectory: true)
    }

    func clearCaches() {
        overlayCache.removeAll()
        frameSourceCache.removeAll()
        frameSourceCacheOrder.removeAll()
    }

    func render(project: Project, assetStore: AssetStore, at timelineTime: CMTime, quality: StoryRenderQuality = .full) async throws -> CVPixelBuffer {
        let output = try engine.makeCanvasBuffer(canvas: project.canvas)
        try await render(project: project, assetStore: assetStore, at: timelineTime, into: output, quality: quality)
        return output
    }

    func render(
        project: Project,
        assetStore: AssetStore,
        at timelineTime: CMTime,
        into output: CVPixelBuffer,
        quality: StoryRenderQuality = .full
    ) async throws {
        guard let clip = activeClip(in: project, at: timelineTime) else {
            renderBackground(for: project.canvas, to: output)
            return
        }

        let sourceTime = sourceTime(for: clip, project: project, timelineTime: timelineTime)
        let source = frameSource(for: clip.assetRef, assetStore: assetStore)
        guard let sourceImage = try await source.image(at: sourceTime) else {
            renderBackground(for: project.canvas, to: output)
            return
        }

        let overlays = quality.includesOverlays
            ? try await renderedOverlays(in: project, assetStore: assetStore, at: timelineTime)
            : []
        let rendered = effectGraph.render(
            sourceImage: sourceImage,
            time: timelineTime,
            clip: clip,
            overlays: overlays,
            canvas: project.canvas,
            useMetalPetal: quality.usesMetalPetal
        )
        engine.render(rendered, to: output, bounds: CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height))
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
        let key = "\(assetRef.kind.rawValue):\(assetRef.relativePath)"
        if let cached = frameSourceCache[key] {
            markFrameSourceCacheHit(key)
            return cached
        }

        let url = assetStore.absoluteURL(for: assetRef.relativePath)
        let source: FrameSource
        switch assetRef.kind {
        case .image:
            source = ImageFrameSource(imageURL: url)
        case .video, .audio:
            source = AssetReaderFrameSource(url: url)
        }
        insertFrameSource(source, forKey: key)
        return source
    }

    private func markFrameSourceCacheHit(_ key: String) {
        frameSourceCacheOrder.removeAll { $0 == key }
        frameSourceCacheOrder.append(key)
    }

    private func insertFrameSource(_ source: FrameSource, forKey key: String) {
        frameSourceCache[key] = source
        markFrameSourceCacheHit(key)
        while frameSourceCacheOrder.count > maxFrameSourceCacheCount, let oldestKey = frameSourceCacheOrder.first {
            frameSourceCacheOrder.removeFirst()
            frameSourceCache.removeValue(forKey: oldestKey)
        }
    }

    private func renderedOverlays(in project: Project, assetStore: AssetStore, at timelineTime: CMTime) async throws -> [RenderedOverlay] {
        let hasTimedMedia = project.tracks.overlays.contains(where: isTimedMediaOverlay)
        let cacheKey = overlayCacheKey(for: project)
        if !hasTimedMedia, let cached = overlayCache[cacheKey] {
            return cached
        }

        var rendered: [RenderedOverlay] = []
        rendered.reserveCapacity(project.tracks.overlays.count)

        for overlay in project.tracks.overlays {
            let overlayStart = overlay.timeRange.start.time
            let overlayEnd = overlayStart + overlay.timeRange.duration.time
            guard timelineTime >= overlayStart, timelineTime < overlayEnd,
                  let image = try await overlayImage(for: overlay, assetStore: assetStore, at: timelineTime) else {
                continue
            }
            rendered.append(positionedOverlay(image: image, transform: transform(for: overlay), canvas: project.canvas))
        }

        if !hasTimedMedia {
            overlayCache = overlayCache.filter { $0.key.projectId != project.id || $0.key == cacheKey }
            overlayCache[cacheKey] = rendered
        }
        return rendered
    }

    private func overlayImage(for overlay: Overlay, assetStore: AssetStore, at timelineTime: CMTime) async throws -> CIImage? {
        if case .sticker(let sticker) = overlay,
           let assetRef = sticker.assetRef,
           isTimedMediaAsset(assetRef) {
            return try await timedStickerImage(
                sticker,
                assetRef: assetRef,
                assetStore: assetStore,
                at: timelineTime
            )
        }

        let cacheKey = try overlayDiskCacheKey(for: overlay, assetStore: assetStore)
        if let cached = cachedOverlayImage(for: cacheKey) {
            CacheMetrics.shared.recordHit(overlayDiskCacheMetricsNamespace)
            return cached
        }
        CacheMetrics.shared.recordMiss(overlayDiskCacheMetricsNamespace)

        let image: CIImage?
        switch overlay {
        case .text(let text):
            image = makeTextOverlayImage(text)
        case .sticker(let sticker):
            image = try await makeStickerOverlayImage(sticker, assetStore: assetStore)
        case .drawing(let drawing):
            image = CIImage(contentsOf: assetStore.absoluteURL(for: drawing.assetRef.relativePath))
        case .link(let link):
            image = makeLinkOverlayImage(link)
        case .interactive(let interactive):
            image = makeInteractiveOverlayImage(interactive)
        }

        if let image {
            try? storeOverlayImage(image, for: cacheKey)
        }
        return image
    }

    private func isTimedMediaOverlay(_ overlay: Overlay) -> Bool {
        guard case .sticker(let sticker) = overlay, let assetRef = sticker.assetRef else { return false }
        return isTimedMediaAsset(assetRef)
    }

    private func isTimedMediaAsset(_ assetRef: AssetRef) -> Bool {
        if assetRef.kind == .video { return true }
        guard assetRef.kind == .image else { return false }
        let ext = URL(fileURLWithPath: assetRef.relativePath).pathExtension.lowercased()
        return ext == "gif" || ext == "webp"
    }

    private func timedStickerImage(
        _ overlay: StickerOverlay,
        assetRef: AssetRef,
        assetStore: AssetStore,
        at timelineTime: CMTime
    ) async throws -> CIImage? {
        let url = assetStore.absoluteURL(for: assetRef.relativePath)
        let localSeconds = max(timelineTime.seconds - overlay.timeRange.start.time.seconds, 0)

        switch assetRef.kind {
        case .video:
            let sourceDuration = max(assetRef.durationSeconds, 0.01)
            let loopedTime = storyLoopedMediaTime(elapsed: localSeconds, duration: sourceDuration)
            return try await frameSource(for: assetRef, assetStore: assetStore).image(
                at: CMTime(seconds: loopedTime, preferredTimescale: projectTimeScale)
            )
        case .image:
            guard let frame = StoryAnimatedImage.frame(at: localSeconds, from: url) else {
                return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            }
            return CIImage(cgImage: frame)
        case .audio:
            return nil
        }
    }

    private struct OverlayDiskCacheInput: Codable {
        let schemaVersion: Int
        let cacheVersion: String
        let overlay: Overlay
        let sourceAssets: [OverlaySourceAssetDigest]
    }

    private struct OverlaySourceAssetDigest: Codable {
        let relativePath: String
        let byteCount: Int
        let sha256: String
    }

    private func overlayDiskCacheKey(for overlay: Overlay, assetStore: AssetStore) throws -> String {
        let input = OverlayDiskCacheInput(
            schemaVersion: 1,
            cacheVersion: overlayDiskCacheVersion,
            overlay: overlay,
            sourceAssets: try overlayAssetRefs(overlay)
                .map { ref in
                    let url = assetStore.absoluteURL(for: ref.relativePath)
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return OverlaySourceAssetDigest(
                        relativePath: ref.relativePath,
                        byteCount: fileSize,
                        sha256: try fileSHA256Hex(url)
                    )
                }
                .sorted { $0.relativePath < $1.relativePath }
        )
        return Self.sha256Hex(try overlayDiskCacheEncoder.encode(input))
    }

    private func overlayAssetRefs(_ overlay: Overlay) -> [AssetRef] {
        switch overlay {
        case .sticker(let sticker):
            return sticker.assetRef.map { [$0] } ?? []
        case .drawing(let drawing):
            return [drawing.assetRef]
        case .text, .link, .interactive:
            return []
        }
    }

    private func cachedOverlayImage(for key: String) -> CIImage? {
        let url = overlayDiskCacheURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = CIImage(contentsOf: url) else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    private func storeOverlayImage(_ image: CIImage, for key: String) throws {
        try FileManager.default.createDirectory(at: overlayDiskCacheRootURL, withIntermediateDirectories: true)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let cgImage = engine.ciContext.createCGImage(normalized, from: normalized.extent),
              let data = UIImage(cgImage: cgImage).pngData() else {
            return
        }
        try data.write(to: overlayDiskCacheURL(for: key), options: [.atomic])
        CacheMetrics.shared.recordStore(overlayDiskCacheMetricsNamespace, bytes: UInt64(data.count))
        try evictOverlayDiskCacheIfNeeded()
    }

    private func overlayDiskCacheURL(for key: String) -> URL {
        overlayDiskCacheRootURL.appendingPathComponent(key + ".png")
    }

    private func evictOverlayDiskCacheIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: overlayDiskCacheRootURL.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: overlayDiskCacheRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let entries = files.compactMap { url -> (url: URL, size: UInt64, modifiedAt: Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values?.fileSize else { return nil }
            return (url, UInt64(size), values?.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard totalBytes > overlayDiskCacheMaxBytes else { return }

        var evictedCount = 0
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? FileManager.default.removeItem(at: entry.url)
            evictedCount += 1
            totalBytes = totalBytes > entry.size ? totalBytes - entry.size : 0
            if totalBytes <= overlayDiskCacheMaxBytes { break }
        }
        if evictedCount > 0 {
            CacheMetrics.shared.recordEviction(overlayDiskCacheMetricsNamespace, count: evictedCount)
        }
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

    private func overlayCacheKey(for project: Project) -> OverlayCacheKey {
        OverlayCacheKey(
            projectId: project.id,
            updatedAt: project.updatedAt,
            overlaySignature: project.tracks.overlays.map(overlaySignature).joined(separator: "|")
        )
    }

    private func overlaySignature(_ overlay: Overlay) -> String {
        let transform: Transform2D
        let payload: String
        switch overlay {
        case .text(let text):
            transform = text.transform
            payload = "text:\(text.text):\(text.style.fontSize):\(text.style.alignment)"
        case .sticker(let sticker):
            transform = sticker.transform
            payload = "sticker:\(sticker.emoji ?? ""):\(sticker.assetRef?.relativePath ?? "")"
        case .drawing(let drawing):
            transform = drawing.transform
            payload = "drawing:\(drawing.assetRef.relativePath)"
        case .link(let link):
            transform = link.transform
            payload = "link:\(link.label):\(link.url)"
        case .interactive(let interactive):
            transform = interactive.transform
            payload = "interactive:\(interactive.kind.rawValue):\(interactive.title):\(interactive.subtitle ?? ""):\(interactive.options.joined(separator: ","))"
        }

        return "\(overlay.id.uuidString):\(transform.scale):\(transform.rotation):\(transform.tx):\(transform.ty):\(payload)"
    }

    private func transform(for overlay: Overlay) -> Transform2D {
        switch overlay {
        case .text(let text):
            return text.transform
        case .sticker(let sticker):
            return sticker.transform
        case .drawing(let drawing):
            return drawing.transform
        case .link(let link):
            return link.transform
        case .interactive(let interactive):
            return interactive.transform
        }
    }

    private func positionedOverlay(image: CIImage, transform: Transform2D, canvas: CanvasSpec) -> RenderedOverlay {
        let canvasWidth = CGFloat(canvas.width)
        let canvasHeight = CGFloat(canvas.height)
        let transformed = image.transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale).rotated(by: transform.rotation))
        let normalized = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.minX, y: -transformed.extent.minY))
        let size = normalized.extent.size
        let centerX = canvasWidth / 2 + transform.tx
        let centerY = canvasHeight / 2 + transform.ty
        return RenderedOverlay(
            image: normalized,
            frame: CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height),
            opacity: 1
        )
    }

    private var overlayRasterScale: CGFloat { 3 }

    private func overlayRenderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = overlayRasterScale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private func canvasScaledOverlayImage(from image: UIImage) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
            scaleX: 1 / overlayRasterScale,
            y: 1 / overlayRasterScale
        ))
    }

    private func makeTextOverlayImage(_ overlay: TextOverlay) -> CIImage? {
        let font = overlay.style.fontName.flatMap { UIFont(name: $0, size: overlay.style.fontSize) }
            ?? UIFont.systemFont(ofSize: overlay.style.fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = overlay.style.nsAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let maxWidth: CGFloat = 760
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
        let imageSize = CGSize(
            width: max(180, min(maxWidth, textRect.width + padding.width * 2)),
            height: max(92, min(360, textRect.height + padding.height * 2))
        )
        let renderer = overlayRenderer(size: imageSize)
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
        return canvasScaledOverlayImage(from: uiImage)
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
        let renderer = overlayRenderer(size: size)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 52).fill()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: UIColor.black.withAlphaComponent(0.22).cgColor)
            let icon = NSAttributedString(string: "LINK", attributes: [.font: iconFont, .foregroundColor: UIColor.black])
            icon.draw(in: CGRect(x: 28, y: 29, width: 70, height: 48))
            NSAttributedString(string: text, attributes: attributes).draw(in: CGRect(x: 112, y: 26, width: width - 140, height: 56))
        }
        return canvasScaledOverlayImage(from: uiImage)
    }

    private func makeStickerOverlayImage(_ overlay: StickerOverlay, assetStore: AssetStore) async throws -> CIImage? {
        if let assetRef = overlay.assetRef {
            let url = assetStore.absoluteURL(for: assetRef.relativePath)
            switch assetRef.kind {
            case .image:
                return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            case .video:
                return try await AssetReaderFrameSource(url: url).image(at: .zero)
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
        let renderer = overlayRenderer(size: size)
        let uiImage = renderer.image { context in
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: UIColor.black.withAlphaComponent(0.38).cgColor)
            attributed.draw(in: CGRect(x: (size.width - rect.width) / 2, y: (size.height - rect.height) / 2, width: rect.width, height: rect.height))
        }
        return canvasScaledOverlayImage(from: uiImage)
    }

    private func makeInteractiveOverlayImage(_ overlay: StoryInteractiveOverlay) -> CIImage? {
        let titleFont = UIFont.systemFont(ofSize: 46, weight: .heavy)
        let bodyFont = UIFont.systemFont(ofSize: 34, weight: .bold)
        let title = overlay.title.isEmpty ? overlay.kind.rawValue.capitalized : overlay.title
        let subtitle = overlay.subtitle ?? interactiveSubtitle(for: overlay)
        let options = overlay.options.isEmpty ? defaultOptions(for: overlay.kind) : overlay.options

        if overlay.kind == .mention {
            return makeMentionOverlayImage(title: title, subtitle: subtitle)
        }
        if overlay.kind == .link {
            let metadata = optionDictionary(overlay.options)
            return makeLinkInteractiveOverlayImage(label: title, url: metadata["url"] ?? overlay.subtitle)
        }

        let width: CGFloat = overlay.kind == .location ? 520 : 700
        let optionHeight: CGFloat = options.isEmpty ? 0 : CGFloat(options.count) * 58 + 18
        let subtitleHeight: CGFloat = subtitle == nil ? 0 : 44
        let height = max(112, 116 + subtitleHeight + optionHeight)
        let size = CGSize(width: width, height: height)
        let renderer = overlayRenderer(size: size)
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
        return canvasScaledOverlayImage(from: uiImage)
    }

    private func makeLinkInteractiveOverlayImage(label: String, url: String?) -> CIImage? {
        let safeLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Link" : label
        let host = url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let titleFont = UIFont.systemFont(ofSize: 34, weight: .heavy)
        let subtitleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
        let titleRect = NSAttributedString(string: safeLabel, attributes: [.font: titleFont]).boundingRect(
            with: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let subtitleRect = NSAttributedString(string: host ?? "", attributes: [.font: subtitleFont]).boundingRect(
            with: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let width = max(300, min(640, max(titleRect.width, subtitleRect.width) + 132))
        let size = CGSize(width: width, height: 104)
        let renderer = overlayRenderer(size: size)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.black.withAlphaComponent(0.86).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 52).fill()
            UIColor.white.withAlphaComponent(0.16).setStroke()
            UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 51).stroke()

            let tint = UIColor(red: 0, green: 0.9, blue: 0.46, alpha: 1)
            let iconFont = UIFont.systemFont(ofSize: 34, weight: .black)
            NSAttributedString(string: "↗", attributes: [.font: iconFont, .foregroundColor: tint])
                .draw(in: CGRect(x: 26, y: 30, width: 42, height: 44))
            NSAttributedString(string: safeLabel, attributes: [.font: titleFont, .foregroundColor: UIColor.white])
                .draw(in: CGRect(x: 82, y: host == nil ? 31 : 18, width: width - 108, height: 40))
            if let host {
                NSAttributedString(string: host, attributes: [.font: subtitleFont, .foregroundColor: UIColor.white.withAlphaComponent(0.58)])
                    .draw(in: CGRect(x: 82, y: 58, width: width - 108, height: 30))
            }
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: UIColor.black.withAlphaComponent(0.34).cgColor)
        }
        return canvasScaledOverlayImage(from: uiImage)
    }

    private func makeMentionOverlayImage(title: String, subtitle: String?) -> CIImage? {
        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mention" : title
        let safeSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleFont = UIFont.systemFont(ofSize: 42, weight: .heavy)
        let subtitleFont = UIFont.systemFont(ofSize: 28, weight: .bold)
        let titleRect = NSAttributedString(string: safeTitle, attributes: [.font: titleFont]).boundingRect(
            with: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let subtitleRect = NSAttributedString(string: safeSubtitle ?? "", attributes: [.font: subtitleFont]).boundingRect(
            with: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        let width = max(320, min(680, max(titleRect.width, subtitleRect.width) + 150))
        let size = CGSize(width: width, height: 124)
        let renderer = overlayRenderer(size: size)
        let uiImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.black.withAlphaComponent(0.76).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 62).fill()
            UIColor.white.withAlphaComponent(0.22).setStroke()
            UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 61).stroke()

            let circleRect = CGRect(x: 24, y: 28, width: 68, height: 68)
            UIColor(red: 0, green: 0.9, blue: 0.46, alpha: 1).setFill()
            UIBezierPath(ovalIn: circleRect).fill()
            let at = NSAttributedString(string: "@", attributes: [.font: UIFont.systemFont(ofSize: 44, weight: .black), .foregroundColor: UIColor.black])
            at.draw(in: CGRect(x: 43, y: 36, width: 34, height: 48))

            NSAttributedString(string: safeTitle, attributes: [.font: titleFont, .foregroundColor: UIColor.white])
                .draw(in: CGRect(x: 112, y: 24, width: width - 140, height: 50))
            if let safeSubtitle, !safeSubtitle.isEmpty {
                NSAttributedString(string: safeSubtitle, attributes: [.font: subtitleFont, .foregroundColor: UIColor.white.withAlphaComponent(0.74)])
                    .draw(in: CGRect(x: 112, y: 72, width: width - 140, height: 36))
            }

            context.cgContext.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: UIColor.black.withAlphaComponent(0.34).cgColor)
        }
        return canvasScaledOverlayImage(from: uiImage)
    }

    private func interactiveSubtitle(for overlay: StoryInteractiveOverlay) -> String? {
        switch overlay.kind {
        case .link: return overlay.subtitle
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

    private func optionDictionary(_ options: [String]) -> [String: String] {
        options.reduce(into: [:]) { result, option in
            guard let separator = option.firstIndex(of: "=") else { return }
            let key = String(option[..<separator])
            let value = String(option[option.index(after: separator)...])
            result[key] = value
        }
    }

    private func backgroundBuffer(for canvas: CanvasSpec) throws -> CVPixelBuffer {
        let output = try engine.makeCanvasBuffer(canvas: canvas)
        renderBackground(for: canvas, to: output)
        return output
    }

    private func renderBackground(for canvas: CanvasSpec, to output: CVPixelBuffer) {
        let color = CIColor(
            red: CGFloat(canvas.backgroundColor.r),
            green: CGFloat(canvas.backgroundColor.g),
            blue: CGFloat(canvas.backgroundColor.b),
            alpha: CGFloat(canvas.backgroundColor.a)
        )
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        engine.render(image, to: output, bounds: image.extent)
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
