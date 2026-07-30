import XCTest
@testable import MediaverseSocialContracts

final class MatrixSessionFoundationTests: XCTestCase {
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
            homeserverURL: "https://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso"
        ).validated())
        XCTAssertThrowsError(try MatrixSSOBootstrap(
            enabled: true,
            ownershipVersion: 2,
            homeserverURL: "http://vibes.westreem.com",
            redirectURL: "westreem://matrix/sso"
        ).validated())
    }

    func testNativeSessionUsesSynapseSSOAndNeverNativeOAuth() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let coordinatorURL = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/MatrixSessionCoordinator.swift")
        let source = try String(contentsOf: coordinatorURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".startSsoLogin("))
        XCTAssertTrue(source.contains("ssoHandler.finish("))
        XCTAssertFalse(source.contains(".urlForOauth("))
        XCTAssertFalse(source.contains(".loginWithOauthCallback("))
        XCTAssertFalse(source.contains("OAuthConfiguration("))
    }
}
