import Foundation

/// Stable Matrix identity derived only from Westreem's immutable user ID.
///
/// Handles, email addresses, display names, and channel names are deliberately
/// rejected as identity inputs by keeping this initializer narrowly scoped.
public struct MatrixCanonicalIdentity: Equatable, Hashable, Sendable {
    public static let serverName = "vibes.westreem.com"

    public let westreemUserID: String
    public let matrixUserID: String

    public init(westreemUserID: String) throws {
        let candidate = westreemUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 192 else {
            throw MatrixSessionFoundationError.invalidWestreemUserID
        }
        self.westreemUserID = candidate
        // Matches the existing Westreem provisioning service. UTF-8 hex keeps
        // every immutable ID collision-free while satisfying Synapse's
        // lowercase localpart constraint.
        let localpart = candidate.utf8.map { String(format: "%02x", $0) }.joined()
        self.matrixUserID = "@u_\(localpart):\(Self.serverName)"
    }

    public func verifies(matrixUserID: String) -> Bool {
        self.matrixUserID == matrixUserID
    }

}

public enum MatrixSessionFoundationError: Error, Equatable, Sendable {
    case disabled
    case invalidWestreemUserID
    case identityMismatch(expected: String, received: String)
    case invalidHomeserver
    case invalidSSOConfiguration
    case invalidSSOCallback
    case authenticationCancelled
    case unavailable
}

public enum MatrixSessionLifecycleState: Equatable, Sendable {
    case disabled
    case disconnected
    case restoring
    case requestingSession
    case authorizing
    case ready(userID: String, deviceID: String)
    case failed(MatrixSessionFoundationError)
}

/// View-safe state for the Matrix Rust SDK sync service. The implementation
/// owns Matrix SDK objects; UI and feature code consume only this contract.
public enum MatrixNativeSyncState: Equatable, Sendable {
    case disabled
    case starting
    case running
    case offline
    case recovering(attempt: Int)
    case failed
    case stopped
}

/// Strongest-model native persistence contract.
///
/// Values are intentionally fixed here so a future implementation cannot
/// silently replace the Matrix SDK encrypted SQLite store or its durable send
/// queue with a parallel Westreem cache.
public struct MatrixNativePersistencePolicy: Equatable, Sendable {
    public let usesSDKEncryptedSQLiteStore: Bool
    public let usesSDKOfflineSync: Bool
    public let usesSDKSendQueue: Bool
    public let maximumRetryDelaySeconds: UInt64

    public static let strongestModel = MatrixNativePersistencePolicy(
        usesSDKEncryptedSQLiteStore: true,
        usesSDKOfflineSync: true,
        usesSDKSendQueue: true,
        maximumRetryDelaySeconds: 30
    )
}

/// Credential-free, server-authoritative metadata for Synapse upstream SSO.
public struct MatrixSSOBootstrap: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let ownershipVersion: Int
    public let homeserverURL: String
    public let redirectURL: String
    public let idpID: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, ownershipVersion
        case homeserverURL = "homeserverUrl"
        case redirectURL = "redirectUrl"
        case idpID = "idpId"
    }

    public init(
        enabled: Bool,
        ownershipVersion: Int,
        homeserverURL: String,
        redirectURL: String,
        idpID: String? = nil
    ) {
        self.enabled = enabled
        self.ownershipVersion = ownershipVersion
        self.homeserverURL = homeserverURL
        self.redirectURL = redirectURL
        self.idpID = idpID
    }

    public func validated() throws -> MatrixSSOBootstrap {
        guard
            enabled,
            ownershipVersion == 2,
            MatrixHomeserverTrustPolicy.accepts(homeserverURL),
            let redirect = URL(string: redirectURL),
            redirect.scheme?.caseInsensitiveCompare("westreem") == .orderedSame,
            redirect.host?.caseInsensitiveCompare("matrix") == .orderedSame,
            redirect.path == "/sso",
            redirect.query == nil,
            redirect.fragment == nil,
            idpID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else {
            throw MatrixSessionFoundationError.invalidSSOConfiguration
        }
        return self
    }

    public func accepts(callbackURL: URL) -> Bool {
        guard
            let expected = URL(string: redirectURL),
            callbackURL.scheme?.caseInsensitiveCompare(expected.scheme ?? "") == .orderedSame,
            callbackURL.host?.caseInsensitiveCompare(expected.host ?? "") == .orderedSame,
            callbackURL.path == expected.path,
            callbackURL.fragment == nil
        else {
            return false
        }
        return true
    }

}

/// Rollout input used by the composition root. Phase 1 remains disabled unless
/// both the local build and the server explicitly select the Matrix-native v2
/// ownership contract.
public struct MatrixSessionRollout: Equatable, Sendable {
    public let localEnabled: Bool
    public let serverEnabled: Bool
    public let ownershipVersion: Int

    public init(localEnabled: Bool, serverEnabled: Bool, ownershipVersion: Int) {
        self.localEnabled = localEnabled
        self.serverEnabled = serverEnabled
        self.ownershipVersion = ownershipVersion
    }

    public var mayStartSDK: Bool {
        localEnabled && serverEnabled && ownershipVersion == 2
    }

    public static let disabled = MatrixSessionRollout(
        localEnabled: false,
        serverEnabled: false,
        ownershipVersion: 1
    )

    public static func resolved(
        local: SocialFeatureConfiguration,
        serverEnabled: Bool,
        ownershipVersion: Int
    ) -> MatrixSessionRollout {
        MatrixSessionRollout(
            localEnabled: local.matrixNativeVibesEnabled,
            serverEnabled: serverEnabled,
            ownershipVersion: ownershipVersion
        )
    }
}

/// Persisted metadata is intentionally credential-free. Access and refresh
/// tokens live only in the dedicated Matrix Keychain namespace.
public struct MatrixPersistedSessionDescriptor: Codable, Equatable, Sendable {
    public let westreemUserID: String
    public let matrixUserID: String
    public let deviceID: String
    public let homeserverURL: String

    public init(
        westreemUserID: String,
        matrixUserID: String,
        deviceID: String,
        homeserverURL: String
    ) throws {
        let identity = try MatrixCanonicalIdentity(westreemUserID: westreemUserID)
        guard identity.verifies(matrixUserID: matrixUserID) else {
            throw MatrixSessionFoundationError.identityMismatch(
                expected: identity.matrixUserID,
                received: matrixUserID
            )
        }
        guard MatrixHomeserverTrustPolicy.accepts(homeserverURL) else {
            throw MatrixSessionFoundationError.invalidHomeserver
        }
        self.westreemUserID = westreemUserID
        self.matrixUserID = matrixUserID
        self.deviceID = deviceID
        self.homeserverURL = homeserverURL
    }
}
