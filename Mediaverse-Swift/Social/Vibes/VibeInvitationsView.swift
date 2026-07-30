import SwiftUI

/// Compatibility destination for invitation links issued before Matrix
/// cutover. Matrix invitations now arrive through native room membership.
struct VibeInviteAcceptView: View {
    let token: String

    var body: some View {
        MatrixNativeLegacyRouteUnavailableView(title: "Legacy invitation retired")
    }
}
