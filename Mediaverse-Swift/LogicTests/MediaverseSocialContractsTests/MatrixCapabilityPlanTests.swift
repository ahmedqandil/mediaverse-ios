import XCTest
@testable import MediaverseSocialContracts

final class MatrixCapabilityPlanTests: XCTestCase {
    func testStrongestModelPromptIsNormativeAndForbidsParallelProtocolClient() {
        XCTAssertEqual(
            MatrixNativeGoverningContract.normativeSource,
            "User strongest-model Matrix-native Vibes prompt (precedence 1)"
        )
        XCTAssertEqual(MatrixNativeGoverningContract.matrixAuthority, "MatrixRustSDK")
        XCTAssertEqual(
            MatrixNativeGoverningContract.acceptanceLedger,
            "qa/matrix-native-strongest-model-acceptance.json"
        )
        XCTAssertFalse(MatrixNativeGoverningContract.permitsHandWrittenMatrixProtocolClient)
    }

    func testPlanCoversEveryRequiredCapabilityExactlyOnce() {
        XCTAssertTrue(MatrixNativeCapabilityPlan.isComplete)
        XCTAssertEqual(
            Set(MatrixNativeCapabilityPlan.current.map(\.capability)),
            Set(MatrixNativeCapability.allCases)
        )
        XCTAssertEqual(
            MatrixNativeCapabilityPlan.current.count,
            MatrixNativeCapability.allCases.count
        )
    }

    func testApplicationE2eeCapabilitiesAreExplicitlyRetired() {
        for capability in [
            MatrixNativeCapability.endToEndEncryption,
            .crossSigning,
            .keyBackup,
            .keyRecovery,
            .deviceVerification,
            .encryptionRecoveryManagement,
        ] {
            XCTAssertEqual(
                MatrixNativeCapabilityPlan.entry(for: capability).state,
                .retired
            )
        }
        XCTAssertEqual(
            MatrixNativeCapabilityPlan.entry(for: .secureTokenStorage).state,
            .foundation
        )
    }

    func testExistingInfrastructureCapabilitiesRemainGated() {
        for capability in [
            MatrixNativeCapability.matrixRTC,
            .voiceRooms,
            .videoRooms,
            .controlledFederation,
            .applicationServiceBridges
        ] {
            XCTAssertEqual(
                MatrixNativeCapabilityPlan.entry(for: capability).state,
                .existingInfrastructureGate
            )
        }
    }

    func testMatrixNativeRuntimeIgnoresStaleDeviceFlagButRequiresV2ServerGate() throws {
        let suiteName = "MatrixCapabilityPlanTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        var local = SocialFeatureConfiguration.runtime(userDefaults: suite)
        XCTAssertTrue(local.matrixNativeVibesEnabled)
        XCTAssertTrue(MatrixSessionRollout.resolved(
            local: local,
            serverEnabled: true,
            ownershipVersion: 2
        ).mayStartSDK)

        suite.set(false, forKey: "social.matrix-native-vibes-v2.enabled")
        local = SocialFeatureConfiguration.runtime(userDefaults: suite)
        XCTAssertTrue(local.matrixNativeVibesEnabled)
        XCTAssertTrue(MatrixSessionRollout.resolved(
            local: local,
            serverEnabled: true,
            ownershipVersion: 2
        ).mayStartSDK)

        suite.set(true, forKey: "social.matrix-native-vibes-v2.enabled")
        local = SocialFeatureConfiguration.runtime(userDefaults: suite)
        XCTAssertFalse(MatrixSessionRollout.resolved(
            local: local,
            serverEnabled: false,
            ownershipVersion: 2
        ).mayStartSDK)
        XCTAssertFalse(MatrixSessionRollout.resolved(
            local: local,
            serverEnabled: true,
            ownershipVersion: 1
        ).mayStartSDK)
        XCTAssertTrue(MatrixSessionRollout.resolved(
            local: local,
            serverEnabled: true,
            ownershipVersion: 2
        ).mayStartSDK)
    }
}
