import Foundation

enum MatrixNativeAvatarContract {
    static let maximumBytes = 5 * 1_024 * 1_024

    static func accepts(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }
        let bytes = [UInt8](data.prefix(12))
        let isJPEG = bytes.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isGIF = bytes.starts(with: Array("GIF8".utf8))
        let isWebP = bytes.count >= 12
            && Array(bytes[0..<4]) == Array("RIFF".utf8)
            && Array(bytes[8..<12]) == Array("WEBP".utf8)
        return isJPEG || isPNG || isGIF || isWebP
    }
}

public enum SocialAuthority: String, Decodable, Equatable, Sendable {
    case matrix = "MATRIX"
    case westreem = "WESTREEM"
}

public enum SocialAuthorityDomain: String, Decodable, Equatable, Hashable, Sendable {
    case realtimeDelivery = "REALTIME_DELIVERY"
    case typing = "TYPING"
    case readReceipts = "READ_RECEIPTS"
    case presence = "PRESENCE"
    case roomRelations = "ROOM_RELATIONS"
    case rtcSignaling = "RTC_SIGNALING"
    case vibeDirectory = "VIBE_DIRECTORY"
    case waveConfiguration = "WAVE_CONFIGURATION"
    case publicRipplePresentation = "PUBLIC_RIPPLE_PRESENTATION"
    case events = "EVENTS"
    case energy = "ENERGY"
    case feeds = "FEEDS"
    case curation = "CURATION"
    case moderation = "MODERATION"
    case audit = "AUDIT"
    case analytics = "ANALYTICS"
    case playback = "PLAYBACK"
    case ads = "ADS"
    case affiliations = "AFFILIATIONS"
    case notifications = "NOTIFICATIONS"
    case mediaDelivery = "MEDIA_DELIVERY"
}

/// Fail-closed authority boundary supplied by Westreem with Matrix-enabled
/// responses. Realtime UI may use Matrix only when this declaration is valid.
public struct SocialAuthorityContract: Decodable, Equatable, Sendable {
    public let version: Int
    public let liveTransport: SocialAuthority
    public let canonicalProduct: SocialAuthority
    public let matrixOwns: [SocialAuthorityDomain]
    public let westreemOwns: [SocialAuthorityDomain]

    public var permitsMatrixRealtime: Bool {
        version == 1
            && liveTransport == .matrix
            && canonicalProduct == .westreem
            && Set(matrixOwns) == Set([
                .realtimeDelivery, .typing, .readReceipts,
                .presence, .roomRelations, .rtcSignaling,
            ])
            && Set([
                SocialAuthorityDomain.publicRipplePresentation,
                .events, .energy, .feeds, .curation, .moderation, .audit,
                .analytics, .playback, .ads, .affiliations, .notifications,
                .mediaDelivery,
            ]).isSubset(of: Set(westreemOwns))
    }

    public func authority(for domain: SocialAuthorityDomain) -> SocialAuthority? {
        if matrixOwns.contains(domain) { return .matrix }
        if westreemOwns.contains(domain) { return .westreem }
        return nil
    }
}

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

public enum ConversationalMediaProcessingStatus: String, Codable, Sendable {
    case preparing = "PREPARING"
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
    case unavailable = "UNAVAILABLE"
}

/// Stable, delivery-safe media metadata. URLs may be absent while processing;
/// clients must not infer readiness from the presence of a thumbnail.
public struct ConversationalMedia: Codable, Equatable, Sendable {
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

public struct ConversationalMediaUploadPreparation: Decodable, Sendable {
    public let mediaId: String
    public let uploadURL: String
    public let objectKey: String?
    public let method: String
    public let headers: [String: String]

    private enum CodingKeys: String, CodingKey {
        case mediaId, objectKey, method, headers
        case uploadURL = "uploadUrl"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try values.decode(String.self, forKey: .mediaId)
        uploadURL = try values.decode(String.self, forKey: .uploadURL)
        objectKey = try values.decodeIfPresent(String.self, forKey: .objectKey)
        method = try values.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

public struct ConversationalMediaUploadCompletion: Decodable, Sendable {
    public let media: ConversationalMedia
}

/// Credentials issued by Westreem's authenticated Matrix session broker.
/// The native Matrix foundation transfers these directly into the Rust SDK
/// session; the SDK session is then stored only in the app's protected
/// Keychain-backed session store. Tokens must never be logged.
public struct MatrixClientSession: Decodable, Equatable, Sendable {
    private static let maximumTokenLength = 8_192
    private static let maximumDeviceIDLength = 255
    private static let maximumUserIDLength = 512
    private static let maximumLifetime: TimeInterval = 24 * 60 * 60

    public let accessToken: String
    public let refreshToken: String
    public let deviceId: String
    public let userId: String
    public let homeserverURL: String
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, deviceId, userId, expiresAt
        case homeserverURL = "homeserverUrl"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        userId = try values.decode(String.self, forKey: .userId)
        homeserverURL = try values.decode(String.self, forKey: .homeserverURL)
        let rawExpiry = try values.decode(String.self, forKey: .expiresAt)
        let now = Date()
        guard
            !accessToken.isEmpty,
            accessToken.utf8.count <= Self.maximumTokenLength,
            !refreshToken.isEmpty,
            refreshToken.utf8.count <= Self.maximumTokenLength,
            !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            deviceId.utf8.count <= Self.maximumDeviceIDLength,
            userId.hasPrefix("@"),
            userId.utf8.count <= Self.maximumUserIDLength,
            let url = URL(string: homeserverURL),
            url.scheme == "https",
            let expiry = ISO8601DateFormatter().date(from: rawExpiry),
            expiry.timeIntervalSince(now) > 30,
            expiry.timeIntervalSince(now) <= Self.maximumLifetime
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .accessToken,
                in: values,
                debugDescription: "Invalid WeStreem Vibes client session"
            )
        }
        expiresAt = expiry
    }

    public func isUsable(at date: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(date) > 30
    }
}

public struct MatrixClientSessionEnvelope: Decodable, Equatable, Sendable {
    public let session: MatrixClientSession
}

/// Server-safe health response. It deliberately contains no credentials.
public struct MatrixSyncStatus: Decodable, Equatable, Sendable {
    public let available: Bool
    public let identityReady: Bool
    public let degradedMode: Bool
    public let retryAfterSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case available, identityReady, degradedMode, retryAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        available = try values.decodeIfPresent(Bool.self, forKey: .available) ?? false
        identityReady = try values.decodeIfPresent(Bool.self, forKey: .identityReady) ?? false
        degradedMode = try values.decodeIfPresent(Bool.self, forKey: .degradedMode) ?? true
        retryAfterSeconds = try values.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
            .map { min(max($0, 1), 3_600) }
    }

    public var canStartClient: Bool {
        available && identityReady && !degradedMode
    }
}

/// Additive Wave binding returned only to authorized Wave viewers.
public struct MatrixWaveBinding: Decodable, Equatable, Sendable {
    public let roomId: String
    public let syncEnabled: Bool

    private enum CodingKeys: String, CodingKey { case roomId, syncEnabled }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try values.decodeIfPresent(String.self, forKey: .roomId) ?? ""
        syncEnabled = try values.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
    }

    public var isUsable: Bool {
        syncEnabled
            && roomId.hasPrefix("!")
            && !roomId.contains("/")
            && !roomId.contains("?")
    }
}

public enum MatrixSyncConnectionState: String, Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case degraded
}

public enum RippleLocalDeliveryState: String, Codable, Equatable, Sendable {
    case queued = "QUEUED"
    case sending = "SENDING"
    case retrying = "RETRYING"
    case sent = "SENT"
    case failed = "FAILED"
}

/// View-safe local echo. It contains no Matrix credential or SDK type.
public struct PendingWaveRipple: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let vibeSlug: String
    public let waveId: String?
    public let body: String
    public let idempotencyKey: String
    public var state: RippleLocalDeliveryState
    public var attemptCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        vibeSlug: String,
        waveId: String?,
        body: String,
        idempotencyKey: String = UUID().uuidString,
        state: RippleLocalDeliveryState = .queued,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.vibeSlug = vibeSlug
        self.waveId = waveId
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.attemptCount = max(0, attemptCount)
        self.lastError = lastError
    }
}

public struct MatrixWaveActivity: Equatable, Sendable {
    public var typingUserIds: [String]
    public var unreadCount: Int
    public var latestEventId: String?

    public init(
        typingUserIds: [String] = [],
        unreadCount: Int = 0,
        latestEventId: String? = nil
    ) {
        self.typingUserIds = Array(typingUserIds.prefix(5))
        self.unreadCount = max(0, unreadCount)
        self.latestEventId = latestEventId
    }
}

/// Narrow `/sync` projection consumed by the native adapter. Unknown Matrix
/// events remain inside the adapter and never leak into SwiftUI.
public struct MatrixSyncResponse: Decodable, Equatable, Sendable {
    public let nextBatch: String
    public let joinedRooms: [String: JoinedRoom]

    public struct JoinedRoom: Decodable, Equatable, Sendable {
        public let unreadCount: Int
        public let latestEventId: String?
        public let typingUserIds: [String]

        private enum CodingKeys: String, CodingKey {
            case unreadNotifications = "unread_notifications"
            case timeline, ephemeral
        }

        private struct Unread: Decodable {
            let notificationCount: Int
            private enum CodingKeys: String, CodingKey {
                case notificationCount = "notification_count"
            }
        }

        private struct Events: Decodable {
            let events: [Event]
        }

        private struct Event: Decodable {
            let type: String
            let eventId: String?
            let content: Content?
            private enum CodingKeys: String, CodingKey {
                case type, content
                case eventId = "event_id"
            }
        }

        private struct Content: Decodable {
            let userIds: [String]
            private enum CodingKeys: String, CodingKey { case userIds = "user_ids" }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                userIds = try values.decodeIfPresent([String].self, forKey: .userIds) ?? []
            }
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            unreadCount = max(
                0,
                try values.decodeIfPresent(Unread.self, forKey: .unreadNotifications)?
                    .notificationCount ?? 0
            )
            latestEventId = try values.decodeIfPresent(Events.self, forKey: .timeline)?
                .events.last?.eventId
            typingUserIds = Array(
                (try values.decodeIfPresent(Events.self, forKey: .ephemeral)?
                    .events
                    .last(where: { $0.type == "m.typing" })?
                    .content?
                    .userIds ?? [])
                    .prefix(5)
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case nextBatch = "next_batch", rooms }
    private struct Rooms: Decodable { let join: [String: JoinedRoom] }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nextBatch = try values.decode(String.self, forKey: .nextBatch)
        joinedRooms = try values.decodeIfPresent(Rooms.self, forKey: .rooms)?.join ?? [:]
    }
}

public enum MatrixClientError: Error, Equatable, Sendable {
    case disabled
    case invalidResponse
    case unauthorized
    case unavailable
}

/// Retained only for the pre-v2 migration comparison path.
///
/// Matrix-native Vibes must use `MatrixRustSDKVibesProvider`. This legacy
/// protocol client fails closed as soon as the native ownership cutover is
/// enabled so it can never become a second Matrix authority.
@available(*, deprecated, message: "Use MatrixRustSDKVibesProvider for Matrix-native Vibes")
public actor MatrixWaveClient {
    private struct TypingRequest: Encodable {
        let typing: Bool
        let timeout: Int
    }

    private let sessionBroker: any LegacySocialTransport
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private var session: MatrixClientSession?
    private var syncToken: String?
    private var typingState: [String: (isTyping: Bool, sentAt: Date)] = [:]

    public init(
        sessionBroker: any LegacySocialTransport,
        urlSession: URLSession = .shared
    ) {
        self.sessionBroker = sessionBroker
        self.urlSession = urlSession
    }

    public func connect(deviceName: String = "Westreem iOS") async throws {
        guard !SocialFeatureConfiguration.runtime().matrixNativeVibesEnabled else {
            throw MatrixClientError.disabled
        }
        let body = try JSONEncoder().encode(["deviceName": String(deviceName.prefix(120))])
        let data = try await sessionBroker.socialPostData(path: "/api/matrix/session", body: body)
        let envelope = try decoder.decode(MatrixClientSessionEnvelope.self, from: data)
        guard envelope.session.isUsable() else { throw MatrixClientError.invalidResponse }
        session = envelope.session
        syncToken = nil
        typingState = [:]
    }

    public func disconnect() {
        session = nil
        syncToken = nil
        typingState = [:]
    }

    public func sync(roomId: String, timeoutMilliseconds: Int = 25_000) async throws -> MatrixWaveActivity {
        guard
            let session,
            session.isUsable(),
            roomId.hasPrefix("!"),
            !roomId.contains("/"),
            !roomId.contains("?")
        else {
            throw MatrixClientError.disabled
        }
        var query = [
            URLQueryItem(name: "timeout", value: String(min(max(timeoutMilliseconds, 0), 30_000)))
        ]
        if let syncToken {
            query.append(URLQueryItem(name: "since", value: syncToken))
        }
        let data = try await request(
            session: session,
            method: "GET",
            path: "/_matrix/client/v3/sync",
            query: query
        )
        let response = try decoder.decode(MatrixSyncResponse.self, from: data)
        syncToken = response.nextBatch
        guard let room = response.joinedRooms[roomId] else {
            return MatrixWaveActivity()
        }
        return MatrixWaveActivity(
            typingUserIds: room.typingUserIds.filter { $0 != session.userId },
            unreadCount: room.unreadCount,
            latestEventId: room.latestEventId
        )
    }

    public func setTyping(_ typing: Bool, roomId: String, timeoutMilliseconds: Int = 6_000) async throws {
        guard
            let session,
            session.isUsable(),
            roomId.hasPrefix("!"),
            !roomId.contains("/"),
            !roomId.contains("?")
        else {
            throw MatrixClientError.disabled
        }
        if let previous = typingState[roomId],
           previous.isTyping == typing,
           Date().timeIntervalSince(previous.sentAt) < 4 {
            return
        }
        let body = try JSONEncoder().encode(TypingRequest(
            typing: typing,
            timeout: typing ? min(max(timeoutMilliseconds, 1_000), 30_000) : 0
        ))
        _ = try await request(
            session: session,
            method: "PUT",
            path: "/_matrix/client/v3/rooms/\(roomId)/typing/\(session.userId)",
            body: body
        )
        typingState[roomId] = (typing, Date())
    }

    public func markRead(roomId: String, eventId: String) async throws {
        guard
            let session,
            session.isUsable(),
            roomId.hasPrefix("!"),
            !roomId.contains("/"),
            !roomId.contains("?"),
            eventId.hasPrefix("$"),
            !eventId.contains("/"),
            !eventId.contains("?")
        else {
            throw MatrixClientError.disabled
        }
        _ = try await request(
            session: session,
            method: "POST",
            path: "/_matrix/client/v3/rooms/\(roomId)/receipt/m.read/\(eventId)",
            body: Data("{}".utf8)
        )
    }

    private func request(
        session: MatrixClientSession,
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: session.homeserverURL) else {
            throw MatrixClientError.invalidResponse
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw MatrixClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixClientError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            self.session = nil
            throw MatrixClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MatrixClientError.unavailable
        }
        return data
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

    public static func waveRealtimeEnabled(
        local: SocialFeatureConfiguration,
        server: SocialRealtimeCapabilities?,
        binding: MatrixWaveBinding?,
        authority: SocialAuthorityContract?
    ) -> Bool {
        matrixEnabled(local: local, server: server)
            && authority?.permitsMatrixRealtime == true
            && local.wavePresenceEnabled
            && server?.typing == true
            && server?.readReceipts == true
            && server?.offlineSend == true
            && binding?.isUsable == true
    }
}

// MARK: - Phase 2 server-authoritative collaboration

public struct CollectionContributionUser: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
}

public struct CollectionContributionComment: Decodable, Identifiable, Sendable {
    public let id: String
    public let body: String
    public let createdAt: String?
    public let user: CollectionContributionUser?
}

public struct CollectionContributionVotes: Decodable, Sendable {
    public let score: Int
    public let count: Int
    public let viewerValue: Int
}

public struct CollectionContribution: Decodable, Identifiable, Sendable {
    public let id: String
    public let targetType: String
    public let targetId: String
    public let proposedPosition: Int?
    public let note: String?
    public let status: String
    public let reviewNote: String?
    public let createdAt: String?
    public let reviewedAt: String?
    public let proposedBy: CollectionContributionUser?
    public let comments: [CollectionContributionComment]
    public let votes: CollectionContributionVotes

    private enum CodingKeys: String, CodingKey {
        case id, targetType, targetId, proposedPosition, note, status, reviewNote
        case createdAt, reviewedAt, proposedBy, comments, votes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        targetType = try values.decode(String.self, forKey: .targetType)
        targetId = try values.decode(String.self, forKey: .targetId)
        proposedPosition = try values.decodeIfPresent(Int.self, forKey: .proposedPosition)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "PENDING"
        reviewNote = try values.decodeIfPresent(String.self, forKey: .reviewNote)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        reviewedAt = try values.decodeIfPresent(String.self, forKey: .reviewedAt)
        proposedBy = try values.decodeIfPresent(CollectionContributionUser.self, forKey: .proposedBy)
        comments = try values.decodeIfPresent([CollectionContributionComment].self, forKey: .comments) ?? []
        votes = try values.decodeIfPresent(CollectionContributionVotes.self, forKey: .votes)
            ?? .init(score: 0, count: 0, viewerValue: 0)
    }
}

public struct CollectionContributionCapabilities: Decodable, Sendable {
    public let canSuggest: Bool
    public let canReview: Bool
}

public struct CollectionContributionsResponse: Decodable, Sendable {
    public let capabilities: CollectionContributionCapabilities
    public let contributions: [CollectionContribution]
}

public struct CollectionContributionResponse: Decodable, Sendable {
    public let contribution: CollectionContribution
}

public struct PollLeaderboardUser: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
}

public struct PollLeaderboardEntry: Decodable, Identifiable, Sendable {
    public var id: String { user.id }
    public let rank: Int
    public let user: PollLeaderboardUser
    public let score: Int
}

public struct InteractivePollViewerVote: Decodable, Sendable {
    public let optionId: String
    public let score: Int
    public let isCorrect: Bool?
    public let answeredAt: String?
}

public struct InteractivePollOptionResult: Decodable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let voteCount: Int?
}

public struct InteractivePollLeaderboardResponse: Decodable, Sendable {
    public let serverTime: String
    public let mode: String
    public let anonymous: Bool
    public let reveal: Bool
    public let correctOptionId: String?
    public let options: [InteractivePollOptionResult]
    public let viewerVotes: [InteractivePollViewerVote]
    public let leaderboard: [PollLeaderboardEntry]?
}

public struct ApprovedWidgetResolution: Decodable, Sendable {
    public let key: String
    public let name: String
    public let version: Int
    public let platform: String
    public let tokenScopes: [String]

    private enum CodingKeys: String, CodingKey {
        case key, name, version, platform, tokenScopes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(Int.self, forKey: .version)
        platform = try values.decode(String.self, forKey: .platform)
        tokenScopes = try values.decodeIfPresent([String].self, forKey: .tokenScopes) ?? []
    }
}

public struct ApprovedWidgetResponse: Decodable, Sendable {
    public let allowed: Bool
    public let reason: String?
    public let widget: ApprovedWidgetResolution?

    /// Native presentation is permitted only for an explicit iOS registry match.
    public var canPresentNatively: Bool {
        allowed && widget?.platform == "IOS" && widget?.key.isEmpty == false
    }
}

public struct WaveSummaryCitation: Decodable, Identifiable, Sendable {
    public let id: String
    public let preview: String
    public let author: String
    public let href: String
}

public struct WaveConversationSummary: Decodable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let sourceStartedAt: String?
    public let sourceEndedAt: String?
    public let generatedAt: String?
    public let publishedAt: String?
    public let citations: [WaveSummaryCitation]
}

public struct WaveConversationSummariesResponse: Decodable, Sendable {
    public let summaries: [WaveConversationSummary]
}
