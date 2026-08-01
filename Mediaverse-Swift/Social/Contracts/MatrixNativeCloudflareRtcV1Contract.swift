import Foundation

private struct MatrixNativeCloudflareRtcV1AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Decoder {
    func rejectUnknownCloudflareRtcV1Keys<Key>(_: Key.Type) throws
        where Key: CodingKey & CaseIterable {
        let actual = try container(
            keyedBy: MatrixNativeCloudflareRtcV1AnyCodingKey.self
        ).allKeys.map(\.stringValue)
        let allowed = Set(Key.allCases.map(\.stringValue))
        guard actual.allSatisfy(allowed.contains) else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
    }
}

public enum MatrixNativeCloudflareRtcV1Contract {
    public static let version = "CLOUDFLARE_RTC_V1"
    public static let provider = MatrixNativeRtcMediaProvider.cloudflareRealtime
    public static let maximumTracksPerMutation = 64
}

public enum MatrixNativeCloudflareRtcV1Experience: String, Codable, Sendable, Hashable {
    case call
    case liveStage = "stage"
    case watchParty = "watch-party"
}

public enum MatrixNativeCloudflareRtcV1Role: String, Codable, Sendable, Hashable {
    case host
    case speaker
    case participant
    case viewer
}

public enum MatrixNativeCloudflareRtcV1MediaPath: String, Codable, Sendable, Hashable {
    case interactiveSFU = "INTERACTIVE_SFU"
    case passiveStream = "PASSIVE_STREAM"
}

public enum MatrixNativeCloudflareRtcV1TrackKind: String, Codable, Sendable, Hashable {
    case microphone
    case camera
    case screenAudio = "screen-audio"
    case screenVideo = "screen-video"
}

public struct MatrixNativeCloudflareRtcV1AuthorizeRequest: Encodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let intent: MatrixNativeRtcIntent
    public let experience: MatrixNativeCloudflareRtcV1Experience
    public let stageMode: MatrixNativeLiveStageMode?
    public let requestedTrackKinds: [MatrixNativeCloudflareRtcV1TrackKind]

    public init(
        roomID: String,
        deviceID: String,
        intent: MatrixNativeRtcIntent,
        experience: MatrixNativeCloudflareRtcV1Experience,
        stageMode: MatrixNativeLiveStageMode? = nil,
        requestedTrackKinds: [MatrixNativeCloudflareRtcV1TrackKind]
    ) throws {
        let session = try MatrixNativeRtcSessionBinding(
            provider: .cloudflareRealtime,
            waveID: roomID,
            callID: "validation-only",
            deviceID: deviceID
        )
        _ = session
        guard stageMode == nil || experience == .liveStage,
              requestedTrackKinds.count <= MatrixNativeCloudflareRtcV1Contract
                .maximumTracksPerMutation,
              Set(requestedTrackKinds).count == requestedTrackKinds.count,
              intent != .audio || !requestedTrackKinds.contains(where: {
                $0 == .camera || $0 == .screenVideo
              }) else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        contractVersion = MatrixNativeCloudflareRtcV1Contract.version
        provider = .cloudflareRealtime
        self.roomID = roomID
        self.deviceID = deviceID
        self.intent = intent
        self.experience = experience
        self.stageMode = stageMode
        self.requestedTrackKinds = requestedTrackKinds
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, provider, intent, experience, stageMode
        case roomID = "roomId"
        case deviceID = "deviceId"
        case requestedTrackKinds = "trackKinds"
    }
}

/// Matrix-issued authority returned before any provider session is created.
public struct MatrixNativeCloudflareRtcV1AuthorityResponse:
    Decodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let authority: String
    public let mediaProtection: MatrixNativeRtcMediaSecurity
    public let applicationMediaEncryption: Bool
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let intent: MatrixNativeRtcIntent
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let publishAllowed: Bool
    public let subscribeAllowed: Bool
    public let allowedTrackKinds: [MatrixNativeCloudflareRtcV1TrackKind]
    public let experience: MatrixNativeCloudflareRtcV1Experience
    public let stageMode: MatrixNativeLiveStageMode?
    public let role: MatrixNativeCloudflareRtcV1Role
    public let mediaPath: MatrixNativeCloudflareRtcV1MediaPath

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try values.decode(String.self, forKey: .contractVersion)
        provider = try values.decode(MatrixNativeRtcMediaProvider.self, forKey: .provider)
        authority = try values.decode(String.self, forKey: .authority)
        mediaProtection = try values.decode(MatrixNativeRtcMediaSecurity.self, forKey: .mediaProtection)
        applicationMediaEncryption = try values.decode(Bool.self, forKey: .applicationMediaEncryption)
        roomID = try values.decode(String.self, forKey: .roomID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        callID = try values.decode(String.self, forKey: .callID)
        intent = try values.decode(MatrixNativeRtcIntent.self, forKey: .intent)
        issuedAtMilliseconds = try values.decode(Int64.self, forKey: .issuedAtMilliseconds)
        expiresAtMilliseconds = try values.decode(Int64.self, forKey: .expiresAtMilliseconds)
        publishAllowed = try values.decode(Bool.self, forKey: .publishAllowed)
        subscribeAllowed = try values.decode(Bool.self, forKey: .subscribeAllowed)
        allowedTrackKinds = try values.decode(
            [MatrixNativeCloudflareRtcV1TrackKind].self,
            forKey: .allowedTrackKinds
        )
        experience = try values.decode(
            MatrixNativeCloudflareRtcV1Experience.self,
            forKey: .experience
        )
        stageMode = try values.decodeIfPresent(
            MatrixNativeLiveStageMode.self,
            forKey: .stageMode
        )
        role = try values.decode(MatrixNativeCloudflareRtcV1Role.self, forKey: .role)
        mediaPath = try values.decode(
            MatrixNativeCloudflareRtcV1MediaPath.self,
            forKey: .mediaPath
        )
        _ = try MatrixNativeRtcSessionBinding(
            provider: provider,
            waveID: roomID,
            callID: callID,
            deviceID: deviceID
        )
        guard contractVersion == MatrixNativeCloudflareRtcV1Contract.version,
              provider == .cloudflareRealtime,
              authority == MatrixNativeRtcContract.authority,
              mediaProtection == .standardWebRTC,
              applicationMediaEncryption == false,
              issuedAtMilliseconds >= 0,
              expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds
                <= MatrixNativeRtcContract.maximumProviderAuthorityLifetimeMilliseconds,
              stageMode == nil || experience == .liveStage,
              allowedTrackKinds.count <= MatrixNativeCloudflareRtcV1Contract
                .maximumTracksPerMutation,
              Set(allowedTrackKinds).count == allowedTrackKinds.count else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
    }

    public func validate(
        request: MatrixNativeCloudflareRtcV1AuthorizeRequest
    ) throws {
        guard roomID == request.roomID,
              deviceID == request.deviceID,
              intent == request.intent,
              experience == request.experience,
              stageMode == request.stageMode,
              Set(request.requestedTrackKinds) == Set(allowedTrackKinds),
              request.requestedTrackKinds.isEmpty || publishAllowed,
              validatesRoleMatrix() else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
    }

    private func validatesRoleMatrix() -> Bool {
        switch (experience, role) {
        case (.call, .participant):
            stageMode == nil && mediaPath == .interactiveSFU
                && publishAllowed && subscribeAllowed
        case (.liveStage, .host), (.liveStage, .speaker):
            mediaPath == .interactiveSFU && publishAllowed && subscribeAllowed
        case (.liveStage, .viewer):
            mediaPath == .passiveStream && !publishAllowed && !subscribeAllowed
        case (.watchParty, .host):
            stageMode == nil && mediaPath == .interactiveSFU
                && publishAllowed && subscribeAllowed
        case (.watchParty, .viewer):
            stageMode == nil && mediaPath == .passiveStream
                && !publishAllowed && !subscribeAllowed
        default:
            false
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion, provider, authority, mediaProtection
        case applicationMediaEncryption
        case publishAllowed, subscribeAllowed, allowedTrackKinds
        case intent, experience, stageMode, role, mediaPath
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case issuedAtMilliseconds = "issuedAtMs"
        case expiresAtMilliseconds = "expiresAtMs"
    }
}

/// Requests an SFU session with no local publications. SDP remains confined to
/// the future transport implementation and is not part of this shared state.
public struct MatrixNativeCloudflareRtcV1ReceiveOnlySessionRequest:
    Encodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let tracks: [MatrixNativeCloudflareRtcV1RemoteTrackSource]

    public init(
        authority: MatrixNativeCloudflareRtcV1AuthorityResponse,
        authorizeRequest: MatrixNativeCloudflareRtcV1AuthorizeRequest
    ) throws {
        try authority.validate(request: authorizeRequest)
        guard authority.subscribeAllowed else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        contractVersion = MatrixNativeCloudflareRtcV1Contract.version
        provider = .cloudflareRealtime
        roomID = authority.roomID
        deviceID = authority.deviceID
        callID = authority.callID
        tracks = []
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, provider, tracks
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
    }
}

public struct MatrixNativeCloudflareRtcV1ReceiveOnlySessionResponse:
    Decodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let providerSessionID: String
    public let authorityExpiresAtMilliseconds: Int64
    public let publishAllowed: Bool
    public let subscribeAllowed: Bool

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try values.decode(String.self, forKey: .contractVersion)
        provider = try values.decode(MatrixNativeRtcMediaProvider.self, forKey: .provider)
        roomID = try values.decode(String.self, forKey: .roomID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        callID = try values.decode(String.self, forKey: .callID)
        providerSessionID = try values.decode(String.self, forKey: .providerSessionID)
        authorityExpiresAtMilliseconds = try values.decode(
            Int64.self,
            forKey: .authorityExpiresAtMilliseconds
        )
        publishAllowed = try values.decode(Bool.self, forKey: .publishAllowed)
        subscribeAllowed = try values.decode(Bool.self, forKey: .subscribeAllowed)
    }

    public func validatedBinding(
        authority: MatrixNativeCloudflareRtcV1AuthorityResponse,
        nowMilliseconds: Int64
    ) throws -> MatrixNativeRtcProviderSessionAuthorityBinding {
        guard contractVersion == MatrixNativeCloudflareRtcV1Contract.version,
              provider == .cloudflareRealtime,
              roomID == authority.roomID,
              deviceID == authority.deviceID,
              callID == authority.callID,
              authorityExpiresAtMilliseconds <= authority.expiresAtMilliseconds,
              publishAllowed == authority.publishAllowed,
              subscribeAllowed == authority.subscribeAllowed else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
        return try MatrixNativeRtcProviderSessionAuthorityBinding(
            session: MatrixNativeRtcSessionBinding(
                provider: provider,
                waveID: roomID,
                callID: callID,
                deviceID: deviceID
            ),
            providerSessionID: providerSessionID,
            authorityExpiresAtMilliseconds: authorityExpiresAtMilliseconds,
            nowMilliseconds: nowMilliseconds,
            publishAllowed: publishAllowed,
            subscribeAllowed: subscribeAllowed
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion, provider
        case publishAllowed, subscribeAllowed
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case providerSessionID = "sessionId"
        case authorityExpiresAtMilliseconds = "expiresAtMs"
    }
}

public struct MatrixNativeCloudflareRtcV1RemoteTrackSource:
    Encodable, Sendable, Equatable, Hashable {
    public let publisherSessionID: String
    public let providerTrackName: String

    public init(publisherSessionID: String, providerTrackName: String) throws {
        let pattern = "^[A-Za-z0-9._~-]{1,256}$"
        guard publisherSessionID.range(of: pattern, options: .regularExpression) != nil,
              providerTrackName.range(of: pattern, options: .regularExpression) != nil else {
            throw MatrixNativeRtcContractError.invalidRemoteTrack
        }
        self.publisherSessionID = publisherSessionID
        self.providerTrackName = providerTrackName
    }

    private enum CodingKeys: String, CodingKey {
        case publisherSessionID = "publisherSessionId"
        case providerTrackName
    }
}

public struct MatrixNativeCloudflareRtcV1SubscribeRequest:
    Encodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let providerSessionID: String
    public let tracks: [MatrixNativeCloudflareRtcV1RemoteTrackSource]

    public init(
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        tracks: [MatrixNativeCloudflareRtcV1RemoteTrackSource]
    ) throws {
        guard binding.session.provider == .cloudflareRealtime,
              binding.subscribeAllowed,
              !tracks.isEmpty,
              tracks.count <= MatrixNativeCloudflareRtcV1Contract.maximumTracksPerMutation,
              Set(tracks).count == tracks.count else {
            throw MatrixNativeRtcContractError.invalidRemoteTrack
        }
        contractVersion = MatrixNativeCloudflareRtcV1Contract.version
        provider = .cloudflareRealtime
        roomID = binding.session.waveID
        deviceID = binding.session.deviceID
        callID = binding.session.callID
        providerSessionID = binding.providerSessionID
        self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, provider, tracks
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case providerSessionID = "sessionId"
    }
}

public struct MatrixNativeCloudflareRtcV1AuthorizedRemoteTrackBinding:
    Decodable, Sendable, Equatable, Hashable {
    public let publisherSessionID: String
    public let providerTrackName: String
    public let participantID: String
    public let kind: MatrixNativeRtcRemoteTrackKind
    public let subscriberTrackMID: String

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publisherSessionID = try values.decode(String.self, forKey: .publisherSessionID)
        providerTrackName = try values.decode(String.self, forKey: .providerTrackName)
        participantID = try values.decode(String.self, forKey: .participantID)
        kind = try values.decode(MatrixNativeRtcRemoteTrackKind.self, forKey: .kind)
        subscriberTrackMID = try values.decode(String.self, forKey: .subscriberTrackMID)
    }

    public func requestedSource() throws -> MatrixNativeCloudflareRtcV1RemoteTrackSource {
        try MatrixNativeCloudflareRtcV1RemoteTrackSource(
            publisherSessionID: publisherSessionID,
            providerTrackName: providerTrackName
        )
    }

    public func validateServerDerivedIdentity() throws {
        _ = try requestedSource()
        guard participantID.range(
            of: "^@[^:\\s]{1,255}:[A-Za-z0-9.-]+(?::[0-9]{1,5})?$",
            options: .regularExpression
        ) != nil,
              subscriberTrackMID.range(
                of: "^[A-Za-z0-9._~:-]{1,128}$",
                options: .regularExpression
              ) != nil else {
            throw MatrixNativeRtcContractError.invalidRemoteTrack
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerTrackName, participantID = "participantId", kind
        case publisherSessionID = "publisherSessionId"
        case subscriberTrackMID = "subscriberTrackMid"
    }
}

public struct MatrixNativeCloudflareRtcV1SubscribeResponse:
    Decodable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let providerSessionID: String
    public let authorityExpiresAtMilliseconds: Int64
    public let publishAllowed: Bool
    public let subscribeAllowed: Bool
    public let requiresImmediateRenegotiation: Bool
    public let offer: MatrixNativeCloudflareRtcV1EphemeralSessionDescription?
    public let tracks: [MatrixNativeCloudflareRtcV1AuthorizedRemoteTrackBinding]

    public var description: String { "<subscribe-response:redacted>" }
    public var debugDescription: String { description }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try values.decode(String.self, forKey: .contractVersion)
        provider = try values.decode(MatrixNativeRtcMediaProvider.self, forKey: .provider)
        roomID = try values.decode(String.self, forKey: .roomID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        callID = try values.decode(String.self, forKey: .callID)
        providerSessionID = try values.decode(String.self, forKey: .providerSessionID)
        authorityExpiresAtMilliseconds = try values.decode(
            Int64.self,
            forKey: .authorityExpiresAtMilliseconds
        )
        publishAllowed = try values.decode(Bool.self, forKey: .publishAllowed)
        subscribeAllowed = try values.decode(Bool.self, forKey: .subscribeAllowed)
        requiresImmediateRenegotiation = try values.decode(
            Bool.self,
            forKey: .requiresImmediateRenegotiation
        )
        offer = try values.decodeIfPresent(
            MatrixNativeCloudflareRtcV1EphemeralSessionDescription.self,
            forKey: .offer
        )
        tracks = try values.decode(
            [MatrixNativeCloudflareRtcV1AuthorizedRemoteTrackBinding].self,
            forKey: .tracks
        )
    }

    public func validate(
        request: MatrixNativeCloudflareRtcV1SubscribeRequest,
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        nowMilliseconds: Int64
    ) throws {
        guard contractVersion == request.contractVersion,
              provider == request.provider,
              roomID == request.roomID,
              deviceID == request.deviceID,
              callID == request.callID,
              providerSessionID == request.providerSessionID,
              binding.session.provider == provider,
              binding.session.waveID == roomID,
              binding.session.deviceID == deviceID,
              binding.session.callID == callID,
              binding.providerSessionID == providerSessionID,
              authorityExpiresAtMilliseconds > nowMilliseconds,
              authorityExpiresAtMilliseconds <= binding.authorityExpiresAtMilliseconds,
              publishAllowed == binding.publishAllowed,
              subscribeAllowed == binding.subscribeAllowed,
              subscribeAllowed,
              requiresImmediateRenegotiation == (offer != nil),
              tracks.count == request.tracks.count,
              Set(tracks.map(\.subscriberTrackMID)).count == tracks.count else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
        for track in tracks {
            try track.validateServerDerivedIdentity()
        }
        guard Set(try tracks.map { try $0.requestedSource() }) == Set(request.tracks) else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion, provider, tracks
        case publishAllowed, subscribeAllowed, requiresImmediateRenegotiation, offer
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case providerSessionID = "sessionId"
        case authorityExpiresAtMilliseconds = "expiresAtMs"
    }
}

/// A provider offer exists only long enough to be applied to RTCPeerConnection.
/// It is decode-only and both printable descriptions are redacted.
public struct MatrixNativeCloudflareRtcV1EphemeralSessionDescription:
    Decodable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let type: String
    public let sdp: String

    public var description: String { "<ephemeral-sdp:redacted>" }
    public var debugDescription: String { description }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        sdp = try values.decode(String.self, forKey: .sdp)
        guard type == "offer",
              (1...1_000_000).contains(sdp.count),
              sdp.rangeOfCharacter(from: .controlCharacters.subtracting(
                CharacterSet(charactersIn: "\r\n\t")
              )) == nil else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, sdp
    }
}

/// The client requests an action, never a TURN TTL. The server selects the
/// authorization expiry and returns short-lived transport material.
public struct MatrixNativeCloudflareRtcV1NetworkRecoveryRequest:
    Encodable, Sendable, Equatable {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let providerSessionID: String
    public let action: MatrixNativeRtcNetworkRecoveryAction

    public init(
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        action: MatrixNativeRtcNetworkRecoveryAction
    ) throws {
        guard binding.session.provider == .cloudflareRealtime else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
        contractVersion = MatrixNativeCloudflareRtcV1Contract.version
        provider = .cloudflareRealtime
        roomID = binding.session.waveID
        deviceID = binding.session.deviceID
        callID = binding.session.callID
        providerSessionID = binding.providerSessionID
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, provider
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case providerSessionID = "sessionId"
        case action = "turnAction"
    }
}

/// A transport-only ICE server decoded from MediaVerse. This DTO is not
/// Encodable and its descriptions redact usernames and credentials. Callers
/// must consume it through the one-use recovery state and never persist it.
public struct MatrixNativeCloudflareRtcV1EphemeralIceServer:
    Decodable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public var description: String { "<ephemeral-ice-server:redacted>" }
    public var debugDescription: String { description }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        urls = try values.decode([String].self, forKey: .urls)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        credential = try values.decodeIfPresent(String.self, forKey: .credential)
        let safeURL = "^(?:stun|turn|turns):[^\\s@]{1,507}$"
        guard (1...12).contains(urls.count),
              Set(urls).count == urls.count,
              urls.allSatisfy({
                $0.count <= 512
                    && $0.range(of: safeURL, options: .regularExpression) != nil
              }),
              Self.isBoundedSecret(username),
              Self.isBoundedSecret(credential),
              (username == nil) == (credential == nil) else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
    }

    private static func isBoundedSecret(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...512).contains(value.count)
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case urls, username, credential
    }
}

public struct MatrixNativeCloudflareRtcV1EphemeralRecoveryMaterial:
    Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let binding: MatrixNativeRtcProviderSessionAuthorityBinding
    public let action: MatrixNativeRtcNetworkRecoveryAction
    public let iceServers: [MatrixNativeCloudflareRtcV1EphemeralIceServer]
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public var description: String { "<ephemeral-network-recovery:redacted>" }
    public var debugDescription: String { description }
}

/// The decoded response itself owns ICE secrets. Every alias shares one locked
/// owner, and only `takeTransportMaterial` can release them to the transport.
public final class MatrixNativeCloudflareRtcV1NetworkRecoveryResponse:
    Decodable, @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let contractVersion: String
    public let provider: MatrixNativeRtcMediaProvider
    public let roomID: String
    public let deviceID: String
    public let callID: String
    public let providerSessionID: String
    public let action: MatrixNativeRtcNetworkRecoveryAction
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    private let lock = NSLock()
    private var availableIceServers: [MatrixNativeCloudflareRtcV1EphemeralIceServer]?

    public var description: String { "<network-recovery-response:redacted>" }
    public var debugDescription: String { description }

    public required init(from decoder: Decoder) throws {
        try decoder.rejectUnknownCloudflareRtcV1Keys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try values.decode(String.self, forKey: .contractVersion)
        provider = try values.decode(MatrixNativeRtcMediaProvider.self, forKey: .provider)
        roomID = try values.decode(String.self, forKey: .roomID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        callID = try values.decode(String.self, forKey: .callID)
        providerSessionID = try values.decode(String.self, forKey: .providerSessionID)
        action = try values.decode(MatrixNativeRtcNetworkRecoveryAction.self, forKey: .action)
        issuedAtMilliseconds = try values.decode(Int64.self, forKey: .issuedAtMilliseconds)
        expiresAtMilliseconds = try values.decode(Int64.self, forKey: .expiresAtMilliseconds)
        availableIceServers = try values.decode(
            [MatrixNativeCloudflareRtcV1EphemeralIceServer].self,
            forKey: .iceServers
        )
    }

    public func takeTransportMaterial(
        request: MatrixNativeCloudflareRtcV1NetworkRecoveryRequest,
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        nowMilliseconds: Int64
    ) throws -> MatrixNativeCloudflareRtcV1EphemeralRecoveryMaterial {
        lock.lock()
        defer { lock.unlock() }
        guard let iceServers = availableIceServers else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        availableIceServers = nil
        guard contractVersion == request.contractVersion,
              provider == request.provider,
              roomID == request.roomID,
              deviceID == request.deviceID,
              callID == request.callID,
              providerSessionID == request.providerSessionID,
              action == request.action,
              binding.session.provider == provider,
              binding.session.waveID == roomID,
              binding.session.deviceID == deviceID,
              binding.session.callID == callID,
              binding.providerSessionID == providerSessionID,
              (1...8).contains(iceServers.count),
              issuedAtMilliseconds >= 0,
              issuedAtMilliseconds <= nowMilliseconds + 60_000,
              expiresAtMilliseconds > nowMilliseconds,
              expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds
                <= MatrixNativeRtcContract.maximumNetworkRecoveryAuthorizationLifetimeMilliseconds,
              expiresAtMilliseconds <= binding.authorityExpiresAtMilliseconds else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
        return MatrixNativeCloudflareRtcV1EphemeralRecoveryMaterial(
            binding: binding,
            action: action,
            iceServers: iceServers,
            issuedAtMilliseconds: issuedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion, provider, iceServers
        case roomID = "roomId"
        case deviceID = "deviceId"
        case callID = "callId"
        case providerSessionID = "sessionId"
        case action = "turnAction"
        case issuedAtMilliseconds = "issuedAtMs"
        case expiresAtMilliseconds = "expiresAtMs"
    }
}
