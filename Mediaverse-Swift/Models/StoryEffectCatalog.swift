import Foundation

struct StoryEffectPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let adjustments: ColorAdjust
    let renderEffect: StoryRenderEffect

    init(id: String, name: String, adjustments: ColorAdjust, renderEffect: StoryRenderEffect = .none) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.renderEffect = renderEffect
    }
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
}

enum StoryEffectCatalog {
    static let presets: [StoryEffectPreset] = [
        StoryEffectPreset(id: "neutral", name: "Neutral", adjustments: .neutral),
        StoryEffectPreset(id: "smooth", name: "Smooth", adjustments: .neutral, renderEffect: .skinSmooth),
        StoryEffectPreset(id: "warm", name: "Warm", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.04, saturation: 1.08, warmth: 0.45, vignette: 0.05)),
        StoryEffectPreset(id: "golden", name: "Golden", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.08, saturation: 1.12, warmth: 0.62, vignette: 0.08)),
        StoryEffectPreset(id: "sunset", name: "Sunset", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.12, saturation: 1.18, warmth: 0.78, vignette: 0.16)),
        StoryEffectPreset(id: "rose", name: "Rose", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.03, saturation: 1.10, warmth: 0.18, vignette: 0.05)),
        StoryEffectPreset(id: "cool", name: "Cool", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.03, saturation: 1.02, warmth: -0.42, vignette: 0.04)),
        StoryEffectPreset(id: "aqua", name: "Aqua", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.06, saturation: 1.10, warmth: -0.62, vignette: 0.06)),
        StoryEffectPreset(id: "teal", name: "Teal", adjustments: ColorAdjust(brightness: -0.01, contrast: 1.10, saturation: 1.06, warmth: -0.34, vignette: 0.12)),
        StoryEffectPreset(id: "bw", name: "B&W", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.18, saturation: 0, warmth: 0, vignette: 0.18)),
        StoryEffectPreset(id: "noir", name: "Noir", adjustments: ColorAdjust(brightness: -0.04, contrast: 1.32, saturation: 0, warmth: -0.06, vignette: 0.30)),
        StoryEffectPreset(id: "film", name: "Film", adjustments: ColorAdjust(brightness: -0.02, contrast: 1.12, saturation: 0.92, warmth: 0.22, vignette: 0.22)),
        StoryEffectPreset(id: "cinema", name: "Cinema", adjustments: ColorAdjust(brightness: -0.03, contrast: 1.20, saturation: 0.90, warmth: -0.12, vignette: 0.22)),
        StoryEffectPreset(id: "vivid", name: "Vivid", adjustments: ColorAdjust(brightness: 0.03, contrast: 1.16, saturation: 1.28, warmth: 0.08, vignette: 0.06)),
        StoryEffectPreset(id: "pop", name: "Pop", adjustments: ColorAdjust(brightness: 0.04, contrast: 1.20, saturation: 1.36, warmth: 0.02, vignette: 0.04)),
        StoryEffectPreset(id: "crisp", name: "Crisp", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.18, saturation: 1.08, warmth: -0.04, vignette: 0.04), renderEffect: .sharpen),
        StoryEffectPreset(id: "fade", name: "Fade", adjustments: ColorAdjust(brightness: 0.06, contrast: 0.86, saturation: 0.86, warmth: 0.12, vignette: 0)),
        StoryEffectPreset(id: "matte", name: "Matte", adjustments: ColorAdjust(brightness: 0.03, contrast: 0.90, saturation: 0.92, warmth: 0.10, vignette: 0.08)),
        StoryEffectPreset(id: "dream", name: "Dream", adjustments: ColorAdjust(brightness: 0.08, contrast: 0.88, saturation: 1.04, warmth: 0.12, vignette: 0), renderEffect: .softBlur),
        StoryEffectPreset(id: "moody", name: "Moody", adjustments: ColorAdjust(brightness: -0.06, contrast: 1.22, saturation: 0.82, warmth: -0.08, vignette: 0.28)),
        StoryEffectPreset(id: "bright", name: "Bright", adjustments: ColorAdjust(brightness: 0.10, contrast: 1.04, saturation: 1.08, warmth: 0.06, vignette: 0)),
        StoryEffectPreset(id: "vintage", name: "Vintage", adjustments: ColorAdjust(brightness: 0.02, contrast: 0.96, saturation: 0.78, warmth: 0.62, vignette: 0.16))
    ]

    static func preset(id: String?) -> StoryEffectPreset {
        presets.first { $0.id == id } ?? presets[0]
    }
}
