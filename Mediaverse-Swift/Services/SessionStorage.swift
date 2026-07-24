import Foundation
import Security

/// Persistent session storage. The session token lives in Keychain; lightweight
/// preferences such as the active context and biometric setting remain in UserDefaults.
enum SessionStorage {
    private static let tokenKey = "westreem.sessionJWT"
    private static let activeContextKey = "westreem.activeContext"
    private static let activeContextCookieJSONKey = "westreem.activeContextCookieJSON"
    private static let biometricUnlockEnabledKey = "westreem.biometricUnlockEnabled"
    private static let tokenService = "com.westreem.mediaverse.session"

    /// The current session JWT, or nil if signed out.
    static var token: String? {
        get {
            if let token = keychainToken {
                return token
            }

            guard let migratedToken = UserDefaults.standard.string(forKey: tokenKey) else {
                return nil
            }
            keychainToken = migratedToken
            UserDefaults.standard.removeObject(forKey: tokenKey)
            return migratedToken
        }
        set {
            keychainToken = newValue
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
    }

    /// Mirrors the web `mv_active_ctx` cookie so API requests resolve the same context.
    static var activeContext: ActiveContext? {
        get {
            if let json = activeContextCookieJSON,
               let data = json.data(using: .utf8),
               let context = try? JSONDecoder().decode(ActiveContext.self, from: data) {
                return context
            }

            guard let data = UserDefaults.standard.data(forKey: activeContextKey) else { return nil }
            return try? JSONDecoder().decode(ActiveContext.self, from: data)
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue) else {
                clearActiveContext()
                return
            }
            UserDefaults.standard.set(data, forKey: activeContextKey)
            if let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: activeContextCookieJSONKey)
            }
        }
    }

    /// Exact JSON body used by the web cookie. Prefer this over re-encoding when the server sends a canonical cookie.
    static var activeContextCookieJSON: String? {
        get {
            if let json = UserDefaults.standard.string(forKey: activeContextCookieJSONKey) {
                return json
            }
            guard let data = UserDefaults.standard.data(forKey: activeContextKey),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            UserDefaults.standard.set(json, forKey: activeContextCookieJSONKey)
            return json
        }
        set {
            guard let newValue,
                  let data = newValue.data(using: .utf8),
                  (try? JSONDecoder().decode(ActiveContext.self, from: data)) != nil else {
                clearActiveContext()
                return
            }
            UserDefaults.standard.set(newValue, forKey: activeContextCookieJSONKey)
            UserDefaults.standard.set(data, forKey: activeContextKey)
        }
    }

    static var activeContextCookieValue: String? {
        activeContextCookieJSON?.addingPercentEncoding(withAllowedCharacters: cookieValueAllowedCharacters)
    }

    static func clearActiveContext() {
        UserDefaults.standard.removeObject(forKey: activeContextKey)
        UserDefaults.standard.removeObject(forKey: activeContextCookieJSONKey)
    }

    /// Local device gate for restoring an already stored server session.
    static var biometricUnlockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: biometricUnlockEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: biometricUnlockEnabledKey) }
    }

    private static let cookieValueAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";, \n\r\t")
        return allowed
    }()

    private static var keychainToken: String? {
        get {
            var query = tokenQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        }
        set {
            SecItemDelete(tokenQuery as CFDictionary)
            guard let newValue,
                  let data = newValue.data(using: .utf8) else {
                return
            }

            var query = tokenQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static var tokenQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenKey
        ]
    }
}
