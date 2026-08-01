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

public enum MatrixNativeRtcExperience: Sendable, Equatable {
    case call
    case liveStage
    case watchParty
}

public enum MatrixNativeLiveStageMode: Sendable, Equatable {
    case conversation
    case gaming
}

public enum MatrixNativeRtcParticipantRole: Sendable, Equatable {
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
