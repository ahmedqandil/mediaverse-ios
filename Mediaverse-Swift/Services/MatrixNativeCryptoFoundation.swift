import Foundation
import MatrixRustSDK

/// Thin, MatrixRustSDK-only crypto facade. It deliberately contains no
/// Client-Server HTTP implementation and never persists recovery material.
extension MatrixSessionCoordinator {
    func cryptoSnapshot() async throws -> MatrixNativeCryptoSnapshot {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()

        async let backupExists = encryption.backupExistsOnServer()
        async let fingerprint = encryption.ed25519Key()
        async let hasOtherDevices = encryption.hasDevicesToVerifyAgainst()
        async let lastDevice = encryption.isLastDevice()

        return try await MatrixNativeCryptoSnapshot(
            recovery: MatrixNativeRecoveryStatus(encryption.recoveryState()),
            backup: MatrixNativeBackupStatus(encryption.backupState()),
            verification: MatrixNativeVerificationStatus(encryption.verificationState()),
            backupExistsOnServer: backupExists,
            currentDeviceID: client.deviceId(),
            currentDeviceFingerprint: fingerprint,
            hasOtherVerifiableDevices: hasOtherDevices,
            isLastDevice: lastDevice
        )
    }

    /// Idempotent SDK-owned maintenance. This may enable an existing trusted
    /// backup and resume uploads, but it never creates/replaces a recovery key.
    /// First-device setup and existing-account recovery therefore remain
    /// explicit user actions.
    func maintainCryptoLifecycle() async throws -> MatrixNativeCryptoSnapshot {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let encryption = client.encryption()
        await encryption.waitForE2eeInitializationTasks()

        if MatrixNativeRecoveryStatus(encryption.recoveryState()) == .enabled {
            try await encryption.enableBackups()
            try await encryption.waitForBackupUploadSteadyState(progressListener: nil)
        }
        return try await cryptoSnapshot()
    }

    func requireCryptoReadyForEncryptedAction() async throws -> MatrixNativeCryptoSnapshot {
        let snapshot = try await maintainCryptoLifecycle()
        guard let action = snapshot.readinessAction else { return snapshot }
        switch action {
        case .setUpRecovery:
            throw MatrixNativeCryptoSecurityError.setupRequired
        case .recoverExistingAccount:
            throw MatrixNativeCryptoSecurityError.existingRecoveryRequired
        case .verifyDevice:
            throw MatrixNativeCryptoSecurityError.deviceVerificationRequired
        case .waitForBackup:
            throw MatrixNativeCryptoSecurityError.backupNotReady
        }
    }

    /// Enables Matrix Recovery and key backup. The returned recovery key is
    /// shown once by the caller and is never written to Westreem storage.
    func enableCryptoRecovery(passphrase: String?) async throws -> String {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let normalizedPassphrase = passphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = MatrixNativeRecoveryProgressObserver()
        let recoveryKey = try await client.encryption().enableRecovery(
            waitForBackupsToUpload: true,
            passphrase: normalizedPassphrase?.isEmpty == false ? normalizedPassphrase : nil,
            progressListener: progress
        )
        try await client.encryption().waitForBackupUploadSteadyState(progressListener: nil)
        return recoveryKey
    }

    func recoverCryptoIdentity(recoveryKey: String) async throws {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let normalized = try MatrixNativeRecoveryKeyPolicy.normalized(recoveryKey)
        try await client.encryption().recoverAndFixBackup(recoveryKey: normalized)
        try await client.encryption().waitForBackupUploadSteadyState(progressListener: nil)
    }

    func resetCryptoRecoveryKey(confirmation: String) async throws -> String {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        try MatrixNativeRecoveryResetPolicy.validate(confirmation)
        return try await client.encryption().resetRecoveryKey()
    }

    func makeDeviceVerificationController(
        delegate: SessionVerificationControllerDelegate
    ) async throws -> SessionVerificationController {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let controller = try await client.getSessionVerificationController()
        controller.setDelegate(delegate: delegate)
        return controller
    }

    /// MatrixRustSDK 26.7.28 did not expose arbitrary device enumeration.
    /// Newer builds surface it via `client.encryption().userIdentity(userId:)`
    /// combined with the CS-API `GET /_matrix/client/v3/devices` (proxied by
    /// the SDK). We wrap it here so the UI has a single entry point and can
    /// keep failing closed if the SDK we ship doesn't expose the call yet.
    ///
    /// TODO(matrix-rust-sdk): once the SDK exposes native `devices()` /
    /// `deleteDevice(id:)`, swap the `throw` for the SDK call. Until then,
    /// the UI catches this and shows the "device management unavailable"
    /// hint — keeping parity with the previous behaviour.
    func matrixDevices() async throws -> [MatrixNativeDevice] {
        guard activeClient() != nil else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        // Prefer the SDK-native path when available. The commented block below
        // is the shape it will take once the SDK binding lands; leaving it
        // documented so the follow-up upgrade is a copy-paste swap.
        //
        // let devices = try await client.encryption().devices()
        // let currentId = client.deviceId()
        // return devices.map { device in
        //     MatrixNativeDevice(
        //         id: device.deviceId,
        //         displayName: device.displayName,
        //         lastSeenAt: device.lastSeenTs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
        //         lastSeenIP: device.lastSeenIp,
        //         isVerified: device.isVerified,
        //         isCurrent: device.deviceId == currentId
        //     )
        // }
        throw MatrixNativeCryptoSecurityError.deviceEnumerationUnavailable
    }

    /// TODO(matrix-rust-sdk): calls `client.deleteDevice(deviceId: id, auth: ...)`
    /// once the SDK surfaces device deletion. The Matrix spec requires
    /// User-Interactive Authentication (UIA) for this endpoint; the SDK
    /// binding is expected to accept an `auth` dictionary sourced from a
    /// completed UIA flow. Fail closed until the binding lands.
    func revokeMatrixDevice(deviceID: String) async throws {
        _ = deviceID
        guard activeClient() != nil else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        throw MatrixNativeCryptoSecurityError.deviceRevocationUnavailable
    }

    /// Start a QR-code assisted self-verification (MSC3906 flow).
    ///
    /// Wraps the standard `SessionVerificationController` since the Rust SDK
    /// exposes both QR (`ShowReciprocateQr`) and SAS callbacks on the same
    /// controller. Callers can render `qrCodeData` and hand back scanned
    /// bytes via `reciprocate(scanned:)`.
    ///
    /// TODO(matrix-rust-sdk): if the Swift binding starts exposing a
    /// dedicated `QrCodeData` type, migrate this to that API for symmetric
    /// scan/show ergonomics. Today we surface the bytes returned by
    /// `controller.qrCodeData()` when it becomes non-nil.
    func beginQrLogin(
        delegate: SessionVerificationControllerDelegate
    ) async throws -> SessionVerificationController {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
        let controller = try await client.getSessionVerificationController()
        controller.setDelegate(delegate: delegate)
        try await controller.requestDeviceVerification()
        return controller
    }
}

/// A remote Matrix device as reported by the homeserver / SDK.
///
/// Mirrors the shape of Element's device-listing rows so we can render
/// "This session" and "Other sessions" without additional plumbing.
public struct MatrixNativeDevice: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String?
    public let lastSeenAt: Date?
    public let lastSeenIP: String?
    public let isVerified: Bool
    public let isCurrent: Bool

    public init(
        id: String,
        displayName: String?,
        lastSeenAt: Date?,
        lastSeenIP: String?,
        isVerified: Bool,
        isCurrent: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.lastSeenIP = lastSeenIP
        self.isVerified = isVerified
        self.isCurrent = isCurrent
    }
}

private final class MatrixNativeRecoveryProgressObserver:
    EnableRecoveryProgressListener,
    @unchecked Sendable
{
    func onUpdate(status: EnableRecoveryProgress) {
        // The SDK owns progress and retry state. The recovery key itself never
        // crosses this callback or enters application persistence.
        _ = status
    }
}

private extension MatrixNativeRecoveryStatus {
    init(_ value: RecoveryState) {
        switch value {
        case .unknown: self = .unknown
        case .enabled: self = .enabled
        case .disabled: self = .disabled
        case .incomplete: self = .incomplete
        }
    }
}

private extension MatrixNativeBackupStatus {
    init(_ value: BackupState) {
        switch value {
        case .unknown: self = .unknown
        case .creating: self = .creating
        case .enabling: self = .enabling
        case .resuming: self = .resuming
        case .enabled: self = .enabled
        case .downloading: self = .downloading
        case .disabling: self = .disabling
        }
    }
}

private extension MatrixNativeVerificationStatus {
    init(_ value: VerificationState) {
        switch value {
        case .unknown: self = .unknown
        case .verified: self = .verified
        case .unverified: self = .unverified
        }
    }
}
