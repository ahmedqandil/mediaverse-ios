import SwiftUI

/// Shown while AuthManager is checking the existing session.
struct SplashView: View {
    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            LinearGradient(
                colors: [
                    C.watch.opacity(0.20),
                    C.bg.opacity(0.0),
                    C.play.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .fill(C.watch.opacity(0.14))
                        .frame(width: 112, height: 112)
                    Circle()
                        .stroke(C.watch.opacity(0.30), lineWidth: 1)
                        .frame(width: 112, height: 112)
                    MediaverseIcon(name: "play", fallbackSystemName: "play.fill")
                        .frame(width: 42, height: 42)
                        .foregroundStyle(C.watch)
                }

                VStack(spacing: 8) {
                    Text("WeStreem")
                        .font(.system(size: 34, weight: .black))
                        .fontDesign(.rounded)
                        .foregroundStyle(C.text)
                    Text("Watch. Follow. Create.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(C.textMuted)
                }

                ProgressView()
                    .tint(C.watch)
            }
            .padding(.horizontal, C.pagePad)
        }
    }
}
