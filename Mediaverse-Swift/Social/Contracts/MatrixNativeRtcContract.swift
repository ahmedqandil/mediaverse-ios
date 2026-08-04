import Foundation

public enum MatrixNativeRtcIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case audio
    case video
}

public enum MatrixNativeRtcMediaProvider: String, Codable, Sendable, CaseIterable {
    case livekit = "LIVEKIT"
    case cloudflareRealtime = "CLOUDFLARE_REALTIME"
    case cloudflareStream = "CLOUDFLARE_STREAM"
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
              experience == .call
                || experience == .liveStage
                || experience == .groupLounge else {
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
              experience == .call
                || experience == .liveStage
                || experience == .groupLounge else {
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
    case groupLounge
}

public enum MatrixNativeRtcAuthorityRoomKind: Sendable, Equatable {
    case vibeSpace
    case waveOrDirect
}

public enum MatrixNativeRtcOwnershipOperation: Sendable, Equatable {
    case create
    case discover
    case join
    case manage
    case end
}

public struct MatrixNativeRtcOwnershipDecision: Sendable, Equatable {
    public let allowed: Bool
    public let expectedRoomKind: MatrixNativeRtcAuthorityRoomKind
    public let legacyCompatibility: Bool
}

public enum MatrixNativeRtcOwnershipContract {
    public static let authority = "MATRIX"
    public static let internalSessionEventType = "com.westreem.vibe.rtc.session.v1"

    public static func decide(
        experience: MatrixNativeRtcExperience,
        roomKind: MatrixNativeRtcAuthorityRoomKind,
        operation: MatrixNativeRtcOwnershipOperation,
        activeLegacyExperience: MatrixNativeRtcExperience? = nil
    ) -> MatrixNativeRtcOwnershipDecision {
        let expected: MatrixNativeRtcAuthorityRoomKind = experience == .call
            ? .waveOrDirect
            : .vibeSpace
        if roomKind == expected {
            return MatrixNativeRtcOwnershipDecision(
                allowed: true,
                expectedRoomKind: expected,
                legacyCompatibility: false
            )
        }
        let legacy = experience != .call
            && roomKind == .waveOrDirect
            && operation != .create
            && activeLegacyExperience == experience
        return MatrixNativeRtcOwnershipDecision(
            allowed: legacy,
            expectedRoomKind: expected,
            legacyCompatibility: legacy
        )
    }
}

/// A Vibe has one canonical live-product slot. Starting a second product while
/// Stage, Watch Party, or Lounge state is active would make Matrix authority
/// ambiguous, so every client must fail closed until the active product ends.
public enum MatrixNativeVibeLiveExperienceContract {
    public static func canStart(
        stageIsActive: Bool,
        watchPartyIsActive: Bool,
        loungeIsActive: Bool
    ) -> Bool {
        !stageIsActive && !watchPartyIsActive && !loungeIsActive
    }
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
    case signedHLS = "SIGNED_HLS"
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
    public static var directCloudflareRealtimeEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["WESTREEM_RTC_CLOUDFLARE_NONPRODUCTION"] == "1"
        #else
        false
        #endif
    }

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

    /// Live Stage uses Cloudflare Realtime as a global broadcast SFU; audience
    /// members receive but cannot publish. Watch Party playback timing remains
    /// durable Matrix room state and uses the Stream content plane.
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
                deliveryPlane: .realtime,
                playbackAuthority: .none,
                liveStageMode: liveStageMode ?? .conversation
            )
        case .watchParty:
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .stream,
                playbackAuthority: .matrixRoomState
            )
        case .groupLounge:
            MatrixNativeRtcMediaPlan(
                deliveryPlane: .realtime,
                playbackAuthority: .none
            )
        }
    }

    public static func acceptsProductionConnectionProvider(_ provider: String) -> Bool {
        MatrixNativeRtcProviderSelection(serverProvider: provider).routingDecision
            == .livekit
    }
}

public enum MatrixNativeRtcMembershipVisibilityResponseContract {
    public static func isTransientMembershipAbsence(
        httpStatusCode: Int,
        serverCode: String?
    ) -> Bool {
        httpStatusCode == 409
            && serverCode
                == MatrixNativeRtcMembershipVisibilityRetryPolicy.confirmationCode
    }
}

public enum MatrixNativeRtcInvitationExpiryContract {
    public static let maximumFutureMilliseconds: Int64 = 60_000

    public static func accepts(
        expiresAtMilliseconds: Int64,
        nowMilliseconds: Int64
    ) -> Bool {
        expiresAtMilliseconds > nowMilliseconds
            && expiresAtMilliseconds <= nowMilliseconds + maximumFutureMilliseconds
    }
}

public enum MatrixNativeRtcMembershipVisibilityRetryPolicy {
    public static let confirmationError =
        "WeStreem did not confirm call membership"
    public static let confirmationCode = "M_RTC_MEMBERSHIP_NOT_VISIBLE"
    public static let maximumAttempts = 6
    public static let delaysMilliseconds: [Int64] = [250, 500, 1_000, 2_000, 4_000]
    public static let invitationExpiryHeadroomMilliseconds: Int64 = 1_000

    public static func shouldRetry(
        serverCode: String?,
        completedAttempts: Int
    ) -> Bool {
        guard completedAttempts > 0,
              completedAttempts < maximumAttempts,
              let serverCode else { return false }
        return serverCode == confirmationCode
    }

    public static func delayMilliseconds(
        afterAttempt attempt: Int,
        invitationExpiresAtMilliseconds: Int64? = nil,
        requiresInvitationExpiry: Bool = false,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> Int64? {
        guard attempt > 0, attempt < maximumAttempts else { return nil }
        guard !requiresInvitationExpiry
                || invitationExpiresAtMilliseconds != nil
        else { return nil }
        let delay = delaysMilliseconds[attempt - 1]
        if let invitationExpiresAtMilliseconds {
            guard invitationExpiresAtMilliseconds - nowMilliseconds
                    > delay + invitationExpiryHeadroomMilliseconds
            else { return nil }
        }
        return delay
    }
}

public enum MatrixNativeRtcJoinFailureCleanupAction: Hashable, Sendable {
    case disconnectProvider
    case tombstoneMembership
    case endCallKit
}

public enum MatrixNativeRtcJoinFailureCleanupContract {
    public static let orderedActions: [MatrixNativeRtcJoinFailureCleanupAction] = [
        .disconnectProvider,
        .tombstoneMembership,
        .endCallKit,
    ]
}

struct MatrixNativeRtcMembershipOperationToken: Equatable, Sendable {
    fileprivate let roomID: String
    fileprivate let generation: UInt64
}

/// Per-room ownership fence for actor-reentrant membership writes. A later
/// begin/end claim invalidates every suspended predecessor for that room, and
/// lifecycle teardown invalidates all rooms until a ready account re-enables
/// scheduling.
struct MatrixNativeRtcMembershipOperationFence: Sendable {
    private var nextGeneration: UInt64 = 0
    private var roomGenerations: [String: UInt64] = [:]
    private(set) var schedulingEnabled = true

    mutating func claim(roomID: String) -> MatrixNativeRtcMembershipOperationToken? {
        guard schedulingEnabled else { return nil }
        nextGeneration &+= 1
        roomGenerations[roomID] = nextGeneration
        return MatrixNativeRtcMembershipOperationToken(
            roomID: roomID,
            generation: nextGeneration
        )
    }

    func owns(_ token: MatrixNativeRtcMembershipOperationToken) -> Bool {
        schedulingEnabled && roomGenerations[token.roomID] == token.generation
    }

    mutating func complete(_ token: MatrixNativeRtcMembershipOperationToken) {
        guard owns(token) else { return }
        roomGenerations[token.roomID] = nil
    }

    mutating func disableAndInvalidateAll() {
        schedulingEnabled = false
        roomGenerations.removeAll()
    }

    mutating func enable() {
        schedulingEnabled = true
    }
}

/// Privacy-safe stages written by the iOS RTC breadcrumb recorder. The
/// contract deliberately has no arbitrary text or identifier-bearing fields:
/// call, room, event, user, device, payload and provider credentials never
/// enter the persisted diagnostic surface.
public enum MatrixNativeRtcBreadcrumbEvent: String, Codable, CaseIterable, Sendable {
    case startup
    case voIPTokenCallback = "voip_token_callback"
    case voIPRegistryReplay = "voip_registry_replay"
    case pushKitCallback = "pushkit_callback"
    case pushValidation = "push_validation"
    case callAcceptance = "call_acceptance"
    case callKitReport = "callkit_report"
    case pushKitCompletion = "pushkit_completion"
    case callKitAnswer = "callkit_answer"
    case audioSession = "audio_session"
    case runtimePrepare = "runtime_prepare"
    case runtimeActivate = "runtime_activate"
    case membershipScheduled = "membership_scheduled"
    case providerJoinRequestBegin = "provider_join_request_begin"
    case providerJoinRequestSuccess = "provider_join_request_success"
    case providerJoinRequestFailure = "provider_join_request_failure"
    case providerJoin = "provider_join"
    case providerConnected = "provider_connected"
    case runtimeCleanup = "runtime_cleanup"
}

public enum MatrixNativeRtcBreadcrumbReason: String, Codable, CaseIterable, Sendable {
    case started
    case available
    case unavailable
    case voIP = "voip"
    case nonVoIP = "non_voip"
    case validCall = "valid_call"
    case validCancellation = "valid_cancellation"
    case invalidKind = "invalid_kind"
    case invalidCallIdentifier = "invalid_call_identifier"
    case invalidRoomIdentifier = "invalid_room_identifier"
    case invalidEventIdentifier = "invalid_event_identifier"
    case invalidInvitationExpiry = "invalid_invitation_expiry"
    case accepted
    case rejectedNoSession = "rejected_no_session"
    case duplicateCall = "duplicate_call"
    case begin
    case success
    case error
    case activated
    case deactivated
    case cancelled
    case failed
    case completed
}

public struct MatrixNativeRtcBreadcrumb: Codable, Equatable, Sendable {
    public let timestamp: String
    public let sequence: UInt64
    public let build: String
    public let stage: MatrixNativeRtcBreadcrumbEvent
    public let reason: MatrixNativeRtcBreadcrumbReason?
    public let credentialByteCount: Int?
    public let tokenPresent: Bool?
    public let canAcceptCalls: Bool?
    public let errorDomain: String?
    public let errorCode: Int?

    public init(
        timestamp: String,
        sequence: UInt64,
        build: String,
        stage: MatrixNativeRtcBreadcrumbEvent,
        reason: MatrixNativeRtcBreadcrumbReason? = nil,
        credentialByteCount: Int? = nil,
        tokenPresent: Bool? = nil,
        canAcceptCalls: Bool? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) {
        self.timestamp = timestamp
        self.sequence = sequence
        self.build = build
        self.stage = stage
        self.reason = reason
        self.credentialByteCount = credentialByteCount.map { max(0, min($0, 4_096)) }
        self.tokenPresent = tokenPresent
        self.canAcceptCalls = canAcceptCalls
        self.errorDomain = errorDomain.map(Self.sanitizedErrorDomain)
        self.errorCode = errorCode
    }

    /// Error domains are reduced to a small category vocabulary. This keeps
    /// useful CallKit failure classification without persisting arbitrary
    /// error text that could contain identifiers or request fragments.
    public static func sanitizedErrorDomain(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("callkit") || normalized.contains("cxerror") {
            return "callkit"
        }
        if normalized == NSCocoaErrorDomain.lowercased() { return "cocoa" }
        if normalized == NSPOSIXErrorDomain.lowercased() { return "posix" }
        if normalized == NSURLErrorDomain.lowercased() { return "url" }
        return "other"
    }
}

public enum MatrixNativeDirectCallJoinOrigin: Sendable, Equatable {
    case outgoing
    case acceptedIncomingInvitation
}

public struct MatrixNativeDirectCallPeerCandidate: Sendable, Equatable {
    public let userID: String
    public let isJoined: Bool
    public let isCurrentUser: Bool
    public let isService: Bool

    public init(
        userID: String,
        isJoined: Bool,
        isCurrentUser: Bool,
        isService: Bool
    ) {
        self.userID = userID
        self.isJoined = isJoined
        self.isCurrentUser = isCurrentUser
        self.isService = isService
    }
}

public enum MatrixNativeDirectCallInvitationDecision: Sendable, Equatable {
    case skip
    case invite(userID: String)
    case reject
}

/// Auto-invitation is deliberately narrower than the manual invite surface:
/// only a newly-originated Personal Wave call with one authoritative joined
/// human peer may emit a signal. Accepted incoming calls and community Waves
/// never echo an invitation back to participants.
public enum MatrixNativeDirectCallInvitationPolicy {
    public static func decision(
        isPersonalWave: Bool,
        origin: MatrixNativeDirectCallJoinOrigin,
        peers: [MatrixNativeDirectCallPeerCandidate]
    ) -> MatrixNativeDirectCallInvitationDecision {
        guard isPersonalWave, origin == .outgoing else { return .skip }
        let eligible = peers.filter {
            $0.isJoined && !$0.isCurrentUser && !$0.isService
        }
        guard eligible.count == 1 else { return .reject }
        return .invite(userID: eligible[0].userID)
    }
}
