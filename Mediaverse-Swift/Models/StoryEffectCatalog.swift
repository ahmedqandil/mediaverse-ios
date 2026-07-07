import Foundation

struct StoryEffectPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let adjustments: ColorAdjust
}

enum StoryEffectCatalog {
    static let presets: [StoryEffectPreset] = [
        StoryEffectPreset(id: "neutral", name: "Neutral", adjustments: .neutral),
        StoryEffectPreset(id: "warm", name: "Warm", adjustments: ColorAdjust(brightness: 0.02, contrast: 1.04, saturation: 1.08, warmth: 0.45, vignette: 0.05)),
        StoryEffectPreset(id: "cool", name: "Cool", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.03, saturation: 1.02, warmth: -0.42, vignette: 0.04)),
        StoryEffectPreset(id: "bw", name: "B&W", adjustments: ColorAdjust(brightness: 0.01, contrast: 1.18, saturation: 0, warmth: 0, vignette: 0.18)),
        StoryEffectPreset(id: "film", name: "Film", adjustments: ColorAdjust(brightness: -0.02, contrast: 1.12, saturation: 0.92, warmth: 0.22, vignette: 0.22)),
        StoryEffectPreset(id: "vivid", name: "Vivid", adjustments: ColorAdjust(brightness: 0.03, contrast: 1.16, saturation: 1.28, warmth: 0.08, vignette: 0.06)),
        StoryEffectPreset(id: "fade", name: "Fade", adjustments: ColorAdjust(brightness: 0.06, contrast: 0.86, saturation: 0.86, warmth: 0.12, vignette: 0)),
        StoryEffectPreset(id: "moody", name: "Moody", adjustments: ColorAdjust(brightness: -0.06, contrast: 1.22, saturation: 0.82, warmth: -0.08, vignette: 0.28)),
        StoryEffectPreset(id: "bright", name: "Bright", adjustments: ColorAdjust(brightness: 0.10, contrast: 1.04, saturation: 1.08, warmth: 0.06, vignette: 0)),
        StoryEffectPreset(id: "vintage", name: "Vintage", adjustments: ColorAdjust(brightness: 0.02, contrast: 0.96, saturation: 0.78, warmth: 0.62, vignette: 0.16))
    ]

    static func preset(id: String?) -> StoryEffectPreset {
        presets.first { $0.id == id } ?? presets[0]
    }
}
