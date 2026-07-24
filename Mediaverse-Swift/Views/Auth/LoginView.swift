import SwiftUI
import AuthenticationServices

/// Two-step sign-in: email -> magic link tap, or Google OAuth.
/// Mirrors /src/app/auth/signin/page.tsx mobile layout and state order.
struct LoginView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMsg: String?

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    brandHeader
                        .padding(.bottom, 32)

                    if auth.biometricUnlockRequired {
                        biometricUnlockView
                    } else if auth.magicLinkPending {
                        magicLinkSentView
                    } else {
                        signInCard
                    }
                }
                .frame(maxWidth: 390)
                .padding(.horizontal, C.pagePad)
                .padding(.top, 76)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(C.watch.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Circle().stroke(C.watch.opacity(0.26), lineWidth: 1)
                    }
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(C.watch)
            }
            VStack(spacing: 4) {
                Text("WeStreem")
                    .font(.system(size: 28, weight: .black))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.text)
                Text("Your streaming superapp")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("We'll send a magic link to your inbox. No password needed.")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            googleButton
            biometricButton
            divider
            emailForm

            Text("By continuing, you agree to our Terms of Service.\nNew accounts are created automatically.")
                .font(.system(size: 11))
                .foregroundStyle(C.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .padding(28)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var biometricButton: some View {
        if auth.biometricUnlockEnabled && auth.biometricUnlockAvailable && SessionStorage.token != nil {
            Button {
                Task { await auth.unlockWithBiometrics() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "faceid")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Continue with \(auth.biometricTypeName)")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(C.text)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(C.elevated)
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(C.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var biometricUnlockView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(C.watch.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "faceid")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(C.watch)
            }

            VStack(spacing: 8) {
                Text("Unlock WeStreem")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("Use \(auth.biometricTypeName) to continue with your saved session.")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)
            }

            if let message = auth.biometricErrorMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.15), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                Task { await auth.unlockWithBiometrics() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                    Text("Unlock with \(auth.biometricTypeName)")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(C.watch)
                .clipShape(RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain)

            Button {
                auth.useFullSignInInstead()
            } label: {
                Text("Use another sign-in method")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            await auth.unlockWithBiometrics()
        }
    }

    private var googleButton: some View {
        Button {
            Task { await signInWithGoogle() }
        } label: {
            HStack(spacing: 12) {
                googleMark
                Text("Continue with Google")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "#1F1F1F"))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color(hex: "#DADCE0"), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.65 : 1)
    }

    private var googleMark: some View {
        GoogleLogoMark()
        .frame(width: 18, height: 18)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            Text("OR")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.textTertiary)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("EMAIL ADDRESS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(C.textMuted.opacity(0.92))
                ZStack(alignment: .leading) {
                    if email.isEmpty {
                        Text("you@example.com")
                            .font(.system(size: 14))
                            .foregroundStyle(C.textTertiary)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        .font(.system(size: 14))
                        .foregroundStyle(C.text)
                        .tint(C.watch)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(C.elevated)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let errorMsg {
                Text(errorMsg)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.15), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                Task { await sendMagicLink() }
            } label: {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Text("Continue with email")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(C.watch)
                .clipShape(RoundedRectangle(cornerRadius: 23))
                .opacity(isLoading || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var magicLinkSentView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(C.watch.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "envelope")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(C.watch)
            }

            VStack(spacing: 8) {
                Text("Check your inbox")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("We sent a sign-in link to")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
                Text(auth.magicLinkEmail)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .lineLimit(1)
            }

            #if DEBUG
            if let debugURL = auth.magicLinkDebugURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NO EMAIL CONFIGURED - TAP TO SIGN IN:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.watch)
                    Button {
                        Task { await signInWithDebugMagicLink(debugURL) }
                    } label: {
                        Text(debugURL)
                            .font(.system(size: 11))
                            .foregroundStyle(C.watch)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.watch.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.watch.opacity(0.20), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #endif

            Text("Click the link in the email to sign in. It expires in 24 hours.\nIf you don't see it, check your spam folder.")
                .font(.system(size: 12))
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                auth.magicLinkPending = false
                auth.magicLinkEmail = ""
                auth.magicLinkDebugURL = nil
                email = ""
                errorMsg = nil
            } label: {
                Label("Use a different email", systemImage: "arrow.left")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func sendMagicLink() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        do {
            try await auth.requestMagicLink(email: trimmed)
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func signInWithGoogle() async {
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        do {
            try await auth.signInWithGoogle()
        } catch {
            if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                errorMsg = error.localizedDescription
            }
        }
    }

    #if DEBUG
    private func signInWithDebugMagicLink(_ debugURL: String) async {
        guard let url = URL(string: debugURL) else { return }
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        do {
            try await auth.signInWithMagicLinkURL(url)
        } catch {
            if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                errorMsg = error.localizedDescription
            }
        }
    }
    #endif
}

private struct GoogleLogoMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = size * 0.18
            let rect = CGRect(
                x: (proxy.size.width - size) / 2 + lineWidth / 2,
                y: (proxy.size.height - size) / 2 + lineWidth / 2,
                width: size - lineWidth,
                height: size - lineWidth
            )

            Canvas { context, _ in
                func strokeArc(start: Angle, end: Angle, color: Color) {
                    var path = Path()
                    path.addArc(
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        radius: rect.width / 2,
                        startAngle: start,
                        endAngle: end,
                        clockwise: false
                    )
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                strokeArc(start: .degrees(-38), end: .degrees(45), color: Color(hex: "#4285F4"))
                strokeArc(start: .degrees(45), end: .degrees(145), color: Color(hex: "#34A853"))
                strokeArc(start: .degrees(145), end: .degrees(215), color: Color(hex: "#FBBC05"))
                strokeArc(start: .degrees(215), end: .degrees(322), color: Color(hex: "#EA4335"))

                var bar = Path()
                bar.move(to: CGPoint(x: rect.midX, y: rect.midY))
                bar.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                context.stroke(bar, with: .color(Color(hex: "#4285F4")), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

                var shortStem = Path()
                shortStem.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                shortStem.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.midY + rect.height * 0.22))
                context.stroke(shortStem, with: .color(Color(hex: "#4285F4")), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
