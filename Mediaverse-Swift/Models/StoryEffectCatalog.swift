import Foundation

struct StoryBeautySettings: Codable, Equatable {
    var intensity: Float
    var skinSmoothing: Float
    var skinTone: Float
    var brightness: Float
    var eyeBrightening: Float
    var underEye: Float
    var teethWhitening: Float
    var lipColor: Float
    var contour: Float

    static let off = StoryBeautySettings(
        intensity: 0,
        skinSmoothing: 0,
        skinTone: 0,
        brightness: 0,
        eyeBrightening: 0,
        underEye: 0,
        teethWhitening: 0,
        lipColor: 0,
        contour: 0
    )

    static let natural = StoryBeautySettings(
        intensity: 0.55,
        skinSmoothing: 0.32,
        skinTone: 0.10,
        brightness: 0.08,
        eyeBrightening: 0.12,
        underEye: 0.10,
        teethWhitening: 0.08,
        lipColor: 0.05,
        contour: 0
    )

    var isEnabled: Bool {
        intensity > 0.001 && (
            skinSmoothing > 0.001 ||
            abs(skinTone) > 0.001 ||
            abs(brightness) > 0.001 ||
            eyeBrightening > 0.001 ||
            underEye > 0.001 ||
            teethWhitening > 0.001 ||
            abs(lipColor) > 0.001 ||
            contour > 0.001
        )
    }

    func clamped() -> StoryBeautySettings {
        StoryBeautySettings(
            intensity: min(max(intensity, 0), 1),
            skinSmoothing: min(max(skinSmoothing, 0), 1),
            skinTone: min(max(skinTone, -1), 1),
            brightness: min(max(brightness, -1), 1),
            eyeBrightening: min(max(eyeBrightening, 0), 1),
            underEye: min(max(underEye, 0), 1),
            teethWhitening: min(max(teethWhitening, 0), 1),
            lipColor: min(max(lipColor, -1), 1),
            contour: min(max(contour, 0), 1)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case intensity
        case skinSmoothing
        case skinTone
        case brightness
        case eyeBrightening
        case underEye
        case teethWhitening
        case lipColor
        case contour
    }

    init(
        intensity: Float,
        skinSmoothing: Float,
        skinTone: Float,
        brightness: Float,
        eyeBrightening: Float = 0,
        underEye: Float = 0,
        teethWhitening: Float = 0,
        lipColor: Float = 0,
        contour: Float = 0
    ) {
        self.intensity = intensity
        self.skinSmoothing = skinSmoothing
        self.skinTone = skinTone
        self.brightness = brightness
        self.eyeBrightening = eyeBrightening
        self.underEye = underEye
        self.teethWhitening = teethWhitening
        self.lipColor = lipColor
        self.contour = contour
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? 0
        skinSmoothing = try container.decodeIfPresent(Float.self, forKey: .skinSmoothing) ?? 0
        skinTone = try container.decodeIfPresent(Float.self, forKey: .skinTone) ?? 0
        brightness = try container.decodeIfPresent(Float.self, forKey: .brightness) ?? 0
        eyeBrightening = try container.decodeIfPresent(Float.self, forKey: .eyeBrightening) ?? 0
        underEye = try container.decodeIfPresent(Float.self, forKey: .underEye) ?? 0
        teethWhitening = try container.decodeIfPresent(Float.self, forKey: .teethWhitening) ?? 0
        lipColor = try container.decodeIfPresent(Float.self, forKey: .lipColor) ?? 0
        contour = try container.decodeIfPresent(Float.self, forKey: .contour) ?? 0
    }
}

struct StoryEffectStack: Codable, Equatable {
    var version: Int
    var lookId: String?
    var lookIntensity: Float
    var beauty: StoryBeautySettings
    var creativeEffects: [StoryRenderEffect]
    var creativeEffectIntensity: Float

    static let currentVersion = 1

    static let none = StoryEffectStack(
        version: currentVersion,
        lookId: nil,
        lookIntensity: 1,
        beauty: .off,
        creativeEffects: [],
        creativeEffectIntensity: 1
    )

    private enum CodingKeys: String, CodingKey {
        case version
        case lookId
        case lookIntensity
        case beauty
        case creativeEffects
        case creativeEffectIntensity
    }

    init(
        version: Int,
        lookId: String?,
        lookIntensity: Float,
        beauty: StoryBeautySettings,
        creativeEffects: [StoryRenderEffect],
        creativeEffectIntensity: Float = 1
    ) {
        self.version = version
        self.lookId = lookId
        self.lookIntensity = lookIntensity
        self.beauty = beauty
        self.creativeEffects = creativeEffects
        self.creativeEffectIntensity = creativeEffectIntensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        lookId = try container.decodeIfPresent(String.self, forKey: .lookId)
        lookIntensity = try container.decodeIfPresent(Float.self, forKey: .lookIntensity) ?? 1
        beauty = try container.decodeIfPresent(StoryBeautySettings.self, forKey: .beauty) ?? .off
        creativeEffects = try container.decodeIfPresent([StoryRenderEffect].self, forKey: .creativeEffects) ?? []
        creativeEffectIntensity = try container.decodeIfPresent(Float.self, forKey: .creativeEffectIntensity) ?? 1
    }
}

struct StoryEffectPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let adjustments: ColorAdjust
    let renderEffect: StoryRenderEffect
    let lut: StoryLUTProfile?

    init(
        id: String,
        name: String,
        adjustments: ColorAdjust,
        renderEffect: StoryRenderEffect = .none,
        lut: StoryLUTProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.renderEffect = renderEffect
        self.lut = lut
    }
}

enum StoryLUTProfile: String, Hashable {
    case portrait
    case golden
    case cinema
    case film
    case vivid
    case vintage
}

enum StoryRenderEffect: String, Codable, Equatable {
    case none
    case clarify
    case softBlur
    case pixel
    case dotScreen
    case halftone
    case sharpen
    case skinSmooth
    case glow
    case comic
    case edges
    case crystallize
    case kaleidoscope
    case vhs
    case lightLeak
    case chromatic
}

enum StoryEffectCatalog {
    static let presets: [StoryEffectPreset] = [
        StoryEffectPreset(id: "neutral", name: "Neutral", adjustments: .neutral),
        StoryEffectPreset(id: "smooth", name: "Smooth", adjustments: .neutral, renderEffect: .skinSmooth),
        StoryEffectPreset(id: "warm", name: "Warm", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.04, saturation: 1.08, warmth: 0.45, vignette: 0.05)),
        StoryEffectPreset(id: "golden", name: "Golden", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.08, saturation: 1.12, warmth: 0.62, vignette: 0.08), lut: .golden),
        StoryEffectPreset(id: "sunset", name: "Sunset", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.12, saturation: 1.18, warmth: 0.78, vignette: 0.16)),
        StoryEffectPreset(id: "rose", name: "Rose", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.03, saturation: 1.10, warmth: 0.18, vignette: 0.05), lut: .portrait),
        StoryEffectPreset(id: "cool", name: "Cool", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.03, saturation: 1.02, warmth: -0.42, vignette: 0.04)),
        StoryEffectPreset(id: "aqua", name: "Aqua", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.06, saturation: 1.10, warmth: -0.62, vignette: 0.06)),
        StoryEffectPreset(id: "teal", name: "Teal", adjustments: ColorAdjust(brightness: -0.01, contrast: 1.10, saturation: 1.06, warmth: -0.34, vignette: 0.12)),
        StoryEffectPreset(id: "bw", name: "B&W", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.18, saturation: 0, warmth: 0, vignette: 0.18)),
        StoryEffectPreset(id: "noir", name: "Noir", adjustments: ColorAdjust(brightness: -0.04, contrast: 1.32, saturation: 0, warmth: -0.06, vignette: 0.30)),
        StoryEffectPreset(id: "film", name: "Film", adjustments: ColorAdjust(brightness: -0.02, contrast: 1.12, saturation: 0.92, warmth: 0.22, vignette: 0.22), lut: .film),
        StoryEffectPreset(id: "cinema", name: "Cinema", adjustments: ColorAdjust(brightness: -0.03, contrast: 1.20, saturation: 0.90, warmth: -0.12, vignette: 0.22), lut: .cinema),
        StoryEffectPreset(id: "vivid", name: "Vivid", adjustments: ColorAdjust(brightness: 0.03, contrast: 1.16, saturation: 1.28, warmth: 0.08, vignette: 0.06), lut: .vivid),
        StoryEffectPreset(id: "pop", name: "Pop", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.20, saturation: 1.36, warmth: 0.02, vignette: 0.04)),
        StoryEffectPreset(id: "crisp", name: "Crisp", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.18, saturation: 1.08, warmth: -0.04, vignette: 0.04), renderEffect: .sharpen),
        StoryEffectPreset(id: "fade", name: "Fade", adjustments: ColorAdjust(brightness: 0.06, contrast: 0.86, saturation: 0.86, warmth: 0.12, vignette: 0)),
        StoryEffectPreset(id: "matte", name: "Matte", adjustments: ColorAdjust(brightness: 0.03, contrast: 0.90, saturation: 0.92, warmth: 0.10, vignette: 0.08)),
        StoryEffectPreset(id: "dream", name: "Dream", adjustments: ColorAdjust(brightness: 0.08, contrast: 0.88, saturation: 1.04, warmth: 0.12, vignette: 0), renderEffect: .softBlur),
        StoryEffectPreset(id: "moody", name: "Moody", adjustments: ColorAdjust(brightness: -0.06, contrast: 1.22, saturation: 0.82, warmth: -0.08, vignette: 0.28)),
        StoryEffectPreset(id: "bright", name: "Bright", adjustments: ColorAdjust(brightness: 0.10, contrast: 1.04, saturation: 1.08, warmth: 0.06, vignette: 0)),
        StoryEffectPreset(id: "vintage", name: "Vintage", adjustments: ColorAdjust(brightness: 0.02, contrast: 0.96, saturation: 0.78, warmth: 0.62, vignette: 0.16), lut: .vintage)
    ]

    static func preset(id: String?) -> StoryEffectPreset {
        presets.first { $0.id == id } ?? presets[0]
    }
}

struct StoryCreativeEffectPreset: Identifiable, Equatable {
    let effect: StoryRenderEffect
    let name: String
    let systemImage: String

    var id: String { effect.rawValue }
}

enum StoryCreativeEffectCatalog {
    static let presets: [StoryCreativeEffectPreset] = [
        StoryCreativeEffectPreset(effect: .none, name: "None", systemImage: "circle.slash"),
        StoryCreativeEffectPreset(effect: .clarify, name: "Clarity", systemImage: "sun.max.fill"),
        StoryCreativeEffectPreset(effect: .softBlur, name: "Dream", systemImage: "cloud.fill"),
        StoryCreativeEffectPreset(effect: .sharpen, name: "Detail", systemImage: "sparkles"),
        StoryCreativeEffectPreset(effect: .pixel, name: "Pixel", systemImage: "square.grid.3x3.fill"),
        StoryCreativeEffectPreset(effect: .dotScreen, name: "Dots", systemImage: "circle.grid.3x3.fill"),
        StoryCreativeEffectPreset(effect: .halftone, name: "Poster", systemImage: "circle.hexagongrid.fill"),
        StoryCreativeEffectPreset(effect: .glow, name: "Glow", systemImage: "sun.haze.fill"),
        StoryCreativeEffectPreset(effect: .comic, name: "Comic", systemImage: "text.bubble.fill"),
        StoryCreativeEffectPreset(effect: .edges, name: "Edges", systemImage: "scribble.variable"),
        StoryCreativeEffectPreset(effect: .crystallize, name: "Crystal", systemImage: "diamond.fill"),
        StoryCreativeEffectPreset(effect: .kaleidoscope, name: "Kaleido", systemImage: "hexagon.fill"),
        StoryCreativeEffectPreset(effect: .vhs, name: "VHS", systemImage: "videocassette.fill"),
        StoryCreativeEffectPreset(effect: .lightLeak, name: "Leak", systemImage: "sun.max.trianglebadge.exclamationmark"),
        StoryCreativeEffectPreset(effect: .chromatic, name: "RGB", systemImage: "circle.lefthalf.filled")
    ]
}
