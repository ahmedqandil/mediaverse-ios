import Foundation

/// Pinned public origins for the existing Westreem Matrix deployment.
///
/// This is deliberately not derived from server data. A compromised session
/// broker or SSO bootstrap response must not be able to redirect Matrix access
/// tokens, crypto state, or media requests to an arbitrary HTTPS host.
public enum MatrixHomeserverTrustPolicy {
    public static let approvedOrigins: Set<String> = [
        "https://vibes.westreem.com",
        "https://matrix.westreem.com",
        "https://westreem-vibes-synapse.fly.dev",
    ]

    public static func normalizedApprovedOrigin(_ value: String) -> String? {
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.port == nil
        else {
            return nil
        }
        let origin = "https://\(host)"
        return approvedOrigins.contains(origin) ? origin : nil
    }

    public static func accepts(_ value: String) -> Bool {
        normalizedApprovedOrigin(value) != nil
    }
}

public enum MatrixNativeRecoveryStatus: String, Equatable, Sendable {
    case unknown
    case enabled
    case disabled
    case incomplete
}

public enum MatrixNativeBackupStatus: String, Equatable, Sendable {
    case unknown
    case creating
    case enabling
    case resuming
    case enabled
    case downloading
    case disabling
}

public enum MatrixNativeVerificationStatus: String, Equatable, Sendable {
    case unknown
    case verified
    case unverified
}

/// View-safe crypto state. No access token, room key, recovery key, or
/// cross-signing private key is ever represented here.
public struct MatrixNativeCryptoSnapshot: Equatable, Sendable {
    public let recovery: MatrixNativeRecoveryStatus
    public let backup: MatrixNativeBackupStatus
    public let verification: MatrixNativeVerificationStatus
    public let backupExistsOnServer: Bool
    public let currentDeviceID: String
    public let currentDeviceFingerprint: String?
    public let hasOtherVerifiableDevices: Bool
    public let isLastDevice: Bool?

    public init(
        recovery: MatrixNativeRecoveryStatus,
        backup: MatrixNativeBackupStatus,
        verification: MatrixNativeVerificationStatus,
        backupExistsOnServer: Bool,
        currentDeviceID: String,
        currentDeviceFingerprint: String?,
        hasOtherVerifiableDevices: Bool,
        isLastDevice: Bool?
    ) {
        self.recovery = recovery
        self.backup = backup
        self.verification = verification
        self.backupExistsOnServer = backupExistsOnServer
        self.currentDeviceID = currentDeviceID
        self.currentDeviceFingerprint = currentDeviceFingerprint
        self.hasOtherVerifiableDevices = hasOtherVerifiableDevices
        self.isLastDevice = isLastDevice
    }

    public var canReadEligibleEncryptedRooms: Bool {
        verification == .verified && recovery == .enabled && backup == .enabled
    }

    public var readinessAction: MatrixNativeCryptoReadinessAction? {
        if recovery == .disabled { return .setUpRecovery }
        if recovery == .unknown || recovery == .incomplete { return .recoverExistingAccount }
        if verification != .verified { return .verifyDevice }
        if backup != .enabled { return .waitForBackup }
        return nil
    }
}

public enum MatrixNativeCryptoReadinessAction: String, Equatable, Sendable {
    case setUpRecovery
    case recoverExistingAccount
    case verifyDevice
    case waitForBackup
}

public enum MatrixNativeCryptoSecurityError: Error, Equatable, Sendable {
    case applicationE2eeDisabled
    case unavailable
    case recoveryKeyRequired
    case recoveryKeyInvalid
    case recoveryResetConfirmationInvalid
    case deviceEnumerationUnavailable
    case deviceRevocationUnavailable
    case setupRequired
    case existingRecoveryRequired
    case deviceVerificationRequired
    case backupNotReady

    public var requiresGuidedRecovery: Bool {
        switch self {
        case .setupRequired,
             .existingRecoveryRequired,
             .deviceVerificationRequired,
             .backupNotReady:
            true
        default:
            false
        }
    }
}

public enum MatrixNativeRecoveryResetPolicy {
    public static let confirmation = "RESET SECURE VIBES"

    public static func validate(_ value: String) throws {
        guard value == confirmation else {
            throw MatrixNativeCryptoSecurityError.recoveryResetConfirmationInvalid
        }
    }
}

public enum MatrixNativeRecoveryKeyPolicy {
    public static let maximumLength = 512

    public static func normalized(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MatrixNativeCryptoSecurityError.recoveryKeyRequired
        }
        guard normalized.utf8.count <= maximumLength,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw MatrixNativeCryptoSecurityError.recoveryKeyInvalid
        }
        return normalized
    }
}

/// Boundaries of the MatrixRustSDK 26.7.28 Swift surface pinned by this app.
/// Listing and revoking arbitrary Matrix devices is intentionally unavailable
/// until the SDK exposes those operations. Westreem must not work around that
/// limitation with a hand-written Client-Server API.
public enum MatrixNativeSDKCryptoCapabilities {
    public static let sdkVersion = "26.7.28"
    public static let supportsEncryptedRoomTimelines = false
    public static let supportsEncryptedMedia = false
    public static let supportsCrossSigning = false
    public static let supportsRecoveryAndKeyBackup = false
    public static let supportsSASDeviceVerification = false
    public static let supportsLegacyEncryptedHistoryRead = true
    public static let supportsDeviceEnumeration = false
    public static let supportsDeviceRevocation = false
    public static let permitsHandWrittenDeviceAPI = false
}
