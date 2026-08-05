import Foundation
import MatrixRustSDK
import OSLog

private let matrixSpaceDirectoryLogger = Logger(
    subsystem: "com.westreem.mediaverse",
    category: "MatrixSpaceDirectory"
)

struct MatrixVibeDirectoryPage: Equatable, Sendable {
    let spaces: [MatrixVibeSummary]
    let nextCursor: String?
}

struct MatrixPublicVibeDirectoryPage: Equatable, Sendable {
    let spaces: [MatrixPublicVibeSummary]
    let loadedPages: UInt32
    let hasMore: Bool
}

struct MatrixPublicVibeSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let topic: String?
    let avatarURL: String?
    let canonicalAlias: String?
    let joinedMemberCount: UInt64
    let membership: MatrixNativeMembership
    let mayJoin: Bool
    let viaServers: [String]
}

struct MatrixNativeCreatedRoom: Equatable, Sendable {
    let roomID: String
    let matrixSpaceID: String
    let entityType: String
    let registrationPending: Bool
    let failedInvitationUserIDs: [String]
}

struct MatrixWaveDirectoryPage: Equatable, Sendable {
    let rooms: [MatrixWaveSummary]
}

enum MatrixNativeSpaceDirectoryError: Error, Equatable, Sendable {
    case stalePurgedSpace
}

private struct MatrixNativeSpaceDirectoryClientErrorMetadata {
    let domain: String
    let code: String
    let kindIsNotFound: Bool

    init(_ error: ClientError) {
        switch error {
        case let .MatrixApi(kind, code, _, _):
            domain = "matrix_api"
            self.code = Self.safeCode(code)
            kindIsNotFound = kind == .notFound
        case let .Generic(_, details):
            domain = "client_generic"
            code = Self.safeCode(Self.errorCode(inJSONDetails: details) ?? "GENERIC")
            kindIsNotFound = false
        case .ContentScanner:
            domain = "content_scanner"
            code = "CONTENT_SCANNER"
            kindIsNotFound = false
        }
    }

    private static func errorCode(inJSONDetails details: String?) -> String? {
        guard
            let details,
            let data = details.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["errcode"] as? String
    }

    private static func safeCode(_ value: String) -> String {
        let normalized = value.uppercased()
        guard
            !normalized.isEmpty,
            normalized.utf8.count <= 64,
            normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else {
            return "UNCLASSIFIED"
        }
        return normalized
    }
}

struct MatrixNativeLoungeParticipant: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let avatarURL: String?
}

struct MatrixTimelinePage: Codable, Equatable, Sendable {
    let roomID: String
    let items: [MatrixTimelineItem]
    let nextToken: String?
    let projectionCacheKey: String
    let suppressedEventIDs: Set<String>

    init(
        roomID: String,
        items: [MatrixTimelineItem],
        nextToken: String?,
        projectionCacheKey: String? = nil,
        suppressedEventIDs: Set<String> = []
    ) {
        self.roomID = roomID
        self.items = items
        self.nextToken = nextToken
        self.projectionCacheKey = projectionCacheKey
            ?? MatrixWaveEstablishmentContract.cacheKey(
                roomID: roomID,
                manifestHash: nil
            )
        self.suppressedEventIDs = suppressedEventIDs
    }
}

struct MatrixNativeTimelineSnapshot: Sendable {
    let items: [MatrixTimelineItem]
    let hasMore: Bool
    let projectionCacheKey: String
    let suppressedEventIDs: Set<String>
}

/// Summary of a single thread inside a Wave, sourced from the Matrix Rust
/// SDK's server-backed `Room.threadListService()` and enriched from a focused
/// thread timeline for actions and participation.
///
/// See `MatrixVibesRepositoryFoundation.threadSummaries(roomID:)`.
public struct MatrixNativeThreadSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let rootEventID: String
    public let rootBody: String
    public let rootSenderName: String
    public let rootSenderAvatarURL: String?
    public let rootTimestamp: Date
    public let replyCount: Int
    public let lastReplyAt: Date
    public let lastReplySenderName: String?
    public let lastReplyBody: String?
    public let participants: [String]
    /// Element's "My threads" filter includes a thread when the current user
    /// authored either the root or a reply. This is derived from the focused
    /// SDK thread timeline, never from display-name matching.
    public let isParticipated: Bool
    /// True when the last reply arrived after the current user last read
    /// this thread. Currently derived from `replyCount > 0`; a future
    /// per-thread receipt (once the SDK surfaces it) can tighten this.
    public let hasUnread: Bool

    public init(
        id: String,
        rootEventID: String,
        rootBody: String,
        rootSenderName: String,
        rootSenderAvatarURL: String?,
        rootTimestamp: Date,
        replyCount: Int,
        lastReplyAt: Date,
        lastReplySenderName: String?,
        lastReplyBody: String?,
        participants: [String],
        isParticipated: Bool,
        hasUnread: Bool
    ) {
        self.id = id
        self.rootEventID = rootEventID
        self.rootBody = rootBody
        self.rootSenderName = rootSenderName
        self.rootSenderAvatarURL = rootSenderAvatarURL
        self.rootTimestamp = rootTimestamp
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.lastReplySenderName = lastReplySenderName
        self.lastReplyBody = lastReplyBody
        self.participants = participants
        self.isParticipated = isParticipated
        self.hasUnread = hasUnread
    }
}

enum MatrixTimelineMerge {
    /// Merges a freshly loaded timeline page into previously known items.
    ///
    /// The loaded page is the authoritative snapshot of the live SDK
    /// timeline: known items are updated in place, new items are appended
    /// (or prepended history is deduplicated when paginating), and local
    /// echoes that no longer exist in the live timeline are dropped —
    /// otherwise a message that materialized under its remote event ID
    /// would render twice next to its stale transaction-ID copy.
    static func items(
        existing: [MatrixTimelineItem],
        loaded: [MatrixTimelineItem],
        paginate: Bool
    ) -> [MatrixTimelineItem] {
        guard !existing.isEmpty else { return loaded }
        let loadedIDs = Set(loaded.map(\.id))
        let retained = existing.filter { item in
            if case .transactionID = item.reference {
                return loadedIDs.contains(item.id)
            }
            return true
        }

        if paginate {
            var seen = Set<String>()
            var merged: [MatrixTimelineItem] = []
            for item in loaded + retained where seen.insert(item.id).inserted {
                merged.append(item)
            }
            return merged
        }

        var merged: [MatrixTimelineItem] = []
        var indexesByID: [String: Int] = [:]
        for item in retained where indexesByID[item.id] == nil {
            indexesByID[item.id] = merged.count
            merged.append(item)
        }
        for item in loaded {
            if let index = indexesByID[item.id] {
                merged[index] = item
            } else {
                indexesByID[item.id] = merged.count
                merged.append(item)
            }
        }
        return merged
    }
}

struct MatrixNativeWaveRulesSnapshot: Equatable, Sendable {
    let state: MatrixNativeWaveRulesState?
    let mayEdit: Bool
}

struct MatrixNativeWaveMember: Identifiable, Equatable, Sendable {
    var id: String { userID }
    let userID: String
    let displayName: String
    let avatarURL: String?
    let role: MatrixNativeWaveMemberRole
    let state: MatrixNativeWaveMemberState
    let isCurrentUser: Bool
    let isService: Bool
    let statusEmoji: String?
    let statusText: String?
}

struct MatrixNativeWaveManagementSnapshot: Equatable, Sendable {
    let name: String
    let topic: String
    let avatarURL: String?
    let access: MatrixNativeWaveAccess
    let restrictedParentSpaceID: String?
    let history: MatrixNativeWaveHistory
    let notificationMode: MatrixNativeWaveNotificationMode
    let isEncrypted: Bool
    let mayEditProfile: Bool
    let mayEditAccess: Bool
    let mayEditHistory: Bool
    let mayInvite: Bool
    let mayManageRoles: Bool
    let mayKick: Bool
    let mayBan: Bool
}

struct MatrixNativeWaveSearchResult: Identifiable, Equatable, Sendable {
    var id: String { "\(roomID)\u{0}\(eventID)" }
    let roomID: String
    let eventID: String
    let senderID: String
    let senderDisplayName: String
    let body: String
    let timestamp: Date
}

// MARK: - Watch Party (com.westreem.watch_party.v1)

/// Playback state for a Wave-hosted synchronized watch party.
///
/// WeStreem branding: a Watch Party is hosted inside a Wave (Matrix room)
/// and streams a WeStreem HLS video with a designated host controlling
/// play/pause. Non-hosts observe and can re-sync to the host's playhead.
enum MatrixNativeWatchPartyPlaybackState: String, Sendable, Equatable {
    case playing
    case paused
}

/// A snapshot of the current watch party state event
/// (`com.westreem.watch_party.v1`, state key `""`).
///
/// Absent value means no active watch party. `endedAt != nil` means the
/// most recent watch party has ended and the room can start a new one.
struct MatrixNativeWatchPartyState: Sendable, Equatable {
    let videoId: String
    let videoUrl: String?
    let startedBy: String?
    let host: String?
    let playbackState: MatrixNativeWatchPartyPlaybackState
    let playheadMs: Int64
    let startedAt: Int64
    let lastUpdatedAt: Int64?
    let playbackEpoch: String?
    let sequence: Int64?
    let endedAt: Int64?

    var isActive: Bool { endedAt == nil }
    var controllingUserID: String? {
        MatrixWatchPartyCrossClientVersion.controllingUserID(
            host: host,
            startedBy: startedBy
        )
    }
}

// MARK: - Live Stage (com.westreem.live.stage.v1 + speaker.v1)

/// Whether a live stage is currently open or has ended.
enum MatrixNativeLiveStageStatus: String, Sendable, Equatable {
    case live
    case ended
}

/// Snapshot of a live stage state event (`com.westreem.live.stage.v1`,
/// state key `""`). Hosts drive the stage; speakers are the users currently
/// permitted to talk in the LiveKit lounge.
struct MatrixNativeLiveStageState: Sendable, Equatable {
    let status: MatrixNativeLiveStageStatus
    let title: String
    let hosts: [String]
    let speakers: [String]
    let startedAt: Int64
    let endedAt: Int64?
    let stageEpoch: String?
    let sequence: Int64
    let updatedAt: Int64

    init(
        status: MatrixNativeLiveStageStatus,
        title: String,
        hosts: [String],
        speakers: [String],
        startedAt: Int64,
        endedAt: Int64?,
        stageEpoch: String? = nil,
        sequence: Int64 = 0,
        updatedAt: Int64? = nil
    ) {
        self.status = status
        self.title = title
        self.hosts = hosts
        self.speakers = speakers
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stageEpoch = stageEpoch
        self.sequence = sequence
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    var isLive: Bool { status == .live && endedAt == nil }
}

/// The three states a per-user `com.westreem.live.speaker.v1` state event
/// can take. The `stateKey` for these events is the target user's Matrix ID.
enum MatrixNativeSpeakerRole: String, Sendable, Equatable {
    case speaker
    case request
    case denied
}

/// One per-user speaker record read from `com.westreem.live.speaker.v1`
/// state events. `id` == `userId` so a request drawer can dedupe by user.
struct MatrixNativeSpeakerRequest: Identifiable, Sendable, Equatable {
    var id: String { userId }
    let userId: String
    let role: MatrixNativeSpeakerRole
    let requestedAt: Int64
}

// MARK: - Wire-level contracts

enum MatrixNativeWatchPartyContract {
    static let eventType = "com.westreem.watch_party.v1"

    static func encode(_ state: MatrixNativeWatchPartyState) throws -> String {
        var content: [String: Any] = [
            "schema_version": 1,
            "videoId": state.videoId,
            "playback_state": state.playbackState.rawValue,
            "playhead_ms": state.playheadMs,
            "started_at": state.startedAt,
        ]
        // Playback URLs are viewer-specific revocable WeStreem leases and must
        // never be copied into Matrix room state.
        if let by = state.startedBy { content["started_by"] = by }
        if let host = state.host { content["host"] = host }
        if let updated = state.lastUpdatedAt { content["last_updated_at"] = updated }
        if let epoch = state.playbackEpoch { content["playback_epoch"] = epoch }
        if let sequence = state.sequence { content["sequence"] = sequence }
        if let ended = state.endedAt { content["ended_at"] = ended }
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode(contentJSON: String) throws
        -> MatrixNativeWatchPartyState {
        guard let data = contentJSON.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw MatrixNativeWaveActionError.unavailable
        }
        guard let videoId = raw["videoId"] as? String,
              let playbackRaw = raw["playback_state"] as? String,
              let playback = MatrixNativeWatchPartyPlaybackState(
                rawValue: playbackRaw
              ) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        return MatrixNativeWatchPartyState(
            videoId: videoId,
            videoUrl: raw["videoUrl"] as? String,
            startedBy: raw["started_by"] as? String,
            host: raw["host"] as? String,
            playbackState: playback,
            playheadMs: (raw["playhead_ms"] as? NSNumber)?.int64Value ?? 0,
            startedAt: (raw["started_at"] as? NSNumber)?.int64Value ?? 0,
            lastUpdatedAt: (raw["last_updated_at"] as? NSNumber)?.int64Value,
            playbackEpoch: raw["playback_epoch"] as? String,
            sequence: (raw["sequence"] as? NSNumber)?.int64Value,
            endedAt: (raw["ended_at"] as? NSNumber)?.int64Value
        )
    }
}

enum MatrixNativeLiveStageContract {
    static let stageEventType = "com.westreem.live.stage.v1"
    static let speakerEventType = "com.westreem.live.speaker.v1"

    static func encodeStage(_ state: MatrixNativeLiveStageState) throws -> String {
        var content: [String: Any] = [
            "status": state.status.rawValue,
            "title": state.title,
            "hosts": state.hosts,
            "speakers": state.speakers,
            "startedAt": state.startedAt,
        ]
        if let ended = state.endedAt { content["endedAt"] = ended }
        if let epoch = state.stageEpoch { content["stageEpoch"] = epoch }
        content["sequence"] = state.sequence
        content["updatedAt"] = state.updatedAt
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeStage(contentJSON: String) throws
        -> MatrixNativeLiveStageState {
        guard let data = contentJSON.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw MatrixNativeWaveActionError.unavailable
        }
        guard let statusRaw = raw["status"] as? String,
              let status = MatrixNativeLiveStageStatus(rawValue: statusRaw) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        return MatrixNativeLiveStageState(
            status: status,
            title: (raw["title"] as? String) ?? "",
            hosts: (raw["hosts"] as? [String]) ?? [],
            speakers: (raw["speakers"] as? [String]) ?? [],
            startedAt: (raw["startedAt"] as? NSNumber)?.int64Value ?? 0,
            endedAt: (raw["endedAt"] as? NSNumber)?.int64Value,
            stageEpoch: raw["stageEpoch"] as? String,
            sequence: (raw["sequence"] as? NSNumber)?.int64Value ?? 0,
            updatedAt: (raw["updatedAt"] as? NSNumber)?.int64Value
        )
    }

    static func encodeSpeaker(
        _ request: MatrixNativeSpeakerRequest
    ) throws -> String {
        let content: [String: Any] = [
            "role": request.role.rawValue,
            "requestedAt": request.requestedAt,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeSpeaker(
        userId: String,
        contentJSON: String
    ) throws -> MatrixNativeSpeakerRequest {
        guard let data = contentJSON.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw MatrixNativeWaveActionError.unavailable
        }
        guard let roleRaw = raw["role"] as? String,
              let role = MatrixNativeSpeakerRole(rawValue: roleRaw) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        return MatrixNativeSpeakerRequest(
            userId: userId,
            role: role,
            requestedAt: (raw["requestedAt"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

struct MatrixVibeSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let topic: String?
    let avatarURL: String?
    let joinedMemberCount: UInt64
    let membership: MatrixNativeMembership
    /// Cached unread notification count. Populated when available from the room info;
    /// defaults to 0 so sorting by unread degrades gracefully to alphabetical for Vibes.
    var unreadCount: Int
    /// ISO-8601 timestamp of the most recent event in this Vibe.
    /// Nil when unavailable; activity-sort falls back to alphabetical order.
    var lastActivityAt: String?

    init(
        id: String,
        name: String,
        topic: String?,
        avatarURL: String?,
        joinedMemberCount: UInt64,
        membership: MatrixNativeMembership,
        unreadCount: Int = 0,
        lastActivityAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.joinedMemberCount = joinedMemberCount
        self.membership = membership
        self.unreadCount = unreadCount
        self.lastActivityAt = lastActivityAt
    }
}

enum MatrixNativeInvitationKind: String, Equatable, Sendable {
    case vibe
    case wave
    case personalWave
}

struct MatrixNativeInvitationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let topic: String?
    let avatarURL: String?
    let kind: MatrixNativeInvitationKind
    let isEncrypted: Bool
    let inviterUserID: String?
    let inviterName: String
    let inviterAvatarURL: String?
    let inviterIsBlocked: Bool

    var canAccept: Bool {
        MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: MatrixInvitationKind(rawValue: kind.rawValue) ?? .wave,
            isEncrypted: isEncrypted,
            inviterIsBlocked: inviterIsBlocked,
            inviterUserID: inviterUserID
        ).canAccept
    }
}

struct MatrixWaveSummary: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let topic: String?
    let avatarURL: String?
    let joinedMemberCount: UInt64
    let membership: MatrixNativeMembership
    let isNestedSpace: Bool
    let isDirect: Bool
    let isEncrypted: Bool
    let unreadCount: UInt64
    /// Matrix-Rust's latest cached event timestamp, used only for inbox ordering.
    /// Nil means the SDK has no locally available activity for this room yet.
    let lastActivity: Date?
    let activeCallParticipantCount: Int
    let activeCallIntent: MatrixNativeRtcIntent?
    let activeCallParticipants: [MatrixNativeLoungeParticipant]

    init(
        id: String,
        name: String,
        topic: String?,
        avatarURL: String?,
        joinedMemberCount: UInt64,
        membership: MatrixNativeMembership,
        isNestedSpace: Bool,
        isDirect: Bool = false,
        isEncrypted: Bool = false,
        unreadCount: UInt64 = 0,
        lastActivity: Date? = nil,
        activeCallParticipantCount: Int = 0,
        activeCallIntent: MatrixNativeRtcIntent? = nil,
        activeCallParticipants: [MatrixNativeLoungeParticipant] = []
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.joinedMemberCount = joinedMemberCount
        self.membership = membership
        self.isNestedSpace = isNestedSpace
        self.isDirect = isDirect
        self.isEncrypted = isEncrypted
        self.unreadCount = unreadCount
        self.lastActivity = lastActivity
        self.activeCallParticipantCount = max(0, activeCallParticipantCount)
        self.activeCallIntent = activeCallIntent
        self.activeCallParticipants = Array(activeCallParticipants.prefix(3))
    }
}

enum MatrixNativeMembership: String, Codable, Equatable, Hashable, Sendable {
    case joined
    case invited
    case left
    case unknown
}

enum MatrixNativeLocalSendState: Codable, Equatable, Sendable {
    case sending
    case failed(isRecoverable: Bool)
    case sent
}

enum MatrixNativeMessageKind: Codable, Equatable, Sendable {
    case text
    case notice
    case emote
    case image
    case audio
    case video
    case file
    case gallery
    case location
    case poll
    case sticker
    case westreemReference
    case redacted
    case unableToDecrypt
    case unavailablePinned
    case unsupported
}

enum MatrixNativeEventReference: Codable, Equatable, Sendable {
    case eventID(String)
    case transactionID(String)

    var remoteEventID: String? {
        guard case let .eventID(value) = self else { return nil }
        return value
    }
}

struct MatrixNativeEnergySummary: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let count: Int
    let isSelectedByCurrentUser: Bool
}

struct MatrixNativeReplyPreview: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let senderDisplayName: String
    let body: String
    let timestamp: Date
}

struct MatrixNativeTimelineActions: Codable, Equatable, Sendable {
    let canReply: Bool
    let canAddEnergy: Bool
    let canEdit: Bool
    let canRedact: Bool
    let canReport: Bool
    let canPin: Bool
    let isPinned: Bool

    static let unavailable = Self(
        canReply: false,
        canAddEnergy: false,
        canEdit: false,
        canRedact: false,
        canReport: false,
        canPin: false,
        isPinned: false
    )
}

struct MatrixTimelineItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let reference: MatrixNativeEventReference
    let senderID: String
    let senderDisplayName: String
    let senderAvatarURL: String?
    let body: String
    let kind: MatrixNativeMessageKind
    let timestamp: Date
    let isOwn: Bool
    let isEdited: Bool
    let localSendState: MatrixNativeLocalSendState?
    let reactionCount: Int
    let energy: [MatrixNativeEnergySummary]
    let readReceiptCount: Int
    /// Matrix-authoritative public receipts attached to this exact event.
    /// User IDs are retained so the UI can resolve current room-member names
    /// and avatars; ignored users and our own receipt are excluded.
    let readReceiptUserIDs: [String]
    let threadReplyCount: UInt64
    let replyPreviews: [MatrixNativeReplyPreview]
    let actions: MatrixNativeTimelineActions
    let media: [MatrixNativeMediaDescriptor]
    let poll: MatrixNativePollDescriptor?
    let westreemReference: MatrixNativeWestreemReferenceV1?
}

struct MatrixOutboundEvent: Equatable, Sendable {
    let eventType: String
    let contentJSON: String
    let transactionID: String
}

struct MatrixSentEvent: Equatable, Sendable {
    let roomID: String
    /// The SDK send queue exposes the transaction ID before the remote echo
    /// exists. This value intentionally remains an optimistic local ID.
    let eventID: String
}

struct MatrixNativeEchoDeliveryResult: Equatable, Sendable {
    let deliveredRoomIDs: [String]
    let failedRoomIDs: [String]
}

protocol MatrixVibesSDKProviding: Sendable {
    func topLevelSpaces() async throws -> [MatrixVibeSummary]
    func pendingInvitations() async throws -> [MatrixNativeInvitationSummary]
    func publicSpaces(query: String?, loadNextPage: Bool) async throws
        -> MatrixPublicVibeDirectoryPage
    func publicSpacePreview(_ space: MatrixPublicVibeSummary) async throws
        -> MatrixPublicVibeSummary
    func joinPublicSpace(_ space: MatrixPublicVibeSummary) async throws
    func leavePublicSpace(_ space: MatrixPublicVibeSummary) async throws
    func createVibe(_ draft: MatrixNativeRoomCreationDraft) async throws
        -> MatrixNativeCreatedRoom
    func createWave(
        inSpaceID spaceID: String,
        draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom
    func registerCreatedRoom(_ room: MatrixNativeCreatedRoom) async throws
        -> MatrixNativeCreatedRoom
    func spacePermissions(spaceID: String) async throws
        -> MatrixNativeSpacePermissionSnapshot
    func inviteUsers(_ userIDs: [String], roomID: String) async throws -> [String]
    func childRooms(spaceID: String) async throws -> [MatrixWaveSummary]
    func localWaveActivity(
        rooms: [MatrixWaveSummary]
    ) async throws -> [MatrixWaveSummary]
    func waveRules(roomID: String) async throws -> MatrixNativeWaveRulesSnapshot
    func updateWaveRules(
        roomID: String,
        state: MatrixNativeWaveRulesState
    ) async throws
    func waveManagement(roomID: String) async throws
        -> MatrixNativeWaveManagementSnapshot
    func updateWaveProfile(
        roomID: String,
        name: String,
        topic: String,
        avatar: MatrixNativeUpload?,
        removeAvatar: Bool
    ) async throws
    func updateWaveAccess(
        roomID: String,
        access: MatrixNativeWaveAccess,
        history: MatrixNativeWaveHistory,
        restrictedParentSpaceID: String?
    ) async throws
    func leaveWave(roomID: String) async throws
    func waveMembers(roomID: String) async throws -> [MatrixNativeWaveMember]
    func joinedWaveDestinations(excludingRoomID: String) async throws
        -> [MatrixWaveSummary]
    func typingUpdates(roomID: String) async throws -> AsyncStream<[String]>
    func updateWaveMemberRole(
        roomID: String,
        userID: String,
        role: MatrixNativeWaveMemberRole
    ) async throws
    func moderateWaveMember(
        roomID: String,
        userID: String,
        action: MatrixNativeWaveModerationAction,
        reason: String?
    ) async throws
    func updateWaveNotification(
        roomID: String,
        mode: MatrixNativeWaveNotificationMode
    ) async throws
    func searchWave(
        roomID: String,
        query: String
    ) async throws -> [MatrixNativeWaveSearchResult]
    func pinnedItems(roomID: String) async throws -> [MatrixTimelineItem]
    func timelineItems(roomID: String, paginateBackwards: Bool) async throws
        -> MatrixNativeTimelineSnapshot
    func releaseTimeline(roomID: String) async
    func releaseThreadTimeline(roomID: String, rootEventID: String) async
    func threadItems(
        roomID: String,
        rootEventID: String,
        paginateBackwards: Bool
    ) async throws -> [MatrixTimelineItem]
    func threadSummaries(roomID: String) async throws -> [MatrixNativeThreadSummary]
    func eventItem(roomID: String, eventID: String) async throws -> MatrixTimelineItem
    func sendThreadReply(
        roomID: String,
        rootEventID: String,
        body: String,
        mentions: [MatrixNativeMentionTarget]
    ) async throws
    func sendText(
        roomID: String,
        body: String,
        mentions: [MatrixNativeMentionTarget],
        transactionID: String
    ) async throws
    func toggleEnergy(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        key: String
    ) async throws -> Bool
    func editText(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        body: String
    ) async throws
    func redact(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        reason: String?
    ) async throws
    func report(
        roomID: String,
        eventID: String,
        senderID: String,
        reason: String
    ) async throws
    func setPinned(
        roomID: String,
        eventID: String,
        senderID: String,
        pinned: Bool
    ) async throws
    func sendRaw(
        roomID: String,
        eventType: String,
        contentJSON: String,
        transactionID: String
    ) async throws
    func sendLiveStageAction(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String
    func sendRtcCallSignal(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String
    func retrySend(transactionID: String) async throws
    func sendAttachments(
        roomID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        transactionID: String
    ) async throws
    func sendThreadAttachments(
        roomID: String,
        rootEventID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        transactionID: String
    ) async throws
    func createPoll(
        roomID: String,
        question: String,
        options: [String],
        maxSelections: UInt64,
        isDisclosed: Bool,
        transactionID: String
    ) async throws
    func voteInPoll(roomID: String, eventID: String, optionIDs: [String]) async throws
    func sendSticker(
        roomID: String,
        upload: MatrixNativeUpload,
        transactionID: String
    ) async throws
    func mediaData(
        roomID: String,
        sourceJSON: String,
        expectedSize: UInt64?
    ) async throws -> Data
    func mediaThumbnailData(
        roomID: String,
        sourceJSON: String,
        width: UInt64,
        height: UInt64
    ) async throws -> Data
    func avatarData(avatarURL: String) async throws -> Data
    func setTyping(roomID: String, isTyping: Bool) async throws
    func markRead(roomID: String) async throws
    func markThreadRead(roomID: String, rootEventID: String) async throws
    func acceptInvite(roomID: String) async throws
    func declineInvite(roomID: String) async throws
    func declineInviteAndBlock(roomID: String) async throws
    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String,
        experience: MatrixNativeRtcExperience
    ) async throws -> String
    func endRtcMembership(roomID: String) async throws

    // MARK: Watch Party
    func watchPartyState(
        roomID: String
    ) async throws -> MatrixNativeWatchPartyState?
    func startWatchParty(
        roomID: String,
        videoId: String,
        videoUrl: String?
    ) async throws
    func updateWatchPartyPlayback(
        roomID: String,
        playbackState: MatrixNativeWatchPartyPlaybackState,
        playheadMs: Int64
    ) async throws
    func endWatchParty(roomID: String) async throws

    // MARK: Live Stage
    func liveStageState(
        roomID: String
    ) async throws -> MatrixNativeLiveStageState?
    func speakerRequests(
        roomID: String
    ) async throws -> [MatrixNativeSpeakerRequest]
    func startLiveStage(roomID: String, title: String) async throws
    func endLiveStage(roomID: String) async throws
    func requestSpeaker(roomID: String) async throws
    func approveSpeaker(roomID: String, userId: String) async throws
    func denySpeaker(roomID: String, userId: String) async throws
    func removeSpeaker(roomID: String, userId: String) async throws
    func updateLiveStageCohost(roomID: String, userId: String, add: Bool) async throws
}

enum MatrixNativeWaveActionError: LocalizedError, Equatable {
    case roomNotJoined
    case ignoredSender
    case invalidEnergy
    case notAllowed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .roomNotJoined:
            "Join this Wave before interacting."
        case .ignoredSender:
            "This message is hidden because you ignored its sender."
        case .invalidEnergy:
            "That Energy signal is not supported."
        case .notAllowed:
            "Your current Vibe role does not allow that action."
        case .unavailable:
            "That Vibe action is temporarily unavailable."
        }
    }
}

private struct MatrixNativeTimelineContext: Sendable {
    let currentUserID: String
    let ignoredUserIDs: Set<String>
    let roomIsEncrypted: Bool
    let pinnedEventIDs: Set<String>
    let maySendMessage: Bool
    let maySendReaction: Bool
    let mayRedactOwn: Bool
    let mayRedactOther: Bool
    let mayPin: Bool
}

private struct MatrixWaveEstablishmentRawCandidate: Sendable {
    let markerEventID: String
    let stateKey: String
    let senderID: String
    let contentJSON: String
}

private enum MatrixNativeWaveRulesInspection {
    case missing
    case malformed
    case value(MatrixNativeWaveRulesState)
}

/// The only production Matrix transport implementation for native Vibes.
///
/// Every operation is performed by MatrixRustSDK. This type must never grow
/// URLSession calls to Matrix Client-Server endpoints.
actor MatrixRustSDKVibesProvider: MatrixVibesSDKProviding {
    private static let directoryBatchSize: UInt32 = 24
    private static let waveRulesRecoveryPageSize: UInt16 = 100
    private static let maximumWaveRulesRecoveryPages = 25

    private let sessionCoordinator: MatrixSessionCoordinator
    private var sendHandles: [String: SendHandle] = [:]
    private var rtcMembershipTasks: [String: Task<Void, Never>] = [:]
    private var directorySearch: RoomDirectorySearch?
    private var directoryAccumulator: MatrixRoomDirectoryAccumulator?
    private var directoryResultsHandle: TaskHandle?
    private var directoryQuery: String?
    private var focusedTimelines: [String: MatrixFocusedTimelineSession] = [:]
    private var focusedThreadTimelines: [String: MatrixFocusedTimelineSession] = [:]
    private var submittedReportFingerprints = Set<String>()
    private var submittedReportOrder: [String] = []
    private var observedLiveStages: [String: MatrixNativeLiveStageState] = [:]
    /// Parent-side `m.space.child` evidence observed through MatrixRustSDK's
    /// Space service. The child-side canonical `m.space.parent` state is
    /// independently required by the establishment projection below.
    private var canonicalParentSpaceIDsByRoomID: [String: Set<String>] = [:]
    private var establishmentProjections: [
        String: MatrixWaveEstablishmentProjection
    ] = [:]
    private var authoritativeEstablishmentProjectionReads: [
        String: (fetchedAt: Date, projection: MatrixWaveEstablishmentProjection?)
    ] = [:]

    init(sessionCoordinator: MatrixSessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator
    }

    func topLevelSpaces() async throws -> [MatrixVibeSummary] {
        let client = try await activeClient()
        let joined = await client.spaceService().topLevelJoinedSpaces()
        var ordered: [MatrixVibeSummary] = []
        for space in joined {
            do {
                let list = try await client.spaceService().spaceRoomList(
                    spaceId: space.roomId
                )
                try await list.paginate()
                ordered.append(MatrixVibeSummary(space, membership: .joined))
            } catch let error as ClientError {
                let metadata = MatrixNativeSpaceDirectoryClientErrorMetadata(error)
                let disposition = MatrixNativeSpaceDirectoryFailureContract.disposition(
                    matrixErrorCode: metadata.code,
                    matrixKindIsNotFound: metadata.kindIsNotFound
                )
                if disposition == .ignoreStalePurgedSpace {
                    matrixSpaceDirectoryLogger.notice(
                        "branch=skip_stale_top_level_space domain=\(metadata.domain, privacy: .public) code=\(metadata.code, privacy: .public)"
                    )
                    continue
                }
                matrixSpaceDirectoryLogger.error(
                    "branch=report_top_level_space_failure domain=\(metadata.domain, privacy: .public) code=\(metadata.code, privacy: .public)"
                )
                throw error
            }
        }
        let joinedIDs = Set(ordered.map(\.id))
        let invitations = client.rooms()
            .filter { $0.isSpace() && $0.membership() == .invited && !joinedIDs.contains($0.id()) }
            .map { room in
                MatrixVibeSummary(
                    id: room.id(),
                    name: MatrixNativeMemberPresentationContract.roomName(
                        room.displayName(),
                        fallback: "Invited Vibe"
                    ),
                    topic: room.topic(),
                    avatarURL: room.avatarUrl(),
                    joinedMemberCount: room.joinedMembersCount(),
                    membership: .invited
                )
            }
        ordered.append(contentsOf: invitations)
        return ordered
    }

    func pendingInvitations() async throws -> [MatrixNativeInvitationSummary] {
        let client = try await activeClient()
        let currentUserID = try client.userId()
        let ignored = Set(try await client.ignoredUsers())
        var result: [MatrixNativeInvitationSummary] = []
        for room in client.rooms().filter({ $0.membership() == .invited }) {
            let info = try? await room.roomInfo()
            let inviterID: String? = info?.inviter?.userId
            let isDirect = await room.isDirect()
            let encrypted = await room.isEncrypted()
            // A Personal Wave must have a different, valid membership-event
            // inviter and encryption before acceptance can be offered.
            let validInviter: String?
            if let inviterID,
               inviterID.first == "@",
               inviterID.contains(":"),
               inviterID != currentUserID {
                validInviter = inviterID
            } else {
                validInviter = nil
            }
            let kind: MatrixNativeInvitationKind = room.isSpace()
                ? .vibe
                : (isDirect ? .personalWave : .wave)
            result.append(MatrixNativeInvitationSummary(
                id: room.id(),
                name: MatrixNativeMemberPresentationContract.roomName(
                    room.displayName(),
                    fallback: kind == .vibe ? "Invited Vibe" : kind == .personalWave ? "Personal Wave" : "Invited Wave"
                ),
                topic: room.topic(),
                avatarURL: room.avatarUrl(),
                kind: kind,
                isEncrypted: encrypted,
                inviterUserID: validInviter,
                inviterName: {
                    let displayName = info?.inviter?.displayName?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return displayName.isEmpty
                        ? (validInviter ?? "Unknown inviter")
                        : displayName
                }(),
                inviterAvatarURL: info?.inviter?.avatarUrl,
                inviterIsBlocked: validInviter.map(ignored.contains) ?? false
            ))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func publicSpaces(
        query: String?,
        loadNextPage: Bool
    ) async throws -> MatrixPublicVibeDirectoryPage {
        let client = try await activeClient()
        let normalizedQuery = query.map {
            $0.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
        }.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }

        let search: RoomDirectorySearch
        let accumulator: MatrixRoomDirectoryAccumulator
        if loadNextPage {
            guard
                normalizedQuery == directoryQuery,
                let existingSearch = directorySearch,
                let existingAccumulator = directoryAccumulator,
                !(try await existingSearch.isAtLastPage())
            else {
                throw MatrixSessionFoundationError.unavailable
            }
            search = existingSearch
            accumulator = existingAccumulator
            try await search.nextPage()
        } else {
            directoryResultsHandle?.cancel()
            let nextSearch = client.roomDirectorySearch()
            let nextAccumulator = MatrixRoomDirectoryAccumulator()
            let nextHandle = await nextSearch.results(listener: nextAccumulator)
            directorySearch = nextSearch
            directoryAccumulator = nextAccumulator
            directoryResultsHandle = nextHandle
            directoryQuery = normalizedQuery
            search = nextSearch
            accumulator = nextAccumulator
            try await search.search(
                filter: normalizedQuery,
                batchSize: Self.directoryBatchSize,
                viaServerName: nil
            )
        }

        await Task.yield()
        let descriptions = accumulator.roomDescriptions
        var spaces: [MatrixPublicVibeSummary] = []
        spaces.reserveCapacity(descriptions.count)

        // Binding limitation (26.7.28): RoomDescription has no roomType.
        // The official RoomPreview API is therefore the only safe way to
        // distinguish Spaces from ordinary public rooms. Preview failures are
        // omitted rather than guessed so discovery remains fail closed.
        for description in descriptions {
            let viaServers = Self.viaServers(
                roomID: description.roomId,
                alias: description.alias
            )
            guard
                let preview = try? await client.getRoomPreviewFromRoomId(
                    roomId: description.roomId,
                    viaServers: viaServers
                ),
                preview.info().roomType == .space
            else {
                continue
            }
            let info = preview.info()
            spaces.append(
                MatrixPublicVibeSummary(
                    id: info.roomId,
                    name: info.name ?? description.name ?? "Public Vibe",
                    topic: info.topic ?? description.topic,
                    avatarURL: info.avatarUrl ?? description.avatarUrl,
                    canonicalAlias: info.canonicalAlias ?? description.alias,
                    joinedMemberCount: info.numJoinedMembers,
                    membership: MatrixNativeMembership(info.membership),
                    mayJoin: Self.mayJoin(info.joinRule),
                    viaServers: viaServers
                )
            )
        }

        return MatrixPublicVibeDirectoryPage(
            spaces: spaces,
            loadedPages: try await search.loadedPages(),
            hasMore: !(try await search.isAtLastPage())
        )
    }

    func joinPublicSpace(_ space: MatrixPublicVibeSummary) async throws {
        let current = try await publicSpacePreview(space)
        if current.membership == .joined { return }
        guard current.mayJoin else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let client = try await activeClient()
        let target = current.canonicalAlias ?? current.id
        let joined = try await client.joinRoomByIdOrAlias(
            roomIdOrAlias: target,
            serverNames: current.viaServers
        )
        guard joined.id() == current.id,
              joined.isSpace(),
              joined.membership() == .joined,
              !(await joined.isEncrypted())
        else {
            if joined.membership() == .joined {
                try? await joined.leave()
            }
            throw MatrixNativeWaveActionError.notAllowed
        }
    }

    func publicSpacePreview(_ space: MatrixPublicVibeSummary) async throws
        -> MatrixPublicVibeSummary
    {
        let client = try await activeClient()
        let preview = try await client.getRoomPreviewFromRoomId(
            roomId: space.id,
            viaServers: space.viaServers
        )
        let info = preview.info()
        guard info.roomId == space.id, info.roomType == .space else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        if let joined = try client.getRoom(roomId: info.roomId), await joined.isEncrypted() {
            throw MatrixNativeWaveActionError.notAllowed
        }
        return MatrixPublicVibeSummary(
            id: info.roomId,
            name: info.name ?? "Public Vibe",
            topic: info.topic,
            avatarURL: info.avatarUrl,
            canonicalAlias: info.canonicalAlias,
            joinedMemberCount: info.numJoinedMembers,
            membership: MatrixNativeMembership(info.membership),
            mayJoin: Self.mayJoin(info.joinRule),
            viaServers: Self.viaServers(roomID: info.roomId, alias: info.canonicalAlias)
        )
    }

    func leavePublicSpace(_ space: MatrixPublicVibeSummary) async throws {
        let current = try await publicSpacePreview(space)
        guard current.membership == .joined else { return }
        let client = try await activeClient()
        guard let room = try client.getRoom(roomId: current.id),
              room.isSpace(),
              room.membership() == .joined,
              !(await room.isEncrypted())
        else { throw MatrixNativeWaveActionError.notAllowed }
        try await room.leave()
    }

    func createVibe(
        _ draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        let client = try await activeClient()
        let validated = try MatrixNativeCreationContract.validate(draft)
        guard validated.visibility != .restricted else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let serviceUserID = try Self.serviceUserID(for: client.userId())
        try Self.validateLocalAlias(validated.canonicalAlias, userID: client.userId())
        let avatarURI = try await uploadCreationAvatar(validated.avatar, client: client)
        let roomID = try await client.createRoom(
            request: createRoomParameters(
                validated,
                isSpace: true,
                serviceUserID: serviceUserID,
                parentSpaceID: nil,
                avatarURI: avatarURI
            )
        )
        let room = try await createdRoom(roomID, client: client)
        guard room.isSpace(), room.membership() == .joined else {
            try? await room.leave()
            throw MatrixNativeWaveActionError.unavailable
        }
        do {
            try await setPublicSharingState(
                room: room,
                isPublic: validated.visibility == .publicVibe
            )
        } catch {
            try? await room.leave()
            throw error
        }
        let failures = await inviteValidatedUsers(
            validated.inviteUserIDs,
            to: room
        )
        let registrationPending = await registerNativeRoom(
            entityType: "SPACE",
            roomID: roomID,
            matrixSpaceID: roomID
        ) == false
        return MatrixNativeCreatedRoom(
            roomID: roomID,
            matrixSpaceID: roomID,
            entityType: "SPACE",
            registrationPending: registrationPending,
            failedInvitationUserIDs: failures
        )
    }

    func createWave(
        inSpaceID spaceID: String,
        draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        let client = try await activeClient()
        let parent = try room(spaceID, in: client)
        let permissions = try await spacePermissions(spaceID: spaceID)
        guard permissions.mayCreateWave else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let validated = try MatrixNativeCreationContract.validate(draft)
        let serviceUserID = try Self.serviceUserID(for: client.userId())
        try Self.validateLocalAlias(validated.canonicalAlias, userID: client.userId())
        let avatarURI = try await uploadCreationAvatar(validated.avatar, client: client)
        let roomID = try await client.createRoom(
            request: createRoomParameters(
                validated,
                isSpace: false,
                serviceUserID: serviceUserID,
                parentSpaceID: spaceID,
                avatarURI: avatarURI
            )
        )
        let child = try await createdRoom(roomID, client: client)
        guard !child.isSpace(), child.membership() == .joined else {
            try? await child.leave()
            throw MatrixNativeWaveActionError.unavailable
        }
        do {
            try await setPublicSharingState(
                room: child,
                isPublic: validated.visibility == .publicVibe
            )
        } catch {
            try? await child.leave()
            throw error
        }
        let childPowerLevels = try await child.getPowerLevels()
        guard childPowerLevels.canOwnUserSendState(stateEvent: .spaceParent) else {
            try? await child.leave()
            throw MatrixNativeWaveActionError.notAllowed
        }

        let via = Self.viaServers(
            roomID: roomID,
            alias: nil,
            fallbackUserID: try client.userId()
        )
        let childContent = try Self.json([
            "via": via,
            "suggested": true,
        ])
        let parentContent = try Self.json([
            "via": Self.viaServers(
                roomID: spaceID,
                alias: nil,
                fallbackUserID: try client.userId()
            ),
            "canonical": true,
        ])

        do {
            _ = try await parent.sendStateEventRaw(
                eventType: "m.space.child",
                stateKey: roomID,
                content: childContent
            )
            do {
                _ = try await child.sendStateEventRaw(
                    eventType: "m.space.parent",
                    stateKey: spaceID,
                    content: parentContent
                )
            } catch {
                // Remove the one-sided child edge before abandoning the room.
                _ = try? await parent.sendStateEventRaw(
                    eventType: "m.space.child",
                    stateKey: roomID,
                    content: "{}"
                )
                throw error
            }
        } catch {
            try? await child.leave()
            throw error
        }

        let failures = await inviteValidatedUsers(
            validated.inviteUserIDs,
            to: child
        )
        let registrationPending = await registerNativeRoom(
            entityType: "ROOM",
            roomID: roomID,
            matrixSpaceID: spaceID
        ) == false
        return MatrixNativeCreatedRoom(
            roomID: roomID,
            matrixSpaceID: spaceID,
            entityType: "ROOM",
            registrationPending: registrationPending,
            failedInvitationUserIDs: failures
        )
    }

    func registerCreatedRoom(
        _ room: MatrixNativeCreatedRoom
    ) async throws -> MatrixNativeCreatedRoom {
        _ = try await APIClient.shared.registerMatrixNativeRoom(
            entityType: room.entityType,
            matrixRoomID: room.roomID,
            matrixSpaceID: room.matrixSpaceID
        )
        return MatrixNativeCreatedRoom(
            roomID: room.roomID,
            matrixSpaceID: room.matrixSpaceID,
            entityType: room.entityType,
            registrationPending: false,
            failedInvitationUserIDs: room.failedInvitationUserIDs
        )
    }

    func spacePermissions(
        spaceID: String
    ) async throws -> MatrixNativeSpacePermissionSnapshot {
        let client = try await activeClient()
        let space = try room(spaceID, in: client)
        guard space.membership() == .joined, space.isSpace() else {
            return .unavailable
        }
        let powerLevels = try await space.getPowerLevels()
        return MatrixNativeSpacePermissionSnapshot(
            isJoined: true,
            isSpace: true,
            maySendSpaceChild: powerLevels.canOwnUserSendState(
                stateEvent: .spaceChild
            ),
            mayInvite: powerLevels.canOwnUserInvite()
        )
    }

    func inviteUsers(
        _ userIDs: [String],
        roomID: String
    ) async throws -> [String] {
        let validated = try MatrixNativeCreationContract.validate(
            MatrixNativeRoomCreationDraft(
                name: "Invitation validation",
                topic: "",
                visibility: .privateVibe,
                inviteUserIDs: userIDs
            )
        )
        let client = try await activeClient()
        let room = try room(roomID, in: client)
        guard room.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await room.getPowerLevels()
        guard powerLevels.canOwnUserInvite() else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        return await inviteValidatedUsers(validated.inviteUserIDs, to: room)
    }

    func childRooms(spaceID: String) async throws -> [MatrixWaveSummary] {
        let client = try await activeClient()
        let list = try await client.spaceService().spaceRoomList(spaceId: spaceID)
        try await list.paginate()
        let localRooms = Dictionary(
            client.rooms().map { ($0.id(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let children = await list.rooms()
        let currentChildRoomIDs = Set(children.map(\.roomId))
        for roomID in Array(canonicalParentSpaceIDsByRoomID.keys) {
            canonicalParentSpaceIDsByRoomID[roomID]?.remove(spaceID)
            if canonicalParentSpaceIDsByRoomID[roomID]?.isEmpty == true {
                canonicalParentSpaceIDsByRoomID.removeValue(forKey: roomID)
                establishmentProjections.removeValue(forKey: roomID)
            }
        }
        for roomID in currentChildRoomIDs {
            canonicalParentSpaceIDsByRoomID[roomID, default: []].insert(spaceID)
            establishmentProjections.removeValue(forKey: roomID)
        }
        // Summaries fan out concurrently: each one awaits several SDK calls
        // (room info, encryption, members) that would otherwise serialize.
        return await withTaskGroup(
            of: (Int, MatrixWaveSummary).self,
            returning: [MatrixWaveSummary].self
        ) { group in
            for (index, child) in children.enumerated() {
                let matrixRoom = localRooms[child.roomId]
                group.addTask {
                    (index, await Self.waveSummary(child: child, matrixRoom: matrixRoom))
                }
            }
            var indexed: [(Int, MatrixWaveSummary)] = []
            for await entry in group {
                indexed.append(entry)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func waveSummary(
        child: SpaceRoom,
        matrixRoom: Room?
    ) async -> MatrixWaveSummary {
        let base = MatrixWaveSummary(child)
        guard let matrixRoom else { return base }
        let info = try? await matrixRoom.roomInfo()
        let lastActivity = await latestActivityDate(room: matrixRoom)
        let activeParticipantIDs = matrixRoom.hasActiveRoomCall()
            ? Set(matrixRoom.activeRoomCallParticipants())
            : []
        let intent: MatrixNativeRtcIntent?
        switch info?.activeRoomCallConsensusIntent {
        case .full(.audio), .partial(intent: .audio, agreeingCount: _, totalCount: _):
            intent = .audio
        case .full(.video), .partial(intent: .video, agreeingCount: _, totalCount: _):
            intent = .video
        case .some(.none), nil:
            intent = nil
        }
        var activeParticipants: [MatrixNativeLoungeParticipant] = []
        if !activeParticipantIDs.isEmpty,
           let iterator = try? await matrixRoom.members() {
            memberLookup: while let chunk = iterator.nextChunk(chunkSize: 100),
                                !chunk.isEmpty {
                for member in chunk where
                    member.membership == .join
                        && activeParticipantIDs.contains(member.userId) {
                    activeParticipants.append(
                        MatrixNativeLoungeParticipant(
                            id: member.userId,
                            displayName: MatrixNativeMemberPresentationContract
                                .displayName(
                                    member.displayName,
                                    matrixUserID: member.userId
                                ),
                            avatarURL: member.avatarUrl
                        )
                    )
                    if activeParticipants.count == 3 { break memberLookup }
                }
            }
        }
        return MatrixWaveSummary(
            id: base.id,
            name: base.name,
            topic: base.topic,
            avatarURL: base.avatarURL,
            joinedMemberCount: base.joinedMemberCount,
            membership: base.membership,
            isNestedSpace: base.isNestedSpace,
            isDirect: false,
            isEncrypted: await matrixRoom.isEncrypted(),
            unreadCount: info?.numUnreadNotifications ?? 0,
            lastActivity: lastActivity,
            activeCallParticipantCount: activeParticipantIDs.count,
            activeCallIntent: intent,
            activeCallParticipants: activeParticipants
        )
    }

    private static func latestActivityDate(room: Room) async -> Date? {
        switch await room.latestEvent() {
        case let .remote(timestamp, _, _, _, _),
             let .local(timestamp, _, _, _, _),
             let .remoteInvite(timestamp, _, _):
            return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        case .none:
            return nil
        }
    }

    /// Refreshes lounge badges only from rooms already held by MatrixRustSDK.
    /// This never paginates the Space directory or calls a Westreem endpoint.
    func localWaveActivity(
        rooms: [MatrixWaveSummary]
    ) async throws -> [MatrixWaveSummary] {
        let client = try await activeClient()
        let localRooms = Dictionary(
            uniqueKeysWithValues: client.rooms().map { ($0.id(), $0) }
        )
        var refreshed: [MatrixWaveSummary] = []
        for base in rooms {
            guard !base.isNestedSpace, let matrixRoom = localRooms[base.id] else {
                refreshed.append(base)
                continue
            }
            let activeParticipantIDs = matrixRoom.hasActiveRoomCall()
                ? Set(matrixRoom.activeRoomCallParticipants())
                : []
            let info = try? await matrixRoom.roomInfo()
            let intent: MatrixNativeRtcIntent?
            switch info?.activeRoomCallConsensusIntent {
            case .full(.audio),
                 .partial(intent: .audio, agreeingCount: _, totalCount: _):
                intent = .audio
            case .full(.video),
                 .partial(intent: .video, agreeingCount: _, totalCount: _):
                intent = .video
            case .some(.none), nil:
                intent = nil
            }
            var participants: [MatrixNativeLoungeParticipant] = []
            if !activeParticipantIDs.isEmpty,
               let iterator = try? await matrixRoom.membersNoSync() {
                memberLookup: while let chunk = iterator.nextChunk(chunkSize: 100),
                                    !chunk.isEmpty {
                    for member in chunk where
                        member.membership == .join
                            && activeParticipantIDs.contains(member.userId) {
                        participants.append(
                            MatrixNativeLoungeParticipant(
                                id: member.userId,
                                displayName: MatrixNativeMemberPresentationContract
                                    .displayName(
                                        member.displayName,
                                        matrixUserID: member.userId
                                    ),
                                avatarURL: member.avatarUrl
                            )
                        )
                        if participants.count == 3 { break memberLookup }
                    }
                }
            }
            refreshed.append(
                MatrixWaveSummary(
                    id: base.id,
                    name: base.name,
                    topic: base.topic,
                    avatarURL: base.avatarURL,
                    joinedMemberCount: base.joinedMemberCount,
                    membership: base.membership,
                    isNestedSpace: base.isNestedSpace,
                    isDirect: base.isDirect,
                    isEncrypted: base.isEncrypted,
                    lastActivity: base.lastActivity,
                    activeCallParticipantCount: activeParticipantIDs.count,
                    activeCallIntent: intent,
                    activeCallParticipants: participants
                )
            )
        }
        return refreshed
    }

    func waveRules(roomID: String) async throws -> MatrixNativeWaveRulesSnapshot {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        let mayEdit = powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeWaveRulesContract.eventType
            )
        )
        return MatrixNativeWaveRulesSnapshot(
            state: try await recoverWaveRules(room: matrixRoom, client: client),
            mayEdit: mayEdit
        )
    }

    func updateWaveRules(
        roomID: String,
        state: MatrixNativeWaveRulesState
    ) async throws {
        let validated = try MatrixNativeWaveRulesContract.validate(state)
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let identity = try MatrixCanonicalIdentity(
            westreemUserID: validated.updatedByWestreemUserID
        )
        guard identity.verifies(matrixUserID: try client.userId()) else {
            throw MatrixSessionFoundationError.identityMismatch(
                expected: identity.matrixUserID,
                received: try client.userId()
            )
        }
        let current = try await recoverWaveRules(room: matrixRoom, client: client)
        guard validated.revision == (current?.revision ?? 0) + 1 else {
            throw MatrixNativeWaveRulesReadError.staleRevision
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeWaveRulesContract.eventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeWaveRulesContract.eventType,
            stateKey: "",
            content: try MatrixNativeWaveRulesContract.encode(validated)
        )
    }

    // MARK: - Watch Party

    func watchPartyState(
        roomID: String
    ) async throws -> MatrixNativeWatchPartyState? {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        guard let (content, _) = try await latestCustomStateEvent(
            room: matrixRoom,
            client: client,
            eventType: MatrixNativeWatchPartyContract.eventType,
            stateKeyFilter: { $0.isEmpty }
        ).first else {
            return nil
        }
        return try MatrixNativeWatchPartyContract.decode(contentJSON: content)
    }

    func startWatchParty(
        roomID: String,
        videoId: String,
        videoUrl: String?
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeWatchPartyContract.eventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let now = Self.currentEpochMs()
        let currentUserID = try client.userId()
        let state = MatrixNativeWatchPartyState(
            videoId: videoId,
            videoUrl: videoUrl,
            startedBy: currentUserID,
            host: currentUserID,
            playbackState: .playing,
            playheadMs: 0,
            startedAt: now,
            lastUpdatedAt: now,
            playbackEpoch: MatrixWatchPartyCrossClientVersion.playbackEpoch(
                nowMilliseconds: now,
                sequence: 0
            ),
            sequence: 0,
            endedAt: nil
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeWatchPartyContract.eventType,
            stateKey: "",
            content: try MatrixNativeWatchPartyContract.encode(state)
        )
    }

    func updateWatchPartyPlayback(
        roomID: String,
        playbackState: MatrixNativeWatchPartyPlaybackState,
        playheadMs: Int64
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeWatchPartyContract.eventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard let existing = try await watchPartyState(roomID: roomID),
              existing.isActive else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let currentUserID = try client.userId()
        guard existing.controllingUserID == currentUserID else {
            // Only the host may drive playback state changes.
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard let nextSequence = MatrixWatchPartyCrossClientVersion.nextSequence(
            after: existing.sequence
        ) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let now = Self.currentEpochMs()
        let updated = MatrixNativeWatchPartyState(
            videoId: existing.videoId,
            videoUrl: existing.videoUrl,
            startedBy: existing.startedBy,
            host: currentUserID,
            playbackState: playbackState,
            playheadMs: max(0, playheadMs),
            startedAt: existing.startedAt,
            lastUpdatedAt: now,
            playbackEpoch: existing.playbackEpoch,
            sequence: nextSequence,
            endedAt: nil
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeWatchPartyContract.eventType,
            stateKey: "",
            content: try MatrixNativeWatchPartyContract.encode(updated)
        )
    }

    func endWatchParty(roomID: String) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeWatchPartyContract.eventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard let existing = try await watchPartyState(roomID: roomID),
              existing.isActive else {
            return
        }
        guard existing.controllingUserID == (try client.userId()) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard let nextSequence = MatrixWatchPartyCrossClientVersion.nextSequence(
            after: existing.sequence
        ) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let now = Self.currentEpochMs()
        let ended = MatrixNativeWatchPartyState(
            videoId: existing.videoId,
            videoUrl: existing.videoUrl,
            startedBy: existing.startedBy,
            host: existing.host,
            playbackState: .paused,
            playheadMs: existing.playheadMs,
            startedAt: existing.startedAt,
            lastUpdatedAt: now,
            playbackEpoch: existing.playbackEpoch,
            sequence: nextSequence,
            endedAt: now
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeWatchPartyContract.eventType,
            stateKey: "",
            content: try MatrixNativeWatchPartyContract.encode(ended)
        )
    }

    // MARK: - Live Stage

    func liveStageState(
        roomID: String
    ) async throws -> MatrixNativeLiveStageState? {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        guard let (content, _) = try await latestCustomStateEvent(
            room: matrixRoom,
            client: client,
            eventType: MatrixNativeLiveStageContract.stageEventType,
            stateKeyFilter: { $0.isEmpty }
        ).first else {
            return nil
        }
        let state = try MatrixNativeLiveStageContract.decodeStage(contentJSON: content)
        var joinedHosts: [String] = []
        for userID in state.hosts {
            if (try? await matrixRoom.member(userId: userID).membership) == .join {
                joinedHosts.append(userID)
            }
        }
        guard state.isLive, joinedHosts.isEmpty else {
            observedLiveStages[roomID] = state
            return state
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(stateEvent: stateEventTypeFromString(
            s: MatrixNativeLiveStageContract.stageEventType
        )) else {
            observedLiveStages[roomID] = state
            return state
        }
        var eligibleSpeakers: [String] = []
        for userID in state.speakers where !state.hosts.contains(userID) {
            if (try? await matrixRoom.member(userId: userID).membership) == .join {
                eligibleSpeakers.append(userID)
            }
        }
        let now = Self.currentEpochMs()
        let successor = eligibleSpeakers.sorted().first
        let recovered = MatrixNativeLiveStageState(
            status: successor == nil ? .ended : .live,
            title: state.title,
            hosts: successor.map { [$0] } ?? [],
            speakers: successor.map { Array(Set(state.speakers + [$0])).sorted() } ?? state.speakers,
            startedAt: state.startedAt,
            endedAt: successor == nil ? now : nil,
            stageEpoch: state.stageEpoch,
            sequence: state.sequence + 1,
            updatedAt: now
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.stageEventType,
            stateKey: "",
            content: try MatrixNativeLiveStageContract.encodeStage(recovered)
        )
        observedLiveStages[roomID] = recovered
        return recovered
    }

    func speakerRequests(
        roomID: String
    ) async throws -> [MatrixNativeSpeakerRequest] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let entries = try await latestCustomStateEvent(
            room: matrixRoom,
            client: client,
            eventType: MatrixNativeLiveStageContract.speakerEventType,
            stateKeyFilter: { !$0.isEmpty }
        )
        var seen = Set<String>()
        var requests: [MatrixNativeSpeakerRequest] = []
        for (content, stateKey) in entries where !seen.contains(stateKey) {
            seen.insert(stateKey)
            if let request = try? MatrixNativeLiveStageContract.decodeSpeaker(
                userId: stateKey,
                contentJSON: content
            ), request.role != .request || request.requestedAt > 0 {
                requests.append(request)
            }
        }
        return requests
    }

    func startLiveStage(roomID: String, title: String) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeLiveStageContract.stageEventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let host = try client.userId()
        let now = Self.currentEpochMs()
        let state = MatrixNativeLiveStageState(
            status: .live,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            hosts: [host],
            speakers: [host],
            startedAt: now,
            endedAt: nil,
            stageEpoch: UUID().uuidString.replacingOccurrences(of: "-", with: "_"),
            sequence: 0,
            updatedAt: now
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.stageEventType,
            stateKey: "",
            content: try MatrixNativeLiveStageContract.encodeStage(state)
        )
    }

    func endLiveStage(roomID: String) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeLiveStageContract.stageEventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let expected = observedLiveStages[roomID]
        guard let existing = try await liveStageState(roomID: roomID),
              existing.isLive else {
            return
        }
        guard expected == nil || expected == existing else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let ended = MatrixNativeLiveStageState(
            status: .ended,
            title: existing.title,
            hosts: existing.hosts,
            speakers: existing.speakers,
            startedAt: existing.startedAt,
            endedAt: Self.currentEpochMs(),
            stageEpoch: existing.stageEpoch,
            sequence: existing.sequence + 1,
            updatedAt: Self.currentEpochMs()
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.stageEventType,
            stateKey: "",
            content: try MatrixNativeLiveStageContract.encodeStage(ended)
        )
    }

    func requestSpeaker(roomID: String) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        guard let stage = try await liveStageState(roomID: roomID), stage.isLive else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let existing = try await speakerRequests(roomID: roomID)
            .first { $0.userId == (try? client.userId()) }
        guard existing?.role != .denied else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        // Own user's speaker state key = own Matrix user ID.
        // A member may always write their own speaker request unless the
        // room's power_levels ban this event type outright.
        let ownID = try client.userId()
        let isCancelling = existing?.role == .request && existing?.requestedAt ?? 0 > 0
        let request = MatrixNativeSpeakerRequest(
            userId: ownID,
            role: .request,
            // A zero timestamp is an interoperable tombstone: it remains
            // schema-valid but both clients exclude it from the live queue.
            requestedAt: isCancelling ? 0 : Self.currentEpochMs()
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.speakerEventType,
            stateKey: ownID,
            content: try MatrixNativeLiveStageContract.encodeSpeaker(request)
        )
    }

    func approveSpeaker(roomID: String, userId: String) async throws {
        try await mutateSpeaker(
            roomID: roomID,
            userId: userId,
            role: .speaker,
            addToStageSpeakers: true
        )
    }

    func denySpeaker(roomID: String, userId: String) async throws {
        try await mutateSpeaker(
            roomID: roomID,
            userId: userId,
            role: .denied,
            addToStageSpeakers: false
        )
    }

    func removeSpeaker(roomID: String, userId: String) async throws {
        try await mutateSpeaker(
            roomID: roomID,
            userId: userId,
            role: .denied,
            addToStageSpeakers: false,
            removeFromStageSpeakers: true
        )
    }

    func updateLiveStageCohost(roomID: String, userId: String, add: Bool) async throws {
        let expected = observedLiveStages[roomID]
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined,
              (try await matrixRoom.member(userId: userId)).membership == .join else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(stateEvent: stateEventTypeFromString(
            s: MatrixNativeLiveStageContract.stageEventType
        )), let current = try await liveStageState(roomID: roomID), current.isLive,
              expected == nil || expected == current else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard userId != current.hosts.first else { throw MatrixNativeWaveActionError.notAllowed }
        var hosts = current.hosts.filter { $0 != userId }
        if add { hosts.append(userId) }
        let updated = MatrixNativeLiveStageState(
            status: current.status, title: current.title,
            hosts: hosts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            speakers: Array(Set(current.speakers + (add ? [userId] : []))).sorted(),
            startedAt: current.startedAt, endedAt: current.endedAt,
            stageEpoch: current.stageEpoch, sequence: current.sequence + 1,
            updatedAt: Self.currentEpochMs()
        )
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.stageEventType,
            stateKey: "", content: try MatrixNativeLiveStageContract.encodeStage(updated)
        )
        observedLiveStages[roomID] = updated
    }

    private func mutateSpeaker(
        roomID: String,
        userId: String,
        role: MatrixNativeSpeakerRole,
        addToStageSpeakers: Bool,
        removeFromStageSpeakers: Bool = false
    ) async throws {
        let expected = observedLiveStages[roomID]
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeLiveStageContract.speakerEventType
            )
        ), powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeLiveStageContract.stageEventType
            )
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let target = try await matrixRoom.member(userId: userId)
        guard target.membership == .join, !target.isServiceMember else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        guard let existing = try await liveStageState(roomID: roomID),
              existing.isLive else {
            throw MatrixNativeWaveActionError.unavailable
        }
        guard expected == nil || expected == existing else {
            throw MatrixNativeWaveActionError.unavailable
        }
        guard !existing.hosts.contains(userId) else {
            // Hosts cannot be denied or removed through speaker moderation.
            throw MatrixNativeWaveActionError.notAllowed
        }
        let request = MatrixNativeSpeakerRequest(
            userId: userId,
            role: role,
            requestedAt: Self.currentEpochMs()
        )
        if addToStageSpeakers || removeFromStageSpeakers {
            var speakers = existing.speakers
            if removeFromStageSpeakers {
                speakers.removeAll { $0 == userId }
            }
            if addToStageSpeakers, !speakers.contains(userId) {
                speakers.append(userId)
            }
            let updated = MatrixNativeLiveStageState(
                status: existing.status,
                title: existing.title,
                hosts: existing.hosts,
                speakers: speakers,
                startedAt: existing.startedAt,
                endedAt: existing.endedAt,
                stageEpoch: existing.stageEpoch,
                sequence: existing.sequence + 1,
                updatedAt: Self.currentEpochMs()
            )
            _ = try await matrixRoom.sendStateEventRaw(
                eventType: MatrixNativeLiveStageContract.stageEventType,
                stateKey: "",
                content: try MatrixNativeLiveStageContract.encodeStage(updated)
            )
        }
        // The stage document is the media authorization authority, so commit
        // it before the per-user queue projection. If this advisory write
        // fails, a refresh still converges to the safe publish permission.
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeLiveStageContract.speakerEventType,
            stateKey: userId,
            content: try MatrixNativeLiveStageContract.encodeSpeaker(request)
        )
    }

    // MARK: - Custom state event recovery

    /// Recover the latest `com.westreem.*` custom state events by pagerinating
    /// the timeline until start or a bounded page count is reached. The
    /// matrix-rust-components-swift 26.07.28 binding does not expose a direct
    /// getter for arbitrary custom state, so we mirror the recovery pattern
    /// used for `com.westreem.room.rules.v1` (see `recoverWaveRules`).
    ///
    /// Returns tuples of (contentJSON, stateKey) with newest events first.
    ///
    /// This is deliberately not used as authoritative input for the Wave
    /// establishment marker: timeline pagination cannot prove the current
    /// sender/event ID after a state replacement, and the pinned Rust FFI has
    /// no authenticated current-state getter. A future binding must expose
    /// full raw state events (type, state key, sender, event ID and content)
    /// before this recovery path can participate in establishment projection.
    private func latestCustomStateEvent(
        room matrixRoom: Room,
        client: Client,
        eventType: String,
        stateKeyFilter: (String) -> Bool
    ) async throws -> [(String, String)] {
        let timeline = try await matrixRoom.timeline()
        let context = try await timelineContext(room: matrixRoom, client: client)
        let accumulator = MatrixTimelineAccumulator(context: context)
        let taskHandle = await timeline.addListener(listener: accumulator)
        defer { withExtendedLifetime(taskHandle) {} }
        await Task.yield()

        for page in 0...Self.maximumCustomStateRecoveryPages {
            let matches = accumulator.customStateEvents(
                eventType: eventType,
                stateKeyFilter: stateKeyFilter
            )
            if !matches.isEmpty {
                return matches
            }
            guard page < Self.maximumCustomStateRecoveryPages else {
                return []
            }
            let hitTimelineStart = try await timeline.paginateBackwards(
                numEvents: Self.customStateRecoveryPageSize
            )
            await Task.yield()
            if hitTimelineStart {
                return accumulator.customStateEvents(
                    eventType: eventType,
                    stateKeyFilter: stateKeyFilter
                )
            }
        }
        return []
    }

    private static let maximumCustomStateRecoveryPages: Int = 4
    private static let customStateRecoveryPageSize: UInt16 = 250

    private static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    func waveManagement(
        roomID: String
    ) async throws -> MatrixNativeWaveManagementSnapshot {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let info = try await matrixRoom.roomInfo()
        guard !info.isSpace else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        let notifications = try await client.getNotificationSettings()
            .getRoomNotificationSettings(
                roomId: roomID,
                isEncrypted: await matrixRoom.isEncrypted(),
                isOneToOne: false
            )
        return MatrixNativeWaveManagementSnapshot(
            name: MatrixNativeMemberPresentationContract.roomName(
                info.rawName ?? info.displayName,
                fallback: "Wave"
            ),
            topic: info.topic ?? "",
            avatarURL: info.avatarUrl,
            access: try Self.access(info.joinRule),
            restrictedParentSpaceID: try Self.restrictedParentSpaceID(info.joinRule),
            history: try Self.history(info.historyVisibility),
            notificationMode: Self.notificationMode(notifications.mode),
            isEncrypted: await matrixRoom.isEncrypted(),
            mayEditProfile: powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.name")
            ) && powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.topic")
            ) && powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.avatar")
            ),
            mayEditAccess: powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.join_rules")
            ),
            mayEditHistory: powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.history_visibility")
            ),
            mayInvite: powerLevels.canOwnUserInvite(),
            mayManageRoles: powerLevels.canOwnUserSendState(
                stateEvent: stateEventTypeFromString(s: "m.room.power_levels")
            ),
            mayKick: powerLevels.canOwnUserKick(),
            mayBan: powerLevels.canOwnUserBan()
        )
    }

    func updateWaveProfile(
        roomID: String,
        name: String,
        topic: String,
        avatar: MatrixNativeUpload?,
        removeAvatar: Bool
    ) async throws {
        guard let normalized = MatrixNativeWaveManagementContract
            .normalizedProfile(name: name, topic: topic),
              !(avatar != nil && removeAvatar)
        else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined, !matrixRoom.isSpace() else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.name")
        ), powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.topic")
        ), powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.avatar")
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        try await matrixRoom.setName(name: normalized.name)
        try await matrixRoom.setTopic(topic: normalized.topic)
        if let avatar {
            guard avatar.kind == .image,
                  avatar.mimeType.lowercased().hasPrefix("image/")
            else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            let maximum = try await client.getMaxMediaUploadSize()
            try MatrixNativeMediaPolicy.validate(
                [avatar],
                serverMaximumBytes: maximum
            )
            try await matrixRoom.uploadAvatar(
                mimeType: avatar.mimeType,
                data: avatar.data,
                mediaInfo: MatrixNativeGalleryFactory.imageInfo(avatar)
            )
        } else if removeAvatar {
            try await matrixRoom.removeAvatar()
        }
    }

    func updateWaveAccess(
        roomID: String,
        access: MatrixNativeWaveAccess,
        history: MatrixNativeWaveHistory,
        restrictedParentSpaceID: String?
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined, !matrixRoom.isSpace() else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        if await matrixRoom.isEncrypted(), access != .inviteOnly {
            throw MatrixNativeWaveActionError.notAllowed
        }
        if access == .restrictedToParent {
            guard let restrictedParentSpaceID else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            let parent = try room(restrictedParentSpaceID, in: client)
            guard parent.membership() == .joined, parent.isSpace() else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            let list = try await client.spaceService().spaceRoomList(
                spaceId: restrictedParentSpaceID
            )
            try await list.paginate()
            guard await list.rooms().contains(where: { $0.roomId == roomID }) else {
                throw MatrixNativeWaveActionError.notAllowed
            }
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.join_rules")
        ), powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.history_visibility")
        ), powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "com.westreem.public_sharing.v1")
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        // Both permissions are checked before either state event is sent.
        // Synapse remains authoritative and rejects any concurrent downgrade.
        try await matrixRoom.updateJoinRules(
            newRule: try Self.joinRule(access, parentSpaceID: restrictedParentSpaceID)
        )
        try await matrixRoom.updateHistoryVisibility(
            visibility: Self.sdkHistory(history)
        )
        try await setPublicSharingState(
            room: matrixRoom,
            isPublic: access == .publicRoom
        )
    }

    func leaveWave(roomID: String) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined, !matrixRoom.isSpace() else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        try await matrixRoom.leave()
    }

    func waveMembers(roomID: String) async throws -> [MatrixNativeWaveMember] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let ownUserID = try client.userId()
        let ignoredUserIDs = Set(try await client.ignoredUsers())
        let iterator = try await matrixRoom.members()
        var values: [MatrixNativeWaveMember] = []
        while let chunk = iterator.nextChunk(chunkSize: 100), !chunk.isEmpty {
            values.append(contentsOf: chunk.compactMap {
                MatrixNativeWaveMember(
                    $0,
                    ownUserID: ownUserID,
                    exposePresence: $0.membership == .join
                        && !ignoredUserIDs.contains($0.userId)
                )
            })
        }
        return values.sorted {
            if $0.role != $1.role {
                return Self.roleRank($0.role) > Self.roleRank($1.role)
            }
            return $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedAscending
        }
    }

    func joinedWaveDestinations(
        excludingRoomID: String
    ) async throws -> [MatrixWaveSummary] {
        let client = try await activeClient()
        var destinations: [MatrixWaveSummary] = []
        for candidate in client.rooms() where
            candidate.id() != excludingRoomID
                && candidate.membership() == .joined
                && !candidate.isSpace() {
            // Raw custom reference events are intentionally excluded from
            // encrypted and direct rooms. Sending them there would either
            // bypass room encryption or confuse direct-message semantics.
            guard !(await candidate.isDirect()),
                  !(await candidate.isEncrypted())
            else {
                continue
            }
            guard let powerLevels = try? await candidate.getPowerLevels()
            else {
                continue
            }
            guard powerLevels.canOwnUserSendMessage(
                message: messageLikeEventTypeFromString(
                    s: MatrixNativeWestreemReferenceContract.shareEventType
                )
            ) else {
                continue
            }
            destinations.append(
                MatrixWaveSummary(
                    id: candidate.id(),
                    name: MatrixNativeMemberPresentationContract.roomName(
                        candidate.displayName(),
                        fallback: "Wave"
                    ),
                    topic: candidate.topic(),
                    avatarURL: candidate.avatarUrl(),
                    joinedMemberCount: candidate.joinedMembersCount(),
                    membership: .joined,
                    isNestedSpace: false,
                    isDirect: false,
                    isEncrypted: false
                )
            )
        }
        return destinations.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func typingUpdates(roomID: String) async throws -> AsyncStream<[String]> {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let ownUserID = try client.userId()
        let pair = AsyncStream<[String]>.makeStream()
        let listener = MatrixNativeTypingListener { userIDs in
            Task {
                let ignoredUserIDs = Set((try? await client.ignoredUsers()) ?? [])
                pair.continuation.yield(
                    Array(
                        Set(userIDs.filter {
                            $0 != ownUserID && !ignoredUserIDs.contains($0)
                        })
                    ).sorted()
                )
            }
        }
        let handle = matrixRoom.subscribeToTypingNotifications(listener: listener)
        pair.continuation.onTermination = { @Sendable _ in
            handle.cancel()
        }
        return pair.stream
    }

    func updateWaveMemberRole(
        roomID: String,
        userID: String,
        role: MatrixNativeWaveMemberRole
    ) async throws {
        guard let nextPowerLevel = MatrixNativeWaveManagementContract
            .powerLevel(role)
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let member = try await matrixRoom.member(userId: userID)
        guard !member.isServiceMember,
              member.suggestedRoleForPowerLevel != .creator,
              userID != (try client.userId())
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(s: "m.room.power_levels")
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        try await matrixRoom.updatePowerLevelsForUsers(
            updates: [
                UserPowerLevelUpdate(
                    userId: userID,
                    powerLevel: nextPowerLevel
                ),
            ]
        )
    }

    func moderateWaveMember(
        roomID: String,
        userID: String,
        action: MatrixNativeWaveModerationAction,
        reason: String?
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let member = try await matrixRoom.member(userId: userID)
        guard !member.isServiceMember,
              member.suggestedRoleForPowerLevel != .creator,
              userID != (try client.userId())
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let normalizedReason = reason.flatMap(
            MatrixNativeWaveManagementContract.normalizedModerationReason
        )
        let powerLevels = try await matrixRoom.getPowerLevels()
        switch action {
        case .kick:
            guard member.membership == .join || member.membership == .invite
            else { throw MatrixNativeWaveActionError.notAllowed }
            guard powerLevels.canOwnUserKick() else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            try await matrixRoom.kickUser(
                userId: userID,
                reason: normalizedReason
            )
        case .ban:
            guard member.membership != .ban else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            guard powerLevels.canOwnUserBan() else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            try await matrixRoom.banUser(
                userId: userID,
                reason: normalizedReason
            )
        case .unban:
            guard member.membership == .ban else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            guard powerLevels.canOwnUserBan() else {
                throw MatrixNativeWaveActionError.notAllowed
            }
            try await matrixRoom.unbanUser(
                userId: userID,
                reason: normalizedReason
            )
        }
    }

    func updateWaveNotification(
        roomID: String,
        mode: MatrixNativeWaveNotificationMode
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        try await client.getNotificationSettings().setRoomNotificationMode(
            roomId: roomID,
            mode: Self.sdkNotificationMode(mode)
        )
    }

    func searchWave(
        roomID: String,
        query: String
    ) async throws -> [MatrixNativeWaveSearchResult] {
        guard let normalized = MatrixNativeWaveManagementContract
            .normalizedSearch(query)
        else {
            return []
        }
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        // MatrixRustSDK search reads the local SDK store. For encrypted Waves,
        // only events this verified device has decrypted can be returned.
        let search = client.searchService()
        let accumulator = MatrixWaveSearchAccumulator(roomID: roomID)
        let handle = await search.subscribeToResults(listener: accumulator)
        defer { withExtendedLifetime(handle) {} }
        try await search.setQuery(query: normalized)
        var page = 0
        searchPages: while page < 10 {
            for _ in 0..<80 {
                if case .idle = search.paginationState() { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard case let .idle(endReached) = search.paginationState() else {
                throw MatrixNativeWaveActionError.unavailable
            }
            if endReached || accumulator.results.count >= 100 {
                break searchPages
            }
            page += 1
            try await search.paginate()
        }
        let accumulated = accumulator.results
        let offsets = MatrixNativeWaveManagementContract.uniqueSearchResultOffsets(
            accumulated.map { ($0.roomID, $0.eventID) }
        )
        return offsets.prefix(100)
            .map { accumulated[$0] }
            .filter {
                establishmentProjections[roomID]?.permitsProjection(
                    of: $0.eventID
                ) != false
            }
    }

    private static func access(
        _ joinRule: JoinRule?
    ) throws -> MatrixNativeWaveAccess {
        switch joinRule {
        case .public: return .publicRoom
        case .invite: return .inviteOnly
        case .knock: return .requestToJoin
        case let .restricted(rules):
            guard rules.count == 1,
                  case .roomMembership = rules[0]
            else { throw MatrixNativeWaveActionError.unavailable }
            return .restrictedToParent
        case .none, .private, .knockRestricted, .custom:
            throw MatrixNativeWaveActionError.unavailable
        }
    }

    private static func history(
        _ value: RoomHistoryVisibility
    ) throws -> MatrixNativeWaveHistory {
        switch value {
        case .invited: .invited
        case .joined: .joined
        case .shared: .shared
        case .worldReadable: .worldReadable
        case .custom: throw MatrixNativeWaveActionError.unavailable
        }
    }

    private static func notificationMode(
        _ value: RoomNotificationMode
    ) -> MatrixNativeWaveNotificationMode {
        switch value {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsOnly
        case .mute: .muted
        }
    }

    private static func restrictedParentSpaceID(_ joinRule: JoinRule?) throws -> String? {
        guard case let .restricted(rules) = joinRule else { return nil }
        guard rules.count == 1,
              case let .roomMembership(roomId) = rules[0],
              roomId.first == "!",
              roomId.contains(":"),
              !roomId.contains(where: \.isWhitespace)
        else { throw MatrixNativeWaveActionError.unavailable }
        return roomId
    }

    private static func joinRule(
        _ value: MatrixNativeWaveAccess,
        parentSpaceID: String?
    ) throws -> JoinRule {
        switch value {
        case .publicRoom: return .public
        case .inviteOnly: return .invite
        case .requestToJoin: return .knock
        case .restrictedToParent:
            guard let parentSpaceID else { throw MatrixNativeWaveActionError.notAllowed }
            return .restricted(rules: [.roomMembership(roomId: parentSpaceID)])
        }
    }

    private static func sdkHistory(
        _ value: MatrixNativeWaveHistory
    ) -> RoomHistoryVisibility {
        switch value {
        case .invited: .invited
        case .joined: .joined
        case .shared: .shared
        case .worldReadable: .worldReadable
        }
    }

    private static func sdkNotificationMode(
        _ value: MatrixNativeWaveNotificationMode
    ) -> RoomNotificationMode {
        switch value {
        case .allMessages: .allMessages
        case .mentionsOnly: .mentionsAndKeywordsOnly
        case .muted: .mute
        }
    }

    private static func roleRank(_ role: MatrixNativeWaveMemberRole) -> Int {
        switch role {
        case .creator: 4
        case .administrator: 3
        case .moderator: 2
        case .member: 1
        }
    }

    /// MatrixRustSDK 26.7 does not expose a direct arbitrary custom-state
    /// getter in its Swift binding. Recover through the SDK-owned timeline
    /// store, paginating to a bounded, provable result. If the bound is
    /// reached before timeline start, fail closed rather than incorrectly
    /// claiming that the room has no rules.
    private func recoverWaveRules(
        room matrixRoom: Room,
        client: Client
    ) async throws -> MatrixNativeWaveRulesState? {
        let timeline = try await matrixRoom.timeline()
        let context = try await timelineContext(room: matrixRoom, client: client)
        let accumulator = MatrixTimelineAccumulator(context: context)
        let taskHandle = await timeline.addListener(listener: accumulator)
        defer { withExtendedLifetime(taskHandle) {} }
        await Task.yield()

        for page in 0...Self.maximumWaveRulesRecoveryPages {
            switch accumulator.waveRulesInspection {
            case .missing:
                break
            case .malformed:
                throw MatrixNativeWaveRulesReadError.invalidCanonicalState
            case .value(let state):
                return state
            }

            guard page < Self.maximumWaveRulesRecoveryPages else {
                throw MatrixNativeWaveRulesReadError.incompleteHistory
            }
            let hitTimelineStart = try await timeline.paginateBackwards(
                numEvents: Self.waveRulesRecoveryPageSize
            )
            await Task.yield()
            if hitTimelineStart {
                switch accumulator.waveRulesInspection {
                case .missing:
                    return nil
                case .malformed:
                    throw MatrixNativeWaveRulesReadError.invalidCanonicalState
                case .value(let state):
                    return state
                }
            }
        }
        throw MatrixNativeWaveRulesReadError.incompleteHistory
    }

    func timelineItems(roomID: String, paginateBackwards: Bool) async throws
        -> MatrixNativeTimelineSnapshot {
        let client = try await activeClient()
        let session: MatrixFocusedTimelineSession
        if let existing = focusedTimelines[roomID] {
            session = existing
        } else {
            let matrixRoom = try room(roomID, in: client)
            let context = try await timelineContext(room: matrixRoom, client: client)
            let timeline = try await matrixRoom.timelineWithConfiguration(
                configuration: TimelineConfiguration(
                    focus: .live(hideThreadedEvents: true),
                    filter: .all,
                    internalIdPrefix: "westreem-room-\(roomID)",
                    dateDividerMode: .daily,
                    trackReadReceipts: .messageLikeEvents,
                    reportUtds: false
                )
            )
            let accumulator = MatrixTimelineAccumulator(context: context)
            let taskHandle = await timeline.addListener(listener: accumulator)
            session = MatrixFocusedTimelineSession(
                timeline: timeline,
                accumulator: accumulator,
                taskHandle: taskHandle
            )
            focusedTimelines[roomID] = session
            await accumulator.waitForInitialSnapshot()
        }
        if paginateBackwards, !session.hitTimelineStart {
            session.hitTimelineStart = try await session.timeline.paginateBackwards(numEvents: 50)
            // Rust completes pagination after dispatching its TimelineDiff batch.
            // Yield once so the listener can publish that batch before snapshotting.
            await Task.yield()
        }
        let authoritativeProjection = await authoritativeEstablishmentProjection(
            roomID: roomID
        )
        let projected = session.accumulator.projectedTimelineItems(
            roomID: roomID,
            trustedServiceUserID: MatrixWaveEstablishmentContract
                .trustedProductionServiceUserID,
            canonicalParentSpaceIDs: canonicalParentSpaceIDsByRoomID[roomID]
                ?? [],
            authoritativeProjection: authoritativeProjection
        )
        if let projection = projected.projection {
            establishmentProjections[roomID] = projection
        } else {
            establishmentProjections.removeValue(forKey: roomID)
        }
        return MatrixNativeTimelineSnapshot(
            items: projected.items,
            hasMore: !session.hitTimelineStart,
            projectionCacheKey: projected.projection?.cacheKey
                ?? MatrixWaveEstablishmentContract.cacheKey(
                    roomID: roomID,
                    manifestHash: nil
                ),
            suppressedEventIDs: projected.projection?.suppressedEventIDs ?? []
        )
    }

    func releaseTimeline(roomID: String) async {
        focusedTimelines.removeValue(forKey: roomID)?.taskHandle.cancel()
        authoritativeEstablishmentProjectionReads.removeValue(forKey: roomID)
    }

    private func authoritativeEstablishmentProjection(
        roomID: String
    ) async -> MatrixWaveEstablishmentProjection? {
        if let cached = authoritativeEstablishmentProjectionReads[roomID],
           Date().timeIntervalSince(cached.fetchedAt) < 10 {
            return cached.projection
        }
        let projection: MatrixWaveEstablishmentProjection?
        do {
            let state = try await APIClient.shared
                .fetchMatrixWaveEstablishmentState(roomID: roomID)
            projection = MatrixWaveEstablishmentContract.verify(
                authoritative: state,
                roomID: roomID,
                trustedServiceUserID: MatrixWaveEstablishmentContract
                    .trustedProductionServiceUserID
            )
        } catch {
            projection = nil
        }
        authoritativeEstablishmentProjectionReads[roomID] = (
            fetchedAt: Date(),
            projection: projection ?? nil
        )
        return projection ?? nil
    }

    func releaseThreadTimeline(roomID: String, rootEventID: String) async {
        focusedThreadTimelines.removeValue(
            forKey: Self.threadTimelineKey(roomID: roomID, rootEventID: rootEventID)
        )?.taskHandle.cancel()
    }

    func eventItem(roomID: String, eventID: String) async throws -> MatrixTimelineItem {
        guard establishmentProjections[roomID]?.permitsProjection(of: eventID)
            != false
        else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let timeline = try await matrixRoom.timeline()
        if let event = try? await timeline.getEventTimelineItemByEventId(eventId: eventID),
           !context.ignoredUserIDs.contains(event.sender),
           let item = MatrixTimelineItem(event, context: context) {
            return item
        }
        try await timeline.fetchDetailsForEvent(eventId: eventID)
        let event = try await timeline.getEventTimelineItemByEventId(eventId: eventID)
        guard !context.ignoredUserIDs.contains(event.sender),
              let item = MatrixTimelineItem(event, context: context) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        return item
    }

    func threadSummaries(roomID: String) async throws -> [MatrixNativeThreadSummary] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let service = matrixRoom.threadListService()
        try await service.paginate()

        var summaries: [MatrixNativeThreadSummary] = []
        for listed in service.items().prefix(100) {
            let rootID = listed.rootEvent.eventId
            guard let root = try? await eventItem(roomID: roomID, eventID: rootID) else {
                continue
            }
            let focused = (try? await threadItems(
                roomID: roomID,
                rootEventID: rootID,
                paginateBackwards: false
            )) ?? []
            let replies = focused.filter { $0.id != rootID }
            let latest = replies.last
            let participants = Set(
                [root.senderDisplayName] + replies.map(\.senderDisplayName)
            ).filter { !$0.isEmpty }.sorted()
            summaries.append(
                MatrixNativeThreadSummary(
                    id: rootID,
                    rootEventID: rootID,
                    rootBody: root.body,
                    rootSenderName: root.senderDisplayName,
                    rootSenderAvatarURL: root.senderAvatarURL,
                    rootTimestamp: root.timestamp,
                    replyCount: Int(listed.numReplies),
                    lastReplyAt: latest?.timestamp ?? root.timestamp,
                    lastReplySenderName: latest?.senderDisplayName,
                    lastReplyBody: latest?.body,
                    participants: participants,
                    isParticipated: root.isOwn || replies.contains(where: \.isOwn),
                    // This SDK release does not expose per-thread unread state
                    // on ThreadListItem. Do not manufacture unread badges from
                    // reply count; the focused receipt path remains accurate.
                    hasUnread: false
                )
            )
        }
        return summaries.sorted { $0.lastReplyAt > $1.lastReplyAt }
    }

    func pinnedItems(roomID: String) async throws -> [MatrixTimelineItem] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let pinnedEventIDs = Array(
            (try await matrixRoom.roomInfo()).pinnedEventIds.prefix(100)
        ).filter {
            establishmentProjections[roomID]?.permitsProjection(of: $0)
                != false
        }
        guard !pinnedEventIDs.isEmpty else { return [] }
        let timeline = try await matrixRoom.timeline()
        var valuesByID: [String: MatrixTimelineItem] = [:]

        for eventID in pinnedEventIDs {
            if let event = try? await timeline.getEventTimelineItemByEventId(
                eventId: eventID
            ), !context.ignoredUserIDs.contains(event.sender),
               let item = MatrixTimelineItem(event, context: context) {
                valuesByID[eventID] = item
                continue
            }

            // Pinned state can point outside the current live timeline. Let
            // MatrixRustSDK hydrate the event and then resolve it locally.
            try? await timeline.fetchDetailsForEvent(eventId: eventID)
            if let event = try? await timeline.getEventTimelineItemByEventId(
                eventId: eventID
            ), !context.ignoredUserIDs.contains(event.sender),
               let item = MatrixTimelineItem(event, context: context) {
                valuesByID[eventID] = item
            }
        }
        return pinnedEventIDs.map { eventID in
            valuesByID[eventID] ?? MatrixTimelineItem(
                id: eventID,
                reference: .eventID(eventID),
                senderID: "",
                senderDisplayName: MatrixPinnedEventFallbackContract.sender,
                senderAvatarURL: nil,
                body: MatrixPinnedEventFallbackContract.body,
                kind: .unavailablePinned,
                timestamp: .distantPast,
                isOwn: false,
                isEdited: false,
                localSendState: nil,
                reactionCount: 0,
                energy: [],
                readReceiptCount: 0,
                readReceiptUserIDs: [],
                threadReplyCount: 0,
                replyPreviews: [],
                actions: MatrixNativeTimelineActions(
                    canReply: false,
                    canAddEnergy: false,
                    canEdit: false,
                    canRedact: false,
                    canReport: false,
                    canPin: MatrixPinnedEventFallbackContract.mayUnpin(
                        canManagePins: context.mayPin
                    ),
                    isPinned: true
                ),
                media: [],
                poll: nil,
                westreemReference: nil
            )
        }
    }

    func threadItems(
        roomID: String,
        rootEventID: String,
        paginateBackwards: Bool
    ) async throws -> [MatrixTimelineItem] {
        let key = Self.threadTimelineKey(roomID: roomID, rootEventID: rootEventID)
        let session: MatrixFocusedTimelineSession
        if let existing = focusedThreadTimelines[key] {
            session = existing
        } else {
            let client = try await activeClient()
            let matrixRoom = try room(roomID, in: client)
            let context = try await timelineContext(room: matrixRoom, client: client)
            let timeline = try await matrixRoom.timelineWithConfiguration(
                configuration: TimelineConfiguration(
                    focus: .thread(rootEventId: rootEventID),
                    filter: .all,
                    internalIdPrefix: "westreem-thread-\(rootEventID)",
                    dateDividerMode: .daily,
                    trackReadReceipts: .messageLikeEvents,
                    reportUtds: false
                )
            )
            let accumulator = MatrixTimelineAccumulator(context: context)
            let taskHandle = await timeline.addListener(listener: accumulator)
            session = MatrixFocusedTimelineSession(
                timeline: timeline,
                accumulator: accumulator,
                taskHandle: taskHandle
            )
            focusedThreadTimelines[key] = session
            // A focused timeline's initial items are delivered asynchronously
            // as its first TimelineDiff batch. Retain the listener and await
            // that batch; a single Task.yield races real devices and produced
            // the false "No replies yet" state seen in Discussion.
            await accumulator.waitForInitialSnapshot()
        }
        if paginateBackwards, !session.hitTimelineStart {
            session.hitTimelineStart = try await session.timeline.paginateBackwards(
                numEvents: 50
            )
            await Task.yield()
        }
        return session.accumulator.timelineItems
    }

    private static func threadTimelineKey(roomID: String, rootEventID: String) -> String {
        "\(roomID)\u{1f}\(rootEventID)"
    }

    func sendThreadReply(
        roomID: String,
        rootEventID: String,
        body: String,
        mentions: [MatrixNativeMentionTarget]
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        guard context.maySendMessage,
              let normalized = MatrixNativeWaveActionPolicy.normalizedMessage(body)
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let timeline = try await matrixRoom.timelineWithConfiguration(
            configuration: TimelineConfiguration(
                focus: .thread(rootEventId: rootEventID),
                filter: .all,
                internalIdPrefix: "westreem-thread-send-\(rootEventID)",
                dateDividerMode: .daily,
                trackReadReceipts: .messageLikeEvents,
                reportUtds: false
            )
        )
        guard let content = try await messageContent(
            body: normalized,
            mentions: mentions,
            room: matrixRoom,
            timeline: timeline
        ) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        // The Rust SDK owns queuing and idempotency. This binding intentionally
        // has no caller-supplied transaction ID for replies.
        try await timeline.sendReply(msg: content, eventId: rootEventID)
    }

    func sendText(
        roomID: String,
        body: String,
        mentions: [MatrixNativeMentionTarget],
        transactionID: String
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        guard context.maySendMessage,
              !transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalized = MatrixNativeWaveActionPolicy.normalizedMessage(body)
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let timeline = try await matrixRoom.timeline()
        guard let content = try await messageContent(
            body: normalized,
            mentions: mentions,
            room: matrixRoom,
            timeline: timeline
        ) else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let handle = try await timeline.send(msg: content)
        sendHandles[transactionID] = handle
    }

    private func messageContent(
        body: String,
        mentions: [MatrixNativeMentionTarget],
        room: Room,
        timeline: Timeline
    ) async throws -> RoomMessageEventContentWithoutRelation? {
        let activeMembers = try await waveMembers(roomID: room.id())
        let memberIDs = Set(
            activeMembers
                .filter { $0.state == .joined && !$0.isService }
                .map(\.userID)
        )
        var uniqueMentions: [String: MatrixNativeMentionTarget] = [:]
        for mention in mentions {
            uniqueMentions[mention.userID] = mention
        }
        guard uniqueMentions.keys.allSatisfy(memberIDs.contains) else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let validated = uniqueMentions.values.sorted { $0.userID < $1.userID }
        let formatted = MatrixNativeMentionComposer.formattedHTML(
            body: body,
            mentions: validated
        ).map { FormattedBody(format: .html, body: $0) }
        guard let base = timeline.createMessageContent(
            msgType: .text(
                content: TextMessageContent(body: body, formatted: formatted)
            )
        ) else {
            return nil
        }
        guard !validated.isEmpty else { return base }
        return base.withMentions(
            mentions: Mentions(
                userIds: validated.map(\.userID),
                room: false
            )
        )
    }

    func toggleEnergy(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        key: String
    ) async throws -> Bool {
        guard MatrixNativeWaveActionPolicy.isSupportedEnergyKey(key) else {
            throw MatrixNativeWaveActionError.invalidEnergy
        }
        let target = try await actionTarget(
            roomID: roomID,
            eventReference: eventReference,
            senderID: senderID
        )
        guard target.context.maySendReaction else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        return try await target.timeline.toggleReaction(
            itemId: eventReference.sdkValue,
            key: key
        )
    }

    func editText(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        body: String
    ) async throws {
        let target = try await actionTarget(
            roomID: roomID,
            eventReference: eventReference,
            senderID: senderID
        )
        guard senderID == target.context.currentUserID,
              target.context.maySendMessage,
              let normalized = MatrixNativeWaveActionPolicy.normalizedMessage(body),
              let content = target.timeline.createMessageContent(
                  msgType: .text(content: TextMessageContent(body: normalized, formatted: nil))
              )
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        try await target.timeline.edit(
            eventOrTransactionId: eventReference.sdkValue,
            newContent: .roomMessage(content: content)
        )
    }

    func redact(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String,
        reason: String?
    ) async throws {
        let target = try await actionTarget(
            roomID: roomID,
            eventReference: eventReference,
            senderID: senderID
        )
        let isOwn = senderID == target.context.currentUserID
        guard isOwn ? target.context.mayRedactOwn : target.context.mayRedactOther else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        try await target.timeline.redactEvent(
            eventOrTransactionId: eventReference.sdkValue,
            reason: reason.flatMap(MatrixNativeWaveActionPolicy.normalizedReportReason)
        )
    }

    func report(
        roomID: String,
        eventID: String,
        senderID: String,
        reason: String
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let timeline = try await matrixRoom.timeline()
        if (try? await timeline.getEventTimelineItemByEventId(eventId: eventID)) == nil {
            try await timeline.fetchDetailsForEvent(eventId: eventID)
        }
        let liveEvent = try await timeline.getEventTimelineItemByEventId(
            eventId: eventID
        )
        let liveItem = MatrixTimelineItem(liveEvent, context: context)
        guard liveEvent.sender == senderID,
              liveItem?.reference.remoteEventID == eventID,
              liveItem?.kind != .redacted,
              liveItem?.kind != .unableToDecrypt,
              senderID != context.currentUserID,
              !context.ignoredUserIDs.contains(senderID),
              !context.roomIsEncrypted,
              let normalized = MatrixNativeWaveActionPolicy.normalizedReportReason(reason)
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let fingerprint = [
            try client.userId(),
            roomID,
            eventID,
            normalized,
        ].joined(separator: "\u{0}")
        guard submittedReportFingerprints.insert(fingerprint).inserted else {
            // Exact retry is already pending or confirmed for this live
            // session. Treat it as converged rather than creating a duplicate
            // Synapse report.
            return
        }
        do {
            try await matrixRoom.reportContent(eventId: eventID, reason: normalized)
            submittedReportOrder.append(fingerprint)
            if submittedReportOrder.count > 512 {
                let expired = submittedReportOrder.removeFirst()
                submittedReportFingerprints.remove(expired)
            }
        } catch {
            submittedReportFingerprints.remove(fingerprint)
            throw error
        }
    }

    func setPinned(
        roomID: String,
        eventID: String,
        senderID: String,
        pinned: Bool
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let currentPinnedIDs = Set((try await matrixRoom.roomInfo()).pinnedEventIds)
        let timeline = try await matrixRoom.timeline()
        let event = try? await timeline.getEventTimelineItemByEventId(
            eventId: eventID
        )
        let projected = event.flatMap { MatrixTimelineItem($0, context: context) }
        let eventIsAvailable = projected.map {
            $0.kind != .redacted
                && $0.kind != .unableToDecrypt
                && $0.kind != .unavailablePinned
        } ?? false
        let decision = MatrixPinnedEventMutationContract.decide(
            eventID: eventID,
            pinned: pinned,
            currentPinnedEventIDs: currentPinnedIDs,
            canManagePins: context.mayPin,
            eventIsAvailable: eventIsAvailable,
            senderMatches: event?.sender == senderID,
            senderIsIgnored: event.map {
                context.ignoredUserIDs.contains($0.sender)
            } ?? false
        )
        switch decision {
        case .deny:
            throw MatrixNativeWaveActionError.notAllowed
        case .noOp:
            return
        case .mutate:
            break
        }
        if pinned {
            _ = try await timeline.pinEvent(eventId: eventID)
        } else {
            _ = try await timeline.unpinEvent(eventId: eventID)
        }
    }

    func sendRaw(
        roomID: String,
        eventType: String,
        contentJSON: String,
        transactionID: String
    ) async throws {
        let client = try await activeClient()
        let room = try room(roomID, in: client)
        guard
            !eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let contentData = contentJSON.data(using: .utf8),
            let content = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        guard room.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let powerLevels = try await room.getPowerLevels()
        guard powerLevels.canOwnUserSendMessage(
            message: messageLikeEventTypeFromString(s: eventType)
        ) else {
            throw MatrixNativeWaveActionError.notAllowed
        }

        if eventType == "m.room.message",
           (content["msgtype"] as? String) == "m.text",
           let body = content["body"] as? String {
            // Standard text events use the SDK timeline send queue. Local
            // echoes, retries and offline persistence therefore remain
            // Matrix-owned instead of being duplicated in Westreem storage.
            let timeline = try await room.timeline()
            guard let message = timeline.createMessageContent(
                msgType: .text(content: TextMessageContent(body: body, formatted: nil))
            ) else {
                throw MatrixSessionFoundationError.unavailable
            }
            let handle = try await timeline.send(msg: message)
            sendHandles[transactionID] = handle
            return
        }

        // Custom events stay on the official SDK transport. They are not
        // represented as successfully queued offline until the SDK exposes a
        // raw-event send-queue API.
        try await room.sendRaw(eventType: eventType, content: contentJSON)
    }

    func sendLiveStageAction(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String {
        let allowedTypes = [
            "com.westreem.live.speaker.v1",
            "com.westreem.live.stage.v1",
            "com.westreem.watch_party.v1",
        ]
        return try await sendVerifiedRawEvent(
            roomID: roomID,
            eventType: eventType,
            contentJSON: contentJSON,
            clientRequestID: clientRequestID,
            allowedTypes: allowedTypes
        )
    }

    func sendRtcCallSignal(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String {
        try await sendVerifiedRawEvent(
            roomID: roomID,
            eventType: eventType,
            contentJSON: contentJSON,
            clientRequestID: clientRequestID,
            allowedTypes: [
                "com.westreem.call_invite.v1",
                "com.westreem.call_invite_cancel.v1",
            ]
        )
    }

    private func sendVerifiedRawEvent(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String,
        allowedTypes: [String]
    ) async throws -> String {
        guard
            allowedTypes.contains(eventType),
            !clientRequestID.isEmpty,
            clientRequestID.count <= 191,
            let contentData = contentJSON.data(using: .utf8),
            let content = try? JSONSerialization.jsonObject(with: contentData)
                as? [String: Any],
            content["schema_version"] as? Int == 1,
            content["client_request_id"] as? String == clientRequestID
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let context = try await timelineContext(room: matrixRoom, client: client)
        let timeline = try await matrixRoom.timeline()
        let accumulator = MatrixTimelineAccumulator(context: context)
        let taskHandle = await timeline.addListener(listener: accumulator)
        defer { withExtendedLifetime(taskHandle) {} }
        await Task.yield()
        if let existing = accumulator.remoteEventID(
            eventType: eventType,
            clientRequestID: clientRequestID
        ) {
            return existing
        }
        // The Rust SDK owns the authenticated send. We only acknowledge the
        // action to Westreem after its remote echo exposes the immutable event
        // ID required for server-side verification.
        try await matrixRoom.sendRaw(eventType: eventType, content: contentJSON)
        for _ in 0..<20 {
            await Task.yield()
            if let eventID = accumulator.remoteEventID(
                eventType: eventType,
                clientRequestID: clientRequestID
            ) {
                return eventID
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw MatrixSessionFoundationError.unavailable
    }

    func retrySend(transactionID: String) async throws {
        guard
            let handle = sendHandles[transactionID],
            MatrixNativeRetryContract.permitsManualRetry(
                for: .text,
                hasLiveSendHandle: true
            )
        else {
            // Never recreate rich payloads from Westreem-owned memory. The
            // Matrix SDK queue remains authoritative across process restarts.
            throw MatrixSessionFoundationError.unavailable
        }
        try await handle.tryResend()
    }

    func sendAttachments(
        roomID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        transactionID: String
    ) async throws {
        try await performAttachmentSend(
            roomID: roomID,
            uploads: uploads,
            caption: caption
        )
    }

    func sendThreadAttachments(
        roomID: String,
        rootEventID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        transactionID: String
    ) async throws {
        try await performAttachmentSend(
            roomID: roomID,
            uploads: uploads,
            caption: caption,
            threadRootEventID: rootEventID
        )
    }

    func createPoll(
        roomID: String,
        question: String,
        options: [String],
        maxSelections: UInt64,
        isDisclosed: Bool,
        transactionID: String
    ) async throws {
        try await performPollSend(
            roomID: roomID,
            question: question,
            options: options,
            maxSelections: maxSelections,
            isDisclosed: isDisclosed
        )
    }

    func voteInPoll(roomID: String, eventID: String, optionIDs: [String]) async throws {
        let client = try await activeClient()
        let timeline = try await room(roomID, in: client).timeline()
        try await timeline.sendPollResponse(pollStartEventId: eventID, answers: optionIDs)
    }

    func sendSticker(
        roomID: String,
        upload: MatrixNativeUpload,
        transactionID: String
    ) async throws {
        try await performStickerSend(roomID: roomID, upload: upload)
    }

    func mediaData(
        roomID: String,
        sourceJSON: String,
        expectedSize: UInt64?
    ) async throws -> Data {
        let client = try await activeClient()
        _ = try room(roomID, in: client)
        let maximum = min(
            try await client.getMaxMediaUploadSize(),
            MatrixNativeMediaPolicy.maximumVideoBytes
        )
        if let expectedSize, expectedSize > maximum {
            throw MatrixNativeMediaError.attachmentTooLarge(limitBytes: maximum)
        }
        // MediaSource preserves the encrypted-file descriptor from the
        // timeline event. MatrixRustSDK authenticates and decrypts it inside
        // getMediaContent; Westreem never handles room keys or reimplements
        // Matrix encrypted-media cryptography.
        let source = try MediaSource.fromJson(json: sourceJSON)
        let data = try await client.getMediaContent(mediaSource: source)
        try MatrixNativeMediaPolicy.validateDownload(
            size: expectedSize,
            receivedBytes: data.count,
            serverMaximumBytes: maximum
        )
        return data
    }

    func mediaThumbnailData(
        roomID: String,
        sourceJSON: String,
        width: UInt64,
        height: UInt64
    ) async throws -> Data {
        let client = try await activeClient()
        _ = try room(roomID, in: client)
        let source = try MediaSource.fromJson(json: sourceJSON)
        return try await client.getMediaThumbnail(
            mediaSource: source,
            width: width,
            height: height
        )
    }

    func avatarData(avatarURL: String) async throws -> Data {
        guard avatarURL.hasPrefix("mxc://") else {
            throw MatrixNativeMediaError.mediaUnavailable
        }
        let client = try await activeClient()
        let source = try MediaSource.fromUrl(url: avatarURL)
        let data = try await client.getMediaThumbnail(
            mediaSource: source,
            width: 256,
            height: 256
        )
        guard MatrixNativeAvatarContract.accepts(data) else {
            throw MatrixNativeMediaError.mediaUnavailable
        }
        return data
    }

    func setTyping(roomID: String, isTyping: Bool) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        try await matrixRoom.typingNotice(isTyping: isTyping)
    }

    func markRead(roomID: String) async throws {
        let client = try await activeClient()
        let timeline = try await room(roomID, in: client).timeline()
        try await timeline.markAsRead(receiptType: .read)
    }

    func markThreadRead(roomID: String, rootEventID: String) async throws {
        let key = Self.threadTimelineKey(roomID: roomID, rootEventID: rootEventID)
        if focusedThreadTimelines[key] == nil {
            _ = try await threadItems(
                roomID: roomID,
                rootEventID: rootEventID,
                paginateBackwards: false
            )
        }
        guard let session = focusedThreadTimelines[key] else {
            throw MatrixNativeWaveActionError.unavailable
        }
        try await session.timeline.markAsRead(receiptType: .read)
    }

    func acceptInvite(roomID: String) async throws {
        let client = try await activeClient()
        let invited = try room(roomID, in: client)
        guard invited.membership() == .invited else {
            throw MatrixSessionFoundationError.unavailable
        }
        let currentUserID = try client.userId()
        let info = try await invited.roomInfo()
        let ignored = Set(try await client.ignoredUsers())
        let rawInviterUserID: String? = info.inviter?.userId
        let inviterUserID: String?
        if let rawInviterUserID,
           rawInviterUserID.first == "@",
           rawInviterUserID.contains(":"),
           rawInviterUserID != currentUserID {
            inviterUserID = rawInviterUserID
        } else {
            inviterUserID = nil
        }
        let isDirect = await invited.isDirect()
        let isEncrypted = await invited.isEncrypted()
        let kind: MatrixInvitationKind = invited.isSpace()
            ? .vibe
            : (isDirect ? .personalWave : .wave)
        let safety = MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: kind,
            isEncrypted: isEncrypted,
            inviterIsBlocked: inviterUserID.map(ignored.contains) ?? false,
            inviterUserID: inviterUserID
        )
        guard safety.canAccept else {
            throw MatrixSessionFoundationError.unavailable
        }
        try await invited.join()
    }

    func declineInvite(roomID: String) async throws {
        let client = try await activeClient()
        let invited = try room(roomID, in: client)
        guard invited.membership() == .invited else {
            throw MatrixSessionFoundationError.unavailable
        }
        try await invited.leave()
    }

    func declineInviteAndBlock(roomID: String) async throws {
        let client = try await activeClient()
        let invited = try room(roomID, in: client)
        let info = try await invited.roomInfo()
        let ignored = Set(try await client.ignoredUsers())
        guard let plan = MatrixInviteDeclineBlockContract.plan(
            membershipIsInvited: invited.membership() == .invited,
            inviterUserID: info.inviter?.userId,
            currentUserID: try client.userId(),
            ignoredUserIDs: ignored
        ) else {
            throw MatrixSessionFoundationError.unavailable
        }
        if plan.mustAddIgnore {
            try await client.ignoreUser(userId: plan.inviterUserID)
        }
        do {
            try await invited.leave()
        } catch {
            if MatrixInviteDeclineBlockContract.mustRollbackNewIgnore(
                plan: plan,
                leaveSucceeded: false
            ) {
                try? await client.unignoreUser(userId: plan.inviterUserID)
            }
            throw error
        }
    }

    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String,
        experience: MatrixNativeRtcExperience
    ) async throws -> String {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixSessionFoundationError.unavailable
        }
        let roomKind: MatrixNativeRtcAuthorityRoomKind = matrixRoom.isSpace()
            ? .vibeSpace
            : .waveOrDirect
        var activeLegacyExperience: MatrixNativeRtcExperience?
        if roomKind == .waveOrDirect {
            switch experience {
            case .liveStage:
                if try await liveStageState(roomID: roomID)?.isLive == true {
                    activeLegacyExperience = .liveStage
                }
            case .watchParty:
                if try await watchPartyState(roomID: roomID)?.isActive == true {
                    activeLegacyExperience = .watchParty
                }
            case .call, .groupLounge:
                break
            }
        }
        guard MatrixNativeRtcOwnershipContract.decide(
            experience: experience,
            roomKind: roomKind,
            operation: .join,
            activeLegacyExperience: activeLegacyExperience
        ).allowed else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let powerLevels = try await matrixRoom.getPowerLevels()
        guard powerLevels.canOwnUserSendState(
            stateEvent: stateEventTypeFromString(
                s: MatrixNativeRtcContract.membershipEventType
            )
        ) else {
            throw MatrixNativeRtcError.adminEnablementRequired
        }
        guard
            let serviceURL = URL(string: livekitServiceURL),
            serviceURL.scheme == "https",
            C.isTrustedBackendURL(serviceURL)
        else {
            throw MatrixNativeRtcError.invalidService
        }
        let userID = try client.userId()
        let deviceID = try client.deviceId()
        let stateKey = "_\(userID)_\(deviceID)_m.call"
        func membershipJSON() throws -> String {
            let createdAt = Int64(Date().timeIntervalSince1970 * 1_000)
            let content: [String: Any] = [
                "application": "m.call",
                "call_id": "",
                "scope": "m.room",
                "device_id": deviceID,
                "membershipID": "\(userID):\(deviceID)",
                "created_ts": createdAt,
                "expires": MatrixNativeRtcContract.membershipLifetimeMilliseconds,
                "m.call.intent": intent.rawValue,
                "focus_active": [
                    "type": "livekit",
                    "focus_selection": "oldest_membership",
                ],
                "foci_preferred": [[
                    "type": "livekit",
                    "livekit_service_url": serviceURL.absoluteString,
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: content)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MatrixNativeRtcError.invalidMembership
            }
            return json
        }

        rtcMembershipTasks[roomID]?.cancel()
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeRtcContract.membershipEventType,
            stateKey: stateKey,
            content: try membershipJSON()
        )
        rtcMembershipTasks[roomID] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .milliseconds(
                        MatrixNativeRtcContract.membershipRefreshMilliseconds
                    )
                )
                guard !Task.isCancelled else { return }
                _ = try? await matrixRoom.sendStateEventRaw(
                    eventType: MatrixNativeRtcContract.membershipEventType,
                    stateKey: stateKey,
                    content: membershipJSON()
                )
            }
        }
        return deviceID
    }

    func endRtcMembership(roomID: String) async throws {
        rtcMembershipTasks[roomID]?.cancel()
        rtcMembershipTasks[roomID] = nil
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let stateKey = "_\(try client.userId())_\(try client.deviceId())_m.call"
        _ = try await matrixRoom.sendStateEventRaw(
            eventType: MatrixNativeRtcContract.membershipEventType,
            stateKey: stateKey,
            content: "{}"
        )
    }

    private func actionTarget(
        roomID: String,
        eventReference: MatrixNativeEventReference,
        senderID: String
    ) async throws -> (
        timeline: Timeline,
        context: MatrixNativeTimelineContext
    ) {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        guard !context.ignoredUserIDs.contains(senderID) else {
            throw MatrixNativeWaveActionError.ignoredSender
        }
        if case .transactionID = eventReference,
           senderID != context.currentUserID {
            throw MatrixNativeWaveActionError.notAllowed
        }
        return (try await matrixRoom.timeline(), context)
    }

    private func timelineContext(
        room: Room,
        client: Client
    ) async throws -> MatrixNativeTimelineContext {
        guard room.membership() == .joined else {
            throw MatrixNativeWaveActionError.roomNotJoined
        }
        let currentUserID = try client.userId()
        let ignored = Set(try await client.ignoredUsers())
        let info = try await room.roomInfo()
        let powerLevels = try await room.getPowerLevels()
        return MatrixNativeTimelineContext(
            currentUserID: currentUserID,
            ignoredUserIDs: ignored,
            roomIsEncrypted: await room.isEncrypted(),
            pinnedEventIDs: Set(info.pinnedEventIds),
            maySendMessage: powerLevels.canOwnUserSendMessage(message: .roomMessage),
            maySendReaction: powerLevels.canOwnUserSendMessage(message: .reaction),
            mayRedactOwn: powerLevels.canOwnUserRedactOwn(),
            mayRedactOther: powerLevels.canOwnUserRedactOther(),
            mayPin: powerLevels.canOwnUserPinUnpin()
        )
    }

    private func activeClient() async throws -> Client {
        guard let client = await sessionCoordinator.activeClient() else {
            throw MatrixSessionFoundationError.unavailable
        }
        return client
    }

    private func room(_ roomID: String, in client: Client) throws -> Room {
        guard let room = client.rooms().first(where: { $0.id() == roomID }) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return room
    }

    private func performAttachmentSend(
        roomID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        threadRootEventID: String? = nil
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let maximum = try await client.getMaxMediaUploadSize()
        try MatrixNativeMediaPolicy.validate(uploads, serverMaximumBytes: maximum)
        // Timeline attachment APIs inspect the room encryption state and
        // upload encrypted file descriptors when required. Keeping this on
        // MatrixRustSDK avoids exposing media keys to Westreem.
        let timeline = if let threadRootEventID {
            try await matrixRoom.timelineWithConfiguration(
                configuration: TimelineConfiguration(
                    focus: .thread(rootEventId: threadRootEventID),
                    filter: .all,
                    internalIdPrefix: "westreem-thread-media-\(threadRootEventID)",
                    dateDividerMode: .daily,
                    trackReadReceipts: .messageLikeEvents,
                    reportUtds: false
                )
            )
        } else {
            try await matrixRoom.timeline()
        }

        if uploads.count > 1 {
            let items = uploads.map(MatrixNativeGalleryFactory.item)
            let handle = try timeline.sendGallery(
                params: GalleryUploadParameters(
                    caption: normalizedCaption(caption),
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: threadRootEventID
                ),
                itemInfos: items
            )
            try await handle.join()
        } else if let upload = uploads.first {
            let params = UploadParameters(
                source: .data(bytes: upload.data, filename: upload.filename),
                caption: normalizedCaption(caption),
                formattedCaption: nil,
                mentions: nil,
                inReplyTo: threadRootEventID
            )
            let handle: SendAttachmentJoinHandle
            switch upload.kind {
            case .image:
                handle = try timeline.sendImage(
                    params: params,
                    thumbnailSource: nil,
                    imageInfo: MatrixNativeGalleryFactory.imageInfo(upload)
                )
            case .audio:
                handle = try timeline.sendAudio(
                    params: params,
                    audioInfo: MatrixNativeGalleryFactory.audioInfo(upload)
                )
            case .voice:
                // Pass captured MSC3245 waveform if available.
                // Our contract stores MSC3245 samples as 0...1024 integers.
                // MatrixRustSDK accepts the same amplitudes normalized to
                // 0...1 Float values at its Swift FFI boundary.
                let waveformFloat = upload.waveform?.map {
                    Float(min(max($0, 0), 1_024)) / 1_024.0
                } ?? []
                handle = try timeline.sendVoiceMessage(
                    params: params,
                    audioInfo: MatrixNativeGalleryFactory.audioInfo(upload),
                    waveform: waveformFloat
                )
            case .video:
                handle = try timeline.sendVideo(
                    params: params,
                    thumbnailSource: nil,
                    videoInfo: MatrixNativeGalleryFactory.videoInfo(upload)
                )
            case .file:
                handle = try timeline.sendFile(
                    params: params,
                    fileInfo: MatrixNativeGalleryFactory.fileInfo(upload)
                )
            case .sticker:
                throw MatrixNativeMediaError.invalidAttachment
            }
            try await handle.join()
        }
    }

    private func performPollSend(
        roomID: String,
        question: String,
        options: [String],
        maxSelections: UInt64,
        isDisclosed: Bool
    ) async throws {
        let validated = try MatrixNativeMediaPolicy.validatePoll(
            question: question,
            options: options
        )
        let client = try await activeClient()
        let timeline = try await room(roomID, in: client).timeline()
        let boundedMaxSelections = min(max(1, maxSelections), UInt64(validated.1.count))
        try await timeline.createPoll(
            question: validated.0,
            answers: validated.1,
            maxSelections: UInt8(clamping: boundedMaxSelections),
            pollKind: isDisclosed ? .disclosed : .undisclosed
        )
    }

    private func performStickerSend(
        roomID: String,
        upload: MatrixNativeUpload
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard !(await matrixRoom.isEncrypted()) else {
            throw MatrixNativeMediaError.encryptedMediaUnavailable
        }
        let maximum = try await client.getMaxMediaUploadSize()
        try MatrixNativeMediaPolicy.validate([upload], serverMaximumBytes: maximum)
        guard upload.kind == .sticker || upload.kind == .image else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        let mediaURI = try await client.uploadMedia(
            mimeType: upload.mimeType,
            data: upload.data,
            progressWatcher: nil
        )
        let content: [String: Any] = [
            "body": String(upload.filename.prefix(255)),
            "url": mediaURI,
            "info": [
                "mimetype": upload.mimeType,
                "size": upload.data.count,
                "w": upload.width ?? 0,
                "h": upload.height ?? 0,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        try await matrixRoom.sendRaw(eventType: "m.sticker", content: json)
    }

    private func normalizedCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let value = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(4_000))
    }

    private func createRoomParameters(
        _ creation: MatrixNativeValidatedRoomCreation,
        isSpace: Bool,
        serviceUserID: String,
        parentSpaceID: String?,
        avatarURI: String?
    ) -> CreateRoomParameters {
        let isPublic = creation.visibility == .publicVibe
        let joinRule: JoinRule = switch creation.visibility {
        case .publicVibe: .public
        case .privateVibe: .invite
        case .knock: .knock
        case .restricted:
            if let parentSpaceID {
                .restricted(rules: [.roomMembership(roomId: parentSpaceID)])
            } else {
                .invite
            }
        }
        return CreateRoomParameters(
            name: creation.name,
            topic: creation.topic,
            // Application-level E2EE is disabled for all new Vibes and Waves.
            isEncrypted: false,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat,
            invite: [serviceUserID],
            avatar: avatarURI,
            powerLevelContentOverride: PowerLevels(
                usersDefault: 0,
                eventsDefault: 0,
                stateDefault: 50,
                ban: 50,
                kick: 50,
                redact: 50,
                invite: 50,
                notifications: nil,
                users: [:],
                events: isSpace
                    ? ["m.space.child": 50]
                    : [MatrixNativeRtcContract.membershipEventType: 0]
            ),
            joinRuleOverride: joinRule,
            historyVisibilityOverride: isPublic ? .shared : .invited,
            // Matrix createRoom's room_alias_name field accepts only the
            // localpart. Keep the validated full canonical alias in the
            // product draft, but send the SDK the wire-format it requires.
            canonicalAlias: MatrixNativeCreationContract.roomAliasLocalpart(
                creation.canonicalAlias
            ),
            isSpace: isSpace
        )
    }

    private func uploadCreationAvatar(
        _ avatar: MatrixNativeRoomCreationAvatar?,
        client: Client
    ) async throws -> String? {
        guard let avatar else { return nil }
        let upload = MatrixNativeUpload(
            kind: .image,
            data: avatar.data,
            filename: avatar.filename,
            mimeType: avatar.mimeType,
            width: avatar.width,
            height: avatar.height
        )
        let maximum = min(
            try await client.getMaxMediaUploadSize(),
            UInt64(MatrixNativeCreationContract.maximumAvatarBytes)
        )
        try MatrixNativeMediaPolicy.validate(
            [upload],
            serverMaximumBytes: maximum
        )
        let mediaURI = try await client.uploadMedia(
            mimeType: upload.mimeType,
            data: upload.data,
            progressWatcher: nil
        )
        guard mediaURI.hasPrefix("mxc://"),
              mediaURI.utf8.count <= 2_048,
              !mediaURI.contains(where: \.isWhitespace),
              (try? MediaSource.fromUrl(url: mediaURI)) != nil
        else {
            throw MatrixNativeMediaError.mediaUnavailable
        }
        return mediaURI
    }

    private static func validateLocalAlias(_ alias: String?, userID: String) throws {
        guard let alias else { return }
        guard let userSeparator = userID.firstIndex(of: ":"),
              let aliasSeparator = alias.firstIndex(of: ":"),
              String(alias[alias.index(after: aliasSeparator)...])
                .caseInsensitiveCompare(String(userID[userID.index(after: userSeparator)...])) == .orderedSame
        else {
            throw MatrixNativeCreationValidationError.invalidCanonicalAlias
        }
    }

    private func setPublicSharingState(
        room: Room,
        isPublic: Bool
    ) async throws {
        let content = try Self.json([
            "schema_version": 1,
            "enabled": isPublic,
            "allowed_event_types": isPublic
                ? [
                    "m.room.message",
                    "m.sticker",
                    "m.poll.start",
                    "org.matrix.msc3381.poll.start",
                    "com.westreem.share.v1",
                    "com.westreem.event_ref.v1",
                ]
                : [],
        ])
        _ = try await room.sendStateEventRaw(
            eventType: "com.westreem.public_sharing.v1",
            stateKey: "",
            content: content
        )
    }

    private func registerNativeRoom(
        entityType: String,
        roomID: String,
        matrixSpaceID: String
    ) async -> Bool {
        do {
            _ = try await APIClient.shared.registerMatrixNativeRoom(
                entityType: entityType,
                matrixRoomID: roomID,
                matrixSpaceID: matrixSpaceID
            )
            return true
        } catch {
            return false
        }
    }

    private static func serviceUserID(for matrixUserID: String) throws -> String {
        guard
            let separator = matrixUserID.firstIndex(of: ":"),
            separator < matrixUserID.index(before: matrixUserID.endIndex)
        else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let server = matrixUserID[matrixUserID.index(after: separator)...]
        return "@westreem_service:\(server)"
    }

    private func createdRoom(_ roomID: String, client: Client) async throws -> Room {
        for _ in 0..<8 {
            if let room = try client.getRoom(roomId: roomID) {
                return room
            }
            await Task.yield()
        }
        throw MatrixSessionFoundationError.unavailable
    }

    private func inviteValidatedUsers(
        _ userIDs: [String],
        to room: Room
    ) async -> [String] {
        guard !userIDs.isEmpty else { return [] }
        guard
            room.membership() == .joined,
            let powerLevels = try? await room.getPowerLevels(),
            powerLevels.canOwnUserInvite()
        else {
            return userIDs
        }

        var failures: [String] = []
        for userID in userIDs {
            do {
                try await room.inviteUserById(userId: userID)
            } catch {
                failures.append(userID)
            }
        }
        return failures
    }

    private static func mayJoin(_ joinRule: JoinRule?) -> Bool {
        guard let joinRule else { return false }
        switch joinRule {
        case .public:
            return true
        case .invite, .knock, .private, .restricted, .knockRestricted, .custom:
            return false
        }
    }

    private static func viaServers(
        roomID: String,
        alias: String?,
        fallbackUserID: String? = nil
    ) -> [String] {
        var values: [String] = []
        for candidate in [alias, roomID, fallbackUserID].compactMap({ $0 }) {
            guard let separator = candidate.lastIndex(of: ":") else { continue }
            let server = candidate[candidate.index(after: separator)...]
            guard !server.isEmpty else { continue }
            let value = String(server)
            if !values.contains(value) {
                values.append(value)
            }
        }
        return values
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let value = String(data: data, encoding: .utf8) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return value
    }

}

private enum MatrixNativeGalleryFactory {
    static func item(_ upload: MatrixNativeUpload) -> GalleryItemInfo {
        let source = UploadSource.data(bytes: upload.data, filename: upload.filename)
        switch upload.kind {
        case .image, .sticker:
            return .image(
                imageInfo: imageInfo(upload),
                source: source,
                caption: nil,
                formattedCaption: nil,
                thumbnailSource: nil
            )
        case .audio, .voice:
            return .audio(
                audioInfo: audioInfo(upload),
                source: source,
                caption: nil,
                formattedCaption: nil
            )
        case .video:
            return .video(
                videoInfo: videoInfo(upload),
                source: source,
                caption: nil,
                formattedCaption: nil,
                thumbnailSource: nil
            )
        case .file:
            return .file(
                fileInfo: fileInfo(upload),
                source: source,
                caption: nil,
                formattedCaption: nil
            )
        }
    }

    static func imageInfo(_ upload: MatrixNativeUpload) -> ImageInfo {
        ImageInfo(
            height: upload.height,
            width: upload.width,
            mimetype: upload.mimeType,
            size: UInt64(upload.data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil,
            blurhash: nil,
            isAnimated: upload.mimeType == "image/gif"
        )
    }

    static func audioInfo(_ upload: MatrixNativeUpload) -> AudioInfo {
        AudioInfo(
            duration: upload.duration,
            size: UInt64(upload.data.count),
            mimetype: upload.mimeType
        )
    }

    static func videoInfo(_ upload: MatrixNativeUpload) -> VideoInfo {
        VideoInfo(
            duration: upload.duration,
            height: upload.height,
            width: upload.width,
            mimetype: upload.mimeType,
            size: UInt64(upload.data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil,
            blurhash: nil
        )
    }

    static func fileInfo(_ upload: MatrixNativeUpload) -> FileInfo {
        FileInfo(
            mimetype: upload.mimeType,
            size: UInt64(upload.data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil
        )
    }
}

private final class MatrixRoomDirectoryAccumulator:
    RoomDirectorySearchEntriesListener,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var rooms: [RoomDescription] = []

    var roomDescriptions: [RoomDescription] {
        lock.withLock { rooms }
    }

    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        lock.withLock {
            for update in roomEntriesUpdate {
                switch update {
                case let .append(values):
                    rooms.append(contentsOf: values)
                case .clear:
                    rooms.removeAll()
                case let .pushFront(value):
                    rooms.insert(value, at: 0)
                case let .pushBack(value):
                    rooms.append(value)
                case .popFront:
                    if !rooms.isEmpty { rooms.removeFirst() }
                case .popBack:
                    if !rooms.isEmpty { rooms.removeLast() }
                case let .insert(index, value):
                    rooms.insert(value, at: min(Int(index), rooms.count))
                case let .set(index, value):
                    guard Int(index) < rooms.count else { continue }
                    rooms[Int(index)] = value
                case let .remove(index):
                    guard Int(index) < rooms.count else { continue }
                    rooms.remove(at: Int(index))
                case let .truncate(length):
                    rooms = Array(rooms.prefix(Int(length)))
                case let .reset(values):
                    rooms = values
                }
            }
        }
    }
}

private final class MatrixWaveSearchAccumulator:
    SearchServiceResultsListener,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let roomID: String
    private var values: [SearchServiceResult] = []

    init(roomID: String) {
        self.roomID = roomID
    }

    var results: [MatrixNativeWaveSearchResult] {
        lock.withLock {
            values.compactMap { value in
                guard case let .message(resultRoomID, result) = value,
                      resultRoomID == roomID,
                      case let .msgLike(content) = result.content
                else {
                    return nil
                }
                let presentation = MatrixNativeMessagePresentation(content.kind)
                let profileName: String?
                switch result.senderProfile {
                case let .ready(name, _, _, _, _): profileName = name
                default: profileName = nil
                }
                return MatrixNativeWaveSearchResult(
                    roomID: resultRoomID,
                    eventID: result.eventId,
                    senderID: result.sender,
                    senderDisplayName: MatrixNativeMemberPresentationContract
                        .displayName(
                            profileName,
                            matrixUserID: result.sender
                        ),
                    body: presentation.body,
                    timestamp: Date(
                        timeIntervalSince1970: TimeInterval(result.timestamp) / 1_000
                    )
                )
            }
        }
    }

    func onUpdate(updates: [SearchServiceResultsUpdate]) {
        lock.withLock {
            for update in updates {
                switch update {
                case let .append(next):
                    values.append(contentsOf: next)
                case .clear:
                    values.removeAll()
                case let .pushFront(value):
                    values.insert(value, at: 0)
                case let .pushBack(value):
                    values.append(value)
                case .popFront:
                    if !values.isEmpty { values.removeFirst() }
                case .popBack:
                    if !values.isEmpty { values.removeLast() }
                case let .insert(index, value):
                    values.insert(value, at: min(Int(index), values.count))
                case let .set(index, value):
                    guard Int(index) < values.count else { continue }
                    values[Int(index)] = value
                case let .remove(index):
                    guard Int(index) < values.count else { continue }
                    values.remove(at: Int(index))
                case let .truncate(length):
                    values = Array(values.prefix(Int(length)))
                case let .reset(next):
                    values = next
                }
            }
        }
    }
}

private final class MatrixTimelineAccumulator: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private let context: MatrixNativeTimelineContext
    private var items: [TimelineItem] = []
    private var updateGeneration = 0
    private var waiters: [(UUID, Int, CheckedContinuation<Void, Never>)] = []
    private var cancelledWaiters = Set<UUID>()

    init(context: MatrixNativeTimelineContext) {
        self.context = context
    }

    var timelineItems: [MatrixTimelineItem] {
        lock.withLock {
            items.compactMap { item in
                guard let event = item.asEvent() else { return nil }
                guard !context.ignoredUserIDs.contains(event.sender) else {
                    return nil
                }
                return MatrixTimelineItem(event, context: context)
            }
        }
    }

    func projectedTimelineItems(
        roomID: String,
        trustedServiceUserID: String,
        canonicalParentSpaceIDs: Set<String>,
        authoritativeProjection: MatrixWaveEstablishmentProjection? = nil
    ) -> (
        items: [MatrixTimelineItem],
        projection: MatrixWaveEstablishmentProjection?
    ) {
        lock.withLock {
            let projection = authoritativeProjection ?? Self.establishmentProjection(
                    in: items,
                    roomID: roomID,
                    trustedServiceUserID: trustedServiceUserID,
                    canonicalParentSpaceIDs: canonicalParentSpaceIDs
                )
            let suppressedEventIDs = projection?.suppressedEventIDs ?? []
            let projected = items.compactMap { item -> MatrixTimelineItem? in
                guard let event = item.asEvent() else { return nil }
                guard !context.ignoredUserIDs.contains(event.sender) else {
                    return nil
                }
                if case let .eventId(eventID) = event.eventOrTransactionId,
                   suppressedEventIDs.contains(eventID) {
                    return nil
                }
                return MatrixTimelineItem(event, context: context)
            }
            return (projected, projection)
        }
    }

    func waveEstablishmentProjection(
        roomID: String,
        trustedServiceUserID: String,
        canonicalParentSpaceIDs: Set<String>
    ) -> MatrixWaveEstablishmentProjection? {
        lock.withLock {
            Self.establishmentProjection(
                in: items,
                roomID: roomID,
                trustedServiceUserID: trustedServiceUserID,
                canonicalParentSpaceIDs: canonicalParentSpaceIDs
            )
        }
    }

    private static func establishmentProjection(
        in items: [TimelineItem],
        roomID: String,
        trustedServiceUserID: String,
        canonicalParentSpaceIDs: Set<String>
    ) -> MatrixWaveEstablishmentProjection? {
        guard !canonicalParentSpaceIDs.isEmpty else { return nil }

        var candidate: MatrixWaveEstablishmentRawCandidate?
        for item in items.reversed() {
            guard
                let event = item.asEvent(),
                event.eventTypeRaw == MatrixWaveEstablishmentContract.eventType
            else {
                continue
            }
            // The newest marker is authoritative. A malformed replacement
            // invalidates projection suppression instead of resurrecting an
            // older valid marker.
            guard
                case let .eventId(eventID) = event.eventOrTransactionId,
                let (contentJSON, stateKey) =
                    MatrixNativeRawEvent.contentAndStateKey(event)
            else {
                return nil
            }
            candidate = MatrixWaveEstablishmentRawCandidate(
                markerEventID: eventID,
                stateKey: stateKey,
                senderID: event.sender,
                contentJSON: contentJSON
            )
            break
        }
        guard let candidate else { return nil }

        return MatrixWaveEstablishmentContract.verify(
            contentJSON: candidate.contentJSON,
            markerEventID: candidate.markerEventID,
            stateKey: candidate.stateKey,
            senderID: candidate.senderID,
            trustedServiceUserID: trustedServiceUserID,
            roomID: roomID,
            canonicalParentSpaceIDs: canonicalParentSpaceIDs,
            hasCanonicalReciprocalParentEdge: { parentSpaceID in
                for item in items.reversed() {
                    guard
                        let event = item.asEvent(),
                        event.eventTypeRaw == "m.space.parent",
                        let (contentJSON, stateKey) =
                            MatrixNativeRawEvent.contentAndStateKey(event),
                        stateKey == parentSpaceID
                    else {
                        continue
                    }
                    // The newest write for this state key is authoritative;
                    // an empty/tombstoned or non-canonical edge must not fall
                    // back to an older valid write.
                    return MatrixWaveEstablishmentContract
                        .isCanonicalParentContent(contentJSON)
                }
                return false
            }
        )
    }

    var waveRulesInspection: MatrixNativeWaveRulesInspection {
        lock.withLock {
            for item in items.reversed() {
                guard
                    let event = item.asEvent(),
                    event.eventTypeRaw == MatrixNativeWaveRulesContract.eventType
                else {
                    continue
                }
                guard
                    let contentJSON = MatrixNativeRawEvent.contentJSON(event),
                    let state = try? MatrixNativeWaveRulesContract.decode(
                        contentJSON: contentJSON
                    )
                else {
                    // The newest matching state event is authoritative. Falling
                    // back to an older valid event would resurrect superseded
                    // rules and hide a schema/security failure.
                    return .malformed
                }
                return .value(state)
            }
            return .missing
        }
    }

    func remoteEventID(
        eventType: String,
        clientRequestID: String
    ) -> String? {
        lock.withLock {
            for item in items.reversed() {
                guard
                    let event = item.asEvent(),
                    event.eventTypeRaw == eventType,
                    let contentJSON = MatrixNativeRawEvent.contentJSON(event),
                    let data = contentJSON.data(using: .utf8),
                    let content = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    content["client_request_id"] as? String == clientRequestID
                else {
                    continue
                }
                if case let .eventId(eventID) = event.eventOrTransactionId {
                    return eventID
                }
            }
            return nil
        }
    }

    /// Returns the newest observed state events matching `eventType` whose
    /// `state_key` satisfies `stateKeyFilter`. Newest events appear first;
    /// for keys that repeat, only the most recent write is returned.
    /// Yields `(contentJSON, stateKey)` tuples.
    func customStateEvents(
        eventType: String,
        stateKeyFilter: (String) -> Bool
    ) -> [(String, String)] {
        lock.withLock {
            var seen = Set<String>()
            var results: [(String, String)] = []
            for item in items.reversed() {
                guard let event = item.asEvent(),
                      event.eventTypeRaw == eventType,
                      let (contentJSON, stateKey) =
                        MatrixNativeRawEvent.contentAndStateKey(event),
                      stateKeyFilter(stateKey),
                      !seen.contains(stateKey) else {
                    continue
                }
                seen.insert(stateKey)
                results.append((contentJSON, stateKey))
            }
            return results
        }
    }

    func onUpdate(diff: [TimelineDiff]) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            for change in diff {
                switch change {
                case let .append(values):
                    items.append(contentsOf: values)
                case .clear:
                    items.removeAll()
                case let .pushFront(value):
                    items.insert(value, at: 0)
                case let .pushBack(value):
                    items.append(value)
                case .popFront:
                    if !items.isEmpty { items.removeFirst() }
                case .popBack:
                    if !items.isEmpty { items.removeLast() }
                case let .insert(index, value):
                    items.insert(value, at: min(Int(index), items.count))
                case let .set(index, value):
                    guard Int(index) < items.count else { continue }
                    items[Int(index)] = value
                case let .remove(index):
                    guard Int(index) < items.count else { continue }
                    items.remove(at: Int(index))
                case let .truncate(length):
                    items = Array(items.prefix(Int(length)))
                case let .reset(values):
                    items = values
                }
            }
            updateGeneration += 1
            let ready = waiters.compactMap { _, generation, continuation in
                generation < updateGeneration ? continuation : nil
            }
            waiters.removeAll { $0.1 < updateGeneration }
            return ready
        }
        continuations.forEach { $0.resume() }
    }

    func waitForInitialSnapshot() async {
        await waitForUpdate(after: 0)
    }

    func waitForUpdate(after generation: Int) async {
        if lock.withLock({ updateGeneration > generation }) { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if updateGeneration > generation
                        || cancelledWaiters.remove(waiterID) != nil {
                        return true
                    }
                    waiters.append((waiterID, generation, continuation))
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            cancelWaiter(waiterID)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            if let index = waiters.firstIndex(where: { $0.0 == id }) {
                return waiters.remove(at: index).2
            }
            cancelledWaiters.insert(id)
            return nil
        }
        continuation?.resume()
    }
}

private final class MatrixFocusedTimelineSession: @unchecked Sendable {
    let timeline: Timeline
    let accumulator: MatrixTimelineAccumulator
    let taskHandle: TaskHandle
    var hitTimelineStart = false

    init(timeline: Timeline, accumulator: MatrixTimelineAccumulator, taskHandle: TaskHandle) {
        self.timeline = timeline
        self.accumulator = accumulator
        self.taskHandle = taskHandle
    }
}

/// Default-off Matrix-authoritative repository installation point.
///
/// The rollout gate is checked for every operation, not only session startup,
/// so an emergency disable cannot leave an already-created repository active.
actor MatrixVibesRepositoryFoundation: VibesRepository {
    typealias VibeDirectory = MatrixVibeDirectoryPage
    typealias WaveDirectory = MatrixWaveDirectoryPage
    typealias Timeline = MatrixTimelinePage
    typealias OutboundEvent = MatrixOutboundEvent
    typealias SentEvent = MatrixSentEvent

    private let sessionCoordinator: MatrixSessionCoordinator
    private let rollout: MatrixSessionRollout
    private let sdk: any MatrixVibesSDKProviding

    init(
        sessionCoordinator: MatrixSessionCoordinator,
        rollout: MatrixSessionRollout = .disabled,
        sdk: (any MatrixVibesSDKProviding)? = nil
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.rollout = rollout
        self.sdk = sdk ?? MatrixRustSDKVibesProvider(sessionCoordinator: sessionCoordinator)
    }

    func startSession(westreemUserID: String) async {
        await sessionCoordinator.start(westreemUserID: westreemUserID, rollout: rollout)
    }

    func vibes(cursor: String?) async throws -> MatrixVibeDirectoryPage {
        try requireEnabled()
        return MatrixVibeDirectoryPage(
            spaces: try await sdk.topLevelSpaces(),
            nextCursor: nil
        )
    }

    func pendingInvitations() async throws -> [MatrixNativeInvitationSummary] {
        try requireEnabled()
        return try await sdk.pendingInvitations()
    }

    func publicVibes(
        query: String?,
        loadNextPage: Bool
    ) async throws -> MatrixPublicVibeDirectoryPage {
        try requireEnabled()
        return try await sdk.publicSpaces(
            query: query,
            loadNextPage: loadNextPage
        )
    }

    func joinPublicVibe(_ space: MatrixPublicVibeSummary) async throws {
        try requireEnabled()
        try await sdk.joinPublicSpace(space)
    }

    func publicVibePreview(_ space: MatrixPublicVibeSummary) async throws
        -> MatrixPublicVibeSummary
    {
        try requireEnabled()
        return try await sdk.publicSpacePreview(space)
    }

    func leavePublicVibe(_ space: MatrixPublicVibeSummary) async throws {
        try requireEnabled()
        try await sdk.leavePublicSpace(space)
    }

    func createVibe(
        _ draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        try requireEnabled()
        return try await sdk.createVibe(draft)
    }

    func createWave(
        inSpaceID spaceID: String,
        draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        try requireEnabled()
        return try await sdk.createWave(inSpaceID: spaceID, draft: draft)
    }

    func registerCreatedRoom(
        _ room: MatrixNativeCreatedRoom
    ) async throws -> MatrixNativeCreatedRoom {
        try requireEnabled()
        return try await sdk.registerCreatedRoom(room)
    }

    func spacePermissions(
        spaceID: String
    ) async throws -> MatrixNativeSpacePermissionSnapshot {
        try requireEnabled()
        return try await sdk.spacePermissions(spaceID: spaceID)
    }

    func inviteUsers(_ userIDs: [String], roomID: String) async throws -> [String] {
        try requireEnabled()
        return try await sdk.inviteUsers(userIDs, roomID: roomID)
    }

    func waves(spaceID: String) async throws -> MatrixWaveDirectoryPage {
        try requireEnabled()
        do {
            return MatrixWaveDirectoryPage(rooms: try await sdk.childRooms(spaceID: spaceID))
        } catch let error as ClientError {
            let metadata = MatrixNativeSpaceDirectoryClientErrorMetadata(error)
            let disposition = MatrixNativeSpaceDirectoryFailureContract.disposition(
                matrixErrorCode: metadata.code,
                matrixKindIsNotFound: metadata.kindIsNotFound
            )
            if disposition == .ignoreStalePurgedSpace {
                matrixSpaceDirectoryLogger.notice(
                    "branch=stale_purged_space domain=\(metadata.domain, privacy: .public) code=\(metadata.code, privacy: .public)"
                )
                throw MatrixNativeSpaceDirectoryError.stalePurgedSpace
            }
            matrixSpaceDirectoryLogger.error(
                "branch=report_failure domain=\(metadata.domain, privacy: .public) code=\(metadata.code, privacy: .public)"
            )
            throw error
        } catch {
            matrixSpaceDirectoryLogger.error(
                "branch=report_failure domain=non_client_error code=UNCLASSIFIED"
            )
            throw error
        }
    }

    func refreshLocalWaveActivity(
        rooms: [MatrixWaveSummary]
    ) async throws -> [MatrixWaveSummary] {
        try requireEnabled()
        return try await sdk.localWaveActivity(rooms: rooms)
    }

    func waveRules(roomID: String) async throws -> MatrixNativeWaveRulesSnapshot {
        try requireEnabled()
        return try await sdk.waveRules(roomID: roomID)
    }

    func updateWaveRules(
        roomID: String,
        state: MatrixNativeWaveRulesState
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveRules(roomID: roomID, state: state)
    }

    // MARK: Watch Party

    func watchPartyState(
        roomID: String
    ) async throws -> MatrixNativeWatchPartyState? {
        try requireEnabled()
        return try await sdk.watchPartyState(roomID: roomID)
    }

    func startWatchParty(
        roomID: String,
        videoId: String,
        videoUrl: String?
    ) async throws {
        try requireEnabled()
        try await sdk.startWatchParty(
            roomID: roomID,
            videoId: videoId,
            videoUrl: videoUrl
        )
    }

    func updateWatchPartyPlayback(
        roomID: String,
        playbackState: MatrixNativeWatchPartyPlaybackState,
        playheadMs: Int64
    ) async throws {
        try requireEnabled()
        try await sdk.updateWatchPartyPlayback(
            roomID: roomID,
            playbackState: playbackState,
            playheadMs: playheadMs
        )
    }

    func endWatchParty(roomID: String) async throws {
        try requireEnabled()
        try await sdk.endWatchParty(roomID: roomID)
    }

    // MARK: Live Stage

    func liveStageState(
        roomID: String
    ) async throws -> MatrixNativeLiveStageState? {
        try requireEnabled()
        return try await sdk.liveStageState(roomID: roomID)
    }

    func speakerRequests(
        roomID: String
    ) async throws -> [MatrixNativeSpeakerRequest] {
        try requireEnabled()
        return try await sdk.speakerRequests(roomID: roomID)
    }

    func startLiveStage(roomID: String, title: String) async throws {
        try requireEnabled()
        try await sdk.startLiveStage(roomID: roomID, title: title)
    }

    func endLiveStage(roomID: String) async throws {
        try requireEnabled()
        try await sdk.endLiveStage(roomID: roomID)
    }

    func requestSpeaker(roomID: String) async throws {
        try requireEnabled()
        try await sdk.requestSpeaker(roomID: roomID)
    }

    func approveSpeaker(roomID: String, userId: String) async throws {
        try requireEnabled()
        try await sdk.approveSpeaker(roomID: roomID, userId: userId)
    }

    func denySpeaker(roomID: String, userId: String) async throws {
        try requireEnabled()
        try await sdk.denySpeaker(roomID: roomID, userId: userId)
    }

    func removeSpeaker(roomID: String, userId: String) async throws {
        try requireEnabled()
        try await sdk.removeSpeaker(roomID: roomID, userId: userId)
    }

    func updateLiveStageCohost(roomID: String, userId: String, add: Bool) async throws {
        try requireEnabled()
        try await sdk.updateLiveStageCohost(roomID: roomID, userId: userId, add: add)
    }

    func waveManagement(
        roomID: String
    ) async throws -> MatrixNativeWaveManagementSnapshot {
        try requireEnabled()
        return try await sdk.waveManagement(roomID: roomID)
    }

    func updateWaveProfile(
        roomID: String,
        name: String,
        topic: String,
        avatar: MatrixNativeUpload?,
        removeAvatar: Bool
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveProfile(
            roomID: roomID,
            name: name,
            topic: topic,
            avatar: avatar,
            removeAvatar: removeAvatar
        )
    }

    func updateWaveAccess(
        roomID: String,
        access: MatrixNativeWaveAccess,
        history: MatrixNativeWaveHistory,
        restrictedParentSpaceID: String?
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveAccess(
            roomID: roomID,
            access: access,
            history: history,
            restrictedParentSpaceID: restrictedParentSpaceID
        )
    }

    func leaveWave(roomID: String) async throws {
        try requireEnabled()
        try await sdk.leaveWave(roomID: roomID)
    }

    func waveMembers(roomID: String) async throws -> [MatrixNativeWaveMember] {
        try requireEnabled()
        return try await sdk.waveMembers(roomID: roomID)
    }

    func joinedWaveDestinations(
        excludingRoomID: String
    ) async throws -> [MatrixWaveSummary] {
        try requireEnabled()
        return try await sdk.joinedWaveDestinations(
            excludingRoomID: excludingRoomID
        )
    }

    func typingUpdates(roomID: String) async throws -> AsyncStream<[String]> {
        try requireEnabled()
        return try await sdk.typingUpdates(roomID: roomID)
    }

    func updateWaveMemberRole(
        roomID: String,
        userID: String,
        role: MatrixNativeWaveMemberRole
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveMemberRole(
            roomID: roomID,
            userID: userID,
            role: role
        )
    }

    func moderateWaveMember(
        roomID: String,
        userID: String,
        action: MatrixNativeWaveModerationAction,
        reason: String?
    ) async throws {
        try requireEnabled()
        try await sdk.moderateWaveMember(
            roomID: roomID,
            userID: userID,
            action: action,
            reason: reason
        )
    }

    func updateWaveNotification(
        roomID: String,
        mode: MatrixNativeWaveNotificationMode
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveNotification(roomID: roomID, mode: mode)
    }

    func searchWave(
        roomID: String,
        query: String
    ) async throws -> [MatrixNativeWaveSearchResult] {
        try requireEnabled()
        return try await sdk.searchWave(roomID: roomID, query: query)
    }

    func timeline(roomID: String, from token: String?) async throws -> MatrixTimelinePage {
        try requireEnabled()
        let snapshot = try await sdk.timelineItems(
            roomID: roomID,
            paginateBackwards: token != nil
        )
        return MatrixTimelinePage(
            roomID: roomID,
            items: snapshot.items,
            nextToken: snapshot.hasMore ? "previous" : nil,
            projectionCacheKey: snapshot.projectionCacheKey,
            suppressedEventIDs: snapshot.suppressedEventIDs
        )
    }

    func releaseTimeline(roomID: String) async {
        await sdk.releaseTimeline(roomID: roomID)
    }

    func releaseThreadTimeline(roomID: String, rootEventID: String) async {
        await sdk.releaseThreadTimeline(roomID: roomID, rootEventID: rootEventID)
    }

    func pinned(roomID: String) async throws -> MatrixTimelinePage {
        try requireEnabled()
        return MatrixTimelinePage(
            roomID: roomID,
            items: try await sdk.pinnedItems(roomID: roomID),
            nextToken: nil
        )
    }

    func thread(
        roomID: String,
        rootEventID: String,
        paginateBackwards: Bool = false
    ) async throws -> MatrixTimelinePage {
        try requireEnabled()
        let items = try await sdk.threadItems(
            roomID: roomID,
            rootEventID: rootEventID,
            paginateBackwards: paginateBackwards
        )
        return MatrixTimelinePage(
            roomID: roomID,
            items: items,
            // The current Rust binding returns only whether pagination hit
            // the start while the listener owns the page. A full 50-event
            // page is therefore the conservative signal that another page
            // may exist; an empty/short page closes the bounded UI affordance.
            nextToken: items.count >= 50 ? "previous" : nil
        )
    }

    func event(roomID: String, eventID: String) async throws -> MatrixTimelineItem {
        try requireEnabled()
        return try await sdk.eventItem(roomID: roomID, eventID: eventID)
    }

    /// Load the first server-sorted thread-list page through the Matrix Rust
    /// SDK. The provider enriches each listed root with its focused timeline,
    /// so My/All classification remains identity-based and room-window
    /// eviction cannot make a valid thread disappear.
    func threadSummaries(roomID: String) async throws -> [MatrixNativeThreadSummary] {
        try requireEnabled()
        return try await sdk.threadSummaries(roomID: roomID)
    }

    func sendThreadReply(
        _ body: String,
        roomID: String,
        rootEventID: String,
        mentions: [MatrixNativeMentionTarget] = []
    ) async throws {
        try requireEnabled()
        try await sdk.sendThreadReply(
            roomID: roomID,
            rootEventID: rootEventID,
            body: body,
            mentions: mentions
        )
    }

    func sendText(
        _ body: String,
        mentions: [MatrixNativeMentionTarget],
        roomID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.sendText(
            roomID: roomID,
            body: body,
            mentions: mentions,
            transactionID: transactionID
        )
    }

    func toggleEnergy(
        roomID: String,
        item: MatrixTimelineItem,
        key: String
    ) async throws -> Bool {
        try requireEnabled()
        return try await sdk.toggleEnergy(
            roomID: roomID,
            eventReference: item.reference,
            senderID: item.senderID,
            key: key
        )
    }

    func editText(
        roomID: String,
        item: MatrixTimelineItem,
        body: String
    ) async throws {
        try requireEnabled()
        try await sdk.editText(
            roomID: roomID,
            eventReference: item.reference,
            senderID: item.senderID,
            body: body
        )
    }

    func redact(
        roomID: String,
        item: MatrixTimelineItem,
        reason: String?
    ) async throws {
        try requireEnabled()
        try await sdk.redact(
            roomID: roomID,
            eventReference: item.reference,
            senderID: item.senderID,
            reason: reason
        )
    }

    func report(
        roomID: String,
        item: MatrixTimelineItem,
        reason: String
    ) async throws {
        try requireEnabled()
        guard let eventID = item.reference.remoteEventID else {
            throw MatrixNativeWaveActionError.unavailable
        }
        try await sdk.report(
            roomID: roomID,
            eventID: eventID,
            senderID: item.senderID,
            reason: reason
        )
    }

    func setPinned(
        roomID: String,
        item: MatrixTimelineItem,
        pinned: Bool
    ) async throws {
        try requireEnabled()
        guard let eventID = item.reference.remoteEventID else {
            throw MatrixNativeWaveActionError.unavailable
        }
        try await sdk.setPinned(
            roomID: roomID,
            eventID: eventID,
            senderID: item.senderID,
            pinned: pinned
        )
    }

    func send(_ event: MatrixOutboundEvent, toRoomID roomID: String) async throws -> MatrixSentEvent {
        try requireEnabled()
        try await sdk.sendRaw(
            roomID: roomID,
            eventType: event.eventType,
            contentJSON: event.contentJSON,
            transactionID: event.transactionID
        )
        return MatrixSentEvent(roomID: roomID, eventID: event.transactionID)
    }

    func sendLiveStageAction(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String {
        try requireEnabled()
        return try await sdk.sendLiveStageAction(
            roomID: roomID,
            eventType: eventType,
            contentJSON: contentJSON,
            clientRequestID: clientRequestID
        )
    }

    func sendRtcCallSignal(
        roomID: String,
        eventType: String,
        contentJSON: String,
        clientRequestID: String
    ) async throws -> String {
        try requireEnabled()
        return try await sdk.sendRtcCallSignal(
            roomID: roomID,
            eventType: eventType,
            contentJSON: contentJSON,
            clientRequestID: clientRequestID
        )
    }

    func retry(transactionID: String) async throws {
        try requireEnabled()
        try await sdk.retrySend(transactionID: transactionID)
    }

    func sendAttachments(
        _ uploads: [MatrixNativeUpload],
        caption: String?,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.sendAttachments(
            roomID: roomID,
            uploads: uploads,
            caption: caption,
            transactionID: transactionID
        )
    }

    func sendThreadAttachments(
        _ uploads: [MatrixNativeUpload],
        caption: String?,
        roomID: String,
        rootEventID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.sendThreadAttachments(
            roomID: roomID,
            rootEventID: rootEventID,
            uploads: uploads,
            caption: caption,
            transactionID: transactionID
        )
    }

    func createPoll(
        question: String,
        options: [String],
        maxSelections: UInt64,
        isDisclosed: Bool,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.createPoll(
            roomID: roomID,
            question: question,
            options: options,
            maxSelections: maxSelections,
            isDisclosed: isDisclosed,
            transactionID: transactionID
        )
    }

    func voteInPoll(roomID: String, eventID: String, optionIDs: [String]) async throws {
        try requireEnabled()
        try await sdk.voteInPoll(
            roomID: roomID,
            eventID: eventID,
            optionIDs: optionIDs
        )
    }

    func sendSticker(
        _ upload: MatrixNativeUpload,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.sendSticker(
            roomID: roomID,
            upload: upload,
            transactionID: transactionID
        )
    }

    func mediaData(
        roomID: String,
        sourceJSON: String,
        expectedSize: UInt64?
    ) async throws -> Data {
        try requireEnabled()
        return try await sdk.mediaData(
            roomID: roomID,
            sourceJSON: sourceJSON,
            expectedSize: expectedSize
        )
    }

    func mediaThumbnailData(
        roomID: String,
        sourceJSON: String,
        width: UInt64,
        height: UInt64
    ) async throws -> Data {
        try requireEnabled()
        return try await sdk.mediaThumbnailData(
            roomID: roomID,
            sourceJSON: sourceJSON,
            width: width,
            height: height
        )
    }

    func avatarData(avatarURL: String) async throws -> Data {
        try requireEnabled()
        return try await sdk.avatarData(avatarURL: avatarURL)
    }

    func setTyping(_ isTyping: Bool, roomID: String) async throws {
        try requireEnabled()
        try await sdk.setTyping(roomID: roomID, isTyping: isTyping)
    }

    func markRead(roomID: String) async throws {
        try requireEnabled()
        try await sdk.markRead(roomID: roomID)
    }

    func markThreadRead(roomID: String, rootEventID: String) async throws {
        try requireEnabled()
        try await sdk.markThreadRead(roomID: roomID, rootEventID: rootEventID)
    }

    func acceptInvite(roomID: String) async throws {
        try requireEnabled()
        try await sdk.acceptInvite(roomID: roomID)
    }

    func declineInvite(roomID: String) async throws {
        try requireEnabled()
        try await sdk.declineInvite(roomID: roomID)
    }

    func declineInviteAndBlock(roomID: String) async throws {
        try requireEnabled()
        try await sdk.declineInviteAndBlock(roomID: roomID)
    }

    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String,
        experience: MatrixNativeRtcExperience
    ) async throws -> String {
        try requireEnabled()
        return try await sdk.beginRtcMembership(
            roomID: roomID,
            intent: intent,
            livekitServiceURL: livekitServiceURL,
            experience: experience
        )
    }

    func endRtcMembership(roomID: String) async throws {
        try requireEnabled()
        try await sdk.endRtcMembership(roomID: roomID)
    }

    private func requireEnabled() throws {
        guard rollout.mayStartSDK else { throw MatrixSessionFoundationError.disabled }
    }
}

private extension MatrixNativeWaveMember {
    init?(
        _ member: RoomMember,
        ownUserID: String,
        exposePresence: Bool
    ) {
        let state: MatrixNativeWaveMemberState
        switch member.membership {
        case .join: state = .joined
        case .invite: state = .invited
        case .ban: state = .banned
        case .knock: state = .requested
        case .leave, .custom: return nil
        }
        let role: MatrixNativeWaveMemberRole
        switch member.suggestedRoleForPowerLevel {
        case .creator: role = .creator
        case .administrator: role = .administrator
        case .moderator: role = .moderator
        case .user: role = .member
        }
        self.init(
            userID: member.userId,
            displayName: MatrixNativeMemberPresentationContract.displayName(
                member.displayName,
                matrixUserID: member.userId
            ),
            avatarURL: member.avatarUrl,
            role: role,
            state: state,
            isCurrentUser: member.userId == ownUserID,
            isService: member.isServiceMember,
            statusEmoji: exposePresence ? member.status?.emoji : nil,
            statusText: exposePresence ? member.status?.text : nil
        )
    }
}

private final class MatrixNativeTypingListener:
    TypingNotificationsListener,
    @unchecked Sendable
{
    private let callback: @Sendable ([String]) -> Void

    init(callback: @escaping @Sendable ([String]) -> Void) {
        self.callback = callback
    }

    func call(typingUserIds: [String]) {
        callback(typingUserIds)
    }
}

private extension MatrixVibeSummary {
    init(_ room: SpaceRoom, membership: MatrixNativeMembership? = nil) {
        self.init(
            id: room.roomId,
            name: MatrixNativeMemberPresentationContract.roomName(
                room.displayName,
                fallback: "Vibe"
            ),
            topic: room.topic,
            avatarURL: room.avatarUrl,
            joinedMemberCount: room.numJoinedMembers,
            membership: membership ?? MatrixNativeMembership(room.state)
        )
    }
}

private extension MatrixWaveSummary {
    init(_ room: SpaceRoom) {
        self.init(
            id: room.roomId,
            name: MatrixNativeMemberPresentationContract.roomName(
                room.displayName,
                fallback: room.roomType == .space ? "Vibe" : "Wave"
            ),
            topic: room.topic,
            avatarURL: room.avatarUrl,
            joinedMemberCount: room.numJoinedMembers,
            membership: MatrixNativeMembership(room.state),
            isNestedSpace: room.roomType == .space
        )
    }
}

private extension MatrixNativeMembership {
    init(_ membership: Membership?) {
        switch membership {
        case .joined: self = .joined
        case .invited: self = .invited
        case .left: self = .left
        default: self = .unknown
        }
    }
}

private extension MatrixNativeEventReference {
    init(_ value: EventOrTransactionId) {
        switch value {
        case let .eventId(eventID): self = .eventID(eventID)
        case let .transactionId(transactionID): self = .transactionID(transactionID)
        }
    }

    var sdkValue: EventOrTransactionId {
        switch self {
        case let .eventID(eventID): .eventId(eventId: eventID)
        case let .transactionID(transactionID): .transactionId(transactionId: transactionID)
        }
    }
}

private extension MatrixTimelineItem {
    init?(_ item: EventTimelineItem, context: MatrixNativeTimelineContext) {
        let reference = MatrixNativeEventReference(item.eventOrTransactionId)
        let id: String
        switch reference {
        case let .eventID(eventID): id = eventID
        case let .transactionID(transactionID): id = transactionID
        }

        let profileName: String?
        let avatarURL: String?
        switch item.senderProfile {
        case let .ready(name, _, avatar, _, _):
            profileName = name
            avatarURL = avatar
        default:
            profileName = nil
            avatarURL = nil
        }
        let displayName = MatrixNativeMemberPresentationContract.displayName(
            profileName,
            matrixUserID: item.sender
        )

        if case .msgLike = item.content {
            // Message-like events continue through the full message/media,
            // reaction, thread and action projection below.
        } else if let activity = MatrixNativeRoomActivityPresentation(
            item.content,
            senderDisplayName: displayName
        ) {
            self.init(
                id: id,
                reference: reference,
                senderID: item.sender,
                senderDisplayName: displayName,
                senderAvatarURL: avatarURL,
                body: activity.body,
                kind: .notice,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(item.timestamp) / 1_000
                ),
                isOwn: item.isOwn,
                isEdited: false,
                localSendState: nil,
                reactionCount: 0,
                energy: [],
                readReceiptCount: 0,
                readReceiptUserIDs: [],
                threadReplyCount: 0,
                replyPreviews: [],
                actions: MatrixNativeTimelineActions(
                    canReply: false,
                    canAddEnergy: false,
                    canEdit: false,
                    canRedact: false,
                    canReport: false,
                    canPin: false,
                    isPinned: false
                ),
                media: [],
                poll: nil,
                westreemReference: nil
            )
            return
        } else {
            return nil
        }

        let westreemReference: MatrixNativeWestreemReferenceV1?
        let presentation: MatrixNativeMessagePresentation
        let reactions: [Reaction]
        let threadSummary: ThreadSummary?
        if
            let eventType = item.eventTypeRaw,
            eventType == MatrixNativeWestreemReferenceContract.shareEventType
                || eventType == MatrixNativeWestreemReferenceContract.eventReferenceType,
            let contentJSON = MatrixNativeRawEvent.contentJSON(item),
            let decoded = try? MatrixNativeWestreemReferenceContract.decode(
                eventType: eventType,
                contentJSON: contentJSON
            )
        {
            westreemReference = decoded
            presentation = MatrixNativeMessagePresentation(reference: decoded)
            guard case let .msgLike(content) = item.content else {
                reactions = []
                threadSummary = nil
                let remoteEventID = reference.remoteEventID
                let actions = MatrixNativeTimelineActions(
                    canReply: remoteEventID != nil && context.maySendMessage,
                    canAddEnergy: remoteEventID != nil && context.maySendReaction,
                    canEdit: false,
                    canRedact: item.isOwn
                        ? context.mayRedactOwn
                        : context.mayRedactOther,
                    canReport: remoteEventID != nil
                        && !item.isOwn
                        && !context.roomIsEncrypted,
                    canPin: remoteEventID != nil && context.mayPin,
                    isPinned: remoteEventID.map(context.pinnedEventIDs.contains) ?? false
                )
                self.init(
                    id: id,
                    reference: reference,
                    senderID: item.sender,
                    senderDisplayName: displayName,
                    senderAvatarURL: avatarURL,
                    body: presentation.body,
                    kind: presentation.kind,
                    timestamp: Date(
                        timeIntervalSince1970: TimeInterval(item.timestamp) / 1_000
                    ),
                    isOwn: item.isOwn,
                    isEdited: false,
                    localSendState: MatrixNativeLocalSendState(item.localSendState),
                    reactionCount: 0,
                    energy: [],
                    readReceiptCount: Self.visibleReadReceiptUserIDs(
                        item,
                        context: context
                    ).count,
                    readReceiptUserIDs: Self.visibleReadReceiptUserIDs(
                        item,
                        context: context
                    ),
                    threadReplyCount: 0,
                    replyPreviews: [],
                    actions: actions,
                    media: [],
                    poll: nil,
                    westreemReference: decoded
                )
                return
            }
            reactions = content.reactions
            threadSummary = content.threadSummary
        } else {
            guard case let .msgLike(content) = item.content else { return nil }
            westreemReference = nil
            presentation = MatrixNativeMessagePresentation(
                content.kind,
                currentUserID: context.currentUserID
            )
            reactions = content.reactions
            threadSummary = content.threadSummary
        }
        let energy = reactions
            .filter { MatrixNativeWaveActionPolicy.isSupportedEnergyKey($0.key) }
            .map {
                MatrixNativeEnergySummary(
                    key: $0.key,
                    count: $0.senders.count,
                    isSelectedByCurrentUser: $0.senders.contains {
                        $0.senderId == context.currentUserID
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.key < rhs.key
            }
        let remoteEventID = reference.remoteEventID
        let isUnableToDecrypt = presentation.kind == .unableToDecrypt
        let isEditableKind = presentation.kind == .text
            || presentation.kind == .notice
            || presentation.kind == .emote
        let actionInputs = (
            roomIsJoined: true,
            senderIsIgnored: false,
            isRemoteEvent: remoteEventID != nil,
            isOwnEvent: item.isOwn,
            isUnableToDecrypt: isUnableToDecrypt,
            roomIsEncrypted: context.roomIsEncrypted
        )
        let actions = MatrixNativeTimelineActions(
            canReply: MatrixNativeWaveActionPolicy.permits(
                .reply,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            canAddEnergy: MatrixNativeWaveActionPolicy.permits(
                .addEnergy,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            canEdit: isEditableKind && MatrixNativeWaveActionPolicy.permits(
                .edit,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            canRedact: MatrixNativeWaveActionPolicy.permits(
                .redact,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            canReport: MatrixNativeWaveActionPolicy.permits(
                .report,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            canPin: MatrixNativeWaveActionPolicy.permits(
                .pin,
                roomIsJoined: actionInputs.roomIsJoined,
                senderIsIgnored: actionInputs.senderIsIgnored,
                isRemoteEvent: actionInputs.isRemoteEvent,
                isOwnEvent: actionInputs.isOwnEvent,
                isUnableToDecrypt: actionInputs.isUnableToDecrypt,
                roomIsEncrypted: actionInputs.roomIsEncrypted,
                maySendMessage: context.maySendMessage,
                maySendReaction: context.maySendReaction,
                mayRedactOwn: context.mayRedactOwn,
                mayRedactOther: context.mayRedactOther,
                mayPin: context.mayPin
            ),
            isPinned: remoteEventID.map(context.pinnedEventIDs.contains) ?? false
        )
        let preview = threadSummary.flatMap {
            MatrixNativeReplyPreview(
                $0.latestEvent(),
                ignoredUserIDs: context.ignoredUserIDs
            )
        }
        self.init(
            id: id,
            reference: reference,
            senderID: item.sender,
            senderDisplayName: displayName,
            senderAvatarURL: avatarURL,
            body: presentation.body,
            kind: presentation.kind,
            timestamp: Date(timeIntervalSince1970: TimeInterval(item.timestamp) / 1_000),
            isOwn: item.isOwn,
            isEdited: presentation.isEdited,
            localSendState: MatrixNativeLocalSendState(item.localSendState),
            reactionCount: reactions.reduce(0) { $0 + $1.senders.count },
            energy: energy,
            readReceiptCount: Self.visibleReadReceiptUserIDs(item, context: context).count,
            readReceiptUserIDs: Self.visibleReadReceiptUserIDs(item, context: context),
            threadReplyCount: threadSummary?.numReplies() ?? 0,
            replyPreviews: preview.map { [$0] } ?? [],
            actions: actions,
            media: presentation.media,
            poll: presentation.poll,
            westreemReference: westreemReference
        )
    }

    private static func visibleReadReceiptUserIDs(
        _ item: EventTimelineItem,
        context: MatrixNativeTimelineContext
    ) -> [String] {
        item.readReceipts.keys
            .filter {
                $0 != context.currentUserID && !context.ignoredUserIDs.contains($0)
            }
            .sorted { lhs, rhs in
                let left = item.readReceipts[lhs]?.timestamp ?? 0
                let right = item.readReceipts[rhs]?.timestamp ?? 0
                return left > right
            }
    }
}

private enum MatrixNativeRawEvent {
    static func contentJSON(_ item: EventTimelineItem) -> String? {
        guard
            let rawJSON = item.lazyProvider.latestJson(),
            let data = rawJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let content = root["content"] as? [String: Any],
            JSONSerialization.isValidJSONObject(content),
            let contentData = try? JSONSerialization.data(withJSONObject: content)
        else {
            return nil
        }
        return String(data: contentData, encoding: .utf8)
    }

    /// Returns `(contentJSON, stateKey)` when the raw event carries a
    /// `state_key`. Used to project custom WeStreem state events (watch
    /// party, live stage, speaker requests) from the timeline stream.
    /// Returns `nil` for message events or events without a state key.
    static func contentAndStateKey(
        _ item: EventTimelineItem
    ) -> (String, String)? {
        guard
            let rawJSON = item.lazyProvider.latestJson(),
            let data = rawJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let stateKey = root["state_key"] as? String,
            let content = root["content"] as? [String: Any],
            JSONSerialization.isValidJSONObject(content),
            let contentData = try? JSONSerialization.data(withJSONObject: content),
            let contentJSON = String(data: contentData, encoding: .utf8)
        else {
            return nil
        }
        return (contentJSON, stateKey)
    }
}

private extension MatrixNativeReplyPreview {
    init?(
        _ details: EmbeddedEventDetails,
        ignoredUserIDs: Set<String>
    ) {
        guard case let .ready(
            content,
            sender,
            senderProfile,
            timestamp,
            reference
        ) = details,
        !ignoredUserIDs.contains(sender),
        case let .msgLike(message) = content
        else {
            return nil
        }
        let presentation = MatrixNativeMessagePresentation(message.kind)
        let profileName: String?
        switch senderProfile {
        case let .ready(name, _, _, _, _):
            profileName = name
        default:
            profileName = nil
        }
        let displayName = MatrixNativeMemberPresentationContract.displayName(
            profileName,
            matrixUserID: sender
        )
        let id: String
        switch reference {
        case let .eventId(eventID): id = eventID
        case let .transactionId(transactionID): id = transactionID
        }
        self.init(
            id: id,
            senderDisplayName: displayName,
            body: presentation.body,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        )
    }
}

private struct MatrixNativeRoomActivityPresentation {
    var body: String

    init?(_ content: TimelineItemContent, senderDisplayName: String) {
        switch content {
        case .msgLike:
            return nil
        case .callInvite:
            body = "\(senderDisplayName) started a call"
        case let .rtcNotification(_, _, activeMembers, _, isJoined):
            if isJoined {
                body = "You joined the call"
            } else if activeMembers.isEmpty {
                body = "The call ended"
            } else {
                body = "A call is active"
            }
        case let .roomMembership(_, userDisplayName, change, reason):
            let member = userDisplayName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false ? userDisplayName! : senderDisplayName
            let suffix = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch change {
            case .joined, .invitationAccepted:
                body = "\(member) joined the Wave"
            case .left:
                body = "\(member) left the Wave"
            case .invited:
                body = "\(member) was invited"
            case .kicked:
                body = "\(member) was removed from the Wave"
            case .banned, .kickedAndBanned:
                body = "\(member) was banned"
            case .unbanned:
                body = "\(member) was unbanned"
            case .invitationRejected, .invitationRevoked:
                body = "\(member)'s invitation was declined"
            case .knocked:
                body = "\(member) requested to join"
            case .knockAccepted:
                body = "\(member)'s join request was accepted"
            case .knockRetracted, .knockDenied:
                body = "\(member)'s join request was closed"
            case .some(.none), .some(.error), .some(.notImplemented), nil:
                body = "\(member)'s membership changed"
            }
            if let suffix, !suffix.isEmpty {
                body += ": \(suffix)"
            }
        case let .profileChange(displayName, previousDisplayName, avatarURL, previousAvatarURL):
            if displayName != previousDisplayName {
                body = "\(senderDisplayName) changed their display name"
            } else if avatarURL != previousAvatarURL {
                body = "\(senderDisplayName) changed their profile photo"
            } else {
                body = "\(senderDisplayName) updated their profile"
            }
        case let .state(_, state):
            switch state {
            case let .roomName(name):
                body = name?.isEmpty == false
                    ? "\(senderDisplayName) named this Wave \(name!)"
                    : "\(senderDisplayName) removed the Wave name"
            case let .roomTopic(topic):
                body = topic?.isEmpty == false
                    ? "\(senderDisplayName) changed the Wave topic"
                    : "\(senderDisplayName) removed the Wave topic"
            case .roomAvatar:
                body = "\(senderDisplayName) changed the Wave photo"
            case .roomPinnedEvents:
                body = "\(senderDisplayName) updated pinned messages"
            case .roomPowerLevels:
                body = "\(senderDisplayName) changed member permissions"
            case .roomJoinRules:
                body = "\(senderDisplayName) changed who can join"
            case .roomHistoryVisibility:
                body = "\(senderDisplayName) changed history visibility"
            case .roomEncryption:
                body = "Encryption was enabled for this Wave"
            case .roomCreate:
                body = "\(senderDisplayName) created this Wave"
            case .roomGuestAccess:
                body = "\(senderDisplayName) changed guest access"
            case .roomCanonicalAlias:
                body = "\(senderDisplayName) changed the Wave address"
            case .roomTombstone:
                body = "This Wave was replaced"
            case .roomThirdPartyInvite:
                body = "\(senderDisplayName) updated an invitation"
            case .spaceChild, .spaceParent:
                body = "\(senderDisplayName) changed the Wave hierarchy"
            case .policyRuleRoom, .policyRuleServer, .policyRuleUser, .roomServerAcl:
                body = "\(senderDisplayName) changed a room safety setting"
            case let .custom(eventType):
                if eventType == "com.westreem.public_sharing.v1" {
                    body = "\(senderDisplayName) changed Wave sharing settings"
                } else if eventType.contains(".call.member") {
                    // Matrix RTC membership state is transport metadata. The
                    // user-facing call lifecycle is projected by
                    // `rtcNotification`; exposing every state heartbeat makes
                    // the room timeline unusably noisy.
                    return nil
                } else {
                    // Unknown custom state is application/protocol metadata.
                    // Keep it available to feature-specific state readers but
                    // do not leak its raw type into the human timeline.
                    return nil
                }
            }
        case .failedToParseMessageLike:
            // The Rust timeline remains the raw authority, but unsupported
            // protocol events have every VAC-002 projection flag off.
            return nil
        case .failedToParseState:
            // The Rust timeline remains the raw authority, but unsupported
            // protocol/state events have every VAC-002 projection flag off.
            // Feature-specific readers may still inspect them separately.
            return nil
        }
    }
}

private struct MatrixNativeMessagePresentation {
    let body: String
    let kind: MatrixNativeMessageKind
    let isEdited: Bool
    let media: [MatrixNativeMediaDescriptor]
    let poll: MatrixNativePollDescriptor?

    init(reference: MatrixNativeWestreemReferenceV1) {
        body = reference.title
        kind = .westreemReference
        isEdited = false
        media = []
        poll = nil
    }

    init(_ content: MsgLikeKind, currentUserID: String? = nil) {
        switch content {
        case let .message(message):
            body = message.body
            isEdited = message.isEdited
            switch message.msgType {
            case .text:
                kind = .text
                media = []
            case .notice:
                kind = .notice
                media = []
            case .emote:
                kind = .emote
                media = []
            case let .image(content):
                kind = .image
                media = [MatrixNativeMediaDescriptor(content)]
            case let .audio(content):
                kind = .audio
                media = [MatrixNativeMediaDescriptor(content)]
            case let .video(content):
                kind = .video
                media = [MatrixNativeMediaDescriptor(content)]
            case let .file(content):
                kind = .file
                media = [MatrixNativeMediaDescriptor(content)]
            case let .gallery(content):
                kind = .gallery
                media = content.itemtypes.compactMap(MatrixNativeMediaDescriptor.init)
            case .location:
                kind = .location
                media = []
            case .other:
                kind = .unsupported
                media = []
            }
            poll = nil
        case let .sticker(stickerBody, info, source):
            body = stickerBody
            kind = .sticker
            isEdited = false
            media = [
                MatrixNativeMediaDescriptor(
                    id: source.url(),
                    kind: .sticker,
                    filename: stickerBody,
                    mimeType: info.mimetype,
                    size: info.size,
                    width: info.width,
                    height: info.height,
                    duration: nil,
                    sourceJSON: source.toJson()
                ),
            ]
            poll = nil
        case let .poll(question, pollKind, maxSelections, answers, votes, endTime, edited):
            body = question
            kind = .poll
            isEdited = edited
            media = []
            poll = MatrixNativePollDescriptor(
                question: question,
                options: answers.map {
                    MatrixNativePollOption(
                        id: $0.id,
                        text: $0.text,
                        voteCount: votes[$0.id]?.count ?? 0
                    )
                },
                maxSelections: maxSelections,
                isDisclosed: pollKind == .disclosed,
                hasEnded: endTime != nil,
                selectedOptionIDs: Set(answers.compactMap { answer in
                    guard let currentUserID,
                          votes[answer.id]?.contains(currentUserID) == true
                    else { return nil }
                    return answer.id
                })
            )
        case .redacted:
            body = "Message removed"
            kind = .redacted
            isEdited = false
            media = []
            poll = nil
        case .unableToDecrypt:
            body = "Encrypted message unavailable on this device"
            kind = .unableToDecrypt
            isEdited = false
            media = []
            poll = nil
        case .other:
            body = "Unsupported Vibe activity"
            kind = .unsupported
            isEdited = false
            media = []
            poll = nil
        case .liveLocation:
            body = "Live location"
            kind = .location
            isEdited = false
            media = []
            poll = nil
        }
    }
}

private extension MatrixNativeMediaDescriptor {
    init(_ content: ImageMessageContent) {
        let thumbnail = content.info?.thumbnailInfo
        self.init(
            id: content.source.url(),
            kind: .image,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: content.info?.width,
            height: content.info?.height,
            duration: nil,
            sourceJSON: content.source.toJson(),
            thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
            thumbnailMimeType: thumbnail?.mimetype,
            thumbnailSize: thumbnail?.size,
            thumbnailWidth: thumbnail?.width,
            thumbnailHeight: thumbnail?.height
        )
    }

    init(_ content: AudioMessageContent) {
        // MSC3245 waveform on inbound voice messages is not exposed by the
        // current matrix-rust-components-swift binding — `UnstableVoiceContent`
        // is just a marker for voice messages and carries no waveform data.
        // We leave the waveform nil here; the audio playback view falls back to
        // a static bar pattern. Wire this up once the SDK exposes it (probably
        // via a future `UnstableAudioDetailsContent` extension).
        let waveform: [UInt16]? = nil
        self.init(
            id: content.source.url(),
            kind: content.voice == nil ? .audio : .voice,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: nil,
            height: nil,
            duration: content.info?.duration,
            sourceJSON: content.source.toJson(),
            waveform: waveform
        )
    }

    init(_ content: VideoMessageContent) {
        let thumbnail = content.info?.thumbnailInfo
        self.init(
            id: content.source.url(),
            kind: .video,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: content.info?.width,
            height: content.info?.height,
            duration: content.info?.duration,
            sourceJSON: content.source.toJson(),
            thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
            thumbnailMimeType: thumbnail?.mimetype,
            thumbnailSize: thumbnail?.size,
            thumbnailWidth: thumbnail?.width,
            thumbnailHeight: thumbnail?.height
        )
    }

    init(_ content: FileMessageContent) {
        self.init(
            id: content.source.url(),
            kind: .file,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: nil,
            height: nil,
            duration: nil,
            sourceJSON: content.source.toJson()
        )
    }

    init?(_ item: GalleryItemType) {
        switch item {
        case let .image(content): self.init(content)
        case let .audio(content): self.init(content)
        case let .video(content): self.init(content)
        case let .file(content): self.init(content)
        case .other: return nil
        }
    }
}

private extension MatrixNativeLocalSendState {
    init?(_ state: EventSendState?) {
        guard let state else { return nil }
        switch state {
        case .notSentYet: self = .sending
        case let .sendingFailed(_, recoverable): self = .failed(isRecoverable: recoverable)
        case .sent: self = .sent
        }
    }
}
