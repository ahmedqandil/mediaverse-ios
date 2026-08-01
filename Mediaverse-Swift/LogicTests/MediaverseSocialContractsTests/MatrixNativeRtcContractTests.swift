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
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .realtime,
                playbackAuthority: .none,
                liveStageMode: .conversation
            )
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .liveStage, role: .audience),
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .none,
                liveStageMode: .conversation
            )
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(for: .watchParty, role: .audience),
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .matrixRoomState
            )
        )
        XCTAssertEqual(
            MatrixNativeRtcContract.mediaPlan(
                for: .liveStage,
                role: .audience,
                liveStageMode: .gaming
            ),
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .none,
                liveStageMode: .gaming
            )
        )
    }

    func testReplayKitAuthorizationIsOpaqueBoundedAndShortLived() throws {
        XCTAssertTrue(MatrixNativeRtcScreenShareContract.appGroupStoresOpaqueReferenceOnly)
        XCTAssertEqual(
            MatrixNativeRtcScreenShareContract.maximumAuthorizationLifetimeMilliseconds,
            300_000
        )
        XCTAssertThrowsError(try MatrixNativeReplayKitAuthorization(
            opaqueReference: "provider://secret",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        ))
        XCTAssertThrowsError(try MatrixNativeReplayKitAuthorization(
            opaqueReference: "opaque_reference_1234",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 301_001
        ))

        let authorization = try MatrixNativeReplayKitAuthorization(
            opaqueReference: "opaque_reference_1234",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 301_000
        )
        var state = MatrixNativeReplayKitAuthorizationState(
            authorization: authorization
        )
        XCTAssertEqual(
            state.activeAuthorization(nowMilliseconds: 300_999),
            authorization
        )
        XCTAssertNil(state.activeAuthorization(nowMilliseconds: 301_000))
    }

    func testReplayKitAuthorizationClearsOnFinish() throws {
        let authorization = try MatrixNativeReplayKitAuthorization(
            opaqueReference: "opaque_reference_5678",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        )
        var state = MatrixNativeReplayKitAuthorizationState(
            authorization: authorization
        )
        state.finish()
        XCTAssertNil(state.activeAuthorization(nowMilliseconds: 1_500))
    }

    func testRemoteSubscriptionIsBoundToProviderWaveCallAndDevice() throws {
        let binding = try makeBinding()
        let track = try MatrixNativeRtcRemoteTrackSource(
            participantID: "@remote-a:matrix.westreem.com",
            publisherSessionID: "publisher-session-a",
            providerTrackName: "camera-a",
            kind: .video
        )
        let subscription = try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .call,
            role: .interactive,
            track: track
        )
        var state = try MatrixNativeRtcRemoteSubscriptionState(
            binding: binding,
            experience: .call,
            role: .interactive
        )

        try state.subscribe(subscription)
        XCTAssertEqual(state.subscriptions, [subscription])

        let otherDevice = try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: binding.waveID,
            callID: binding.callID,
            deviceID: "DEVICE-B"
        )
        let rebound = try MatrixNativeRtcRemoteSubscription(
            binding: otherDevice,
            experience: .call,
            role: .interactive,
            track: track
        )
        XCTAssertThrowsError(try state.subscribe(rebound)) { error in
            XCTAssertEqual(error as? MatrixNativeRtcContractError, .bindingMismatch)
        }
    }

    func testOnlyCallAndInteractiveLiveStageTracksCanBeSubscribed() throws {
        let binding = try makeBinding()
        let track = try MatrixNativeRtcRemoteTrackSource(
            participantID: "@stage-speaker:matrix.westreem.com",
            publisherSessionID: "stage-publisher-session",
            providerTrackName: "stage-microphone",
            kind: .audio
        )
        XCTAssertNoThrow(try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .liveStage,
            role: .interactive,
            track: track
        ))
        XCTAssertThrowsError(try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .liveStage,
            role: .audience,
            track: track
        ))
        XCTAssertThrowsError(try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .watchParty,
            role: .interactive,
            track: track
        ))
    }

    func testUnsubscribeUsesExactParticipantAndTrackIdentityAndCleansUp() throws {
        let binding = try makeBinding()
        var state = try MatrixNativeRtcRemoteSubscriptionState(
            binding: binding,
            experience: .liveStage,
            role: .interactive
        )
        let first = try makeSubscription(
            binding: binding,
            participantID: "@speaker-a:matrix.westreem.com",
            publisherSessionID: "publisher-session-a",
            providerTrackName: "shared-provider-track-name"
        )
        let second = try makeSubscription(
            binding: binding,
            participantID: "@speaker-a:matrix.westreem.com",
            publisherSessionID: "publisher-session-b",
            providerTrackName: "shared-provider-track-name"
        )
        try state.subscribe(first)
        try state.subscribe(second)
        try state.subscribe(second)
        XCTAssertEqual(state.subscriptions.count, 2)

        XCTAssertEqual(state.unsubscribe(track: first.track), first)
        XCTAssertEqual(state.subscriptions, [second])
        XCTAssertEqual(
            state.removeParticipant("@speaker-a:matrix.westreem.com"),
            [second]
        )
        XCTAssertTrue(state.subscriptions.isEmpty)

        try state.subscribe(first)
        state.finish()
        XCTAssertTrue(state.subscriptions.isEmpty)
    }

    func testBindingsAndRemoteParticipantsRejectMalformedMatrixIdentity() throws {
        XCTAssertThrowsError(try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: "wave-without-matrix-sigil",
            callID: "CALL-A",
            deviceID: "DEVICE-A"
        ))
        XCTAssertThrowsError(try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: "!wave:matrix.westreem.com",
            callID: "call id with spaces",
            deviceID: "DEVICE-A"
        ))
        XCTAssertThrowsError(try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: "!wave:matrix.westreem.com",
            callID: "CALL-A",
            deviceID: "device?id"
        ))

        XCTAssertThrowsError(try MatrixNativeRtcRemoteTrackSource(
            participantID: "participant-without-matrix-sigil",
            publisherSessionID: "publisher-session-a",
            providerTrackName: "camera-a",
            kind: .video
        ))
    }

    func testNetworkRecoveryAuthorizationIsOpaqueBoundedAndOneUse() throws {
        let binding = try makeBinding()
        XCTAssertEqual(
            MatrixNativeRtcContract.maximumNetworkRecoveryAuthorizationLifetimeMilliseconds,
            300_000
        )
        XCTAssertThrowsError(try MatrixNativeRtcNetworkRecoveryAuthorization(
            binding: binding,
            action: .refreshTurn,
            opaqueReference: "turn://username:password",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        ))
        XCTAssertThrowsError(try MatrixNativeRtcNetworkRecoveryAuthorization(
            binding: binding,
            action: .restartIce,
            opaqueReference: "network_recovery_1234",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 301_001
        ))

        let authorization = try MatrixNativeRtcNetworkRecoveryAuthorization(
            binding: binding,
            action: .restartIce,
            opaqueReference: "network_recovery_1234",
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 301_000
        )
        var state = MatrixNativeRtcNetworkRecoveryAuthorizationState(
            authorization: authorization
        )
        XCTAssertEqual(
            try state.takeAuthorization(
                binding: binding,
                action: .restartIce,
                nowMilliseconds: 300_999
            ),
            authorization
        )
        XCTAssertThrowsError(try state.takeAuthorization(
            binding: binding,
            action: .restartIce,
            nowMilliseconds: 300_999
        ))
    }

    func testNetworkRecoveryAuthorizationRejectsBindingActionAndExpiryMismatch() throws {
        let binding = try makeBinding()
        let authorization = try MatrixNativeRtcNetworkRecoveryAuthorization(
            binding: binding,
            action: .refreshTurn,
            opaqueReference: "network_recovery_5678",
            issuedAtMilliseconds: 10_000,
            expiresAtMilliseconds: 20_000
        )
        let otherCall = try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: binding.waveID,
            callID: "CALL-B",
            deviceID: binding.deviceID
        )

        var wrongBinding = MatrixNativeRtcNetworkRecoveryAuthorizationState(
            authorization: authorization
        )
        XCTAssertThrowsError(try wrongBinding.takeAuthorization(
            binding: otherCall,
            action: .refreshTurn,
            nowMilliseconds: 15_000
        ))

        var wrongAction = MatrixNativeRtcNetworkRecoveryAuthorizationState(
            authorization: authorization
        )
        XCTAssertThrowsError(try wrongAction.takeAuthorization(
            binding: binding,
            action: .restartIce,
            nowMilliseconds: 15_000
        ))

        var expired = MatrixNativeRtcNetworkRecoveryAuthorizationState(
            authorization: authorization
        )
        XCTAssertThrowsError(try expired.takeAuthorization(
            binding: binding,
            action: .refreshTurn,
            nowMilliseconds: 20_000
        ))
    }

    private func makeBinding() throws -> MatrixNativeRtcSessionBinding {
        try MatrixNativeRtcSessionBinding(
            provider: .livekit,
            waveID: "!wave:matrix.westreem.com",
            callID: "CALL-A",
            deviceID: "DEVICE-A"
        )
    }

    private func makeSubscription(
        binding: MatrixNativeRtcSessionBinding,
        participantID: String,
        publisherSessionID: String,
        providerTrackName: String
    ) throws -> MatrixNativeRtcRemoteSubscription {
        try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .liveStage,
            role: .interactive,
            track: MatrixNativeRtcRemoteTrackSource(
                participantID: participantID,
                publisherSessionID: publisherSessionID,
                providerTrackName: providerTrackName,
                kind: .video
            )
        )
    }

}
