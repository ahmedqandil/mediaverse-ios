import SwiftUI

/// Compatibility presentation for callers that still expose the former
/// create-Vibe sheet. Creation is now performed by the Matrix-native client.
struct CreateVibeView: View {
    let onCreated: (VibeSummary) -> Void

    var body: some View {
        NavigationStack {
            MatrixNativeVibesRootView()
        }
    }
}
