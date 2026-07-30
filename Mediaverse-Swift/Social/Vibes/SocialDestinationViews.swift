import SwiftUI

/// Compatibility destination for pre-Matrix slug links.
///
/// A legacy slug cannot safely identify a Matrix Space or Wave. The active app
/// therefore fails closed instead of querying or mutating the retired social
/// authority. New links carry exact Matrix room identifiers and enter through
/// `MatrixNativeVibesRootView`.
struct VibeDetailView: View {
    let slug: String
    var initialWaveSlug: String? = nil
    var initialManagementTab: String? = nil

    var body: some View {
        MatrixNativeLegacyRouteUnavailableView(
            title: initialManagementTab == nil
                ? (initialWaveSlug == nil
                    ? "Legacy Vibe link unavailable"
                    : "Legacy Wave link unavailable")
                : "Legacy Vibe settings retired"
        )
    }
}

/// Compatibility destination for a legacy Westreem Ripple identifier.
///
/// Matrix events require both room and event identifiers. An unscoped legacy
/// post id must never be guessed or resolved through the retired Fan Club API.
struct RippleDetailView: View {
    let postId: String

    var body: some View {
        MatrixNativeLegacyRouteUnavailableView(
            title: "Legacy Ripple link unavailable"
        )
    }
}
