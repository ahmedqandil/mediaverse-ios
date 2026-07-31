import CryptoKit
import Foundation
import MatrixRustSDK
import Security

/// Dedicated Matrix credential namespace. It is intentionally separate from
/// Westreem's web-session Keychain service and never uses the shared extension
/// access group.
final class MatrixSessionKeychain: ClientSessionDelegate, @unchecked Sendable {
    private struct StoredSession: Codable {
        let accessToken: String
        let refreshToken: String?
        let userID: String
        let deviceID: String
        let homeserverURL: String
        let oauthData: String?
        let nativeSlidingSync: Bool
    }

    private static let sessionService = "com.westreem.mediaverse.matrix.session.v2"
    private static let storeKeyService = "com.westreem.mediaverse.matrix.store-key.v2"

    private let expectedIdentity: MatrixCanonicalIdentity

    init(expectedIdentity: MatrixCanonicalIdentity) {
        self.expectedIdentity = expectedIdentity
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard expectedIdentity.verifies(matrixUserID: userId) else {
            throw ClientError.Generic(msg: "WeStreem identity mismatch", details: nil)
        }
        guard
            let data = read(service: Self.sessionService, account: expectedIdentity.matrixUserID),
            let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
            expectedIdentity.verifies(matrixUserID: stored.userID)
        else {
            throw ClientError.Generic(msg: "WeStreem Vibes session unavailable", details: nil)
        }
        return Session(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userID,
            deviceId: stored.deviceID,
            homeserverUrl: stored.homeserverURL,
            oauthData: stored.oauthData,
            slidingSyncVersion: stored.nativeSlidingSync ? .native : .none
        )
    }

    func saveSessionInKeychain(session: Session) {
        guard expectedIdentity.verifies(matrixUserID: session.userId) else { return }
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userID: session.userId,
            deviceID: session.deviceId,
            homeserverURL: session.homeserverUrl,
            oauthData: session.oauthData,
            nativeSlidingSync: session.slidingSyncVersion == .native
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        write(data, service: Self.sessionService, account: expectedIdentity.matrixUserID)
    }

    func storedSession() -> Session? {
        try? retrieveSessionFromKeychain(userId: expectedIdentity.matrixUserID)
    }

    func storePassphrase() throws -> String {
        if
            let data = read(service: Self.storeKeyService, account: expectedIdentity.matrixUserID),
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        {
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MatrixSessionFoundationError.unavailable
        }
        let value = Data(bytes).base64EncodedString()
        write(Data(value.utf8), service: Self.storeKeyService, account: expectedIdentity.matrixUserID)
        return value
    }

    func removeSession(keepStoreKey: Bool = true) {
        delete(service: Self.sessionService, account: expectedIdentity.matrixUserID)
        if !keepStoreKey {
            delete(service: Self.storeKeyService, account: expectedIdentity.matrixUserID)
        }
    }

    private func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return data
    }

    private func write(_ data: Data, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        SecItemAdd(insert as CFDictionary, nil)
    }

    private func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum MatrixSessionStorePaths {
    private struct Binding: Codable, Equatable {
        let version: Int
        let userID: String
        let deviceID: String
    }

    private static let bindingFilename = "session-binding-v1.json"

    static func directory(for identity: MatrixCanonicalIdentity) throws -> URL {
        let digest = SHA256.hash(data: Data(identity.matrixUserID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("WestreemMatrix", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }

    static func isBound(to session: Session, identity: MatrixCanonicalIdentity) throws -> Bool {
        let url = try directory(for: identity).appendingPathComponent(bindingFilename)
        guard let data = try? Data(contentsOf: url),
              let binding = try? JSONDecoder().decode(Binding.self, from: data)
        else {
            return false
        }
        return binding == Binding(
            version: 1,
            userID: session.userId,
            deviceID: session.deviceId
        )
    }

    static func bind(session: Session, identity: MatrixCanonicalIdentity) throws {
        let binding = Binding(
            version: 1,
            userID: session.userId,
            deviceID: session.deviceId
        )
        let data = try JSONEncoder().encode(binding)
        let url = try directory(for: identity).appendingPathComponent(bindingFilename)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    static func quarantineUnboundStore(for identity: MatrixCanonicalIdentity) throws {
        let directory = try directory(for: identity)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard !contents.isEmpty else { return }
        let quarantine = directory
            .deletingLastPathComponent()
            .appendingPathComponent(
                directory.lastPathComponent + ".unbound-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.moveItem(at: directory, to: quarantine)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }
}
