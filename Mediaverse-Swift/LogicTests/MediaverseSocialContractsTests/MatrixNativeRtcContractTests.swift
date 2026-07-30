import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeRtcContractTests: XCTestCase {
    func testRtcRemainsMatrixAuthoritativeOnExistingInfrastructure() {
        XCTAssertEqual(
            MatrixNativeRtcContract.normativeSource,
            "User strongest-model Matrix-native Vibes prompt (precedence 1)"
        )
        XCTAssertEqual(MatrixNativeRtcContract.authority, "MATRIX")
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaTransport,
            "EXISTING_LIVEKIT"
        )
        XCTAssertFalse(MatrixNativeRtcContract.permitsNewInfrastructure)
    }

    func testStandardMembershipAndBoundedRefreshContract() {
        XCTAssertEqual(
            MatrixNativeRtcContract.membershipEventType,
            "org.matrix.msc3401.call.member"
        )
        XCTAssertEqual(MatrixNativeRtcContract.application, "m.call")
        XCTAssertEqual(MatrixNativeRtcContract.roomScope, "m.room")
        XCTAssertGreaterThan(
            MatrixNativeRtcContract.membershipLifetimeMilliseconds,
            MatrixNativeRtcContract.membershipRefreshMilliseconds
        )
    }

    func testEncryptedCallsFailClosedUntilMediaE2EEIsVerified() {
        XCTAssertFalse(
            MatrixNativeRtcContract
                .permitsEncryptedRoomCallsBeforeMediaE2EEVerification
        )
        XCTAssertFalse(
            MatrixNativeRtcContract.swiftBindingsExportMatrixRtcMediaKeys
        )
    }

}
