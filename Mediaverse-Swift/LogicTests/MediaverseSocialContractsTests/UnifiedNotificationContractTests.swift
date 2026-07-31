import XCTest
@testable import MediaverseSocialContracts

final class UnifiedNotificationContractTests: XCTestCase {
    func testDecodesTwoAuthoritiesWithoutMatrixMetadataStorage() throws {
        let data = Data(
            """
            {
              "version": 1,
              "enabled": true,
              "items": [{
                "id": "westreem:n1",
                "source": "WESTREEM",
                "canonicalId": "n1",
                "category": "ATMO",
                "type": "atmo_energy",
                "title": "Energy",
                "message": "Added Energy",
                "read": false,
                "createdAt": "2026-07-29T12:00:00Z",
                "linkUrl": "/atmo/ahmed?post=p1",
                "imageUrl": null,
                "readAuthority": "WESTREEM_API"
              }],
              "sources": {
                "westreem": {
                  "authority": "WESTREEM",
                  "readAuthority": "WESTREEM_API",
                  "status": "READY"
                },
                "matrix": {
                  "authority": "MATRIX",
                  "readAuthority": "MATRIX_RECEIPT",
                  "status": "CLIENT_REQUIRED",
                  "storesContentMetadata": false
                }
              }
            }
            """.utf8
        )
        let feed = try JSONDecoder().decode(UnifiedNotificationFeedV1.self, from: data)
        XCTAssertTrue(feed.isSupportedVersion)
        XCTAssertEqual(feed.items.first?.category, .atmo)
        XCTAssertEqual(feed.items.first?.readAuthority, .westreemAPI)
        XCTAssertEqual(feed.sources.matrix.readAuthority, .matrixReceipt)
        XCTAssertEqual(feed.sources.matrix.storesContentMetadata, false)
    }

    func testSwiftUsesRustNotificationAdapterWithoutCopyingMatrixAuthority() {
        XCTAssertTrue(UnifiedNotificationSwiftCapability.matrixNotificationAdapterAvailable)
        XCTAssertFalse(UnifiedNotificationSwiftCapability.permitsWestreemMatrixNotificationCopies)
        XCTAssertEqual(
            UnifiedNotificationSwiftCapability.matrixReadAuthority,
            "MatrixRustSDK receipt"
        )
        XCTAssertEqual(
            UnifiedNotificationSwiftCapability.apnsTransportAuthority,
            "Existing Westreem APNs registration"
        )
    }

    func testDirectMessageContractRejectsSelfAndNonCanonicalTargets() {
        XCTAssertFalse(MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: "@u_31:vibes.westreem.com",
            targetMatrixUserID: "@u_31:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: "@u_31:vibes.westreem.com",
            targetMatrixUserID: "@handle:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: "@u_31:vibes.westreem.com",
            targetMatrixUserID: "@u_32:external.example"
        ))
        XCTAssertTrue(MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: "@u_31:vibes.westreem.com",
            targetMatrixUserID: "@u_32:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: "@u_31:vibes.westreem.com",
            targetMatrixUserID: "@u_32:vibes.westreem.com",
            ignoredMatrixUserIDs: ["@u_32:vibes.westreem.com"]
        ))
        XCTAssertEqual(MatrixDirectMessageContract.normalizedSearchQuery("  ahmed  "), "ahmed")
        XCTAssertNil(MatrixDirectMessageContract.normalizedSearchQuery("a"))
        XCTAssertTrue(MatrixDirectMessageContract.requiresEncryptedRoom)
        XCTAssertTrue(MatrixDirectMessageContract.requiresMatrixIgnoredUserCheck)
        XCTAssertFalse(MatrixDirectMessageContract.permitsUnencryptedExistingRoom)
        XCTAssertTrue(MatrixDirectMessageContract.mayUseExistingRoom(isEncrypted: true))
        XCTAssertFalse(MatrixDirectMessageContract.mayUseExistingRoom(isEncrypted: false))
        XCTAssertTrue(MatrixDirectMessageContract.mayPresentExistingRoom(
            isEncrypted: true,
            isDirect: true,
            peerMatrixUserID: "@u_32:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayPresentExistingRoom(
            isEncrypted: false,
            isDirect: true,
            peerMatrixUserID: "@u_32:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayPresentExistingRoom(
            isEncrypted: true,
            isDirect: false,
            peerMatrixUserID: "@u_32:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.mayPresentExistingRoom(
            isEncrypted: true,
            isDirect: true,
            peerMatrixUserID: "@u_32:external.example"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.isCanonicalWestreemPeer(
            "@u_nothex:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.isCanonicalWestreemPeer(
            "@u_3:vibes.westreem.com"
        ))
        XCTAssertFalse(MatrixDirectMessageContract.permitsLegacyMessageAPI)
    }

    func testMatrixNotificationProjectionUsesRoomAndEventIdentity() {
        XCTAssertEqual(
            MatrixNotificationPresentationContract.canonicalID(
                roomID: "!room:vibes.westreem.com",
                eventID: "$event"
            ),
            "!room:vibes.westreem.com|$event"
        )
        XCTAssertEqual(
            MatrixNotificationPresentationContract.canonicalID(
                roomID: "!room:vibes.westreem.com",
                eventID: nil
            ),
            "!room:vibes.westreem.com|unread"
        )
        XCTAssertEqual(MatrixNotificationPresentationContract.readAuthority, .matrixReceipt)
        XCTAssertFalse(MatrixNotificationPresentationContract.permitsServerSideContentCopies)
    }
}
