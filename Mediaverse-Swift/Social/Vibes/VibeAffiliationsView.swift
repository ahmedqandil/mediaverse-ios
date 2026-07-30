import SwiftUI

/// Legacy slug-scoped affiliation management cannot mutate Matrix Spaces.
/// Channel and Show affiliation review remains a separate Westreem workflow.
struct VibeAffiliationsView: View {
    let slug: String

    var body: some View {
        MatrixNativeLegacyRouteUnavailableView(
            title: "Legacy affiliation settings retired"
        )
    }
}
