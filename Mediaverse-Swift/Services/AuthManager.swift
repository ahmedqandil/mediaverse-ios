import SwiftUI
import AuthenticationServices

/// Manages authentication state for the entire app.
/// Handles magic-link email flow and Google OAuth via ASWebAuthenticationSession.
@MainActor
final class AuthManager: ObservableObject {

    // MARK: - Published state

    @Published var isLoading       = true
    @Published var isAuthenticated = false
    @Published var currentUser: UserProfile?

    // Magic-link step 1: waiting for user to tap the emailed link
    @Published var magicLinkPending  = false
    @Published var magicLinkEmail    = ""
    @Published var magicLinkDebugURL: String?

    private var webAuthSession: ASWebAuthenticationSession?

    // MARK: - Init

    init() {
        if SessionStorage.token != nil {
            // Token was stored from a previous session — restore immediately.
            // Setting state synchronously prevents any race condition with background checks.
            isAuthenticated = true
            isLoading       = false
            // Background-refresh the user profile (non-blocking, won't reset auth on failure)
            Task { await refreshUser() }
        } else {
            Task { await checkSession() }
        }
    }

    // MARK: - Session check

    /// Full network check. Only used on cold start when no stored token exists.
    func checkSession() async {
        defer { isLoading = false }
        do {
            let user = try await APIClient.shared.fetchSession()
            currentUser     = user
            isAuthenticated = user != nil
            // If server returned a user, nothing more needed.
            // If nil, isAuthenticated stays false → LoginView.
        } catch {
            isAuthenticated = false
        }
    }

    /// Background user-profile refresh. Never resets auth on failure.
    private func refreshUser() async {
        if let user = try? await APIClient.shared.fetchSession() {
            currentUser = user
        }
        isLoading = false
    }

    // MARK: - Post-login state setter

    /// Called immediately after any successful login (magic link or Google OAuth).
    /// Sets auth state synchronously so there's zero risk of a race condition.
    private func didAuthenticate() {
        isAuthenticated  = true
        isLoading        = false
        magicLinkPending = false
        // Fetch user profile in background — doesn't block the UI transition
        Task { await refreshUser() }
    }

    // MARK: - Magic link

    /// Step 1: send the email.
    func requestMagicLink(email: String) async throws {
        let debugURL = try await APIClient.shared.requestMagicLink(email: email)
        magicLinkEmail    = email
        magicLinkDebugURL = debugURL
        magicLinkPending  = true
    }

    /// Step 2: called from onOpenURL when the deep link arrives.
    /// Handles both magic-link and Google OAuth callbacks.
    func handleDeepLink(_ url: URL) {
        Task { try? await authenticate(from: url) }
    }

    private func authenticate(from url: URL) async throws {
        guard url.scheme == "westreem",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw APIError.badURL(url.absoluteString) }

        let path = url.path

        if path == "/verify" {
            // Magic link: westreem:///verify?token=...
            guard let token = comps.queryItems?.first(where: { $0.name == "token" })?.value
            else { throw APIError.unauthorized }

            let ok = try await APIClient.shared.verifyMagicLink(token: token)
            if ok { didAuthenticate() }
        } else if path == "/auth/google" {
            // Google OAuth fallback: westreem:///auth/google?sessionToken=...
            guard let jwt = comps.queryItems?.first(where: { $0.name == "sessionToken" })?.value
            else { throw APIError.unauthorized }

            await APIClient.shared.storeSessionToken(jwt)
            didAuthenticate()
        } else {
            throw APIError.badURL(url.absoluteString)
        }
    }

    private func callbackURL(from startURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: "westreem"
            ) { [weak self] url, error in
                Task { @MainActor in
                    self?.webAuthSession = nil
                    if let error { cont.resume(throwing: error) }
                    else if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: APIError.unauthorized) }
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = WebAuthAnchor.shared
            webAuthSession = session

            if !session.start() {
                webAuthSession = nil
                cont.resume(throwing: APIError.unauthorized)
            }
        }
    }

    // MARK: - Google OAuth

    func signInWithGoogle() async throws {
        guard let startURL = URL(string: "\(C.baseURL)/api/auth/google?mobile=true&appScheme=westreem")
        else { throw APIError.badURL("/api/auth/google") }

        let callbackURL = try await callbackURL(from: startURL)
        try await authenticate(from: callbackURL)
    }

    func signInWithMagicLinkURL(_ url: URL) async throws {
        let callbackURL = try await callbackURL(from: url)
        try await authenticate(from: callbackURL)
    }

    // MARK: - Sign out

    func signOut() async {
        try? await APIClient.shared.signOut()
        await APIClient.shared.clearSessionToken()
        currentUser     = nil
        isAuthenticated = false
    }
}

// MARK: - ASWebAuthenticationSession presentation anchor

final class WebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthAnchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
