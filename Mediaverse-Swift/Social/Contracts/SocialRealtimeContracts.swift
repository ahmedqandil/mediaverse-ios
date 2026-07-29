import Foundation

/// Server-owned rollout declaration for Matrix-backed social capabilities.
/// Missing fields fail closed so older Westreem APIs retain current behavior.
public struct SocialRealtimeCapabilities: Decodable, Equatable, Sendable {
    public let transport: String
    public let schemaVersion: Int
    public let presence: Bool
    public let typing: Bool
    public let readReceipts: Bool
    public let offlineSend: Bool
    public let threadSubscriptions: Bool
    public let directMessages: Bool
    public let stickers: Bool
    public let voiceRipples: Bool
    public let videoRipples: Bool
    public let liveEventRooms: Bool
    public let watchParties: Bool
    public let voiceLounges: Bool

    private enum CodingKeys: String, CodingKey {
        case transport, schemaVersion, presence, typing, readReceipts, offlineSend
        case threadSubscriptions, directMessages, stickers, voiceRipples, videoRipples
        case liveEventRooms, watchParties, voiceLounges
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? "LEGACY"
        schemaVersion = max(0, try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0)
        presence = try values.decodeIfPresent(Bool.self, forKey: .presence) ?? false
        typing = try values.decodeIfPresent(Bool.self, forKey: .typing) ?? false
        readReceipts = try values.decodeIfPresent(Bool.self, forKey: .readReceipts) ?? false
        offlineSend = try values.decodeIfPresent(Bool.self, forKey: .offlineSend) ?? false
        threadSubscriptions = try values.decodeIfPresent(Bool.self, forKey: .threadSubscriptions) ?? false
        directMessages = try values.decodeIfPresent(Bool.self, forKey: .directMessages) ?? false
        stickers = try values.decodeIfPresent(Bool.self, forKey: .stickers) ?? false
        voiceRipples = try values.decodeIfPresent(Bool.self, forKey: .voiceRipples) ?? false
        videoRipples = try values.decodeIfPresent(Bool.self, forKey: .videoRipples) ?? false
        liveEventRooms = try values.decodeIfPresent(Bool.self, forKey: .liveEventRooms) ?? false
        watchParties = try values.decodeIfPresent(Bool.self, forKey: .watchParties) ?? false
        voiceLounges = try values.decodeIfPresent(Bool.self, forKey: .voiceLounges) ?? false
    }

    public var usesMatrix: Bool {
        transport.caseInsensitiveCompare("MATRIX") == .orderedSame && schemaVersion > 0
    }
}

public enum ConversationalMediaKind: String, Codable, Sendable {
    case voice = "VOICE"
    case video = "VIDEO"
}

public enum ConversationalMediaProcessingStatus: String, Decodable, Sendable {
    case preparing = "PREPARING"
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
    case unavailable = "UNAVAILABLE"
}

/// Stable, delivery-safe media metadata. URLs may be absent while processing;
/// clients must not infer readiness from the presence of a thumbnail.
public struct ConversationalMedia: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: ConversationalMediaKind
    public let status: ConversationalMediaProcessingStatus
    public let playbackURL: String?
    public let thumbnailURL: String?
    public let waveform: [Int]
    public let durationMilliseconds: Int
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let transcript: String?
    public let captionsURL: String?
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, status, waveform, durationMilliseconds, width, height, mimeType
        case transcript, failureReason
        case playbackURL = "playbackUrl"
        case thumbnailURL = "thumbnailUrl"
        case captionsURL = "captionsUrl"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(ConversationalMediaKind.self, forKey: .kind)
        status = try values.decodeIfPresent(
            ConversationalMediaProcessingStatus.self,
            forKey: .status
        ) ?? .processing
        playbackURL = try values.decodeIfPresent(String.self, forKey: .playbackURL)
        thumbnailURL = try values.decodeIfPresent(String.self, forKey: .thumbnailURL)
        waveform = (try values.decodeIfPresent([Int].self, forKey: .waveform) ?? [])
            .prefix(256)
            .map { min(max($0, 0), 1024) }
        durationMilliseconds = max(
            0,
            try values.decodeIfPresent(Int.self, forKey: .durationMilliseconds) ?? 0
        )
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        transcript = try values.decodeIfPresent(String.self, forKey: .transcript)
        captionsURL = try values.decodeIfPresent(String.self, forKey: .captionsURL)
        failureReason = try values.decodeIfPresent(String.self, forKey: .failureReason)
    }

    public var isPlayable: Bool {
        status == .ready && playbackURL?.isEmpty == false
    }
}

/// Resolves local and server gates together. This prevents a debug preference
/// from activating an incomplete server capability.
public enum SocialRealtimeRollout {
    public static func matrixEnabled(
        local: SocialFeatureConfiguration,
        server: SocialRealtimeCapabilities?
    ) -> Bool {
        local.matrixRealtimeEnabled && server?.usesMatrix == true
    }

    public static func voiceRipplesEnabled(
        local: SocialFeatureConfiguration,
        server: SocialRealtimeCapabilities?
    ) -> Bool {
        matrixEnabled(local: local, server: server)
            && local.voiceRipplesEnabled
            && server?.voiceRipples == true
    }

    public static func videoRipplesEnabled(
        local: SocialFeatureConfiguration,
        server: SocialRealtimeCapabilities?
    ) -> Bool {
        matrixEnabled(local: local, server: server)
            && local.videoRipplesEnabled
            && server?.videoRipples == true
    }
}
