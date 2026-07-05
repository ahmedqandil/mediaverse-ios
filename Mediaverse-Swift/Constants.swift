import SwiftUI

enum C {
    // ── API ──────────────────────────────────────────────────────────────────
    /// Base URL of the Mediaverse web backend (no trailing slash).
    /// Override in scheme environment variables: MEDIAVERSE_BASE_URL
    static var baseURL: String {
        ProcessInfo.processInfo.environment["MEDIAVERSE_BASE_URL"]
            ?? "https://www.westreem.com"
    }

    static func mediaURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        let path = value.hasPrefix("/") ? value : "/\(value)"
        return URL(string: baseURL + path)
    }

    // ── Colors (exact match to web globals.css CSS variables) ─────────────
    // Background depth hierarchy
    static let bg          = Color(hex: "#080810")   // --bg-base / --night
    static let surface     = Color(hex: "#0F1019")   // --bg-surface
    static let elevated    = Color(hex: "#161824")   // --bg-elevated
    static let overlay     = Color(hex: "#1E1F30")   // --bg-overlay
    // Legacy alias so existing code using surfaceAlt keeps compiling
    static let surfaceAlt  = Color(hex: "#161824")   // → elevated

    // Text hierarchy
    static let text         = Color(hex: "#F0F0F5")                              // --text-primary
    static let textMuted    = Color(red: 240/255, green: 240/255, blue: 245/255).opacity(0.55)  // --text-secondary
    static let textTertiary = Color(red: 240/255, green: 240/255, blue: 245/255).opacity(0.28)  // --text-tertiary

    // Borders
    static let borderSubtle  = Color.white.opacity(0.06)   // --border-subtle
    static let border        = Color.white.opacity(0.10)   // --border-default
    static let borderStrong  = Color.white.opacity(0.22)   // --border-strong

    // Accent colours — super-app palette
    static let watch     = Color(hex: "#00E676")   // --watch  (green)
    static let watchDim  = Color(hex: "#00C853")   // --watch-dim
    static let listen    = Color(hex: "#C77DFF")   // --listen (purple, microdramas)
    static let listenDim = Color(hex: "#9C4DCC")   // --listen-dim
    static let play      = Color(hex: "#40C4FF")   // --play   (light blue)

    // Semantic accent (defaults to watch)
    static let accent = Color(hex: "#00E676")

    // ── Layout ───────────────────────────────────────────────────────────────
    static let cardRadius: CGFloat  = 12
    static let pagePad: CGFloat     = 16
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
