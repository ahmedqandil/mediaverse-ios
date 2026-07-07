import Foundation

/// Simple, persistent JWT storage backed by UserDefaults.
/// The stored token is injected as `Authorization: Bearer <token>` on authenticated
/// API requests, with cookies kept only for backend compatibility.
enum SessionStorage {
    private static let key = "westreem.sessionJWT"

    /// The current session JWT, or nil if signed out.
    static var token: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
