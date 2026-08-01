import Foundation

public enum MatrixNativeRtcIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case audio
    case video
}

public enum MatrixNativeRtcMediaProvider: String, Codable, Sendable, CaseIterable {
    case livekit = "LIVEKIT"
    case cloudflareRealtime = "CLOUDFLARE_REALTIME"
}

public enum MatrixNativeRtcProviderRoutingDecision: Sendable, Equatable {
    case livekit
    case cloudflareRealtime
    case rejected
}

/// Captures the server-selected transport once for the lifetime of a call.
/// Clients never infer or switch providers after joining.
public struct MatrixNativeRtcProviderSelection: Sendable, Equatable {
    public let provider: MatrixNativeRtcMediaProvider?
    public let routingDecision: MatrixNativeRtcProviderRoutingDecision

    public init(
        serverProvider: String,
        directCloudflareRealtimeEnabled: Bool =
            MatrixNativeRtcContract.directCloudflareRealtimeEnabled
    ) {
        let normalized = serverProvider.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        provider = MatrixNativeRtcMediaProvider(rawValue: normalized)
        switch provider {
        case .livekit:
            routingDecision = .livekit
        case .cloudflareRealtime where directCloudflareRealtimeEnabled:
            routingDecision = .cloudflareRealtime
        default:
            routingDecision = .rejected
        }
    }
}

public enum MatrixNativeRtcTrackIntent: String, Codable, Sendable, CaseIterable {
    case microphone
    case camera
    case screen
}

public enum MatrixNativeRtcContractError: Error, Equatable {
    case invalidBinding
    case bindingMismatch
    case invalidRemoteTrack
    case ineligibleRemoteSubscription
    case invalidAuthorization
}

/// Immutable application identity for one native RTC transport. The Wave,
/// call and device cannot be changed while the transport is alive.
public struct MatrixNativeRtcSessionBinding: Sendable, Equatable, Hashable {
    public let provider: MatrixNativeRtcMediaProvider
    public let waveID: String
    public let callID: String
    public let deviceID: String

    public init(
        provider: MatrixNativeRtcMediaProvider,
        waveID: String,
        callID: String,
        deviceID: String
    ) throws {
        guard Self.matches(
            waveID,
            pattern: "^![^:\\s]{1,255}:[A-Za-z0-9.-]+(?::[0-9]{1,5})?$"
        ),
              Self.matches(callID, pattern: "^[A-Za-z0-9._~-]{1,256}$"),
              Self.matches(deviceID, pattern: "^[A-Za-z0-9._~+=/-]{1,255}$") else {
            throw MatrixNativeRtcContractError.invalidBinding
        }
        self.provider = provider
        self.waveID = waveID
        self.callID = callID
        self.deviceID = deviceID
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Extends the immutable application binding with one exact provider session
/// and the Matrix-authorized lifetime for that session. It contains no SDP,
/// endpoint, TURN material, token, or provider credential.
public struct MatrixNativeRtcProviderSessionAuthorityBinding:
    Sendable, Equatable, Hashable {
    public let session: MatrixNativeRtcSessionBinding
    public let providerSessionID: String
    public let authorityExpiresAtMilliseconds: Int64
    public let publishAllowed: Bool
    public let subscribeAllowed: Bool

    public init(
        session: MatrixNativeRtcSessionBinding,
        providerSessionID: String,
        authorityExpiresAtMilliseconds: Int64,
        nowMilliseconds: Int64,
        publishAllowed: Bool = false,
        subscribeAllowed: Bool = false
    ) throws {
        guard providerSessionID.range(
            of: "^[A-Za-z0-9._~-]{1,256}$",
            options: .regularExpression
        ) != nil,
              nowMilliseconds >= 0,
              authorityExpiresAtMilliseconds > nowMilliseconds,
              authorityExpiresAtMilliseconds - nowMilliseconds
                <= MatrixNativeRtcContract.maximumProviderAuthorityLifetimeMilliseconds else {
            throw MatrixNativeRtcContractError.invalidBinding
        }
        self.session = session
        self.providerSessionID = providerSessionID
        self.authorityExpiresAtMilliseconds = authorityExpiresAtMilliseconds
        self.publishAllowed = publishAllowed
        self.subscribeAllowed = subscribeAllowed
    }
}

public enum MatrixNativeRtcRemoteTrackKind: String, Codable, Sendable, CaseIterable {
    case audio
    case video
}

/// Provider-neutral source for one requested remote media track. The publisher
/// session and provider track name are both required because a track name is
/// not globally unique across provider sessions.
public struct MatrixNativeRtcRemoteTrackSource: Sendable, Equatable, Hashable {
    public let participantID: String
    public let publisherSessionID: String
    public let providerTrackName: String
    public let kind: MatrixNativeRtcRemoteTrackKind

    public init(
        participantID: String,
        publisherSessionID: String,
        providerTrackName: String,
        kind: MatrixNativeRtcRemoteTrackKind
    ) throws {
        guard Self.matches(
            participantID,
            pattern: "^@[^:\\s]{1,255}:[A-Za-z0-9.-]+(?::[0-9]{1,5})?$"
        ),
              Self.matches(
                publisherSessionID,
                pattern: "^[A-Za-z0-9._~-]{1,256}$"
              ),
              Self.matches(
                providerTrackName,
                pattern: "^[A-Za-z0-9._~-]{1,256}$"
              ) else {
            throw MatrixNativeRtcContractError.invalidRemoteTrack
        }
        self.participantID = participantID
        self.publisherSessionID = publisherSessionID
        self.providerTrackName = providerTrackName
        self.kind = kind
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct MatrixNativeRtcRemoteSubscription: Sendable, Equatable, Hashable {
    public let binding: MatrixNativeRtcSessionBinding
    public let experience: MatrixNativeRtcExperience
    public let role: MatrixNativeRtcParticipantRole
    public let track: MatrixNativeRtcRemoteTrackSource

    public init(
        binding: MatrixNativeRtcSessionBinding,
        experience: MatrixNativeRtcExperience,
        role: MatrixNativeRtcParticipantRole,
        track: MatrixNativeRtcRemoteTrackSource
    ) throws {
        guard role == .interactive,
              experience == .call || experience == .liveStage else {
            throw MatrixNativeRtcContractError.ineligibleRemoteSubscription
        }
        self.binding = binding
        self.experience = experience
        self.role = role
        self.track = track
    }
}

/// Owns the desired remote-track set for exactly one transport binding.
/// Ending the transport or removing a participant deterministically removes
/// all corresponding subscriptions.
public struct MatrixNativeRtcRemoteSubscriptionState: Sendable, Equatable {
    public let binding: MatrixNativeRtcSessionBinding
    public let experience: MatrixNativeRtcExperience
    public let role: MatrixNativeRtcParticipantRole
    public private(set) var subscriptions: Set<MatrixNativeRtcRemoteSubscription>

    public init(
        binding: MatrixNativeRtcSessionBinding,
        experience: MatrixNativeRtcExperience,
        role: MatrixNativeRtcParticipantRole
    ) throws {
        guard role == .interactive,
              experience == .call || experience == .liveStage else {
            throw MatrixNativeRtcContractError.ineligibleRemoteSubscription
        }
        self.binding = binding
        self.experience = experience
        self.role = role
        subscriptions = []
    }

    public mutating func subscribe(_ subscription: MatrixNativeRtcRemoteSubscription) throws {
        guard subscription.binding == binding,
              subscription.experience == experience,
              subscription.role == role else {
            throw MatrixNativeRtcContractError.bindingMismatch
        }
        subscriptions.insert(subscription)
    }

    @discardableResult
    public mutating func unsubscribe(
        track: MatrixNativeRtcRemoteTrackSource
    ) -> MatrixNativeRtcRemoteSubscription? {
        guard let subscription = subscriptions.first(where: { $0.track == track }) else {
            return nil
        }
        subscriptions.remove(subscription)
        return subscription
    }

    @discardableResult
    public mutating func removeParticipant(_ participantID: String)
        -> Set<MatrixNativeRtcRemoteSubscription> {
        let removed = subscriptions.filter { $0.track.participantID == participantID }
        subscriptions.subtract(removed)
        return Set(removed)
    }

    public mutating func finish() {
        subscriptions.removeAll(keepingCapacity: false)
    }
}

public enum MatrixNativeRtcExperience: Sendable, Equatable, Hashable {
    case call
    case liveStage
    case watchParty
}

public enum MatrixNativeLiveStageMode: String, Codable, Sendable, Equatable {
    case conversation
    case gaming
}

public enum MatrixNativeRtcParticipantRole: Sendable, Equatable, Hashable {
    case interactive
    case audience
}

public enum MatrixNativeRtcDeliveryPlane: Sendable, Equatable {
    case realtime
    case stream
}

public enum MatrixNativeRtcPlaybackAuthority: Sendable, Equatable {
    case none
    case matrixRoomState
}

public struct MatrixNativeRtcMediaPlan: Sendable, Equatable {
    public let deliveryPlane: MatrixNativeRtcDeliveryPlane
    public let playbackAuthority: MatrixNativeRtcPlaybackAuthority
    public let liveStageMode: MatrixNativeLiveStageMode?

    public init(
        deliveryPlane: MatrixNativeRtcDeliveryPlane,
        playbackAuthority: MatrixNativeRtcPlaybackAuthority,
        liveStageMode: MatrixNativeLiveStageMode? = nil
    ) {
        self.deliveryPlane = deliveryPlane
        self.playbackAuthority = playbackAuthority
        self.liveStageMode = liveStageMode
    }
}

public enum MatrixNativeRtcScreenShareContract {
    /// ReplayKit remains unavailable until the native Cloudflare transport,
    /// broadcast extension, and release gates have passed on a physical device.
    public static let replayKitEnabled = false
    public static let permitsLongLivedProviderSecrets = false
    public static let requiresShortLivedAppGroupAuthorization = true
    public static let maximumBroadcastExtensionMemoryMegabytes = 45
    public static let maximumAuthorizationLifetimeMilliseconds: Int64 = 300_000
    public static let appGroupStoresOpaqueReferenceOnly = true
}

public enum MatrixNativeReplayKitAuthorizationError: Error, Equatable {
    case invalidReference
    case invalidLifetime
}

/// The broadcast extension receives only a short-lived opaque reference.
/// Provider credentials, SDP, URLs and Matrix access tokens never cross the
/// App Group boundary.
public struct MatrixNativeReplayKitAuthorization: Sendable, Equatable {
    public let opaqueReference: String
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public init(
        opaqueReference: String,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) throws {
        guard opaqueReference.range(
            of: "^[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil else {
            throw MatrixNativeReplayKitAuthorizationError.invalidReference
        }
        let lifetime = expiresAtMilliseconds - issuedAtMilliseconds
        guard issuedAtMilliseconds >= 0,
              lifetime > 0,
              lifetime <= MatrixNativeRtcScreenShareContract
                .maximumAuthorizationLifetimeMilliseconds else {
            throw MatrixNativeReplayKitAuthorizationError.invalidLifetime
        }
        self.opaqueReference = opaqueReference
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct MatrixNativeReplayKitAuthorizationState: Sendable, Equatable {
    private var authorization: MatrixNativeReplayKitAuthorization?

    public init(authorization: MatrixNativeReplayKitAuthorization? = nil) {
        self.authorization = authorization
    }

    public mutating func activeAuthorization(nowMilliseconds: Int64)
        -> MatrixNativeReplayKitAuthorization? {
        guard let authorization,
              nowMilliseconds >= authorization.issuedAtMilliseconds,
              nowMilliseconds < authorization.expiresAtMilliseconds else {
            self.authorization = nil
            return nil
        }
        return authorization
    }

    public mutating func finish() {
        authorization = nil
    }
}

public protocol MatrixNativeReplayKitAuthorizationStore {
    func loadAuthorization() throws -> MatrixNativeReplayKitAuthorization?
    func saveAuthorization(_ authorization: MatrixNativeReplayKitAuthorization) throws
    func clearAuthorization() throws
}

public enum MatrixNativeRtcNetworkRecoveryAction: String, Codable, Sendable, CaseIterable {
    case refreshTurn = "REFRESH_TURN"
    case restartIce = "RESTART_ICE"
}

/// A one-use, short-lived application authorization to request fresh network
/// recovery material from MediaVerse. It intentionally contains no ICE server
/// URL, TURN username/password, provider credential or session description.
public struct MatrixNativeRtcNetworkRecoveryAuthorization: Sendable, Equatable {
    public let binding: MatrixNativeRtcProviderSessionAuthorityBinding
    public let action: MatrixNativeRtcNetworkRecoveryAction
    public let opaqueReference: String
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public init(
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        action: MatrixNativeRtcNetworkRecoveryAction,
        opaqueReference: String,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) throws {
        guard opaqueReference.range(
            of: "^[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        let lifetime = expiresAtMilliseconds - issuedAtMilliseconds
        guard issuedAtMilliseconds >= 0,
              lifetime > 0,
              lifetime <= MatrixNativeRtcContract
                .maximumNetworkRecoveryAuthorizationLifetimeMilliseconds,
              expiresAtMilliseconds <= binding.authorityExpiresAtMilliseconds else {
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        self.binding = binding
        self.action = action
        self.opaqueReference = opaqueReference
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

/// Consumes authorizations exactly once and fails closed on a different Wave,
/// call, device, provider, action, or time window.
public struct MatrixNativeRtcNetworkRecoveryAuthorizationState: Sendable, Equatable {
    private var authorization: MatrixNativeRtcNetworkRecoveryAuthorization?

    public init(authorization: MatrixNativeRtcNetworkRecoveryAuthorization? = nil) {
        self.authorization = authorization
    }

    public mutating func takeAuthorization(
        binding: MatrixNativeRtcProviderSessionAuthorityBinding,
        action: MatrixNativeRtcNetworkRecoveryAction,
        nowMilliseconds: Int64
    ) throws -> MatrixNativeRtcNetworkRecoveryAuthorization {
        guard let authorization,
              authorization.binding == binding,
              authorization.action == action,
              nowMilliseconds >= authorization.issuedAtMilliseconds,
              nowMilliseconds < authorization.expiresAtMilliseconds else {
            self.authorization = nil
            throw MatrixNativeRtcContractError.invalidAuthorization
        }
        self.authorization = nil
        return authorization
    }

    public mutating func finish() {
        authorization = nil
    }
}

public enum MatrixNativeRtcMediaSecurity: String, Codable, Sendable {
    case standardWebRTC = "DTLS_SRTP"
}

public enum MatrixNativeRtcContract {
    public static let normativeSource =
        "User strongest-model Matrix-native Vibes prompt (precedence 1)"
    public static let authority = "MATRIX"
    public static let mediaTransport = "EXISTING_LIVEKIT"
    public static let productionMediaProvider = MatrixNativeRtcMediaProvider.livekit
    public static let membershipEventType = "org.matrix.msc3401.call.member"
    public static let application = "m.call"
    public static let roomScope = "m.room"
    public static let membershipLifetimeMilliseconds: Int64 =
        4 * 60 * 60 * 1_000
    public static let membershipRefreshMilliseconds: Int64 =
        3 * 60 * 60 * 1_000
    public static let maximumNetworkRecoveryAuthorizationLifetimeMilliseconds: Int64 =
        5 * 60 * 1_000
    public static let maximumProviderAuthorityLifetimeMilliseconds: Int64 =
        5 * 60 * 1_000
    public static let permitsNewInfrastructure = false
    public static let applicationMediaEncryptionEnabled = false
    public static let swiftBindingsExportMatrixRtcMediaKeys = false
    /// Migration groundwork only. Cloudflare cannot receive any cohort while
    /// this remains false, and provider selection is fixed when a call starts.
    public static let directCloudflareRealtimeEnabled = false

    public static func trackIntents(for intent: MatrixNativeRtcIntent)
        -> Set<MatrixNativeRtcTrackIntent> {
        switch intent {
        case .audio:
            [.microphone]
        case .video:
            [.microphone, .camera]
        }
    }

    public static func permitsTrackIntent(_ intent: MatrixNativeRtcTrackIntent) -> Bool {
        intent != .screen || MatrixNativeRtcScreenShareContract.replayKitEnabled
    }

    /// Keeps interactive WebRTC fan-out separate from passive program delivery.
    /// Watch Party playback timing remains durable Matrix room state.
    public static func mediaPlan(
        for experience: MatrixNativeRtcExperience,
        role: MatrixNativeRtcParticipantRole,
        liveStageMode: MatrixNativeLiveStageMode? = nil
    ) -> MatrixNativeRtcMediaPlan {
        switch experience {
        case .call:
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .realtime,
                playbackAuthority: .none
            )
        case .liveStage:
            MatrixNativeRtcMediaPlan(
                deliveryPlane: role == .interactive ? .realtime : .stream,
                playbackAuthority: .none,
                liveStageMode: liveStageMode ?? .conversation
            )
        case .watchParty:
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .matrixRoomState
            )
        }
    }

    public static func acceptsProductionConnectionProvider(_ provider: String) -> Bool {
        MatrixNativeRtcProviderSelection(serverProvider: provider).routingDecision
            == .livekit
    }
}
