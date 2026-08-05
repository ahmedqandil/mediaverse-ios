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
        static let ink950 = Color(hex: "#06090B")
        static let ink900 = Color(hex: "#0B0F0E")
        static let ink800 = Color(hex: "#0E1312")
        static let ink700 = Color(hex: "#1A201E")
        static let surfaceSunken = Color(hex: "#0C110F")
        static let surfaceSelected = Color(hex: "#101614")
        static let surfaceRaisedEnd = Color(hex: "#121716")
        static let lineSoft = Color(hex: "#131917")
        static let lineFrame = Color(hex: "#1E2724")
        static let lineEdge = Color(hex: "#232B29")
        static let lineHard = Color(hex: "#2C3531")
        static let green = Color(hex: "#00E676")
        static let greenSoft = Color(hex: "#8CF3BA")
        static let greenOn = Color(hex: "#04150C")
        static let greenDim = Color(hex: "#0E2A1D")
        static let actRow = Color(hex: "#0A1711")
        static let pink = Color(hex: "#FF3D8A")
        static let pinkOn = Color(hex: "#1C0410")
        static let pinkDim = Color(hex: "#2A0C1B")
        static let lavender = Color(hex: "#B388FF")
        static let lavenderOn = Color(hex: "#150B26")
        static let lavenderDim = Color(hex: "#1B1430")
        static let text = Color(hex: "#E7EFEB")
        static let textBody = Color(hex: "#D6E2DD")
        static let muted = Color(hex: "#A9B8B2")
        static let textFaint = Color(hex: "#5F6E69")
    }

    // Approved Design System fonts are bundled in Resources/Fonts under the
    // SIL Open Font License. Use their registered PostScript names so every
    // semantic token resolves deterministically on device and in extensions.
    enum FontFamily {
        static let body = "Manrope"
        static let mono = "JetBrains Mono"

        static let bodyRegular = "Manrope-Regular"
        static let bodyMedium = "Manrope-Medium"
        static let bodySemibold = "Manrope-SemiBold"
        static let bodyBold = "Manrope-Bold"
        static let monoMedium = "JetBrainsMonoRoman-Medium"
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
        static let fast: Double = 0.12
        static let standard: Double = 0.20
        static let slow: Double = 0.24
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
        static let title: Font = .custom(FontFamily.bodyBold, size: 22, relativeTo: .title2)
        static let heading: Font = .custom(FontFamily.bodySemibold, size: 17, relativeTo: .headline)
        static let body: Font = .custom(FontFamily.bodyRegular, size: 15, relativeTo: .body)
        static let bodyEmphasized: Font = .custom(FontFamily.bodySemibold, size: 15, relativeTo: .body)
        static let caption: Font = .custom(FontFamily.bodyRegular, size: 13, relativeTo: .caption)
        static let small: Font = .custom(FontFamily.bodyMedium, size: 11, relativeTo: .caption2)
        static let monoSmall: Font = .custom(FontFamily.monoMedium, size: 11, relativeTo: .caption2)
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip: CGFloat = 12
        static let row: CGFloat = 14
        static let card: CGFloat = 16
        static let panel: CGFloat = 18
        static let sheet: CGFloat = 26
        static let control: CGFloat = 999

        // Compatibility aliases for existing Vibes callers.
        static let small: CGFloat = chip
        static let large: CGFloat = card
        static let full: CGFloat = control

        /// Design System large radius for content cards.
        /// Full pill for chips and control surfaces.
        static let pill: CGFloat = control
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

// MARK: - Adaptive presentation

/// Design System 04-D / CORE-09 native sheet chrome. The keyed consumer owns
/// its detents and content; this modifier owns only the shared presentation
/// treatment and dismissal policy. Requiring detents prevents the primitive
/// from inventing feature-specific compact or half heights.
private struct WestreemAdaptiveSheetModifier: ViewModifier {
    let detents: Set<PresentationDetent>
    let dismissible: Bool

    func body(content: Content) -> some View {
        content
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(WestreemTokens.Radius.sheet)
            .presentationBackground(WestreemTokens.Palette.ink900)
            .interactiveDismissDisabled(!dismissible)
    }
}

extension View {
    /// Applies the exact WeStreem mobile sheet surface while preserving native
    /// iOS detents, rubber-band interaction, accessibility and keyboard flow.
    func westreemAdaptiveSheet(
        detents: Set<PresentationDetent>,
        dismissible: Bool = true
    ) -> some View {
        modifier(WestreemAdaptiveSheetModifier(
            detents: detents,
            dismissible: dismissible
        ))
    }
}

// MARK: - View helpers
//
// Callers should use `.animation(WestreemTokens.Easing.standard, value: state)`
// directly rather than a wrapper — SwiftUI needs the actual state binding to
// decide when to animate, and hiding that behind a helper only invites bugs.
