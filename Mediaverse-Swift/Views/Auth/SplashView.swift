import SwiftUI

/// Cold-start surface shown while the app restores session state and warms core services.
struct SplashView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            LinearGradient(
                colors: [
                    C.watch.opacity(0.28),
                    C.bg.opacity(0.04),
                    C.play.opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                logoMark

                VStack(spacing: 8) {
                    Text("WeStreem")
                        .font(.system(size: 36, weight: .black))
                        .fontDesign(.rounded)
                        .foregroundStyle(C.text)

                    Text("Watch. Follow. Create.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                }

                loadingBar
                    .frame(width: 148)
                    .padding(.top, 4)
            }
            .padding(.horizontal, C.pagePad)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var logoMark: some View {
        ZStack {
            Circle()
                .fill(C.watch.opacity(isAnimating ? 0.22 : 0.12))
                .frame(width: 124, height: 124)
                .scaleEffect(isAnimating ? 1.04 : 0.98)

            Circle()
                .stroke(C.watch.opacity(0.34), lineWidth: 1)
                .frame(width: 124, height: 124)

            Circle()
                .stroke(C.play.opacity(0.20), lineWidth: 8)
                .frame(width: 96, height: 96)

            MediaverseIcon(name: "play", fallbackSystemName: "play.fill")
                .frame(width: 44, height: 44)
                .foregroundStyle(C.watch)
                .shadow(color: C.watch.opacity(0.30), radius: 18, x: 0, y: 0)
        }
    }

    private var loadingBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))

                Capsule()
                    .fill(C.watch)
                    .frame(width: proxy.size.width * (isAnimating ? 0.72 : 0.28))
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isAnimating)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
