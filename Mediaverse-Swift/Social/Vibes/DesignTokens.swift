import SwiftUI

/// WeStreem design-token layer that maps Element X's Compound iOS design
/// tokens onto our existing `C.*` palette. The Compound iOS package
/// (`element-hq/compound-ios`) ships as a SwiftPM dependency — this file
/// intentionally does not import it because pulling that package requires
/// editing `Project.pbxproj` from Xcode. Once added, the raw values below
/// can be swapped for the equivalent `CompoundCoreTokens` / `Compound`
/// semantic tokens without touching any consumers.
///
/// Scope: Vibes UI (WaveRoom, ThreadPanel, MediaViews, WatchParty, LiveStage).
/// Rest of the app continues to reference `C.pagePad`, `C.watch`, etc.
enum WestreemTokens {

    // MARK: - Design System palette
    //
    // These are the exact v1 values from the WeStreem Design System. Keep
    // semantic aliases in Constants.swift pointed here so platform surfaces
    // cannot drift by retyping hex values at call sites.
    enum Palette {
        static let ink950 = Color(hex: "#070A09")
        static let ink900 = Color(hex: "#0B0F0E")
        static let ink800 = Color(hex: "#0E1211")
        static let ink700 = Color(hex: "#151A18")
        static let lineSoft = Color(hex: "#1B2320")
        static let lineHard = Color(hex: "#2A332F")
        static let green = Color(hex: "#00E676")
        static let pink = Color(hex: "#FF3D8A")
        static let lavender = Color(hex: "#B388FF")
        static let text = Color(hex: "#E7EFEB")
        static let muted = Color(hex: "#7E8F89")
    }

    // Font files are not bundled in this checkout yet. These names are kept
    // as token metadata; existing semantic Font aliases remain system-backed
    // until the approved font assets are added to the app target.
    enum FontFamily {
        static let body = "Manrope"
        static let mono = "JetBrains Mono"
    }

    // MARK: - Spacing scale
    //
    // Matches Compound's `spacing` scale (`x4`, `x8`, `x12`, `x16`, `x24`,
    // `x32`) and Element X iOS usage. Use these instead of magic numbers so
    // future density changes cascade correctly.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Motion tokens

    enum Duration {
        static let fast: Double = 0.15
        static let standard: Double = 0.25
        static let slow: Double = 0.4
    }

    /// Reusable `Animation` presets so callers can write
    /// `withAnimation(WestreemTokens.Easing.standard) { ... }`.
    enum Easing {
        static let fast: Animation = .easeInOut(duration: Duration.fast)
        static let standard: Animation = .easeInOut(duration: Duration.standard)
        static let slow: Animation = .easeInOut(duration: Duration.slow)

        /// Compound uses a spring for interactive gestures (bottom sheets,
        /// message row actions). Response ~0.35 is a close match to Element X.
        static let spring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    }

    // MARK: - Typography scale
    //
    // Aligns with Compound's semantic type ramp (`headingXLBold`,
    // `headingLGBold`, `bodyMD`, `bodySM`, `bodyXS`). Kept as SwiftUI `Font`
    // so consumers can drop the values in directly.
    enum Typography {
        static let title: Font = .system(size: 22, weight: .bold, design: .default)
        static let heading: Font = .system(size: 17, weight: .semibold, design: .default)
        static let body: Font = .system(size: 15, weight: .regular, design: .default)
        static let bodyEmphasized: Font = .system(size: 15, weight: .semibold, design: .default)
        static let caption: Font = .system(size: 13, weight: .regular, design: .default)
        static let small: Font = .system(size: 11, weight: .medium, design: .default)
    }

    // MARK: - Corner radii

    enum Radius {
        static let small: CGFloat = 8
        static let control: CGFloat = 10
        static let large: CGFloat = 14
        static let full: CGFloat = 999

        /// Design System large radius for content cards.
        static let card: CGFloat = large
        /// Compound `borderRadius400`. Used by sheets & prominent surfaces.
        static let sheet: CGFloat = 16
        /// Compound `borderRadius600` — full pill for chips & QR frame.
        static let pill: CGFloat = 999
    }
}

// MARK: - Additional semantic colours
//
// The primary palette lives in `Constants.swift` as `C.*`. Compound layers a
// role-based set (`iconPrimary`, `iconSecondary`, `borderInteractive`,
// `textOnAccent`) on top of the palette. These extensions expose exactly
// those role tokens so Vibes UI can reference them the same way Element X
// iOS references Compound tokens.
extension C {
    /// Text/icon foreground when placed on top of `C.watch` (the accent).
    /// `C.watch` is `#00E676` — a high-luminance green — so black provides
    /// AAA contrast rather than white.
    static let textOnAccent: Color = .black

    /// Foreground icon tint for primary controls (matches `C.text`).
    static let iconPrimary: Color = C.text

    /// Foreground icon tint for secondary controls (matches `C.textMuted`).
    static let iconSecondary: Color = C.textMuted

    /// Border used on interactive controls when hovered/focused. Compound's
    /// `borderInteractiveHovered` maps to this. Falls back to `C.watch` at
    /// low opacity to give the impression of the accent glow.
    static let borderInteractive: Color = C.watch.opacity(0.35)

    /// Amber colour used exclusively by the offline banner. Distinct from
    /// `C.warning` so semantic search can distinguish "network offline" from
    /// "recoverable warning".
    static let offlineBanner: Color = Color(hex: "#F2B341")
}

// MARK: - View helpers
//
// Callers should use `.animation(WestreemTokens.Easing.standard, value: state)`
// directly rather than a wrapper — SwiftUI needs the actual state binding to
// decide when to animate, and hiding that behind a helper only invites bugs.
