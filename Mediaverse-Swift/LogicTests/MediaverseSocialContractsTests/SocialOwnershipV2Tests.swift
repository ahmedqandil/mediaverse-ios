import XCTest
@testable import MediaverseSocialContracts

final class SocialOwnershipV2Tests: XCTestCase {
    func testV1HybridRollbackContractRemainsValid() throws {
        let contract = try JSONDecoder().decode(
            SocialAuthorityContract.self,
            from: Data(
                """
                {
                  "version":1,
                  "liveTransport":"MATRIX",
                  "canonicalProduct":"WESTREEM",
                  "matrixOwns":[
                    "REALTIME_DELIVERY","TYPING","READ_RECEIPTS",
                    "PRESENCE","ROOM_RELATIONS","RTC_SIGNALING"
                  ],
                  "westreemOwns":[
                    "PUBLIC_RIPPLE_PRESENTATION","EVENTS","ENERGY","FEEDS",
                    "CURATION","MODERATION","AUDIT","ANALYTICS","PLAYBACK",
                    "ADS","AFFILIATIONS","NOTIFICATIONS","MEDIA_DELIVERY"
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(contract.version, 1)
        XCTAssertTrue(contract.permitsMatrixRealtime)
        XCTAssertEqual(contract.authority(for: .energy), .westreem)
    }

    func testV2KeepsIdentityPersonalAtmoAndAtmosphereInWestreem() {
        let contract = MatrixNativeSocialOwnershipContract.current

        XCTAssertEqual(contract.version, 2)
        XCTAssertEqual(contract.identityAuthority, .westreem)
        XCTAssertEqual(contract.publicSocialAuthority, .westreem)
        XCTAssertEqual(contract.authority(for: .personalAtmo), .westreem)
        XCTAssertEqual(contract.authority(for: .atmosphereFeed), .westreem)
    }

    func testV2MakesCommunityDomainsMatrixAuthoritative() {
        let contract = MatrixNativeSocialOwnershipContract.current

        XCTAssertEqual(contract.vibesAuthority, .matrix)
        XCTAssertEqual(contract.authority(for: .vibesSpaces), .matrix)
        XCTAssertEqual(contract.authority(for: .wavesRooms), .matrix)
        XCTAssertEqual(contract.authority(for: .ripplesEvents), .matrix)
        XCTAssertEqual(contract.authority(for: .membershipInvitations), .matrix)
        XCTAssertEqual(contract.authority(for: .e2ee), .matrix)
    }

    func testV2OnlyAllowsDeclaredOperationalProjections() {
        let contract = MatrixNativeSocialOwnershipContract.current

        XCTAssertTrue(contract.allowsProjection(.identityBindings))
        XCTAssertTrue(contract.allowsProjection(.publicSearchProjections))
        XCTAssertFalse(
            contract.westreemMayProject
                .map(\.rawValue)
                .contains(MatrixVibesDomain.ripplesEvents.rawValue)
        )
    }

    func testV2ForbidsCompetingAuthorityAndPrivacyLeaks() {
        let contract = MatrixNativeSocialOwnershipContract.current

        XCTAssertEqual(contract.invariants.matrixUserIdSource, "IMMUTABLE_WESTREEM_USER_ID")
        XCTAssertFalse(contract.invariants.prismaFirstVibeWritesAllowed)
        XCTAssertFalse(contract.invariants.ordinaryVibeMessagesInAtmosphere)
        XCTAssertFalse(contract.invariants.encryptedOrPrivateContentPubliclyProjected)
        XCTAssertFalse(contract.invariants.indefiniteDualWriteAllowed)

        let westreem = Set(contract.westreemOwns.map(\.rawValue))
        let matrix = Set(contract.matrixOwns.map(\.rawValue))
        XCTAssertTrue(westreem.isDisjoint(with: matrix))
    }

    func testRepositoryBoundaryRejectsWrongAuthority() {
        XCTAssertTrue(SocialRepositoryBoundary.acceptsAtmoAuthority(.westreem))
        XCTAssertFalse(SocialRepositoryBoundary.acceptsAtmoAuthority(.matrix))
        XCTAssertTrue(SocialRepositoryBoundary.acceptsVibesAuthority(.matrix))
        XCTAssertFalse(SocialRepositoryBoundary.acceptsVibesAuthority(.westreem))
    }
}
