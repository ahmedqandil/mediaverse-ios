import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeCloudflareRtcV1ContractTests: XCTestCase {
    func testAuthorizeRequestHasNoClientCallOrProviderAuthority() throws {
        let request = try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .liveStage,
            stageMode: .gaming,
            requestedTrackKinds: [.microphone, .camera]
        )
        let json = try encodedObject(request)

        XCTAssertEqual(json["contractVersion"] as? String, "CLOUDFLARE_RTC_V1")
        XCTAssertEqual(json["provider"] as? String, "CLOUDFLARE_REALTIME")
        XCTAssertEqual(json["trackKinds"] as? [String], ["microphone", "camera"])
        XCTAssertNil(json["requestedTrackKinds"])
        XCTAssertNil(json["callId"])
        XCTAssertNil(json["sessionId"])
        XCTAssertNil(json["ttlSeconds"])
        XCTAssertNil(json["sdp"])
        XCTAssertNil(json["token"])
        XCTAssertThrowsError(try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .audio,
            experience: .call,
            stageMode: .gaming,
            requestedTrackKinds: [.camera]
        ))
    }

    func testAuthorityIsMatrixIssuedBoundedAndFailsClosed() throws {
        let authority = try makeAuthority()
        XCTAssertEqual(authority.callID, "CALL-A")
        XCTAssertEqual(authority.authority, "MATRIX")
        XCTAssertFalse(authority.applicationMediaEncryption)
        XCTAssertNoThrow(try authority.validate(request: makeAuthorizeRequest()))

        var json = authorityObject()
        json["expiresAtMs"] = 301_001
        XCTAssertThrowsError(try decodeAuthority(json))
        json = authorityObject()
        json["applicationMediaEncryption"] = true
        XCTAssertThrowsError(try decodeAuthority(json))
        json = authorityObject()
        json["provider"] = "LIVEKIT"
        XCTAssertThrowsError(try decodeAuthority(json))
        json = authorityObject()
        json["allowedTrackKinds"] = ["microphone", "microphone"]
        XCTAssertThrowsError(try decodeAuthority(json))
        json = authorityObject()
        json["mediaPath"] = "PASSIVE_STREAM"
        XCTAssertThrowsError(try decodeAuthority(json).validate(
            request: makeAuthorizeRequest()
        ))
        json = authorityObject()
        json["experience"] = "call"
        XCTAssertThrowsError(try decodeAuthority(json).validate(
            request: makeAuthorizeRequest()
        ))
        json = authorityObject()
        json["intent"] = "audio"
        XCTAssertThrowsError(try decodeAuthority(json).validate(
            request: makeAuthorizeRequest()
        ))
        json = authorityObject()
        json["role"] = "participant"
        XCTAssertThrowsError(try decodeAuthority(json).validate(
            request: makeAuthorizeRequest()
        ))
        json = authorityObject()
        json["unexpectedAuthority"] = true
        XCTAssertThrowsError(try decodeAuthority(json))
    }

    func testReceiveOnlySessionProducesExactProviderAuthorityBinding() throws {
        let authority = try makeAuthority()
        let request = try MatrixNativeCloudflareRtcV1ReceiveOnlySessionRequest(
            authority: authority,
            authorizeRequest: makeAuthorizeRequest()
        )
        let requestJSON = try encodedObject(request)
        XCTAssertEqual((requestJSON["tracks"] as? [Any])?.count, 0)
        XCTAssertNil(requestJSON["receiveOnly"])
        XCTAssertNil(requestJSON["sdp"])

        let response = try decodeReceiveOnly(receiveOnlyObject())
        let binding = try response.validatedBinding(
            authority: authority,
            nowMilliseconds: 1_000
        )
        XCTAssertEqual(binding.providerSessionID, "provider-session-a")
        XCTAssertEqual(binding.session.callID, "CALL-A")

        var invalid = receiveOnlyObject()
        invalid["publishAllowed"] = false
        XCTAssertThrowsError(try decodeReceiveOnly(invalid).validatedBinding(
            authority: authority,
            nowMilliseconds: 1_000
        ))
        invalid = receiveOnlyObject()
        invalid["callId"] = "CALL-B"
        XCTAssertThrowsError(try decodeReceiveOnly(invalid).validatedBinding(
            authority: authority,
            nowMilliseconds: 1_000
        ))
        invalid = receiveOnlyObject()
        invalid["expiresAtMs"] = 301_001
        XCTAssertThrowsError(try decodeReceiveOnly(invalid).validatedBinding(
            authority: authority,
            nowMilliseconds: 1_000
        ))
        invalid = receiveOnlyObject()
        invalid["unexpectedSession"] = true
        XCTAssertThrowsError(try decodeReceiveOnly(invalid))
    }

    func testAuthorityRoleMatrixAcrossCallStageAndWatchParty() throws {
        var json = authorityObject()
        json["experience"] = "call"
        json.removeValue(forKey: "stageMode")
        json["role"] = "participant"
        let call = try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .call,
            requestedTrackKinds: [.microphone, .camera]
        )
        XCTAssertNoThrow(try decodeAuthority(json).validate(request: call))

        json = authorityObject()
        json["role"] = "host"
        XCTAssertNoThrow(try decodeAuthority(json).validate(
            request: makeAuthorizeRequest()
        ))

        json = authorityObject()
        json["publishAllowed"] = false
        json["subscribeAllowed"] = false
        json["allowedTrackKinds"] = []
        json["role"] = "viewer"
        json["mediaPath"] = "PASSIVE_STREAM"
        let stageViewer = try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .liveStage,
            stageMode: .gaming,
            requestedTrackKinds: []
        )
        XCTAssertNoThrow(try decodeAuthority(json).validate(request: stageViewer))

        json["experience"] = "watch-party"
        json.removeValue(forKey: "stageMode")
        let watchViewer = try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .watchParty,
            requestedTrackKinds: []
        )
        XCTAssertNoThrow(try decodeAuthority(json).validate(request: watchViewer))

        json = authorityObject()
        json["experience"] = "watch-party"
        json.removeValue(forKey: "stageMode")
        json["role"] = "host"
        let watchHost = try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .watchParty,
            requestedTrackKinds: [.microphone, .camera]
        )
        XCTAssertNoThrow(try decodeAuthority(json).validate(request: watchHost))
    }

    func testSubscribeRequestContainsOnlyProviderTrackCoordinates() throws {
        let request = try makeSubscribeRequest()
        let json = try encodedObject(request)
        let tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        XCTAssertEqual(Set(tracks[0].keys), ["publisherSessionId", "providerTrackName"])
        XCTAssertNil(tracks[0]["participantId"])
        XCTAssertNil(tracks[0]["kind"])
        XCTAssertNil(tracks[0]["subscriberTrackMid"])
    }

    func testSubscribeResponseAddsAndValidatesServerDerivedIdentity() throws {
        let request = try makeSubscribeRequest()
        let binding = try makeProviderBinding()
        let response = try decodeSubscribe(subscribeObject())
        XCTAssertNoThrow(try response.validate(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        ))
        XCTAssertEqual(response.tracks.first?.participantID, "@remote:matrix.westreem.com")
        XCTAssertEqual(response.tracks.first?.kind, .video)
        XCTAssertEqual(response.tracks.first?.subscriberTrackMID, "0")
        XCTAssertEqual(response.offer?.description, "<ephemeral-sdp:redacted>")

        var invalid = subscribeObject()
        invalid["sessionId"] = "different-session"
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        var tracks = try XCTUnwrap(invalid["tracks"] as? [[String: Any]])
        tracks[0]["providerTrackName"] = "substituted-track"
        invalid["tracks"] = tracks
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        tracks = try XCTUnwrap(invalid["tracks"] as? [[String: Any]])
        tracks[0]["participantId"] = "not-a-matrix-user"
        invalid["tracks"] = tracks
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        invalid.removeValue(forKey: "offer")
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        invalid["requiresImmediateRenegotiation"] = false
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid.removeValue(forKey: "offer")
        XCTAssertNoThrow(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        invalid["expiresAtMs"] = 301_001
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        invalid["publishAllowed"] = false
        XCTAssertThrowsError(try validateSubscribe(invalid, request, binding))
        invalid = subscribeObject()
        invalid["offer"] = ["type": "answer", "sdp": "v=0\r\n"]
        XCTAssertThrowsError(try decodeSubscribe(invalid))
        invalid = subscribeObject()
        invalid["unexpectedSubscription"] = true
        XCTAssertThrowsError(try decodeSubscribe(invalid))
        invalid = subscribeObject()
        tracks = try XCTUnwrap(invalid["tracks"] as? [[String: Any]])
        tracks[0]["unexpectedTrack"] = true
        invalid["tracks"] = tracks
        XCTAssertThrowsError(try decodeSubscribe(invalid))
        invalid = subscribeObject()
        invalid["offer"] = [
            "type": "offer",
            "sdp": "v=0\r\n",
            "unexpectedSdp": true
        ]
        XCTAssertThrowsError(try decodeSubscribe(invalid))
    }

    func testRecoveryIsProviderSessionBoundServerExpiredAndOneUse() throws {
        let binding = try makeProviderBinding()
        let request = try MatrixNativeCloudflareRtcV1NetworkRecoveryRequest(
            binding: binding,
            action: .restartIce
        )
        let requestJSON = try encodedObject(request)
        XCTAssertEqual(requestJSON["sessionId"] as? String, "provider-session-a")
        XCTAssertEqual(requestJSON["turnAction"] as? String, "RESTART_ICE")
        XCTAssertNil(requestJSON["action"])
        XCTAssertNil(requestJSON["ttlSeconds"])
        XCTAssertNil(requestJSON["expiresAtMs"])
        XCTAssertNil(requestJSON["turnUsername"])

        let response = try decodeRecovery(recoveryObject())
        XCTAssertEqual(response.description, "<network-recovery-response:redacted>")
        let copiedReference = response
        let material = try response.takeTransportMaterial(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        )
        XCTAssertEqual(
            material.iceServers[0].description,
            "<ephemeral-ice-server:redacted>"
        )
        XCTAssertThrowsError(try copiedReference.takeTransportMaterial(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        ))
    }

    func testRecoveryRejectsWrongSessionAndExpiryBeyondAuthority() throws {
        let binding = try makeProviderBinding()
        let request = try MatrixNativeCloudflareRtcV1NetworkRecoveryRequest(
            binding: binding,
            action: .refreshTurn
        )
        var json = recoveryObject(action: "REFRESH_TURN")
        json["sessionId"] = "wrong-session"
        XCTAssertThrowsError(try decodeRecovery(json).takeTransportMaterial(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        ))
        json = recoveryObject(action: "REFRESH_TURN")
        json["expiresAtMs"] = 301_001
        XCTAssertThrowsError(try decodeRecovery(json).takeTransportMaterial(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        ))
        json = recoveryObject(action: "REFRESH_TURN")
        json["iceServers"] = [[
            "urls": ["https://credential-leak.example"],
            "username": "user",
            "credential": "secret"
        ]]
        XCTAssertThrowsError(try decodeRecovery(json))
        json = recoveryObject(action: "REFRESH_TURN")
        json["iceServers"] = Array(repeating: [
            "urls": ["turn:turn.cloudflare.com:3478"],
            "username": "user",
            "credential": "secret"
        ], count: 9)
        XCTAssertThrowsError(try decodeRecovery(json).takeTransportMaterial(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        ))
        json = recoveryObject(action: "REFRESH_TURN")
        json["iceServers"] = [[
            "urls": ["turn:turn.cloudflare.com:3478"],
            "username": String(repeating: "u", count: 513),
            "credential": "secret"
        ]]
        XCTAssertThrowsError(try decodeRecovery(json))
        json = recoveryObject(action: "REFRESH_TURN")
        json["unexpectedRecovery"] = true
        XCTAssertThrowsError(try decodeRecovery(json))
        json = recoveryObject(action: "REFRESH_TURN")
        var servers = try XCTUnwrap(json["iceServers"] as? [[String: Any]])
        servers[0]["unexpectedIce"] = true
        json["iceServers"] = servers
        XCTAssertThrowsError(try decodeRecovery(json))
    }

    func testProductionCloudflareAndReplayKitGatesRemainDisabled() {
        XCTAssertFalse(MatrixNativeRtcContract.directCloudflareRealtimeEnabled)
        XCTAssertFalse(MatrixNativeRtcScreenShareContract.replayKitEnabled)
    }

    func testProviderAuthorityPermissionsDefaultClosed() throws {
        let binding = try MatrixNativeRtcProviderSessionAuthorityBinding(
            session: MatrixNativeRtcSessionBinding(
                provider: .cloudflareRealtime,
                waveID: "!wave:matrix.westreem.com",
                callID: "CALL-A",
                deviceID: "DEVICE-A"
            ),
            providerSessionID: "provider-session-a",
            authorityExpiresAtMilliseconds: 301_000,
            nowMilliseconds: 1_000
        )
        XCTAssertFalse(binding.publishAllowed)
        XCTAssertFalse(binding.subscribeAllowed)
        XCTAssertThrowsError(try MatrixNativeCloudflareRtcV1SubscribeRequest(
            binding: binding,
            tracks: [MatrixNativeCloudflareRtcV1RemoteTrackSource(
                publisherSessionID: "publisher-session-a",
                providerTrackName: "camera-a"
            )]
        ))
    }

    private func makeAuthority() throws -> MatrixNativeCloudflareRtcV1AuthorityResponse {
        try decodeAuthority(authorityObject())
    }

    private func makeAuthorizeRequest() throws -> MatrixNativeCloudflareRtcV1AuthorizeRequest {
        try MatrixNativeCloudflareRtcV1AuthorizeRequest(
            roomID: "!wave:matrix.westreem.com",
            deviceID: "DEVICE-A",
            intent: .video,
            experience: .liveStage,
            stageMode: .gaming,
            requestedTrackKinds: [.microphone, .camera]
        )
    }

    private func makeProviderBinding() throws -> MatrixNativeRtcProviderSessionAuthorityBinding {
        try MatrixNativeRtcProviderSessionAuthorityBinding(
            session: MatrixNativeRtcSessionBinding(
                provider: .cloudflareRealtime,
                waveID: "!wave:matrix.westreem.com",
                callID: "CALL-A",
                deviceID: "DEVICE-A"
            ),
            providerSessionID: "provider-session-a",
            authorityExpiresAtMilliseconds: 301_000,
            nowMilliseconds: 1_000,
            publishAllowed: true,
            subscribeAllowed: true
        )
    }

    private func makeSubscribeRequest() throws -> MatrixNativeCloudflareRtcV1SubscribeRequest {
        try MatrixNativeCloudflareRtcV1SubscribeRequest(
            binding: makeProviderBinding(),
            tracks: [MatrixNativeCloudflareRtcV1RemoteTrackSource(
                publisherSessionID: "publisher-session-a",
                providerTrackName: "camera-a"
            )]
        )
    }

    private func authorityObject() -> [String: Any] {
        [
            "contractVersion": "CLOUDFLARE_RTC_V1",
            "provider": "CLOUDFLARE_REALTIME",
            "authority": "MATRIX",
            "mediaProtection": "DTLS_SRTP",
            "applicationMediaEncryption": false,
            "roomId": "!wave:matrix.westreem.com",
            "deviceId": "DEVICE-A",
            "callId": "CALL-A",
            "intent": "video",
            "issuedAtMs": 1_000,
            "expiresAtMs": 301_000,
            "publishAllowed": true,
            "subscribeAllowed": true,
            "allowedTrackKinds": ["microphone", "camera"],
            "experience": "stage",
            "stageMode": "gaming",
            "role": "speaker",
            "mediaPath": "INTERACTIVE_SFU"
        ]
    }

    private func receiveOnlyObject() -> [String: Any] {
        [
            "contractVersion": "CLOUDFLARE_RTC_V1",
            "provider": "CLOUDFLARE_REALTIME",
            "roomId": "!wave:matrix.westreem.com",
            "deviceId": "DEVICE-A",
            "callId": "CALL-A",
            "sessionId": "provider-session-a",
            "expiresAtMs": 301_000,
            "publishAllowed": true,
            "subscribeAllowed": true
        ]
    }

    private func subscribeObject() -> [String: Any] {
        [
            "contractVersion": "CLOUDFLARE_RTC_V1",
            "provider": "CLOUDFLARE_REALTIME",
            "roomId": "!wave:matrix.westreem.com",
            "deviceId": "DEVICE-A",
            "callId": "CALL-A",
            "sessionId": "provider-session-a",
            "expiresAtMs": 301_000,
            "publishAllowed": true,
            "subscribeAllowed": true,
            "requiresImmediateRenegotiation": true,
            "offer": ["type": "offer", "sdp": "v=0\r\na=ice-options:trickle\r\n"],
            "tracks": [[
                "publisherSessionId": "publisher-session-a",
                "providerTrackName": "camera-a",
                "participantId": "@remote:matrix.westreem.com",
                "kind": "video",
                "subscriberTrackMid": "0"
            ]]
        ]
    }

    private func recoveryObject(action: String = "RESTART_ICE") -> [String: Any] {
        [
            "contractVersion": "CLOUDFLARE_RTC_V1",
            "provider": "CLOUDFLARE_REALTIME",
            "roomId": "!wave:matrix.westreem.com",
            "deviceId": "DEVICE-A",
            "callId": "CALL-A",
            "sessionId": "provider-session-a",
            "turnAction": action,
            "iceServers": [[
                "urls": ["turn:turn.cloudflare.com:3478?transport=udp"],
                "username": "ephemeral-user",
                "credential": "ephemeral-credential"
            ]],
            "issuedAtMs": 1_000,
            "expiresAtMs": 2_000
        ]
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)
        ) as? [String: Any])
    }

    private func decodeAuthority(
        _ object: [String: Any]
    ) throws -> MatrixNativeCloudflareRtcV1AuthorityResponse {
        try decode(MatrixNativeCloudflareRtcV1AuthorityResponse.self, object)
    }

    private func decodeReceiveOnly(
        _ object: [String: Any]
    ) throws -> MatrixNativeCloudflareRtcV1ReceiveOnlySessionResponse {
        try decode(MatrixNativeCloudflareRtcV1ReceiveOnlySessionResponse.self, object)
    }

    private func decodeSubscribe(
        _ object: [String: Any]
    ) throws -> MatrixNativeCloudflareRtcV1SubscribeResponse {
        try decode(MatrixNativeCloudflareRtcV1SubscribeResponse.self, object)
    }

    private func validateSubscribe(
        _ object: [String: Any],
        _ request: MatrixNativeCloudflareRtcV1SubscribeRequest,
        _ binding: MatrixNativeRtcProviderSessionAuthorityBinding
    ) throws {
        try decodeSubscribe(object).validate(
            request: request,
            binding: binding,
            nowMilliseconds: 1_500
        )
    }

    private func decodeRecovery(
        _ object: [String: Any]
    ) throws -> MatrixNativeCloudflareRtcV1NetworkRecoveryResponse {
        try decode(MatrixNativeCloudflareRtcV1NetworkRecoveryResponse.self, object)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        _ object: [String: Any]
    ) throws -> T {
        try JSONDecoder().decode(
            type,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
