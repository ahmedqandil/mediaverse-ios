import SwiftUI

/// Shown while AuthManager is checking the existing session.
struct SplashView: View {
    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(C.watch)
                Text("Mediaverse")
                    .font(.system(size: 28, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.text)
                ProgressView()
                    .tint(C.watch)
            }
        }
    }
}
