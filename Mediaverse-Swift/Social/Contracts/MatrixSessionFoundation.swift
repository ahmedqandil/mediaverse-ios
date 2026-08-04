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

/// Pure policy used by SDK adapters to distinguish a revoked credential from
/// ordinary authorization, connectivity and homeserver failures.
public enum MatrixSessionCredentialRecoveryPolicy {
    public static func requiresSessionReplacement(
        matrixErrorCode: String?,
        message: String,
        details: String? = nil
    ) -> Bool {
        let code = matrixErrorCode?.uppercased()
        if code == "M_UNKNOWN_TOKEN" { return true }
        let evidence = (message + " " + (details ?? "")).lowercased()
        let embeddedUnknownToken = evidence.contains("m_unknown_token")
        if embeddedUnknownToken { return true }
        let forbidden = code == "M_FORBIDDEN"
            || evidence.contains("m_forbidden")
            || evidence.contains("403")
        guard forbidden, evidence.contains("refresh token") else { return false }
        return evidence.contains("invalid")
            || evidence.contains("isn't valid")
            || evidence.contains("not valid")
            || evidence.contains("revoked")
            || evidence.contains("expired")
            || evidence.contains("unknown")
    }
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

public enum MatrixNativeSessionAuthMode: String, Codable, Equatable, Sendable {
    case sso = "SSO"
    case brokerFallback = "BROKER_FALLBACK"
}

public enum MatrixHumanIdentityMode: String, Codable, Equatable, Sendable {
    case applicationService = "APPLICATION_SERVICE"
    case nativeOIDC = "NATIVE_OIDC"
}

/// Local-only provenance for the credential stored by MatrixRustSDK.
///
/// This is deliberately not part of the server bootstrap or Matrix wire
/// contract. It prevents a same-MXID application-service credential from
/// being silently restored after the server selects native SSO, while still
/// allowing an explicit APPLICATION_SERVICE rollback to select the broker.
public enum MatrixSessionCredentialProvenance: String, Codable, Equatable, Sendable {
    case sso = "SSO_V1"
    case applicationServiceBroker = "APPLICATION_SERVICE_BROKER_V1"
}

public enum MatrixSessionRestorationDecision: Equatable, Sendable {
    case restore
    case quarantineAndReauthenticate
}

public enum MatrixSessionRestorationPolicy {
    public static func requiredProvenance(
        for authMode: MatrixNativeSessionAuthMode
    ) -> MatrixSessionCredentialProvenance {
        switch authMode {
        case .sso:
            return .sso
        case .brokerFallback:
            return .applicationServiceBroker
        }
    }

    public static func decision(
        storedProvenance: MatrixSessionCredentialProvenance?,
        authMode: MatrixNativeSessionAuthMode,
        humanIdentityMode: MatrixHumanIdentityMode
    ) -> MatrixSessionRestorationDecision {
        if storedProvenance == requiredProvenance(for: authMode) {
            return .restore
        }
        // Old clients did not persist provenance. Preserve their current
        // behavior while APPLICATION_SERVICE is authoritative; NATIVE_OIDC
        // is the explicit boundary that quarantines unmarked/broker sessions.
        if storedProvenance == nil, humanIdentityMode == .applicationService {
            return .restore
        }
        return .quarantineAndReauthenticate
    }
}

public enum MatrixAccountTransitionPolicy {
    public static func requiresClientDisconnect(
        previousWestreemUserID: String?,
        nextWestreemUserID: String?
    ) -> Bool {
        guard let previousWestreemUserID, let nextWestreemUserID else {
            return false
        }
        return previousWestreemUserID != nextWestreemUserID
    }
}

/// Deduplicates identity observations without conflating an initial `nil`
/// (which must disconnect any restored Matrix projection) with "not observed".
/// Task cancellation and activation generations intentionally remain owned by
/// AuthManager and MatrixNativeSessionController.
public struct MatrixIdentityReconcileGate: Sendable {
    private enum Observation: Equatable, Sendable {
        case disconnected
        case authenticated(String)
    }

    private var lastObservation: Observation?

    public init() {}

    public mutating func claim(_ westreemUserID: String?) -> Bool {
        let observation = westreemUserID.map(Observation.authenticated)
            ?? .disconnected
        guard observation != lastObservation else { return false }
        lastObservation = observation
        return true
    }
}

/// Allows Matrix foreground recovery only after the app has first reached an
/// active scene and subsequently left it. SwiftUI may publish an initial
/// inactive -> active transition during launch; treating that transition as a
/// resume races the identity observer and cancels its in-flight negotiation.
public struct MatrixForegroundRecoveryGate: Sendable {
    private var hasObservedInitialActive = false
    private var isArmedAfterLeavingActive = false

    public init() {}

    public mutating func claim(isActive: Bool) -> Bool {
        guard isActive else {
            if hasObservedInitialActive {
                isArmedAfterLeavingActive = true
            }
            return false
        }
        guard hasObservedInitialActive else {
            hasObservedInitialActive = true
            return false
        }
        guard isArmedAfterLeavingActive else { return false }
        isArmedAfterLeavingActive = false
        return true
    }
}

public enum MatrixPusherOwnerProofMode: String, Decodable, Equatable, Sendable {
    case off = "OFF"
    case optional = "OPTIONAL"
    case required = "REQUIRED"
}

private struct MatrixPusherProofCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct MatrixPusherOwnerProof: Codable, Equatable, Sendable {
    public let v: Int
    public let kid: String
    public let iat: Int64
    public let exp: Int64
    public let mac: String

    private static let exactKeys = Set(["v", "kid", "iat", "exp", "mac"])
    private static let maximumLifetimeSeconds: Int64 = 15_552_000

    public init(v: Int, kid: String, iat: Int64, exp: Int64, mac: String) {
        self.v = v
        self.kid = kid
        self.iat = iat
        self.exp = exp
        self.mac = mac
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: MatrixPusherProofCodingKey.self)
        guard Set(values.allKeys.map(\.stringValue)) == Self.exactKeys else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Matrix owner proof"
                )
            )
        }
        func key(_ value: String) -> MatrixPusherProofCodingKey {
            MatrixPusherProofCodingKey(stringValue: value)!
        }
        v = try values.decode(Int.self, forKey: key("v"))
        kid = try values.decode(String.self, forKey: key("kid"))
        iat = try values.decode(Int64.self, forKey: key("iat"))
        exp = try values.decode(Int64.self, forKey: key("exp"))
        mac = try values.decode(String.self, forKey: key("mac"))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: MatrixPusherProofCodingKey.self)
        func key(_ value: String) -> MatrixPusherProofCodingKey {
            MatrixPusherProofCodingKey(stringValue: value)!
        }
        try values.encode(v, forKey: key("v"))
        try values.encode(kid, forKey: key("kid"))
        try values.encode(iat, forKey: key("iat"))
        try values.encode(exp, forKey: key("exp"))
        try values.encode(mac, forKey: key("mac"))
    }

    public func validated(
        now: Date = Date(),
        maximumClockSkewSeconds: Int64 = 300
    ) throws -> Self {
        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let boundedClockSkew = min(max(maximumClockSkewSeconds, 0), 900)
        guard
            v == 1,
            kid.range(
                of: "^[A-Za-z0-9._-]{1,32}$",
                options: .regularExpression
            ) != nil,
            exp > iat,
            exp - iat <= Self.maximumLifetimeSeconds,
            iat <= nowSeconds + boundedClockSkew,
            exp > nowSeconds,
            mac.range(
                of: "^[A-Za-z0-9_-]{43}$",
                options: .regularExpression
            ) != nil
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        return self
    }

    public func defaultPayloadJSON(now: Date = Date()) throws -> String {
        struct Payload: Encodable {
            let westreem_owner_proof_v1: MatrixPusherOwnerProof
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            Payload(westreem_owner_proof_v1: try validated(now: now))
        )
        guard data.count <= 1_024,
              let json = String(data: data, encoding: .utf8)
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        return json
    }
}

public enum MatrixPusherOwnerProofPolicy {
    public static func defaultPayload(
        mode: MatrixPusherOwnerProofMode,
        proof: MatrixPusherOwnerProof?,
        now: Date = Date()
    ) throws -> String? {
        switch mode {
        case .off:
            guard proof == nil else {
                throw MatrixSessionFoundationError.unavailable
            }
            return nil
        case .optional:
            return try proof?.defaultPayloadJSON(now: now)
        case .required:
            guard let proof else {
                throw MatrixSessionFoundationError.unavailable
            }
            return try proof.defaultPayloadJSON(now: now)
        }
    }
}

/// Opaque compare-and-swap revision returned by the authenticated Westreem
/// push registration endpoint. Clients validate only the transport shape and
/// must never derive ordering or ownership from this random value.
public struct MatrixPushRegistrationRevision: Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 22,
              rawValue.range(
                  of: "^[A-Za-z0-9_-]{22}$",
                  options: .regularExpression
              ) != nil
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Per-app, per-authenticated-session nonce. The server permanently tombstones
/// this epoch during sign-out, which makes a delayed request from the old
/// session non-replayable even after the active token row has been deleted.
public struct MatrixPushRegistrationEpoch: Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 43,
              rawValue.range(
                  of: "^[A-Za-z0-9_-]{43}$",
                  options: .regularExpression
              ) != nil
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Independent 256-bit bearer capability authorizing registration cleanup
/// after the Westreem cookie or bearer session has expired. It is generated
/// before POST, never logged, and the server persists only its HMAC hash.
public struct MatrixPushRegistrationRevocationCapability: Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 43,
              rawValue.range(
                  of: "^[A-Za-z0-9_-]{43}$",
                  options: .regularExpression
              ) != nil
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Opaque Matrix pusher identifier from the v3 registration contract. The
/// APNs provider token is a separate delivery credential and must never be
/// installed in Matrix once this identifier has been prepared.
public struct MatrixOpaquePushKey: Codable, Equatable, Hashable, Sendable {
    public static let prefix = "wsp2."
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 48,
              rawValue.hasPrefix(Self.prefix),
              String(rawValue.dropFirst(Self.prefix.count)).range(
                  of: "^[A-Za-z0-9_-]{43}$",
                  options: .regularExpression
              ) != nil
        else { throw MatrixSessionFoundationError.unavailable }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MatrixPushRegistrationV3Command: String, Codable, Sendable {
    case prepare = "PREPARE"
    case confirm = "CONFIRM"
    case retireRaw = "RETIRE_RAW"
}

public enum MatrixPushRegistrationV3State: String, Codable, Sendable {
    case rawActiveV2 = "RAW_ACTIVE_V2"
    case dualPrepared = "DUAL_PREPARED"
    case opaquePreparedNoRaw = "OPAQUE_PREPARED_NO_RAW"
    case opaqueConfirmedRawActive = "OPAQUE_CONFIRMED_RAW_ACTIVE"
    case rawGrace = "RAW_GRACE"
    case opaqueActiveRawRetired = "OPAQUE_ACTIVE_RAW_RETIRED"
    case revoked = "REVOKED"
}

public struct MatrixPushRegistrationRoutes: Codable, Equatable, Sendable {
    public let opaque: Bool
    public let raw: Bool

    public init(opaque: Bool, raw: Bool) {
        self.opaque = opaque
        self.raw = raw
    }
}

public struct MatrixPusherObservation: Codable, Equatable, Sendable {
    public let opaquePresent: Bool
    public let rawPresent: Bool

    public init(opaquePresent: Bool, rawPresent: Bool) {
        self.opaquePresent = opaquePresent
        self.rawPresent = rawPresent
    }
}

/// The minimal homeserver pusher projection needed to prove registration
/// presence. Values are never logged and are validated by
/// `MatrixPusherObservationPolicy` before they can authorize a transition.
public struct MatrixObservedPusher: Equatable, Sendable {
    public let pushKey: String
    public let appID: String
    public let kind: String?
    public let url: String?
    public let format: String?

    public init(
        pushKey: String,
        appID: String,
        kind: String?,
        url: String?,
        format: String?
    ) {
        self.pushKey = pushKey
        self.appID = appID
        self.kind = kind
        self.url = url
        self.format = format
    }
}

public enum MatrixPusherObservationPolicy {
    public static func observe(
        pushers: [MatrixObservedPusher],
        appID: String,
        rawPushKey: String?,
        opaquePushKey: MatrixOpaquePushKey
    ) throws -> MatrixPusherObservation {
        guard pushers.count <= 64 else {
            throw MatrixSessionFoundationError.unavailable
        }

        func exactIdentifierMatches(_ key: String) throws -> [MatrixObservedPusher] {
            let matches = pushers.filter {
                $0.appID == appID && $0.pushKey == key
            }
            guard matches.count <= 1 else {
                throw MatrixSessionFoundationError.unavailable
            }
            return matches
        }

        let opaque = try exactIdentifierMatches(opaquePushKey.rawValue)
        for match in opaque {
            guard match.kind == "http",
                  match.url == MatrixPushGatewayContract.canonicalURLString,
                  match.format == "event_id_only"
            else { throw MatrixSessionFoundationError.unavailable }
        }

        // The exact legacy raw identifier is deletion authority only. Its old
        // delivery metadata is intentionally neither trusted nor accepted as a
        // delivery target during the opaque migration.
        let raw = try rawPushKey.map(exactIdentifierMatches) ?? []
        return MatrixPusherObservation(
            opaquePresent: opaque.count == 1,
            rawPresent: raw.count == 1
        )
    }
}

public enum MatrixPushConfirmationMode: Equatable, Sendable {
    case standard
    case dualPreparedMissingRawRecovery
}

public struct MatrixPushRegistrationV3Pusher: Codable, Equatable, Sendable {
    public let appId: String
    public let gatewayUrl: String
    public let format: String
    public let pushKey: MatrixOpaquePushKey

    public func validated(expectedAppID: String, expectedKey: MatrixOpaquePushKey) throws -> Self {
        guard appId == expectedAppID,
              ["com.westreem.app", "com.westreem.app.voip"].contains(appId),
              format == "event_id_only",
              MatrixPushGatewayContract.accepts(gatewayUrl),
              pushKey == expectedKey
        else { throw MatrixSessionFoundationError.unavailable }
        return self
    }
}

public struct MatrixPushRegistrationV3RawRemoval: Codable, Equatable, Sendable {
    public let authority: String
    public let pushKey: String
    public let appId: String

    public func validated(expectedAppID: String) throws -> Self {
        guard authority == "MATRIX_PUSHER_API",
              appId == expectedAppID,
              ["com.westreem.app", "com.westreem.app.voip"].contains(appId),
              (64...512).contains(pushKey.utf8.count),
              pushKey.utf8.count.isMultiple(of: 2),
              pushKey == pushKey.lowercased(),
              pushKey.allSatisfy(\.isHexDigit)
        else { throw MatrixSessionFoundationError.unavailable }
        return self
    }
}

public struct MatrixPushRegistrationV3Response: Codable, Equatable, Sendable {
    public let registrationContractVersion: Int
    public let registrationCapability: String
    public let registrationState: MatrixPushRegistrationV3State
    public let registrationRevision: String
    public let pushSetupPending: Bool
    public let rawRetireAt: String?
    public let routes: MatrixPushRegistrationRoutes
    public let matrixPusher: MatrixPushRegistrationV3Pusher
    public let rawMatrixRemoval: MatrixPushRegistrationV3RawRemoval?

    public func validated(
        expectedAppID: String,
        expectedKey: MatrixOpaquePushKey,
        expectedRawPushKey: String?
    ) throws -> Self {
        guard registrationContractVersion == MatrixOpaquePushMigrationPolicy.contractVersion,
              registrationCapability == MatrixOpaquePushMigrationPolicy.capability,
              (try? MatrixPushRegistrationRevision(rawValue: registrationRevision)) != nil
        else { throw MatrixSessionFoundationError.unavailable }
        _ = try matrixPusher.validated(expectedAppID: expectedAppID, expectedKey: expectedKey)
        if let rawRetireAt {
            guard MatrixOpaquePushMigrationPolicy.rawRetireDate(rawRetireAt) != nil else {
                throw MatrixSessionFoundationError.unavailable
            }
        }
        switch registrationState {
        case .opaqueConfirmedRawActive:
            guard let rawMatrixRemoval,
                  let expectedRawPushKey,
                  rawMatrixRemoval.pushKey == expectedRawPushKey
            else {
                throw MatrixSessionFoundationError.unavailable
            }
            _ = try rawMatrixRemoval.validated(expectedAppID: expectedAppID)
        case .rawActiveV2, .dualPrepared, .opaquePreparedNoRaw, .rawGrace,
             .opaqueActiveRawRetired, .revoked:
            guard rawMatrixRemoval == nil else {
                throw MatrixSessionFoundationError.unavailable
            }
        }
        guard MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: registrationState,
            routes: routes,
            pushSetupPending: pushSetupPending,
            rawRetireAt: rawRetireAt
        ) else { throw MatrixSessionFoundationError.unavailable }
        return self
    }
}

public enum MatrixPushRegistrationV3Phase: String, Codable, Sendable {
    case generated = "GENERATED"
    case prepared = "PREPARED"
    case opaqueInstalled = "OPAQUE_INSTALLED"
    case confirmed = "CONFIRMED"
    case rawRemoved = "RAW_REMOVED"
    case active = "ACTIVE"
    case cleanupPending = "CLEANUP_PENDING"
}

public enum MatrixPushSetupStatus: String, Codable, Equatable, Sendable {
    case ready
    case finishingSetup
    case retryingOffline
    case actionRequired
    case cleanupPending
}

public enum MatrixPushDeliveryLeaseRetryPolicy {
    public static let maximumDelayMilliseconds = 30_000
    public static let maximumInCallWaits = 1

    public static func validatedMilliseconds(_ value: Int) -> UInt64? {
        guard (1...maximumDelayMilliseconds).contains(value) else { return nil }
        return UInt64(value)
    }
}

public enum MatrixPushRegistrationV3Conflict: Equatable, Sendable {
    case revision(String)
    case deliveryLease(UInt64)
}

public enum MatrixPushRegistrationV3ConflictPolicy {
    public static func decode(_ data: Data) throws -> MatrixPushRegistrationV3Conflict {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MatrixSessionFoundationError.unavailable }
        let keys = Set(object.keys)
        if keys == Set(["error", "registrationRevision"]),
           object["error"] as? String == "Push registration revision conflict",
           let rawRevision = object["registrationRevision"] as? String,
           let revision = try? MatrixPushRegistrationRevision(rawValue: rawRevision) {
            return .revision(revision.rawValue)
        }
        if keys == Set(["error", "code", "retryAfterMs"]),
           object["error"] as? String == "Push delivery handoff in progress",
           object["code"] as? String == "delivery_lease_active",
           let retryAfter = object["retryAfterMs"] as? Int,
           let delay = MatrixPushDeliveryLeaseRetryPolicy
            .validatedMilliseconds(retryAfter) {
            return .deliveryLease(delay)
        }
        throw MatrixSessionFoundationError.unavailable
    }
}

public enum MatrixOpaquePushMigrationPolicy {
    public static let contractVersion = 3
    public static let capability = "opaque_matrix_push_key_v1"

    public static func rawRetireDate(_ value: String) -> Date? {
        guard value.range(
            of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$",
            options: .regularExpression
        ) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func acceptsServerProjection(
        state: MatrixPushRegistrationV3State,
        routes: MatrixPushRegistrationRoutes,
        pushSetupPending: Bool,
        rawRetireAt: String?
    ) -> Bool {
        switch state {
        case .rawActiveV2:
            return routes == .init(opaque: false, raw: true)
                && !pushSetupPending && rawRetireAt == nil
        case .dualPrepared:
            return routes == .init(opaque: true, raw: true)
                && !pushSetupPending && rawRetireAt == nil
        case .opaquePreparedNoRaw:
            return routes == .init(opaque: true, raw: false)
                && pushSetupPending && rawRetireAt == nil
        case .opaqueConfirmedRawActive:
            return routes == .init(opaque: true, raw: true)
                && !pushSetupPending && rawRetireAt == nil
        case .rawGrace:
            return routes == .init(opaque: true, raw: true)
                && !pushSetupPending && rawRetireAt != nil
        case .opaqueActiveRawRetired:
            return routes == .init(opaque: true, raw: false)
                && !pushSetupPending
        case .revoked:
            return routes == .init(opaque: false, raw: false)
                && !pushSetupPending
        }
    }

    public static func confirmationMode(
        state: MatrixPushRegistrationV3State,
        observed: MatrixPusherObservation
    ) -> MatrixPushConfirmationMode? {
        switch state {
        case .dualPrepared:
            guard observed.opaquePresent else { return nil }
            return observed.rawPresent
                ? .standard
                : .dualPreparedMissingRawRecovery
        case .opaquePreparedNoRaw:
            return observed.opaquePresent && !observed.rawPresent ? .standard : nil
        default:
            return nil
        }
    }

    public static func confirmationObservation(
        state: MatrixPushRegistrationV3State,
        observed: MatrixPusherObservation
    ) -> Bool {
        confirmationMode(state: state, observed: observed) != nil
    }

    public static func canRetireRaw(observed: MatrixPusherObservation) -> Bool {
        observed.opaquePresent && !observed.rawPresent
    }
}

public enum MatrixPushProviderEnvironment {
    /// Apple provisioning profiles call the development APNs environment
    /// `development`; the frozen push-registration v3 wire contract calls the
    /// same provider environment `sandbox`. Keep this translation exact so an
    /// unknown entitlement value can never be persisted as a server tuple.
    public static func backendValue(forAPNsEnvironment value: String) -> String? {
        switch value {
        case "development", "sandbox":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }
}

public struct MatrixPushRegistrationHandleIdentity: Equatable, Sendable {
    public let tokenDigest: String
    public let appID: String
    public let registrationEpoch: String
    public let revocationCapabilityDigest: String

    public init(
        tokenDigest: String,
        appID: String,
        registrationEpoch: String,
        revocationCapabilityDigest: String
    ) {
        self.tokenDigest = tokenDigest
        self.appID = appID
        self.registrationEpoch = registrationEpoch
        self.revocationCapabilityDigest = revocationCapabilityDigest
    }

    fileprivate func occupiesSameServerSlot(
        as other: MatrixPushRegistrationHandleIdentity
    ) -> Bool {
        tokenDigest == other.tokenDigest && appID == other.appID
    }
}

public enum MatrixPushGatewayContract {
    public static let canonicalURLString =
        "https://www.westreem.com/_matrix/push/v1/notify"

    /// Matrix pushers do not follow redirects. Accept only the one production
    /// endpoint whose bytes are safe to persist in Synapse. This deliberately
    /// does not inherit the broader first-party URL allowlist used by ordinary
    /// API and browser traffic.
    public static func accepts(_ value: String) -> Bool {
        guard value == canonicalURLString,
              let components = URLComponents(string: value)
        else { return false }
        return components.scheme == "https"
            && components.host == "www.westreem.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/_matrix/push/v1/notify"
            && components.query == nil
            && components.fragment == nil
    }
}

public enum MatrixPushCleanupQueuePolicy {
    /// Durable cleanup entries are de-duplicated only by their exact
    /// token/app/epoch/capability identity.
    /// There is deliberately no suffix/count eviction: an unconfirmed server
    /// registration may not be forgotten merely to bound local storage.
    public static func merging(
        _ identity: MatrixPushRegistrationHandleIdentity,
        into existing: [MatrixPushRegistrationHandleIdentity]
    ) -> [MatrixPushRegistrationHandleIdentity] {
        existing.filter { $0 != identity } + [identity]
    }

    public static func removing(
        _ identity: MatrixPushRegistrationHandleIdentity,
        from existing: [MatrixPushRegistrationHandleIdentity]
    ) -> [MatrixPushRegistrationHandleIdentity] {
        existing.filter { $0 != identity }
    }

    /// A successful v2 registration is the only client-observable proof that
    /// the server atomically replaced the row for this exact token/app slot
    /// and tombstoned its prior epoch/capability. Only at that boundary may
    /// older capabilities for the same slot be compacted. Other tokens and
    /// app topics remain potentially live and are retained without a count
    /// limit until their own authoritative registration or revocation result.
    public static func removingAuthoritativelySuperseded(
        by confirmed: MatrixPushRegistrationHandleIdentity,
        from existing: [MatrixPushRegistrationHandleIdentity]
    ) -> [MatrixPushRegistrationHandleIdentity] {
        existing.filter { !$0.occupiesSameServerSlot(as: confirmed) }
    }
}

/// Generation fence shared by ordinary APNs and VoIP registration work.
/// Sign-out first closes the fence, then cancels and awaits every leased task,
/// and only then performs revision-bound deletion. A response carrying an old
/// lease can therefore never update local pusher state after sign-out begins.
public struct MatrixPushRegistrationFence: Equatable, Sendable {
    public struct Lease: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var isSigningOut = false

    public init() {}

    public mutating func openSession() {
        generation &+= 1
        isSigningOut = false
    }

    /// Matrix transport readiness can change repeatedly while the same
    /// authenticated account and APNs token remain authoritative. It must not
    /// invalidate an in-flight pusher response for that unchanged context.
    public mutating func preserveAcrossReadinessChange() {
        // Deliberately no generation change.
    }

    public mutating func invalidateRegistrationContext() {
        generation &+= 1
    }

    public mutating func beginRegistration() -> Lease? {
        guard !isSigningOut else { return nil }
        return Lease(generation: generation)
    }

    public func accepts(_ lease: Lease) -> Bool {
        !isSigningOut && lease.generation == generation
    }

    public mutating func beginSignOut() {
        generation &+= 1
        isSigningOut = true
    }

    public func mayDeleteRegistration(pendingUploadCount: Int) -> Bool {
        isSigningOut && pendingUploadCount == 0
    }
}

public enum MatrixPushRegistrationRetryPolicy {
    public static let maximumConflictRetries = 2

    public static func mayRetry(
        conflictAttempt: Int,
        contextIsCurrent: Bool,
        revision: String
    ) -> Bool {
        contextIsCurrent
            && conflictAttempt < maximumConflictRetries
            && (try? MatrixPushRegistrationRevision(rawValue: revision)) != nil
    }
}

public enum MatrixPushRegistrationSessionTransition: Sendable {
    case fullSignIn
    case accountSwitch
    case accessTokenRefresh
    case appRestore
    case signOut
}

public enum MatrixPushRegistrationEpochPolicy {
    /// Epochs identify one durable authenticated app/account session. A bearer
    /// refresh and app restoration remain inside that session; only explicit
    /// identity boundaries rotate or retire its epoch.
    public static func rotates(
        on transition: MatrixPushRegistrationSessionTransition
    ) -> Bool {
        switch transition {
        case .fullSignIn, .accountSwitch, .signOut:
            return true
        case .accessTokenRefresh, .appRestore:
            return false
        }
    }
}

/// Credential-free, server-authoritative metadata selecting exactly one
/// Matrix authentication mechanism for this client session.
public struct MatrixSSOBootstrap: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let ownershipVersion: Int
    public let humanIdentityMode: MatrixHumanIdentityMode
    public let authMode: MatrixNativeSessionAuthMode?
    public let homeserverURL: String
    public let redirectURL: String?
    public let idpID: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, ownershipVersion, humanIdentityMode
        case authMode
        case homeserverURL = "homeserverUrl"
        case redirectURL = "redirectUrl"
        case idpID = "idpId"
    }

    public init(
        enabled: Bool,
        ownershipVersion: Int,
        humanIdentityMode: MatrixHumanIdentityMode,
        authMode: MatrixNativeSessionAuthMode? = .sso,
        homeserverURL: String,
        redirectURL: String? = "westreem://matrix/sso",
        idpID: String? = nil
    ) {
        self.enabled = enabled
        self.ownershipVersion = ownershipVersion
        self.humanIdentityMode = humanIdentityMode
        self.authMode = authMode
        self.homeserverURL = homeserverURL
        self.redirectURL = redirectURL
        self.idpID = idpID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        ownershipVersion = try values.decode(
            Int.self,
            forKey: .ownershipVersion
        )
        // Backward compatibility is intentionally one-way: an old server that
        // omits the field remains APPLICATION_SERVICE, while any present but
        // unknown/empty value fails decoding instead of guessing ownership.
        humanIdentityMode = try values.decodeIfPresent(
            MatrixHumanIdentityMode.self,
            forKey: .humanIdentityMode
        ) ?? .applicationService
        authMode = try values.decodeIfPresent(
            MatrixNativeSessionAuthMode.self,
            forKey: .authMode
        )
        homeserverURL = try values.decodeIfPresent(
            String.self,
            forKey: .homeserverURL
        ) ?? ""
        redirectURL = try values.decodeIfPresent(
            String.self,
            forKey: .redirectURL
        )
        idpID = try values.decodeIfPresent(String.self, forKey: .idpID)
    }

    public func validated() throws -> MatrixSSOBootstrap {
        guard
            enabled,
            ownershipVersion == 2,
            MatrixHomeserverTrustPolicy.accepts(homeserverURL),
            let authMode
        else {
            throw MatrixSessionFoundationError.invalidSSOConfiguration
        }
        switch authMode {
        case .sso:
            guard
                let redirectURL,
                let redirect = URL(string: redirectURL),
                redirect.scheme?.caseInsensitiveCompare("westreem")
                    == .orderedSame,
                redirect.host?.caseInsensitiveCompare("matrix")
                    == .orderedSame,
                redirect.path == "/sso",
                redirect.query == nil,
                redirect.fragment == nil,
                idpID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != true
            else {
                throw MatrixSessionFoundationError.invalidSSOConfiguration
            }
        case .brokerFallback:
            guard humanIdentityMode == .applicationService,
                  redirectURL == nil,
                  idpID == nil
            else {
                throw MatrixSessionFoundationError.invalidSSOConfiguration
            }
        }
        return self
    }

    public func accepts(callbackURL: URL) -> Bool {
        guard
            authMode == .sso,
            let redirectURL,
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
