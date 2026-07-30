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

    func resetCryptoRecoveryKey() async throws -> String {
        guard let client = activeClient() else {
            throw MatrixNativeCryptoSecurityError.unavailable
        }
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

    /// MatrixRustSDK 26.7.28 does not expose arbitrary device enumeration or
    /// revocation through its Swift bindings. Fail closed rather than bypassing
    /// the SDK with a second protocol client.
    func matrixDevices() throws -> Never {
        throw MatrixNativeCryptoSecurityError.deviceEnumerationUnavailable
    }

    func revokeMatrixDevice(deviceID: String) throws -> Never {
        _ = deviceID
        throw MatrixNativeCryptoSecurityError.deviceRevocationUnavailable
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
