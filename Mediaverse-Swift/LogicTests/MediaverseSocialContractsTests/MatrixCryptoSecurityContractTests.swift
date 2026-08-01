import XCTest
@testable import MediaverseSocialContracts

final class MatrixCryptoSecurityContractTests: XCTestCase {
    func testHomeserverPolicyPinsExistingWestreemOriginsExactly() {
        XCTAssertTrue(MatrixHomeserverTrustPolicy.accepts("https://vibes.westreem.com"))
        XCTAssertTrue(MatrixHomeserverTrustPolicy.accepts("https://matrix.westreem.com/"))
        XCTAssertTrue(MatrixHomeserverTrustPolicy.accepts("https://westreem-vibes-synapse.fly.dev"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("https://westreem-vibes-synapse.fly.dev.evil.test"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("https://vibes.westreem.com.evil.test"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("https://user@vibes.westreem.com"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("https://vibes.westreem.com:8448"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("https://vibes.westreem.com/_matrix"))
        XCTAssertFalse(MatrixHomeserverTrustPolicy.accepts("http://vibes.westreem.com"))
    }

    func testCryptoReadyRequiresVerificationRecoveryAndBackup() {
        let ready = MatrixNativeCryptoSnapshot(
            recovery: .enabled,
            backup: .enabled,
            verification: .verified,
            backupExistsOnServer: true,
            currentDeviceID: "IOS",
            currentDeviceFingerprint: "ABC",
            hasOtherVerifiableDevices: true,
            isLastDevice: false
        )
        XCTAssertTrue(ready.canReadEligibleEncryptedRooms)
        XCTAssertNil(ready.readinessAction)

        let unverified = MatrixNativeCryptoSnapshot(
            recovery: .enabled,
            backup: .enabled,
            verification: .unverified,
            backupExistsOnServer: true,
            currentDeviceID: "IOS",
            currentDeviceFingerprint: nil,
            hasOtherVerifiableDevices: false,
            isLastDevice: true
        )
        XCTAssertFalse(unverified.canReadEligibleEncryptedRooms)
        XCTAssertEqual(unverified.readinessAction, .verifyDevice)
    }

    func testReadinessActionsKeepSetupRecoveryAndBackupExplicit() {
        func snapshot(
            recovery: MatrixNativeRecoveryStatus,
            backup: MatrixNativeBackupStatus,
            verification: MatrixNativeVerificationStatus
        ) -> MatrixNativeCryptoSnapshot {
            MatrixNativeCryptoSnapshot(
                recovery: recovery,
                backup: backup,
                verification: verification,
                backupExistsOnServer: recovery != .disabled,
                currentDeviceID: "IOS",
                currentDeviceFingerprint: nil,
                hasOtherVerifiableDevices: false,
                isLastDevice: true
            )
        }

        XCTAssertEqual(
            snapshot(recovery: .disabled, backup: .unknown, verification: .unverified)
                .readinessAction,
            .setUpRecovery
        )
        XCTAssertEqual(
            snapshot(recovery: .incomplete, backup: .enabled, verification: .verified)
                .readinessAction,
            .recoverExistingAccount
        )
        XCTAssertEqual(
            snapshot(recovery: .enabled, backup: .enabling, verification: .verified)
                .readinessAction,
            .waitForBackup
        )
    }

    func testCommunityWaveEncryptionIsExplicitAndNeverPublic() throws {
        let publicDraft = MatrixNativeRoomCreationDraft(
            name: "Public",
            topic: "",
            visibility: .publicVibe,
            inviteUserIDs: [],
            isEncrypted: true,
            canonicalAlias: "#public:example.org"
        )
        XCTAssertFalse(try MatrixNativeCreationContract.validate(publicDraft).isEncrypted)

        let privateDraft = MatrixNativeRoomCreationDraft(
            name: "Private",
            topic: "",
            visibility: .privateVibe,
            inviteUserIDs: [],
            isEncrypted: true
        )
        XCTAssertFalse(try MatrixNativeCreationContract.validate(privateDraft).isEncrypted)
    }

    func testRecoveryKeyValidationDoesNotPersistOrLoosenInput() throws {
        XCTAssertEqual(
            try MatrixNativeRecoveryKeyPolicy.normalized("  EsABC DEF  "),
            "EsABC DEF"
        )
        XCTAssertThrowsError(try MatrixNativeRecoveryKeyPolicy.normalized(" \n "))
        XCTAssertThrowsError(try MatrixNativeRecoveryKeyPolicy.normalized(
            String(repeating: "x", count: MatrixNativeRecoveryKeyPolicy.maximumLength + 1)
        ))
    }

    func testRecoveryResetRequiresExactDestructiveConfirmation() throws {
        XCTAssertNoThrow(try MatrixNativeRecoveryResetPolicy.validate(
            MatrixNativeRecoveryResetPolicy.confirmation
        ))
        XCTAssertThrowsError(try MatrixNativeRecoveryResetPolicy.validate("reset secure vibes"))
        XCTAssertThrowsError(try MatrixNativeRecoveryResetPolicy.validate(" RESET SECURE VIBES "))
    }

    func testPinnedSDKLimitationsForbidParallelDeviceAPI() {
        XCTAssertFalse(MatrixNativeSDKCryptoCapabilities.supportsEncryptedMedia)
        XCTAssertFalse(MatrixNativeSDKCryptoCapabilities.supportsSASDeviceVerification)
        XCTAssertTrue(MatrixNativeSDKCryptoCapabilities.supportsLegacyEncryptedHistoryRead)
        XCTAssertFalse(MatrixNativeSDKCryptoCapabilities.supportsDeviceEnumeration)
        XCTAssertFalse(MatrixNativeSDKCryptoCapabilities.supportsDeviceRevocation)
        XCTAssertFalse(MatrixNativeSDKCryptoCapabilities.permitsHandWrittenDeviceAPI)
    }
}
