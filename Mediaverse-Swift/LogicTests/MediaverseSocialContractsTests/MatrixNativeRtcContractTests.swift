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

    func testProviderSelectionIsTypedImmutableAndFailsClosed() {
        let livekit = MatrixNativeRtcProviderSelection(serverProvider: "livekit")
        XCTAssertEqual(livekit.provider, .livekit)
        XCTAssertEqual(livekit.routingDecision, .livekit)

        let cloudflareOff = MatrixNativeRtcProviderSelection(
            serverProvider: "CLOUDFLARE_REALTIME"
        )
        XCTAssertEqual(cloudflareOff.provider, .cloudflareRealtime)
        XCTAssertEqual(cloudflareOff.routingDecision, .rejected)

        let cloudflareTestSeam = MatrixNativeRtcProviderSelection(
            serverProvider: "CLOUDFLARE_REALTIME",
            directCloudflareRealtimeEnabled: true
        )
        XCTAssertEqual(cloudflareTestSeam.routingDecision, .cloudflareRealtime)
        XCTAssertEqual(
            MatrixNativeRtcProviderSelection(serverProvider: "unknown").routingDecision,
            .rejected
        )
    }

    func testTrackIntentMappingKeepsScreenShareGated() {
        XCTAssertEqual(MatrixNativeRtcContract.trackIntents(for: .audio), [.microphone])
        XCTAssertEqual(
            MatrixNativeRtcContract.trackIntents(for: .video),
            [.microphone, .camera]
        )
        XCTAssertFalse(MatrixNativeRtcContract.permitsTrackIntent(.screen))
        XCTAssertFalse(MatrixNativeRtcScreenShareContract.replayKitEnabled)
        XCTAssertFalse(
            MatrixNativeRtcScreenShareContract.permitsLongLivedProviderSecrets
        )
        XCTAssertTrue(
            MatrixNativeRtcScreenShareContract.requiresShortLivedAppGroupAuthorization
        )
        XCTAssertEqual(
            MatrixNativeRtcScreenShareContract.maximumBroadcastExtensionMemoryMegabytes,
            45
        )
    }

    func testHighTrafficMediaPlanesDoNotFanPassiveAudiencesThroughRtc() {
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .liveStage, role: .interactive),
            MatrixNativeRtcMediaPlan(deliveryPlane: .realtime, playbackAuthority: .none)
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .liveStage, role: .audience),
            MatrixNativeRtcMediaPlan(deliveryPlane: .stream, playbackAuthority: .none)
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .watchParty, role: .audience),
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .matrixRoomState
            )
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .gamingBroadcast, role: .audience),
            MatrixNativeRtcMediaPlan(deliveryPlane: .stream, playbackAuthority: .none)
        )
    }

}
