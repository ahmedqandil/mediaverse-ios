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
        Image("westreem-mark")
            .resizable()
            .scaledToFit()
            .frame(width: 148, height: 148)
            .scaleEffect(isAnimating ? 1.03 : 0.97)
            .shadow(color: C.watch.opacity(0.30), radius: 18, x: 0, y: 0)
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
