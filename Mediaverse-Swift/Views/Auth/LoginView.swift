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

                    if auth.magicLinkPending {
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
                    .fill(C.watch.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(C.watch)
            }
            VStack(spacing: 4) {
                Text("WeStreem")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(C.text)
                Text("Your streaming superapp")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textTertiary)
            }
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("We'll send a magic link to your inbox - no password needed.")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            googleButton
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
        .background(Color.white.opacity(0.03))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var googleButton: some View {
        Button {
            Task { await signInWithGoogle() }
        } label: {
            HStack(spacing: 12) {
                googleMark
                Text("Continue with Google")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var googleMark: some View {
        ZStack {
            Text("G")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: "#4285F4"))
        }
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
                    .foregroundStyle(C.textMuted)
                TextField("you@example.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(C.text)
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
                        Text("Continue with email ->")
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
                    .foregroundStyle(C.textTertiary)
                Text(auth.magicLinkEmail)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .lineLimit(1)
            }

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

            Text("Click the link in the email to sign in. It expires in 24 hours.\nIf you don't see it, check your spam folder.")
                .font(.system(size: 12))
                .foregroundStyle(C.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                auth.magicLinkPending = false
                auth.magicLinkEmail = ""
                auth.magicLinkDebugURL = nil
                email = ""
                errorMsg = nil
            } label: {
                Text("<- Use a different email")
                    .font(.system(size: 14))
                    .foregroundStyle(C.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .background(Color.white.opacity(0.03))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
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
}
