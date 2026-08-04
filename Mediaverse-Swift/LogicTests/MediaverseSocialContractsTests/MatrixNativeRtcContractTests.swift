import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeRtcContractTests: XCTestCase {
    func testVibeOwnsCommunityLiveProductsWhileCallsStayInWaves() {
        XCTAssertTrue(MatrixNativeRtcOwnershipContract.decide(
            experience: .call,
            roomKind: .waveOrDirect,
            operation: .create
        ).allowed)
        XCTAssertFalse(MatrixNativeRtcOwnershipContract.decide(
            experience: .call,
            roomKind: .vibeSpace,
            operation: .create
        ).allowed)
        for experience in [
            MatrixNativeRtcExperience.liveStage,
            .watchParty,
            .groupLounge,
        ] {
            XCTAssertTrue(MatrixNativeRtcOwnershipContract.decide(
                experience: experience,
                roomKind: .vibeSpace,
                operation: .create
            ).allowed)
            XCTAssertFalse(MatrixNativeRtcOwnershipContract.decide(
                experience: experience,
                roomKind: .waveOrDirect,
                operation: .create
            ).allowed)
        }
    }

    func testOnlyExactActiveLegacyWaveProductCanDrain() {
        XCTAssertTrue(MatrixNativeRtcOwnershipContract.decide(
            experience: .liveStage,
            roomKind: .waveOrDirect,
            operation: .join,
            activeLegacyExperience: .liveStage
        ).legacyCompatibility)
        XCTAssertFalse(MatrixNativeRtcOwnershipContract.decide(
            experience: .liveStage,
            roomKind: .waveOrDirect,
            operation: .create,
            activeLegacyExperience: .liveStage
        ).allowed)
        XCTAssertFalse(MatrixNativeRtcOwnershipContract.decide(
            experience: .liveStage,
            roomKind: .waveOrDirect,
            operation: .join,
            activeLegacyExperience: .watchParty
        ).allowed)
        XCTAssertTrue(MatrixNativeRtcOwnershipContract.decide(
            experience: .watchParty,
            roomKind: .waveOrDirect,
            operation: .join,
            activeLegacyExperience: .watchParty
        ).allowed)
        XCTAssertTrue(MatrixNativeRtcOwnershipContract.decide(
            experience: .watchParty,
            roomKind: .waveOrDirect,
            operation: .end,
            activeLegacyExperience: .watchParty
        ).allowed)
        XCTAssertFalse(MatrixNativeRtcOwnershipContract.decide(
            experience: .watchParty,
            roomKind: .waveOrDirect,
            operation: .create,
            activeLegacyExperience: .watchParty
        ).allowed)
    }

    func testVibeAllowsOnlyOneActiveLiveExperience() {
        XCTAssertTrue(MatrixNativeVibeLiveExperienceContract.canStart(
            stageIsActive: false,
            watchPartyIsActive: false,
            loungeIsActive: false
        ))
        for active in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertFalse(MatrixNativeVibeLiveExperienceContract.canStart(
                stageIsActive: active.0,
                watchPartyIsActive: active.1,
                loungeIsActive: active.2
            ))
        }
    }

    func testGroupLoungeAllowsInteractiveRemoteSubscriptions() throws {
        let binding = try makeBinding()
        let track = try MatrixNativeRtcRemoteTrackSource(
            participantID: "@remote-lounge:matrix.westreem.com",
            publisherSessionID: "publisher-lounge",
            providerTrackName: "microphone-lounge",
            kind: .audio
        )
        XCTAssertNoThrow(try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .groupLounge,
            role: .interactive,
            track: track
        ))
        XCTAssertThrowsError(try MatrixNativeRtcRemoteSubscription(
            binding: binding,
            experience: .watchParty,
            role: .interactive,
            track: track
        ))
    }
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

    func testMembershipVisibilityRetryIsExactAndBounded() {
        let policy = MatrixNativeRtcMembershipVisibilityRetryPolicy.self
        XCTAssertTrue(policy.shouldRetry(
            serverCode: policy.confirmationCode,
            completedAttempts: 1
        ))
        XCTAssertFalse(policy.shouldRetry(
            serverCode: "M_RTC_MEMBERSHIP_NOT_VISIBLE ",
            completedAttempts: 5
        ))
        XCTAssertFalse(policy.shouldRetry(
            serverCode: policy.confirmationCode,
            completedAttempts: 6
        ))
        XCTAssertEqual(policy.delaysMilliseconds, [250, 500, 1_000, 2_000, 4_000])
        XCTAssertEqual(policy.delaysMilliseconds.reduce(0, +), 7_750)
        XCTAssertNil(policy.delayMilliseconds(
            afterAttempt: 1,
            invitationExpiresAtMilliseconds: 2_250,
            nowMilliseconds: 1_000
        ))
        XCTAssertEqual(policy.delayMilliseconds(
            afterAttempt: 1,
            invitationExpiresAtMilliseconds: 2_251,
            nowMilliseconds: 1_000
        ), 250)
    }

    func testMembershipVisibilityResponseUsesStatusAndCodeNotMessage() {
        let response = MatrixNativeRtcMembershipVisibilityResponseContract.self
        let code = MatrixNativeRtcMembershipVisibilityRetryPolicy.confirmationCode
        XCTAssertTrue(response.isTransientMembershipAbsence(
            httpStatusCode: 409,
            serverCode: code
        ))
        // A localized or changed human message is intentionally absent from
        // this decision. Missing code never gains retry authority from text.
        XCTAssertFalse(response.isTransientMembershipAbsence(
            httpStatusCode: 409,
            serverCode: nil
        ))
        XCTAssertFalse(response.isTransientMembershipAbsence(
            httpStatusCode: 409,
            serverCode: "M_RTC_MEMBERSHIP_NOT_VISIBLE "
        ))
        XCTAssertFalse(response.isTransientMembershipAbsence(
            httpStatusCode: 400,
            serverCode: code
        ))
        XCTAssertFalse(response.isTransientMembershipAbsence(
            httpStatusCode: 500,
            serverCode: code
        ))
    }

    func testModernInvitationExpiryIsFutureAndBounded() {
        let expiry = MatrixNativeRtcInvitationExpiryContract.self
        XCTAssertTrue(expiry.accepts(
            expiresAtMilliseconds: 61_000,
            nowMilliseconds: 1_000
        ))
        XCTAssertFalse(expiry.accepts(
            expiresAtMilliseconds: 1_000,
            nowMilliseconds: 1_000
        ))
        XCTAssertFalse(expiry.accepts(
            expiresAtMilliseconds: 61_001,
            nowMilliseconds: 1_000
        ))
    }

    func testLegacyInvitationWithoutExpiryGetsNoVisibilityRetry() {
        XCTAssertNil(
            MatrixNativeRtcMembershipVisibilityRetryPolicy.delayMilliseconds(
                afterAttempt: 1,
                invitationExpiresAtMilliseconds: nil,
                requiresInvitationExpiry: true,
                nowMilliseconds: 1_000
            )
        )
        XCTAssertEqual(
            MatrixNativeRtcMembershipVisibilityRetryPolicy.delayMilliseconds(
                afterAttempt: 5,
                invitationExpiresAtMilliseconds: nil,
                requiresInvitationExpiry: false,
                nowMilliseconds: 1_000
            ),
            4_000
        )
    }

    func testMembershipMismatchExpiryAndUntrustedFocusNeverRetry() {
        let policy = MatrixNativeRtcMembershipVisibilityRetryPolicy.self
        for code in [
            "M_RTC_MEMBERSHIP_MALFORMED",
            "M_RTC_MEMBERSHIP_EXPIRED",
            "M_RTC_MEMBERSHIP_DEVICE_MISMATCH",
            "M_RTC_MEMBERSHIP_UNTRUSTED_FOCUS",
            "M_UNAUTHORIZED",
        ] {
            XCTAssertFalse(policy.shouldRetry(
                serverCode: code,
                completedAttempts: 1
            ))
        }
        XCTAssertFalse(policy.shouldRetry(serverCode: nil, completedAttempts: 1))
    }

    func testMembershipVisibilityTimeoutUsesSingleOrderedCleanup() {
        XCTAssertEqual(
            MatrixNativeRtcJoinFailureCleanupContract.orderedActions,
            [.disconnectProvider, .tombstoneMembership, .endCallKit]
        )
        XCTAssertEqual(
            Set(MatrixNativeRtcJoinFailureCleanupContract.orderedActions).count,
            MatrixNativeRtcJoinFailureCleanupContract.orderedActions.count
        )
    }

    func testMembershipFenceSupersedesSuspendedBeginWithNewBegin() throws {
        var fence = MatrixNativeRtcMembershipOperationFence()
        let beginA = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        let beginB = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        XCTAssertFalse(fence.owns(beginA))
        XCTAssertTrue(fence.owns(beginB))
    }

    func testMembershipFenceSupersedesSuspendedEndWithBegin() throws {
        var fence = MatrixNativeRtcMembershipOperationFence()
        let suspendedEnd = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        let begin = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        XCTAssertFalse(fence.owns(suspendedEnd))
        XCTAssertTrue(fence.owns(begin))
    }

    func testMembershipFenceBeginEndBeginLeavesOnlyLatestOwner() throws {
        var fence = MatrixNativeRtcMembershipOperationFence()
        let firstBegin = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        let end = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        let nextBegin = try XCTUnwrap(fence.claim(roomID: "!room:example.org"))
        XCTAssertFalse(fence.owns(firstBegin))
        XCTAssertFalse(fence.owns(end))
        XCTAssertTrue(fence.owns(nextBegin))
    }

    func testMembershipFenceAccountTeardownInvalidatesAllUntilReady() throws {
        var fence = MatrixNativeRtcMembershipOperationFence()
        let roomA = try XCTUnwrap(fence.claim(roomID: "!a:example.org"))
        let roomB = try XCTUnwrap(fence.claim(roomID: "!b:example.org"))
        fence.disableAndInvalidateAll()
        XCTAssertFalse(fence.owns(roomA))
        XCTAssertFalse(fence.owns(roomB))
        XCTAssertNil(fence.claim(roomID: "!a:example.org"))
        fence.enable()
        XCTAssertNotNil(fence.claim(roomID: "!a:example.org"))
    }

    func testOutgoingPersonalWaveAutoInvitesExactlyOneJoinedHumanPeer() {
        let decision = MatrixNativeDirectCallInvitationPolicy.decision(
            isPersonalWave: true,
            origin: .outgoing,
            peers: [
                .init(
                    userID: "@me:matrix.westreem.com",
                    isJoined: true,
                    isCurrentUser: true,
                    isService: false
                ),
                .init(
                    userID: "@service:matrix.westreem.com",
                    isJoined: true,
                    isCurrentUser: false,
                    isService: true
                ),
                .init(
                    userID: "@invited:matrix.westreem.com",
                    isJoined: false,
                    isCurrentUser: false,
                    isService: false
                ),
                .init(
                    userID: "@peer:matrix.westreem.com",
                    isJoined: true,
                    isCurrentUser: false,
                    isService: false
                ),
            ]
        )
        XCTAssertEqual(decision, .invite(userID: "@peer:matrix.westreem.com"))
    }

    func testPersonalWaveAutoInvitationRejectsZeroOrMultipleJoinedHumanPeers() {
        XCTAssertEqual(
            MatrixNativeDirectCallInvitationPolicy.decision(
                isPersonalWave: true,
                origin: .outgoing,
                peers: []
            ),
            .reject
        )
        XCTAssertEqual(
            MatrixNativeDirectCallInvitationPolicy.decision(
                isPersonalWave: true,
                origin: .outgoing,
                peers: [
                    .init(
                        userID: "@one:matrix.westreem.com",
                        isJoined: true,
                        isCurrentUser: false,
                        isService: false
                    ),
                    .init(
                        userID: "@two:matrix.westreem.com",
                        isJoined: true,
                        isCurrentUser: false,
                        isService: false
                    ),
                ]
            ),
            .reject
        )
    }

    func testAcceptedIncomingAndCommunityCallsNeverAutoInvite() {
        let peer = MatrixNativeDirectCallPeerCandidate(
            userID: "@peer:matrix.westreem.com",
            isJoined: true,
            isCurrentUser: false,
            isService: false
        )
        XCTAssertEqual(
            MatrixNativeDirectCallInvitationPolicy.decision(
                isPersonalWave: true,
                origin: .acceptedIncomingInvitation,
                peers: [peer]
            ),
            .skip
        )
        XCTAssertEqual(
            MatrixNativeDirectCallInvitationPolicy.decision(
                isPersonalWave: false,
                origin: .outgoing,
                peers: [peer]
            ),
            .skip
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

    func testHighTrafficMediaPlanesUseRealtimeBroadcastForStageAndStreamForWatchParty() {
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
                deliveryPlane: .realtime,
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
                deliveryPlane: .realtime,
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
        let binding = try makeProviderBinding()
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
        let binding = try makeProviderBinding()
        let authorization = try MatrixNativeRtcNetworkRecoveryAuthorization(
            binding: binding,
            action: .refreshTurn,
            opaqueReference: "network_recovery_5678",
            issuedAtMilliseconds: 10_000,
            expiresAtMilliseconds: 20_000
        )
        let otherCall = try MatrixNativeRtcProviderSessionAuthorityBinding(
            session: MatrixNativeRtcSessionBinding(
                provider: .livekit,
                waveID: binding.session.waveID,
                callID: "CALL-B",
                deviceID: binding.session.deviceID
            ),
            providerSessionID: binding.providerSessionID,
            authorityExpiresAtMilliseconds: 301_000,
            nowMilliseconds: 1_000
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

    private func makeProviderBinding()
        throws -> MatrixNativeRtcProviderSessionAuthorityBinding {
        try MatrixNativeRtcProviderSessionAuthorityBinding(
            session: makeBinding(),
            providerSessionID: "provider-session-a",
            authorityExpiresAtMilliseconds: 301_000,
            nowMilliseconds: 1_000
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

    func testRtcBreadcrumbContractCoversEverySystemCallBoundary() {
        XCTAssertEqual(
            Set(MatrixNativeRtcBreadcrumbEvent.allCases),
            Set([
                .startup,
                .voIPTokenCallback,
                .voIPRegistryReplay,
                .pushKitCallback,
                .pushValidation,
                .callAcceptance,
                .callKitReport,
                .pushKitCompletion,
                .callKitAnswer,
                .audioSession,
                .runtimePrepare,
                .runtimeActivate,
                .membershipScheduled,
                .providerJoinRequestBegin,
                .providerJoinRequestSuccess,
                .providerJoinRequestFailure,
                .providerJoin,
                .providerConnected,
                .runtimeCleanup,
            ])
        )
    }

    func testRtcBreadcrumbEncodingCannotCarryIdentifiersOrPayloadText() throws {
        let breadcrumb = MatrixNativeRtcBreadcrumb(
            timestamp: "2026-08-04T12:21:13Z",
            sequence: 7,
            build: "1.13 (1)",
            stage: .callKitReport,
            reason: .error,
            credentialByteCount: 9_999,
            tokenPresent: true,
            canAcceptCalls: true,
            errorDomain: "secret-room-and-event-value",
            errorCode: 3
        )
        let encoded = try JSONEncoder().encode(breadcrumb)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(breadcrumb.errorDomain, "other")
        XCTAssertEqual(breadcrumb.credentialByteCount, 4_096)
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "timestamp",
                "sequence",
                "build",
                "stage",
                "reason",
                "credentialByteCount",
                "tokenPresent",
                "canAcceptCalls",
                "errorDomain",
                "errorCode",
            ])
        )
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8)).lowercased()
        for forbidden in [
            "secret-room-and-event-value",
            "calluuid",
            "roomid",
            "eventid",
            "userid",
            "deviceid",
            "payload",
            "body",
            "digest",
            "tokenvalue",
        ] {
            XCTAssertFalse(text.contains(forbidden), "leaked forbidden field: \(forbidden)")
        }
    }

}
