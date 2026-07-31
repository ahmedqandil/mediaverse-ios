import SwiftUI
import AuthenticationServices
import LocalAuthentication

enum StoredSessionValidation: Equatable {
    case authenticated
    case rejected

    static func resolve(hasUser: Bool) -> Self {
        hasUser ? .authenticated : .rejected
    }
}

/// Decides whether a 401 response is authoritative for the session that is
/// currently installed. Requests started before a magic-link completion or an
/// account switch may finish later with 401; that stale response must fail its
/// own operation without deleting the newer account's credential.
enum SessionRejectionPolicy {
    static func shouldExpireCurrentSession(
        responseStatus: Int,
        requestToken: String?,
        currentToken: String?
    ) -> Bool {
        responseStatus == 401
            && requestToken != nil
            && requestToken == currentToken
    }
}

/// Manages authentication state for the entire app.
/// Handles magic-link email flow and Google OAuth via ASWebAuthenticationSession.
@MainActor
final class AuthManager: ObservableObject {

    // MARK: - Published state

    @Published var isLoading       = true
    @Published var isAuthenticated = false
    @Published var currentUser: UserProfile?
    @Published var biometricUnlockAvailable = false
    @Published var biometricUnlockEnabled = false
    @Published var biometricUnlockRequired = false
    @Published var biometricTypeName = "Face ID"
    @Published var biometricErrorMessage: String?

    // Magic-link step 1: waiting for user to tap the emailed link
    @Published var magicLinkPending  = false
    @Published var magicLinkEmail    = ""
    @Published var magicLinkDebugURL: String?
    @Published var pendingDeviceActivationCode: String?

    private var webAuthSession: ASWebAuthenticationSession?
    private var sessionExpiredObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var authGeneration = UUID()

    // MARK: - Init

    init() {
        observeSessionExpiry()
        refreshBiometricCapability()
        biometricUnlockEnabled = SessionStorage.biometricUnlockEnabled

        if SessionStorage.token != nil {
            if biometricUnlockEnabled && biometricUnlockAvailable {
                biometricUnlockRequired = true
                isLoading = false
            } else {
                restoreStoredSession()
            }
        } else {
            Task { await checkSession() }
        }
    }

    deinit {
        if let sessionExpiredObserver {
            NotificationCenter.default.removeObserver(sessionExpiredObserver)
        }
        refreshTask?.cancel()
    }

    // MARK: - Session check

    private func observeSessionExpiry() {
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .sessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.expireSessionLocally()
            }
        }
    }

    private func expireSessionLocally() async {
        authGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        currentUser = nil
        isAuthenticated = false
        isLoading = false
        biometricUnlockRequired = false
        pendingDeviceActivationCode = nil
        await CacheMaintenanceService.shared.clearUserScopedCaches()
    }

    /// Full network check. Only used on cold start when no stored token exists.
    func checkSession() async {
        let generation = authGeneration
        do {
            let user = try await APIClient.shared.fetchSession()
            guard authGeneration == generation else { return }
            currentUser     = user
            isAuthenticated = user != nil
            // If server returned a user, nothing more needed.
            // If nil, isAuthenticated stays false → LoginView.
        } catch {
            guard authGeneration == generation else { return }
            isAuthenticated = false
        }
        if authGeneration == generation {
            isLoading = false
        }
    }

    /// Background user-profile refresh. Transient transport failures retain the
    /// local session, but an explicit `{ user: null }` response means the stored
    /// JWT is no longer a valid authenticated session.
    private func refreshUser(generation: UUID) async {
        do {
            let user = try await APIClient.shared.fetchSession()
            guard StoredSessionValidation.resolve(hasUser: user != nil) == .authenticated,
                  let user else {
                guard authGeneration == generation else { return }
                await APIClient.shared.clearSessionToken()
                await expireSessionLocally()
                return
            }
            guard authGeneration == generation else { return }
            currentUser = user
        } catch {
            // Stay signed in during a temporary connectivity failure. Authenticated
            // endpoints still expire the session immediately if they return 401.
        }
        if authGeneration == generation {
            isLoading = false
        }
    }

    // MARK: - Post-login state setter

    /// Called immediately after any successful login (magic link or Google OAuth).
    /// Sets auth state synchronously so there's zero risk of a race condition.
    private func didAuthenticate() {
        authGeneration = UUID()
        let generation = authGeneration
        isAuthenticated  = true
        isLoading        = false
        magicLinkPending = false
        biometricUnlockRequired = false
        enableBiometricUnlockIfAvailable()
        // Fetch user profile in background — doesn't block the UI transition
        Task { await refreshUser(generation: generation) }
        Task { await PushNotificationManager.shared.retryRegistrationIfAuthorized() }
    }

    // MARK: - Magic link

    /// Step 1: send the email.
    func requestMagicLink(email: String) async throws {
        let debugURL = try await APIClient.shared.requestMagicLink(email: email)
        magicLinkEmail    = email
        magicLinkDebugURL = debugURL
        magicLinkPending  = true
    }

    /// Step 2: called from onOpenURL/universal links when the deep link arrives.
    /// Handles magic-link, Google OAuth, and web-style device pairing links.
    func handleDeepLink(_ url: URL) {
        Task { await handleIncomingLink(url) }
    }

    static func isAuthenticationLink(_ url: URL) -> Bool {
        let isCustomScheme = url.scheme == "westreem"
        let isUniversalLink = url.scheme == "https" && [ "westreem.com", "www.westreem.com" ].contains(url.host ?? "")
        guard isCustomScheme || isUniversalLink else { return false }
        let route = deepLinkRouteName(from: url)
        return route == "verify" || route == "auth/verify" || route == "auth/google"
    }

    private func handleIncomingLink(_ url: URL) async {
        if let code = Self.deviceActivationCode(from: url) {
            pendingDeviceActivationCode = code
            return
        }

        try? await authenticate(from: url)
    }

    func requestDeviceActivation(code: String) {
        guard let normalized = Self.normalizedActivationCode(code) else { return }
        pendingDeviceActivationCode = normalized
    }

    private func authenticate(from url: URL) async throws {
        let isCustomScheme   = url.scheme == "westreem"
        // Fix 4: also accept universal links from westreem.com (AASA now covers /auth/verify)
        let isUniversalLink  = url.scheme == "https" &&
            ["westreem.com", "www.westreem.com"].contains(url.host ?? "")

        guard (isCustomScheme || isUniversalLink),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw APIError.badURL(url.absoluteString) }

        let route = Self.deepLinkRouteName(from: url)

        if route == "verify" || route == "auth/verify" {
            // Magic link: westreem:///verify?token=... OR https://westreem.com/auth/verify?token=...
            guard let token = comps.queryItems?.first(where: { $0.name == "token" })?.value
            else { throw APIError.unauthorized }

            let ok = try await APIClient.shared.verifyMagicLink(token: token)
            if ok { didAuthenticate() }
        } else if route == "auth/google" {
            // Google OAuth fallback: westreem:///auth/google?sessionToken=...
            guard let jwt = comps.queryItems?.first(where: { $0.name == "sessionToken" })?.value
            else { throw APIError.unauthorized }

            await APIClient.shared.storeSessionToken(jwt)
            didAuthenticate()
        } else if route == "activate" {
            guard let code = Self.deviceActivationCode(from: url) else { throw APIError.badURL(url.absoluteString) }
            pendingDeviceActivationCode = code
        } else {
            throw APIError.badURL(url.absoluteString)
        }
    }

    static func deviceActivationCode(from userInfo: [AnyHashable: Any]) -> String? {
        let codeKeys = ["code", "userCode", "user_code", "activationCode", "activation_code", "pairingCode", "pairing_code", "deviceCode", "device_code"]
        for key in codeKeys {
            if let value = stringValue(for: key, in: userInfo), let normalized = normalizedActivationCode(value) {
                return normalized
            }
        }

        let linkKeys = ["linkUrl", "link_url", "url", "deeplink", "deepLink", "activationUrl", "activation_url", "pairingUrl", "pairing_url"]
        for key in linkKeys {
            guard let value = stringValue(for: key, in: userInfo), let url = URL(string: value) else { continue }
            if let code = deviceActivationCode(from: url) {
                return code
            }
        }
        return nil
    }

    private static func deepLinkRouteName(from url: URL) -> String {
        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "auth", path == "google" { return "auth/google" }
        if !path.isEmpty { return path }
        return host
    }

    static func deviceActivationCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let pathParts = url.path
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let route = deepLinkRouteName(from: url).lowercased()
        let host = (url.host ?? "").lowercased()
        let isAppScheme = url.scheme == "westreem"
        let isWebLink = ["westreem.com", "www.westreem.com"].contains(host)
        let isActivationRoute = route == "activate"
            || route == "pair"
            || route == "pairing"
            || route == "device/activate"
            || route == "device/pair"
            || route == "devices/activate"
            || route == "devices/pair"
            || route == "auth/device/activate"
            || route == "auth/device/pair"
            || pathParts.contains("activate") && (pathParts.contains("device") || pathParts.contains("devices") || pathParts.contains("auth"))
            || pathParts.contains("pair")
            || pathParts.contains("pairing")

        guard (isAppScheme || isWebLink), isActivationRoute else { return nil }

        let queryNames = ["code", "userCode", "user_code", "activationCode", "activation_code", "pairingCode", "pairing_code", "deviceCode", "device_code"]
        for name in queryNames {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value,
               let normalized = normalizedActivationCode(value) {
                return normalized
            }
        }

        if let candidate = pathParts.last, let normalized = normalizedActivationCode(candidate) {
            return normalized
        }
        return nil
    }

    static func normalizedActivationCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeWords = Set(["activate", "pair", "pairing", "device", "devices", "auth"])
        guard !trimmed.isEmpty, !routeWords.contains(trimmed.lowercased()) else { return nil }
        return trimmed.uppercased()
    }

    private static func stringValue(for key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String, !value.isEmpty { return value }
        if let value = userInfo[AnyHashable(key)] as? String, !value.isEmpty { return value }
        if let value = userInfo[key] as? CustomStringConvertible {
            let string = value.description
            if !string.isEmpty { return string }
        }
        if let value = userInfo[AnyHashable(key)] as? CustomStringConvertible {
            let string = value.description
            if !string.isEmpty { return string }
        }
        return nil
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

    // MARK: - Token refresh (Fix 6)

    /// Decode the `exp` claim from the JWT payload without verifying the signature.
    /// Used only to decide whether a refresh call is worth making — the server still
    /// verifies the full token.
    static func tokenExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp  = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Call on foreground resume. Silently refreshes if the token expires within 24 h.
    /// Never signs the user out — a failed refresh just retains the old token.
    func refreshSessionIfNeeded() {
        guard isAuthenticated,
              let token  = SessionStorage.token,
              let expiry = Self.tokenExpiry(token) else { return }
        let hoursLeft = expiry.timeIntervalSinceNow / 3_600
        guard hoursLeft < 24, refreshTask == nil else { return }
        let generation = authGeneration
        refreshTask = Task { @MainActor in
            defer {
                if authGeneration == generation {
                    refreshTask = nil
                }
            }
            try? await APIClient.shared.refreshMobileToken()
        }
    }

    // MARK: - Sign out

    func signOut() async {
        authGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        // Remove both the Westreem APNs record and the canonical Matrix HTTP
        // pusher while both authenticated sessions are still available.
        await PushNotificationManager.shared.unregisterForSignOut()
        try? await APIClient.shared.signOut()
        await APIClient.shared.clearSessionToken()
        await CacheMaintenanceService.shared.clearUserScopedCaches()
        currentUser     = nil
        isAuthenticated = false
        biometricUnlockRequired = false
    }

    // MARK: - Biometric unlock

    func unlockWithBiometrics() async {
        biometricErrorMessage = nil
        refreshBiometricCapability()

        guard biometricUnlockAvailable else {
            biometricErrorMessage = "\(biometricTypeName) is not available on this device."
            restoreStoredSession()
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Use sign in"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometricErrorMessage = error?.localizedDescription ?? "\(biometricTypeName) is unavailable."
            return
        }

        do {
            let reason = "Unlock WeStreem with \(biometricTypeName)."
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            if success {
                restoreStoredSession()
            }
        } catch {
            biometricErrorMessage = error.localizedDescription
        }
    }

    func useFullSignInInstead() {
        biometricUnlockRequired = false
        biometricErrorMessage = nil
        isAuthenticated = false
        isLoading = false
    }

    private func restoreStoredSession() {
        guard SessionStorage.token != nil else {
            isAuthenticated = false
            isLoading = false
            return
        }
        authGeneration = UUID()
        let generation = authGeneration
        isAuthenticated = true
        isLoading = false
        biometricUnlockRequired = false
        Task { await refreshUser(generation: generation) }
        Task { await PushNotificationManager.shared.retryRegistrationIfAuthorized() }
    }

    private func enableBiometricUnlockIfAvailable() {
        refreshBiometricCapability()
        guard biometricUnlockAvailable else { return }
        SessionStorage.biometricUnlockEnabled = true
        biometricUnlockEnabled = true
    }

    private func refreshBiometricCapability() {
        #if targetEnvironment(simulator)
        biometricUnlockAvailable = false
        biometricTypeName = "biometrics"
        return
        #else
        let context = LAContext()
        var error: NSError?
        biometricUnlockAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID:
            biometricTypeName = "Face ID"
        case .touchID:
            biometricTypeName = "Touch ID"
        case .opticID:
            biometricTypeName = "Optic ID"
        default:
            biometricTypeName = "biometrics"
        }
        #endif
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
