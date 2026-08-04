import XCTest
@testable import MediaverseSocialContracts

final class MatrixSessionFoundationTests: XCTestCase {
    func testIdentityReconcileGateClaimsInitialExistingUserOnce() {
        var gate = MatrixIdentityReconcileGate()

        XCTAssertTrue(gate.claim("user-a"))
        XCTAssertFalse(gate.claim("user-a"))
    }

    func testIdentityReconcileGateClaimsInitialNilThenRestoredUser() {
        var gate = MatrixIdentityReconcileGate()

        XCTAssertTrue(gate.claim(nil))
        XCTAssertTrue(gate.claim("user-a"))
        XCTAssertFalse(gate.claim("user-a"))
    }

    func testIdentityReconcileGateIgnoresDuplicateDisconnectedObservation() {
        var gate = MatrixIdentityReconcileGate()

        XCTAssertTrue(gate.claim(nil))
        XCTAssertFalse(gate.claim(nil))
    }

    func testIdentityReconcileGateDisconnectsBetweenAccounts() {
        var gate = MatrixIdentityReconcileGate()

        XCTAssertTrue(gate.claim("user-a"))
        XCTAssertTrue(gate.claim(nil))
        XCTAssertTrue(gate.claim("user-b"))
        XCTAssertFalse(gate.claim("user-b"))
    }

    func testForegroundRecoveryGateSkipsInitialActivation() {
        var gate = MatrixForegroundRecoveryGate()

        XCTAssertFalse(gate.claim(isActive: false))
        XCTAssertFalse(gate.claim(isActive: true))
        XCTAssertFalse(gate.claim(isActive: true))
    }

    func testForegroundRecoveryGateAllowsOneRecoveryAfterLeavingActive() {
        var gate = MatrixForegroundRecoveryGate()

        XCTAssertFalse(gate.claim(isActive: true))
        XCTAssertFalse(gate.claim(isActive: false))
        XCTAssertTrue(gate.claim(isActive: true))
        XCTAssertFalse(gate.claim(isActive: true))
    }

    func testForegroundRecoveryGateRearmsForEveryRealResume() {
        var gate = MatrixForegroundRecoveryGate()

        XCTAssertFalse(gate.claim(isActive: true))
        XCTAssertFalse(gate.claim(isActive: false))
        XCTAssertTrue(gate.claim(isActive: true))
        XCTAssertFalse(gate.claim(isActive: false))
        XCTAssertTrue(gate.claim(isActive: true))
    }

    func testIdentityUsesImmutableWestreemIDAndFixedServer() throws {
        let identity = try MatrixCanonicalIdentity(westreemUserID: "cm_user-123")
        XCTAssertEqual(
            identity.matrixUserID,
            "@u_636d5f757365722d313233:vibes.westreem.com"
        )
        XCTAssertTrue(identity.verifies(
            matrixUserID: "@u_636d5f757365722d313233:vibes.westreem.com"
        ))
        XCTAssertFalse(identity.verifies(matrixUserID: "@u_new-handle:vibes.westreem.com"))
    }

    func testIdentityRejectsEmptyImmutableID() {
        XCTAssertThrowsError(try MatrixCanonicalIdentity(westreemUserID: ""))
    }

    func testPersistedDescriptorRequiresCanonicalIdentityAndHomeserver() throws {
        XCTAssertNoThrow(try MatrixPersistedSessionDescriptor(
            westreemUserID: "user_1",
            matrixUserID: "@u_757365725f31:vibes.westreem.com",
            deviceID: "IOS1",
            homeserverURL: "https://matrix.westreem.com"
        ))
        XCTAssertThrowsError(try MatrixPersistedSessionDescriptor(
            westreemUserID: "user_1",
            matrixUserID: "@u_other:vibes.westreem.com",
            deviceID: "IOS1",
            homeserverURL: "https://vibes.westreem.com"
        ))
        XCTAssertThrowsError(try MatrixPersistedSessionDescriptor(
            westreemUserID: "user_1",
            matrixUserID: "@u_757365725f31:vibes.westreem.com",
            deviceID: "IOS1",
            homeserverURL: "http://matrix.example.com"
        ))
    }

    func testSDKRolloutFailsClosed() {
        XCTAssertFalse(MatrixSessionRollout.disabled.mayStartSDK)
        XCTAssertFalse(MatrixSessionRollout(
            localEnabled: true,
            serverEnabled: true,
            ownershipVersion: 1
        ).mayStartSDK)
        XCTAssertTrue(MatrixSessionRollout(
            localEnabled: true,
            serverEnabled: true,
            ownershipVersion: 2
        ).mayStartSDK)
    }

    func testStrongestModelPersistencePolicyRequiresSDKOwnedOfflineState() {
        let policy = MatrixNativePersistencePolicy.strongestModel
        XCTAssertTrue(policy.usesSDKEncryptedSQLiteStore)
        XCTAssertTrue(policy.usesSDKOfflineSync)
        XCTAssertTrue(policy.usesSDKSendQueue)
        XCTAssertEqual(policy.maximumRetryDelaySeconds, 30)
    }

    func testRevokedRefreshTokenRequiresMatrixSessionReplacement() {
        XCTAssertTrue(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: nil,
                message: "[403 / M_FORBIDDEN] refresh token isn't valid anymore"
            )
        )
        XCTAssertTrue(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: "M_UNKNOWN_TOKEN",
                message: "Unknown access token"
            )
        )
        XCTAssertTrue(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: "M_FORBIDDEN",
                message: "Refresh token revoked"
            )
        )
    }

    func testOrdinaryForbiddenAndTemporaryFailuresKeepCurrentMatrixSession() {
        XCTAssertFalse(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: "M_FORBIDDEN",
                message: "You do not have permission to change this room"
            )
        )
        XCTAssertFalse(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: nil,
                message: "Network request failed"
            )
        )
        XCTAssertFalse(
            MatrixSessionCredentialRecoveryPolicy.requiresSessionReplacement(
                matrixErrorCode: "M_FORBIDDEN",
                message: "Access token is valid but this action is forbidden"
            )
        )
    }

    func testLegacyCommunityWritesRetireAtNativeCutover() {
        XCTAssertTrue(LegacyCommunityWriteBoundary.isRetiredCommunityPath(
            "/api/fan-clubs/community-1/posts"
        ))
        XCTAssertTrue(LegacyCommunityWriteBoundary.isRetiredCommunityPath(
            "/api/fan-club-posts/post-1/comments"
        ))
        XCTAssertFalse(LegacyCommunityWriteBoundary.isRetiredCommunityPath(
            "/api/v2/atmo/posts"
        ))
        XCTAssertFalse(LegacyCommunityWriteBoundary.isRetiredCommunityPath(
            "/api/collections/collection-1/contributions"
        ))

        XCTAssertThrowsError(try LegacyCommunityWriteBoundary.requireLegacyWriteAllowed(
            path: "/api/fan-clubs/community-1/posts",
            matrixNativeCutoverEnabled: true
        )) { error in
            XCTAssertEqual(
                error as? LegacySocialAPIError,
                .matrixNativeCommunityWriteRetired
            )
        }
        XCTAssertNoThrow(try LegacyCommunityWriteBoundary.requireLegacyWriteAllowed(
            path: "/api/v2/atmo/posts",
            matrixNativeCutoverEnabled: true
        ))
    }

    func testSSOBootstrapAcceptsOnlyExactWestreemCallback() throws {
        let bootstrap = MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            humanIdentityMode: .nativeOIDC,
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso",
            idpID: "westreem"
        )

        XCTAssertNoThrow(try bootstrap.validated())
        XCTAssertTrue(bootstrap.accepts(
            callbackURL: URL(string: "westreem://matrix/sso?loginToken=abc")!
        ))
        XCTAssertFalse(bootstrap.accepts(
            callbackURL: URL(string: "westreem://auth/matrix?loginToken=abc")!
        ))
        XCTAssertFalse(bootstrap.accepts(
            callbackURL: URL(string: "https://matrix/sso?loginToken=abc")!
        ))
    }

    func testSSOBootstrapFailsClosedForWrongAuthorityOrInsecureHomeserver() {
        XCTAssertThrowsError(try MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 1,
            humanIdentityMode: .nativeOIDC,
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso"
        ).validated())
        XCTAssertThrowsError(try MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            humanIdentityMode: .nativeOIDC,
            homeserverURL: "http://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso"
        ).validated())
    }

    func testBrokerBootstrapRequiresExplicitModeAndNoSSOParameters() throws {
        let broker = MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            humanIdentityMode: .applicationService,
            authMode: .brokerFallback,
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: nil
        )
        XCTAssertNoThrow(try broker.validated())
        XCTAssertFalse(
            broker.accepts(
                callbackURL: URL(
                    string: "westreem://matrix/sso?loginToken=abc"
                )!
            )
        )
        XCTAssertThrowsError(
            try MatrixSSOBootstrap(
                enabled: true,
                ownershipVersion: 2,
                humanIdentityMode: .applicationService,
                authMode: .brokerFallback,
                homeserverURL: "https://vibes.westreem.com",
                redirectURL: "westreem://matrix/sso"
            ).validated()
        )
    }

    func testDisabledBootstrapDecodesWithoutReceivingServerConfiguration() throws {
        let value = try JSONDecoder().decode(
            MatrixSSOBootstrap.self,
            from: Data(
                #"{"enabled":false,"ownershipVersion":2}"#.utf8
            )
        )
        XCTAssertFalse(value.enabled)
        XCTAssertEqual(value.humanIdentityMode, .applicationService)
        XCTAssertNil(value.authMode)
        XCTAssertEqual(value.homeserverURL, "")
        XCTAssertThrowsError(try value.validated())
    }

    func testNativeOIDCRejectsBrokerAndApplicationServiceAllowsSSO() {
        XCTAssertThrowsError(try MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            humanIdentityMode: .nativeOIDC,
            authMode: .brokerFallback,
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: nil
        ).validated())
        XCTAssertNoThrow(try MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            humanIdentityMode: .applicationService,
            authMode: .sso,
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso",
            idpID: "westreem"
        ).validated())
    }

    func testOldServerMissingModeWithSSORemainsCompatible() throws {
        let value = try JSONDecoder().decode(
            MatrixSSOBootstrap.self,
            from: Data(
                #"{"enabled":true,"ownershipVersion":2,"authMode":"SSO","homeserverUrl":"https://vibes.westreem.com","redirectUrl":"westreem://matrix/sso","idpId":"westreem"}"#.utf8
            )
        )
        XCTAssertEqual(value.humanIdentityMode, .applicationService)
        XCTAssertEqual(value.authMode, .sso)
        XCTAssertNoThrow(try value.validated())
    }

    func testUnknownHumanIdentityModeFailsClosed() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            MatrixSSOBootstrap.self,
            from: Data(
                #"{"enabled":true,"ownershipVersion":2,"humanIdentityMode":"UNKNOWN","authMode":"SSO","homeserverUrl":"https://vibes.westreem.com","redirectUrl":"westreem://matrix/sso","idpId":"westreem"}"#.utf8
            )
        ))
    }

    func testSameMXIDLegacyCredentialRequiresOneNativeReauthentication() {
        let identity = try? MatrixCanonicalIdentity(westreemUserID: "stable-user")
        XCTAssertEqual(
            identity?.matrixUserID,
            "@u_737461626c652d75736572:vibes.westreem.com"
        )
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: nil,
                authMode: .sso,
                humanIdentityMode: .nativeOIDC
            ),
            .quarantineAndReauthenticate
        )
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: .applicationServiceBroker,
                authMode: .sso,
                humanIdentityMode: .nativeOIDC
            ),
            .quarantineAndReauthenticate
        )
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: .sso,
                authMode: .sso,
                humanIdentityMode: .nativeOIDC
            ),
            .restore
        )
    }

    func testExplicitApplicationServiceRollbackRequiresBrokerProvenance() {
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: .sso,
                authMode: .brokerFallback,
                humanIdentityMode: .applicationService
            ),
            .quarantineAndReauthenticate
        )
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: .applicationServiceBroker,
                authMode: .brokerFallback,
                humanIdentityMode: .applicationService
            ),
            .restore
        )
        XCTAssertEqual(
            MatrixSessionRestorationPolicy.decision(
                storedProvenance: nil,
                authMode: .brokerFallback,
                humanIdentityMode: .applicationService
            ),
            .restore
        )
    }

    func testAccountSwitchRequiresOldMatrixClientDisconnect() {
        XCTAssertFalse(MatrixAccountTransitionPolicy.requiresClientDisconnect(
            previousWestreemUserID: nil,
            nextWestreemUserID: "one"
        ))
        XCTAssertFalse(MatrixAccountTransitionPolicy.requiresClientDisconnect(
            previousWestreemUserID: "one",
            nextWestreemUserID: "one"
        ))
        XCTAssertTrue(MatrixAccountTransitionPolicy.requiresClientDisconnect(
            previousWestreemUserID: "one",
            nextWestreemUserID: "two"
        ))
    }

    func testPusherOwnerProofValidatesAndEncodesExactDefaultPayloadShape() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let proof = MatrixPusherOwnerProof(
            v: 1,
            kid: "current-key_1",
            iat: 1_999_900,
            exp: 2_086_300,
            mac: String(repeating: "A", count: 43)
        )
        XCTAssertNoThrow(try proof.validated(now: now))
        let payload = try proof.defaultPayloadJSON(now: now)
        XCTAssertLessThanOrEqual(payload.utf8.count, 1_024)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["westreem_owner_proof_v1"])
        let encodedProof = try XCTUnwrap(
            object["westreem_owner_proof_v1"] as? [String: Any]
        )
        XCTAssertEqual(Set(encodedProof.keys), ["v", "kid", "iat", "exp", "mac"])
    }

    func testPusherOwnerProofRejectsUnknownOversizedAndMalformedContent() {
        let unknown = Data(
            #"{"v":1,"kid":"k","iat":100,"exp":200,"mac":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","extra":true}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(MatrixPusherOwnerProof.self, from: unknown)
        )
        for proof in [
            MatrixPusherOwnerProof(
                v: 2,
                kid: "k",
                iat: 100,
                exp: 200,
                mac: String(repeating: "A", count: 43)
            ),
            MatrixPusherOwnerProof(
                v: 1,
                kid: String(repeating: "k", count: 33),
                iat: 100,
                exp: 200,
                mac: String(repeating: "A", count: 43)
            ),
            MatrixPusherOwnerProof(
                v: 1,
                kid: "k",
                iat: 100,
                exp: 200,
                mac: String(repeating: "A", count: 44)
            ),
        ] {
            XCTAssertThrowsError(
                try proof.validated(now: Date(timeIntervalSince1970: 150))
            )
        }
    }

    func testPusherOwnerProofRejectsFutureExpiredAndOverlongLifetime() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let mac = String(repeating: "A", count: 43)
        XCTAssertThrowsError(try MatrixPusherOwnerProof(
            v: 1,
            kid: "k",
            iat: 2_000_301,
            exp: 2_100_000,
            mac: mac
        ).validated(now: now))
        XCTAssertThrowsError(try MatrixPusherOwnerProof(
            v: 1,
            kid: "k",
            iat: 1_999_000,
            exp: 2_000_000,
            mac: mac
        ).validated(now: now))
        XCTAssertThrowsError(try MatrixPusherOwnerProof(
            v: 1,
            kid: "k",
            iat: 1_999_000,
            exp: 1_999_000 + 15_552_001,
            mac: mac
        ).validated(now: now))
    }

    func testPusherOwnerProofModeHandlesOffOptionalAndRequiredExactly() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let proof = MatrixPusherOwnerProof(
            v: 1,
            kid: "k",
            iat: 1_999_900,
            exp: 2_086_300,
            mac: String(repeating: "A", count: 43)
        )
        XCTAssertNil(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .off,
            proof: nil,
            now: now
        ))
        XCTAssertThrowsError(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .off,
            proof: proof,
            now: now
        ))
        XCTAssertNil(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .optional,
            proof: nil,
            now: now
        ))
        XCTAssertNotNil(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .optional,
            proof: proof,
            now: now
        ))
        XCTAssertThrowsError(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .required,
            proof: nil,
            now: now
        ))
        XCTAssertNotNil(try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: .required,
            proof: proof,
            now: now
        ))
    }

    func testPushRegistrationRevisionAndEpochAcceptOnlyExactOpaqueBase64URLShapes() throws {
        let revision = try MatrixPushRegistrationRevision(
            rawValue: "Abcdefghijklmnopqrstu_"
        )
        XCTAssertEqual(revision.rawValue, "Abcdefghijklmnopqrstu_")
        let epoch = try MatrixPushRegistrationEpoch(
            rawValue: "Abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE"
        )
        XCTAssertEqual(epoch.rawValue.count, 43)

        for invalid in [
            String(repeating: "a", count: 21),
            String(repeating: "a", count: 23),
            "abcdefghijklmnopqrstu+",
            "not-a-revision",
            String(repeating: "a", count: 65),
        ] {
            XCTAssertThrowsError(
                try MatrixPushRegistrationRevision(rawValue: invalid)
            )
        }
        for invalid in [
            String(repeating: "a", count: 42),
            String(repeating: "a", count: 44),
            String(repeating: "+", count: 43),
        ] {
            XCTAssertThrowsError(try MatrixPushRegistrationEpoch(rawValue: invalid))
        }
    }

    func testPushRegistrationConflictRetryIsBoundedAndContextFenced() {
        let revision = "Abcdefghijklmnopqrstu_"
        XCTAssertTrue(MatrixPushRegistrationRetryPolicy.mayRetry(
            conflictAttempt: 0,
            contextIsCurrent: true,
            revision: revision
        ))
        XCTAssertTrue(MatrixPushRegistrationRetryPolicy.mayRetry(
            conflictAttempt: 1,
            contextIsCurrent: true,
            revision: revision
        ))
        XCTAssertFalse(MatrixPushRegistrationRetryPolicy.mayRetry(
            conflictAttempt: 2,
            contextIsCurrent: true,
            revision: revision
        ))
        XCTAssertFalse(MatrixPushRegistrationRetryPolicy.mayRetry(
            conflictAttempt: 0,
            contextIsCurrent: false,
            revision: revision
        ))
        XCTAssertFalse(MatrixPushRegistrationRetryPolicy.mayRetry(
            conflictAttempt: 0,
            contextIsCurrent: true,
            revision: "invalid"
        ))
    }

    func testPushRegistrationEpochSurvivesRefreshAndRestoreUntilSignOut() {
        XCTAssertFalse(
            MatrixPushRegistrationEpochPolicy.rotates(on: .accessTokenRefresh)
        )
        XCTAssertFalse(
            MatrixPushRegistrationEpochPolicy.rotates(on: .appRestore)
        )
        XCTAssertTrue(
            MatrixPushRegistrationEpochPolicy.rotates(on: .fullSignIn)
        )
        XCTAssertTrue(
            MatrixPushRegistrationEpochPolicy.rotates(on: .accountSwitch)
        )
        XCTAssertTrue(
            MatrixPushRegistrationEpochPolicy.rotates(on: .signOut)
        )
    }

    func testPushRevocationCapabilityIsAnIndependentExact256BitValue() throws {
        let epoch = try MatrixPushRegistrationEpoch(rawValue: String(repeating: "e", count: 43))
        let capability = try MatrixPushRegistrationRevocationCapability(
            rawValue: String(repeating: "c", count: 43)
        )
        XCTAssertNotEqual(epoch.rawValue, capability.rawValue)
        for invalid in ["", String(repeating: "c", count: 42), String(repeating: "c", count: 44), String(repeating: "+", count: 43)] {
            XCTAssertThrowsError(
                try MatrixPushRegistrationRevocationCapability(rawValue: invalid)
            )
        }
    }

    func testPushCleanupQueueDeduplicatesOnlyExactCapabilityIdentity() {
        let exact = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "same-epoch",
            revocationCapabilityDigest: "capability-a"
        )
        let differentCapability = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "same-epoch",
            revocationCapabilityDigest: "capability-b"
        )
        let repeatedlyMerged = (0..<1_000).reduce(
            into: [MatrixPushRegistrationHandleIdentity]()
        ) { result, _ in
            result = MatrixPushCleanupQueuePolicy.merging(exact, into: result)
        }
        XCTAssertEqual(repeatedlyMerged, [exact])
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.merging(
                differentCapability,
                into: repeatedlyMerged
            ),
            [exact, differentCapability]
        )
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.removing(
                exact,
                from: [exact, differentCapability]
            ),
            [differentCapability]
        )
    }

    func testPushCleanupQueueNeverEvictsPotentiallyLiveOfflineRotations() {
        let identities = (0..<32).reduce(into: [MatrixPushRegistrationHandleIdentity]()) {
            result, index in
            result = MatrixPushCleanupQueuePolicy.merging(
                MatrixPushRegistrationHandleIdentity(
                    tokenDigest: "token-\(index)",
                    appID: index.isMultiple(of: 2)
                        ? "com.westreem.app"
                        : "com.westreem.app.voip",
                    registrationEpoch: "epoch-\(index)",
                    revocationCapabilityDigest: "capability-\(index)"
                ),
                into: result
            )
        }
        XCTAssertEqual(identities.count, 32)

        let old = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "old-epoch",
            revocationCapabilityDigest: "old-capability"
        )
        let current = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "new-epoch",
            revocationCapabilityDigest: "new-capability"
        )
        let afterOldCompletion = MatrixPushCleanupQueuePolicy.removing(
            old,
            from: [old, current]
        )
        XCTAssertEqual(afterOldCompletion, [current])
    }

    func testAuthoritativeRegistrationCompactsOnlyItsExactTokenAppSlot() {
        let oldOrdinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-a",
            appID: "com.westreem.app",
            registrationEpoch: "old-epoch",
            revocationCapabilityDigest: "old-capability"
        )
        let confirmedOrdinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-a",
            appID: "com.westreem.app",
            registrationEpoch: "new-epoch",
            revocationCapabilityDigest: "new-capability"
        )
        let otherToken = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-b",
            appID: "com.westreem.app",
            registrationEpoch: "other-epoch",
            revocationCapabilityDigest: "other-capability"
        )
        let sameBytesVoIP = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-a",
            appID: "com.westreem.app.voip",
            registrationEpoch: "voip-epoch",
            revocationCapabilityDigest: "voip-capability"
        )
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.removingAuthoritativelySuperseded(
                by: confirmedOrdinary,
                from: [oldOrdinary, confirmedOrdinary, otherToken, sameBytesVoIP]
            ),
            [otherToken, sameBytesVoIP]
        )
    }

    func testOfflineABARotationRetainsBAndDropsOldAOnlyAfterNewAConfirmation() {
        let oldA = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-a",
            appID: "com.westreem.app",
            registrationEpoch: "account-a-old",
            revocationCapabilityDigest: "cap-a-old"
        )
        let tokenB = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-b",
            appID: "com.westreem.app",
            registrationEpoch: "account-b",
            revocationCapabilityDigest: "cap-b"
        )
        let newA = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "token-a",
            appID: "com.westreem.app",
            registrationEpoch: "account-a-new",
            revocationCapabilityDigest: "cap-a-new"
        )
        let offlineQueue = [oldA, tokenB]

        let afterNewAConfirmed = MatrixPushCleanupQueuePolicy
            .removingAuthoritativelySuperseded(by: newA, from: offlineQueue)
        XCTAssertEqual(afterNewAConfirmed, [tokenB])
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.removing(
                tokenB,
                from: afterNewAConfirmed + [newA]
            ),
            [newA]
        )
    }

    func testAccountAToBCleanupCompactsOrdinaryAndVoIPIndependently() {
        let accountAOrdinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "ordinary-token",
            appID: "com.westreem.app",
            registrationEpoch: "account-a",
            revocationCapabilityDigest: "a-ordinary"
        )
        let accountAVoIP = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "voip-token",
            appID: "com.westreem.app.voip",
            registrationEpoch: "account-a",
            revocationCapabilityDigest: "a-voip"
        )
        let accountBOrdinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "ordinary-token",
            appID: "com.westreem.app",
            registrationEpoch: "account-b",
            revocationCapabilityDigest: "b-ordinary"
        )
        let accountBVoIP = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "voip-token",
            appID: "com.westreem.app.voip",
            registrationEpoch: "account-b",
            revocationCapabilityDigest: "b-voip"
        )

        let offlineAQueue = [accountAOrdinary, accountAVoIP]
        let afterBOrdinary = MatrixPushCleanupQueuePolicy
            .removingAuthoritativelySuperseded(
                by: accountBOrdinary,
                from: offlineAQueue
            )
        XCTAssertEqual(afterBOrdinary, [accountAVoIP])
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.removingAuthoritativelySuperseded(
                by: accountBVoIP,
                from: afterBOrdinary
            ),
            []
        )
    }

    func testMatrixPushGatewayAcceptsOnlyExactNonRedirectingCanonicalURL() {
        XCTAssertEqual(
            MatrixPushGatewayContract.canonicalURLString,
            "https://www.westreem.com/_matrix/push/v1/notify"
        )
        XCTAssertTrue(
            MatrixPushGatewayContract.accepts(
                "https://www.westreem.com/_matrix/push/v1/notify"
            )
        )

        let rejected = [
            "https://westreem.com/_matrix/push/v1/notify",
            "https://push.westreem.com/_matrix/push/v1/notify",
            "http://www.westreem.com/_matrix/push/v1/notify",
            "https://www.westreem.com:443/_matrix/push/v1/notify",
            "https://user@www.westreem.com/_matrix/push/v1/notify",
            "https://user:password@www.westreem.com/_matrix/push/v1/notify",
            "https://www.westreem.com/_matrix/push/v1/notify?retry=1",
            "https://www.westreem.com/_matrix/push/v1/notify#fragment",
            "https://www.westreem.com/_matrix/push/v1/notify/",
            "https://www.westreem.com/api/matrix/push/v1/notify",
        ]
        for value in rejected {
            XCTAssertFalse(
                MatrixPushGatewayContract.accepts(value),
                "Unexpectedly accepted \(value)"
            )
        }
    }

    func testForegroundRegistrationReplacesOneExactSlotAndKeepsTopicsDistinct() {
        let ordinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "ordinary-new",
            revocationCapabilityDigest: "ordinary-capability-new"
        )
        let oldOrdinary = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app",
            registrationEpoch: "ordinary-old",
            revocationCapabilityDigest: "ordinary-capability-old"
        )
        let voIP = MatrixPushRegistrationHandleIdentity(
            tokenDigest: "same-token",
            appID: "com.westreem.app.voip",
            registrationEpoch: "voip",
            revocationCapabilityDigest: "voip-capability"
        )

        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let foregroundLease = try! XCTUnwrap(fence.beginRegistration())
        XCTAssertTrue(fence.accepts(foregroundLease))
        XCTAssertEqual(
            MatrixPushCleanupQueuePolicy.removingAuthoritativelySuperseded(
                by: ordinary,
                from: [oldOrdinary, voIP]
            ),
            [voIP]
        )
        XCTAssertEqual(ordinary.appID, "com.westreem.app")
        XCTAssertEqual(voIP.appID, "com.westreem.app.voip")

        fence.invalidateRegistrationContext()
        XCTAssertFalse(fence.accepts(foregroundLease))
    }

    func testForegroundAndMatrixReadinessKeepOneOrdinaryLease() throws {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let ordinary = try XCTUnwrap(fence.beginRegistration())
        let generation = fence.generation

        // Overlapping foreground/readiness hooks join the production
        // ordinaryUploadTask. Readiness itself must not stale that task.
        fence.preserveAcrossReadinessChange()
        fence.preserveAcrossReadinessChange()

        XCTAssertEqual(fence.generation, generation)
        XCTAssertTrue(fence.accepts(ordinary))
    }

    func testUnavailableManagerRecoveryKeepsPendingContextCurrent() throws {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let pending = try XCTUnwrap(fence.beginRegistration())

        // A missing manager throws in production and schedules a retry. When
        // the manager becomes ready, the same account/token context survives.
        fence.preserveAcrossReadinessChange()
        XCTAssertTrue(fence.accepts(pending))
        fence.preserveAcrossReadinessChange()
        XCTAssertTrue(fence.accepts(pending))
    }

    func testRealTokenChangeRejectsPendingOrdinaryButNotTopicIdentity() throws {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let oldTokenLease = try XCTUnwrap(fence.beginRegistration())

        fence.invalidateRegistrationContext()
        let rotatedTokenLease = try XCTUnwrap(fence.beginRegistration())

        XCTAssertFalse(fence.accepts(oldTokenLease))
        XCTAssertTrue(fence.accepts(rotatedTokenLease))
        XCTAssertNotEqual("com.westreem.app", "com.westreem.app.voip")
    }

    func testPendingRegistrationCannotApplyOrRestartAfterSignOutFenceCloses() {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let pendingOrdinary = fence.beginRegistration()
        let pendingVoIP = fence.beginRegistration()
        XCTAssertNotNil(pendingOrdinary)
        XCTAssertNotNil(pendingVoIP)

        fence.beginSignOut()

        XCTAssertFalse(fence.accepts(try! XCTUnwrap(pendingOrdinary)))
        XCTAssertFalse(fence.accepts(try! XCTUnwrap(pendingVoIP)))
        XCTAssertNil(fence.beginRegistration())
        XCTAssertFalse(fence.mayDeleteRegistration(pendingUploadCount: 2))
        // Models cancel + await of both request tasks before the DELETE begins.
        XCTAssertTrue(fence.mayDeleteRegistration(pendingUploadCount: 0))

        fence.openSession()
        let nextAccount = fence.beginRegistration()
        XCTAssertNotNil(nextAccount)
        XCTAssertTrue(fence.accepts(try! XCTUnwrap(nextAccount)))
        XCTAssertFalse(fence.accepts(try! XCTUnwrap(pendingOrdinary)))
    }

    func testAccountAToBTransitionRejectsLateAccountARegistration() {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let accountA = try! XCTUnwrap(fence.beginRegistration())

        fence.openSession()
        let accountB = try! XCTUnwrap(fence.beginRegistration())

        XCTAssertFalse(fence.accepts(accountA))
        XCTAssertTrue(fence.accepts(accountB))
    }

    func testOpaqueMatrixPushKeyAcceptsOnlyExactFrozenShape() throws {
        let valid = "wsp2." + String(repeating: "A", count: 42) + "_"
        XCTAssertEqual(try MatrixOpaquePushKey(rawValue: valid).rawValue, valid)

        for invalid in [
            "WSP2." + String(repeating: "A", count: 43),
            "wsp2." + String(repeating: "A", count: 42),
            "wsp2." + String(repeating: "A", count: 44),
            "wsp2." + String(repeating: "A", count: 42) + "=",
            "wsp2." + String(repeating: "A", count: 42) + "+",
            " wsp2." + String(repeating: "A", count: 43),
            "wsp2." + String(repeating: "A", count: 43) + "\n",
        ] {
            XCTAssertThrowsError(try MatrixOpaquePushKey(rawValue: invalid))
        }
    }

    func testDeliveryLeaseRetryDelayAcceptsExactFrozenBoundaries() {
        XCTAssertEqual(
            MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(1),
            1
        )
        XCTAssertEqual(
            MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(99),
            99
        )
        XCTAssertEqual(
            MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(100),
            100
        )
        XCTAssertEqual(
            MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(30_000),
            30_000
        )
        XCTAssertNil(MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(0))
        XCTAssertNil(MatrixPushDeliveryLeaseRetryPolicy.validatedMilliseconds(30_001))
        XCTAssertEqual(MatrixPushDeliveryLeaseRetryPolicy.maximumInCallWaits, 1)
    }

    func testV3ConflictDecoderAcceptsOnlyExactFrozenShapes() throws {
        let revision = String(repeating: "r", count: 22)
        XCTAssertEqual(
            try MatrixPushRegistrationV3ConflictPolicy.decode(Data(
                #"{"error":"Push registration revision conflict","registrationRevision":"\#(revision)"}"#.utf8
            )),
            .revision(revision)
        )
        XCTAssertEqual(
            try MatrixPushRegistrationV3ConflictPolicy.decode(Data(
                #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":1}"#.utf8
            )),
            .deliveryLease(1)
        )
        XCTAssertEqual(
            try MatrixPushRegistrationV3ConflictPolicy.decode(Data(
                #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":30000}"#.utf8
            )),
            .deliveryLease(30_000)
        )

        let rejected = [
            #"{"error":"Push registration revision conflict","registrationRevision":"\#(revision)","extra":true}"#,
            #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":1,"registrationRevision":"\#(revision)"}"#,
            #"{"error":"invalid_transition","registrationRevision":"\#(revision)"}"#,
            #"{"error":"Invalid push registration transition"}"#,
            #"{"error":"revoked","registrationRevision":"\#(revision)"}"#,
            #"{"error":"upgrade_required","registrationRevision":"\#(revision)"}"#,
            #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":0}"#,
            #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":30001}"#,
            #"{"error":"Push delivery handoff in progress","code":"delivery_lease_active","retryAfterMs":"1"}"#,
        ]
        for value in rejected {
            XCTAssertThrowsError(
                try MatrixPushRegistrationV3ConflictPolicy.decode(Data(value.utf8)),
                value
            )
        }
    }

    func testOpaquePushMigrationAcceptsOnlyFrozenServerProjections() {
        XCTAssertTrue(MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: .dualPrepared,
            routes: .init(opaque: true, raw: true),
            pushSetupPending: false,
            rawRetireAt: nil
        ))
        XCTAssertTrue(MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: .opaquePreparedNoRaw,
            routes: .init(opaque: true, raw: false),
            pushSetupPending: true,
            rawRetireAt: nil
        ))
        XCTAssertTrue(MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: .rawGrace,
            routes: .init(opaque: true, raw: true),
            pushSetupPending: false,
            rawRetireAt: "2026-08-03T12:00:00Z"
        ))
        XCTAssertFalse(MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: .opaquePreparedNoRaw,
            routes: .init(opaque: true, raw: true),
            pushSetupPending: false,
            rawRetireAt: nil
        ))
        XCTAssertNotNil(MatrixOpaquePushMigrationPolicy.rawRetireDate(
            "2026-08-03T12:00:00.123Z"
        ))
        XCTAssertNotNil(MatrixOpaquePushMigrationPolicy.rawRetireDate(
            "2026-08-03T12:00:00Z"
        ))
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.rawRetireDate(
            "2026-08-03T15:00:00+03:00"
        ))
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.rawRetireDate("not-a-date"))
        XCTAssertFalse(MatrixOpaquePushMigrationPolicy.acceptsServerProjection(
            state: .rawGrace,
            routes: .init(opaque: true, raw: true),
            pushSetupPending: false,
            rawRetireAt: nil
        ))
    }

    func testPushProviderEnvironmentMatchesFrozenV3WireValues() {
        XCTAssertEqual(
            MatrixPushProviderEnvironment.backendValue(
                forAPNsEnvironment: "development"
            ),
            "sandbox"
        )
        XCTAssertEqual(
            MatrixPushProviderEnvironment.backendValue(
                forAPNsEnvironment: "sandbox"
            ),
            "sandbox"
        )
        XCTAssertEqual(
            MatrixPushProviderEnvironment.backendValue(
                forAPNsEnvironment: "production"
            ),
            "production"
        )
        for invalid in ["Development", "debug", " production", "production\n", ""] {
            XCTAssertNil(
                MatrixPushProviderEnvironment.backendValue(
                    forAPNsEnvironment: invalid
                )
            )
        }
    }

    func testOpaquePushConfirmationAllowsOnlyBoundedDualMissingRawRecovery() {
        XCTAssertEqual(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .dualPrepared,
            observed: .init(opaquePresent: true, rawPresent: true)
        ), .standard)
        XCTAssertEqual(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .dualPrepared,
            observed: .init(opaquePresent: true, rawPresent: false)
        ), .dualPreparedMissingRawRecovery)
        XCTAssertEqual(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .opaquePreparedNoRaw,
            observed: .init(opaquePresent: true, rawPresent: false)
        ), .standard)
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .dualPrepared,
            observed: .init(opaquePresent: false, rawPresent: true)
        ))
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .dualPrepared,
            observed: .init(opaquePresent: false, rawPresent: false)
        ))
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .opaquePreparedNoRaw,
            observed: .init(opaquePresent: false, rawPresent: false)
        ))
        XCTAssertNil(MatrixOpaquePushMigrationPolicy.confirmationMode(
            state: .rawGrace,
            observed: .init(opaquePresent: true, rawPresent: false)
        ))
        XCTAssertTrue(MatrixOpaquePushMigrationPolicy.canRetireRaw(
            observed: .init(opaquePresent: true, rawPresent: false)
        ))
    }

    func testLegacyApexRawPusherAuthorizesOnlyStandardConfirmRemovalAndRetire() throws {
        for (appID, keyCharacter) in [
            ("com.westreem.app", "o"),
            ("com.westreem.app.voip", "v"),
        ] {
            let opaqueKey = try MatrixOpaquePushKey(
                rawValue: "wsp2." + String(repeating: keyCharacter, count: 43)
            )
            let rawKey = String(repeating: keyCharacter, count: 64)
            let opaque = MatrixObservedPusher(
                pushKey: opaqueKey.rawValue,
                appID: appID,
                kind: "http",
                url: MatrixPushGatewayContract.canonicalURLString,
                format: "event_id_only"
            )
            let legacyApexRaw = MatrixObservedPusher(
                pushKey: rawKey,
                appID: appID,
                kind: nil,
                url: "https://westreem.com/_matrix/push/v1/notify",
                format: nil
            )

            let prepared = try MatrixPusherObservationPolicy.observe(
                pushers: [opaque, legacyApexRaw],
                appID: appID,
                rawPushKey: rawKey,
                opaquePushKey: opaqueKey
            )
            XCTAssertEqual(prepared, .init(opaquePresent: true, rawPresent: true))
            XCTAssertEqual(
                MatrixOpaquePushMigrationPolicy.confirmationMode(
                    state: .dualPrepared,
                    observed: prepared
                ),
                .standard
            )

            // After exact raw deletion, only the canonical opaque pusher can
            // authorize retirement. The legacy raw entry is never promoted to
            // a delivery target.
            let afterRemoval = try MatrixPusherObservationPolicy.observe(
                pushers: [opaque],
                appID: appID,
                rawPushKey: rawKey,
                opaquePushKey: opaqueKey
            )
            XCTAssertEqual(afterRemoval, .init(opaquePresent: true, rawPresent: false))
            XCTAssertTrue(MatrixOpaquePushMigrationPolicy.canRetireRaw(
                observed: afterRemoval
            ))
        }
    }

    func testPusherObservationRejectsMalformedOrNoncanonicalOpaqueDeliveryMetadata() throws {
        let appID = "com.westreem.app"
        let rawKey = String(repeating: "a", count: 64)
        let opaqueKey = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "o", count: 43)
        )
        let invalidMetadata: [(String?, String?, String?)] = [
            (nil, nil, nil),
            ("email", MatrixPushGatewayContract.canonicalURLString, "event_id_only"),
            ("http", "https://westreem.com/_matrix/push/v1/notify", "event_id_only"),
            ("http", MatrixPushGatewayContract.canonicalURLString, "event_id_only "),
        ]

        for (kind, url, format) in invalidMetadata {
            XCTAssertThrowsError(try MatrixPusherObservationPolicy.observe(
                pushers: [
                    .init(
                        pushKey: opaqueKey.rawValue,
                        appID: appID,
                        kind: kind,
                        url: url,
                        format: format
                    ),
                    .init(
                        pushKey: rawKey,
                        appID: appID,
                        kind: nil,
                        url: "https://westreem.com/_matrix/push/v1/notify",
                        format: nil
                    ),
                ],
                appID: appID,
                rawPushKey: rawKey,
                opaquePushKey: opaqueKey
            ))
        }
    }

    func testPusherObservationRejectsDuplicateExactIdentifiers() throws {
        let appID = "com.westreem.app"
        let rawKey = String(repeating: "a", count: 64)
        let opaqueKey = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "o", count: 43)
        )
        let opaque = MatrixObservedPusher(
            pushKey: opaqueKey.rawValue,
            appID: appID,
            kind: "http",
            url: MatrixPushGatewayContract.canonicalURLString,
            format: "event_id_only"
        )
        let raw = MatrixObservedPusher(
            pushKey: rawKey,
            appID: appID,
            kind: nil,
            url: nil,
            format: nil
        )

        XCTAssertThrowsError(try MatrixPusherObservationPolicy.observe(
            pushers: [opaque, opaque, raw],
            appID: appID,
            rawPushKey: rawKey,
            opaquePushKey: opaqueKey
        ))
        XCTAssertThrowsError(try MatrixPusherObservationPolicy.observe(
            pushers: [opaque, raw, raw],
            appID: appID,
            rawPushKey: rawKey,
            opaquePushKey: opaqueKey
        ))
    }

    func testPusherObservationIgnoresWrongAppAndWrongKeys() throws {
        let appID = "com.westreem.app"
        let rawKey = String(repeating: "a", count: 64)
        let opaqueKey = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "o", count: 43)
        )
        let observed = try MatrixPusherObservationPolicy.observe(
            pushers: [
                .init(
                    pushKey: opaqueKey.rawValue,
                    appID: "com.westreem.app.voip",
                    kind: "http",
                    url: MatrixPushGatewayContract.canonicalURLString,
                    format: "event_id_only"
                ),
                .init(
                    pushKey: "wrong-key",
                    appID: appID,
                    kind: "http",
                    url: MatrixPushGatewayContract.canonicalURLString,
                    format: "event_id_only"
                ),
                .init(
                    pushKey: rawKey,
                    appID: "com.westreem.app.voip",
                    kind: nil,
                    url: nil,
                    format: nil
                ),
            ],
            appID: appID,
            rawPushKey: rawKey,
            opaquePushKey: opaqueKey
        )
        XCTAssertEqual(observed, .init(opaquePresent: false, rawPresent: false))
    }

    func testV3ExactPrepareAndStatusJSONDecodesForOrdinaryAndVoIPRecovery() throws {
        for (appID, keyCharacter) in [
            ("com.westreem.app", "o"),
            ("com.westreem.app.voip", "v"),
        ] {
            let opaqueKey = "wsp2." + String(repeating: keyCharacter, count: 43)
            let json = Data(
                """
                {"registrationContractVersion":3,"registrationCapability":"opaque_matrix_push_key_v1","registrationState":"DUAL_PREPARED","registrationRevision":"rrrrrrrrrrrrrrrrrrrrrr","pushSetupPending":false,"rawRetireAt":null,"routes":{"opaque":true,"raw":true},"matrixPusher":{"appId":"\(appID)","gatewayUrl":"https://www.westreem.com/_matrix/push/v1/notify","format":"event_id_only","pushKey":"\(opaqueKey)"}}
                """.utf8
            )
            let expectedKey = try MatrixOpaquePushKey(rawValue: opaqueKey)
            let decoded = try JSONDecoder().decode(
                MatrixPushRegistrationV3Response.self,
                from: json
            )
            XCTAssertNoThrow(try decoded.validated(
                expectedAppID: appID,
                expectedKey: expectedKey,
                expectedRawPushKey: String(repeating: "a", count: 64)
            ))
            XCTAssertEqual(
                MatrixOpaquePushMigrationPolicy.confirmationMode(
                    state: decoded.registrationState,
                    observed: .init(opaquePresent: true, rawPresent: false)
                ),
                .dualPreparedMissingRawRecovery
            )

            // Status returns the same projection after a process restart. The
            // recovery decision must remain deterministic after persistence.
            let restarted = try JSONDecoder().decode(
                MatrixPushRegistrationV3Response.self,
                from: JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(restarted, decoded)
            XCTAssertEqual(
                MatrixOpaquePushMigrationPolicy.confirmationMode(
                    state: restarted.registrationState,
                    observed: .init(opaquePresent: true, rawPresent: false)
                ),
                .dualPreparedMissingRawRecovery
            )
        }
    }

    func testV3RecoveryRejectsAccountTokenKeyAndRevisionMismatch() throws {
        var fence = MatrixPushRegistrationFence()
        fence.openSession()
        let accountA = try XCTUnwrap(fence.beginRegistration())
        fence.openSession()
        XCTAssertFalse(fence.accepts(accountA))

        let key = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "k", count: 43)
        )
        let otherKey = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "x", count: 43)
        )
        let response = MatrixPushRegistrationV3Response(
            registrationContractVersion: 3,
            registrationCapability: "opaque_matrix_push_key_v1",
            registrationState: .dualPrepared,
            registrationRevision: String(repeating: "r", count: 22),
            pushSetupPending: false,
            rawRetireAt: nil,
            routes: .init(opaque: true, raw: true),
            matrixPusher: .init(
                appId: "com.westreem.app",
                gatewayUrl: MatrixPushGatewayContract.canonicalURLString,
                format: "event_id_only",
                pushKey: key
            ),
            rawMatrixRemoval: nil
        )
        XCTAssertThrowsError(try response.validated(
            expectedAppID: "com.westreem.app.voip",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))
        XCTAssertThrowsError(try response.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: otherKey,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))

        let malformedRevision = MatrixPushRegistrationV3Response(
            registrationContractVersion: response.registrationContractVersion,
            registrationCapability: response.registrationCapability,
            registrationState: response.registrationState,
            registrationRevision: String(repeating: "r", count: 21),
            pushSetupPending: response.pushSetupPending,
            rawRetireAt: response.rawRetireAt,
            routes: response.routes,
            matrixPusher: response.matrixPusher,
            rawMatrixRemoval: response.rawMatrixRemoval
        )
        XCTAssertThrowsError(try malformedRevision.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))
    }

    func testV3PusherValidationSeparatesOpaqueAndProviderIdentifiers() throws {
        let key = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "k", count: 43)
        )
        let pusher = MatrixPushRegistrationV3Pusher(
            appId: "com.westreem.app",
            gatewayUrl: MatrixPushGatewayContract.canonicalURLString,
            format: "event_id_only",
            pushKey: key
        )
        XCTAssertNoThrow(try pusher.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key
        ))
        XCTAssertThrowsError(try pusher.validated(
            expectedAppID: "com.westreem.app.voip",
            expectedKey: key
        ))
    }

    func testV3ResponseAuthorizesRawRemovalOnlyForSameOwnerConfirmedState() throws {
        let key = try MatrixOpaquePushKey(
            rawValue: "wsp2." + String(repeating: "r", count: 43)
        )
        let pusher = MatrixPushRegistrationV3Pusher(
            appId: "com.westreem.app",
            gatewayUrl: MatrixPushGatewayContract.canonicalURLString,
            format: "event_id_only",
            pushKey: key
        )
        let removal = MatrixPushRegistrationV3RawRemoval(
            authority: "MATRIX_PUSHER_API",
            pushKey: String(repeating: "a", count: 64),
            appId: "com.westreem.app"
        )
        let sameOwner = MatrixPushRegistrationV3Response(
            registrationContractVersion: 3,
            registrationCapability: "opaque_matrix_push_key_v1",
            registrationState: .opaqueConfirmedRawActive,
            registrationRevision: String(repeating: "v", count: 22),
            pushSetupPending: false,
            rawRetireAt: nil,
            routes: .init(opaque: true, raw: true),
            matrixPusher: pusher,
            rawMatrixRemoval: removal
        )
        XCTAssertNoThrow(try sameOwner.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))

        let missingRemoval = MatrixPushRegistrationV3Response(
            registrationContractVersion: 3,
            registrationCapability: "opaque_matrix_push_key_v1",
            registrationState: .opaqueConfirmedRawActive,
            registrationRevision: String(repeating: "v", count: 22),
            pushSetupPending: false,
            rawRetireAt: nil,
            routes: .init(opaque: true, raw: true),
            matrixPusher: pusher,
            rawMatrixRemoval: nil
        )
        XCTAssertThrowsError(try missingRemoval.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))

        let crossOwnerLeak = MatrixPushRegistrationV3Response(
            registrationContractVersion: 3,
            registrationCapability: "opaque_matrix_push_key_v1",
            registrationState: .opaquePreparedNoRaw,
            registrationRevision: String(repeating: "v", count: 22),
            pushSetupPending: true,
            rawRetireAt: nil,
            routes: .init(opaque: true, raw: false),
            matrixPusher: pusher,
            rawMatrixRemoval: removal
        )
        XCTAssertThrowsError(try crossOwnerLeak.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "a", count: 64)
        ))
        XCTAssertThrowsError(try sameOwner.validated(
            expectedAppID: "com.westreem.app",
            expectedKey: key,
            expectedRawPushKey: String(repeating: "b", count: 64)
        ))
    }

    func testV3RawRemovalRequiresExactLowercase64Hex() throws {
        let make = { (value: String) in
            MatrixPushRegistrationV3RawRemoval(
                authority: "MATRIX_PUSHER_API",
                pushKey: value,
                appId: "com.westreem.app"
            )
        }
        XCTAssertNoThrow(try make(String(repeating: "a", count: 64)).validated(
            expectedAppID: "com.westreem.app"
        ))
        XCTAssertNoThrow(try make(String(repeating: "a", count: 512)).validated(
            expectedAppID: "com.westreem.app"
        ))
        for invalid in [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "a", count: 513),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            XCTAssertThrowsError(try make(invalid).validated(
                expectedAppID: "com.westreem.app"
            ))
        }
    }

}
