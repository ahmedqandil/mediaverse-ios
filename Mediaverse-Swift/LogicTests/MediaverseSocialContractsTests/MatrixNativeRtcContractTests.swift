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

    func testApplicationMediaE2EEIsDisabledWhileTransportSecurityRemains() {
        XCTAssertEqual(
            MatrixNativeRtcMediaSecurity.standardWebRTC.rawValue,
            "DTLS_SRTP"
        )
        XCTAssertFalse(MatrixNativeRtcContract.applicationMediaEncryptionEnabled)
        XCTAssertFalse(
            MatrixNativeRtcContract.swiftBindingsExportMatrixRtcMediaKeys
        )
    }

    func testCloudflareGroundworkCannotReceiveCalls() {
        XCTAssertEqual(MatrixNativeRtcContract.productionMediaProvider, .livekit)
        XCTAssertFalse(MatrixNativeRtcContract.directCloudflareRealtimeEnabled)
        XCTAssertTrue(
            MatrixNativeRtcContract.acceptsProductionConnectionProvider("livekit")
        )
        XCTAssertFalse(
            MatrixNativeRtcContract.acceptsProductionConnectionProvider("cloudflare")
        )
    }

}
