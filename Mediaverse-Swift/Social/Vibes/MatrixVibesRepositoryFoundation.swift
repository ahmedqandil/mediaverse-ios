import Foundation
import MatrixRustSDK

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

struct MatrixNativeLoungeParticipant: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let avatarURL: String?
}

struct MatrixTimelinePage: Codable, Equatable, Sendable {
    let roomID: String
    let items: [MatrixTimelineItem]
    let nextToken: String?
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
    var id: String { eventID }
    let eventID: String
    let senderID: String
    let senderDisplayName: String
    let body: String
    let timestamp: Date
}

struct MatrixVibeSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let topic: String?
    let avatarURL: String?
    let joinedMemberCount: UInt64
    let membership: MatrixNativeMembership
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
    func publicSpaces(query: String?, loadNextPage: Bool) async throws
        -> MatrixPublicVibeDirectoryPage
    func joinPublicSpace(_ space: MatrixPublicVibeSummary) async throws
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
        history: MatrixNativeWaveHistory
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
    func timelineItems(roomID: String, paginateBackwards: Bool) async throws -> [MatrixTimelineItem]
    func threadItems(
        roomID: String,
        rootEventID: String,
        paginateBackwards: Bool
    ) async throws -> [MatrixTimelineItem]
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
    func retrySend(transactionID: String) async throws
    func sendAttachments(
        roomID: String,
        uploads: [MatrixNativeUpload],
        caption: String?,
        transactionID: String
    ) async throws
    func createPoll(
        roomID: String,
        question: String,
        options: [String],
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
    func avatarData(avatarURL: String) async throws -> Data
    func setTyping(roomID: String, isTyping: Bool) async throws
    func markRead(roomID: String) async throws
    func acceptInvite(roomID: String) async throws
    func declineInvite(roomID: String) async throws
    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String
    ) async throws -> String
    func endRtcMembership(roomID: String) async throws
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

    init(sessionCoordinator: MatrixSessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator
    }

    func topLevelSpaces() async throws -> [MatrixVibeSummary] {
        let client = try await activeClient()
        let joined = await client.spaceService().topLevelJoinedSpaces()
        var ordered = joined.map { MatrixVibeSummary($0, membership: .joined) }
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

    func publicSpaces(
        query: String?,
        loadNextPage: Bool
    ) async throws -> MatrixPublicVibeDirectoryPage {
        let client = try await activeClient()
        let trimmedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.flatMap {
            $0.isEmpty ? nil : String($0.prefix(128))
        }

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
        guard space.mayJoin, space.membership != .joined else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let client = try await activeClient()
        let target = space.canonicalAlias ?? space.id
        let joined = try await client.joinRoomByIdOrAlias(
            roomIdOrAlias: target,
            serverNames: space.viaServers
        )
        guard joined.isSpace(), joined.membership() == .joined else {
            if joined.membership() == .joined {
                try? await joined.leave()
            }
            throw MatrixNativeWaveActionError.notAllowed
        }
    }

    func createVibe(
        _ draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        let client = try await activeClient()
        let validated = try MatrixNativeCreationContract.validate(draft)
        let serviceUserID = try Self.serviceUserID(for: client.userId())
        let roomID = try await client.createRoom(
            request: createRoomParameters(
                validated,
                isSpace: true,
                serviceUserID: serviceUserID
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
        let roomID = try await client.createRoom(
            request: createRoomParameters(
                validated,
                isSpace: false,
                serviceUserID: serviceUserID
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
            activeCallParticipantCount: activeParticipantIDs.count,
            activeCallIntent: intent,
            activeCallParticipants: activeParticipants
        )
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
        history: MatrixNativeWaveHistory
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined, !matrixRoom.isSpace() else {
            throw MatrixNativeWaveActionError.roomNotJoined
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
        try await matrixRoom.updateJoinRules(newRule: Self.joinRule(access))
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
                    exposePresence: !ignoredUserIDs.contains($0.userId)
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
        let ignoredUserIDs = Set(try await client.ignoredUsers())
        let pair = AsyncStream<[String]>.makeStream()
        let listener = MatrixNativeTypingListener { userIDs in
            pair.continuation.yield(
                Array(
                    Set(userIDs.filter {
                        $0 != ownUserID && !ignoredUserIDs.contains($0)
                    })
                ).sorted()
            )
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
        let normalizedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .kick:
            guard member.membership == .join || member.membership == .invite
            else { throw MatrixNativeWaveActionError.notAllowed }
            try await matrixRoom.kickUser(
                userId: userID,
                reason: normalizedReason
            )
        case .ban:
            guard member.membership != .ban else {
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
        return Array(accumulator.results.prefix(100))
    }

    private static func access(
        _ joinRule: JoinRule?
    ) throws -> MatrixNativeWaveAccess {
        switch joinRule {
        case .public: .publicRoom
        case .invite: .inviteOnly
        case .knock: .requestToJoin
        case .none, .private, .restricted, .knockRestricted, .custom:
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

    private static func joinRule(_ value: MatrixNativeWaveAccess) -> JoinRule {
        switch value {
        case .publicRoom: .public
        case .inviteOnly: .invite
        case .requestToJoin: .knock
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

    func timelineItems(roomID: String, paginateBackwards: Bool) async throws -> [MatrixTimelineItem] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let timeline = try await matrixRoom.timeline()
        let accumulator = MatrixTimelineAccumulator(context: context)
        let taskHandle = await timeline.addListener(listener: accumulator)
        if paginateBackwards {
            _ = try await timeline.paginateBackwards(numEvents: 50)
        }
        await Task.yield()
        withExtendedLifetime(taskHandle) {}
        return accumulator.timelineItems
    }

    func pinnedItems(roomID: String) async throws -> [MatrixTimelineItem] {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let context = try await timelineContext(room: matrixRoom, client: client)
        let pinnedEventIDs = (try await matrixRoom.roomInfo()).pinnedEventIds
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
        return pinnedEventIDs.compactMap { valuesByID[$0] }
    }

    func threadItems(
        roomID: String,
        rootEventID: String,
        paginateBackwards: Bool
    ) async throws -> [MatrixTimelineItem] {
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
                reportUtds: true
            )
        )
        let accumulator = MatrixTimelineAccumulator(context: context)
        let taskHandle = await timeline.addListener(listener: accumulator)
        if paginateBackwards {
            _ = try await timeline.paginateBackwards(numEvents: 50)
        }
        await Task.yield()
        withExtendedLifetime(taskHandle) {}
        return accumulator.timelineItems
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
                reportUtds: true
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
        guard senderID != context.currentUserID,
              !context.ignoredUserIDs.contains(senderID),
              !context.roomIsEncrypted,
              let normalized = MatrixNativeWaveActionPolicy.normalizedReportReason(reason)
        else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        try await matrixRoom.reportContent(eventId: eventID, reason: normalized)
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
        guard !context.ignoredUserIDs.contains(senderID), context.mayPin else {
            throw MatrixNativeWaveActionError.notAllowed
        }
        let timeline = try await matrixRoom.timeline()
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

    func createPoll(
        roomID: String,
        question: String,
        options: [String],
        transactionID: String
    ) async throws {
        try await performPollSend(
            roomID: roomID,
            question: question,
            options: options
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
        guard let expectedSize else {
            // Do not download an unbounded payload when the event omitted its
            // declared size. The user can still see the fail-closed card.
            throw MatrixNativeMediaError.mediaUnavailable
        }
        let maximum = min(
            try await client.getMaxMediaUploadSize(),
            MatrixNativeMediaPolicy.maximumVideoBytes
        )
        if expectedSize > maximum {
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

    func acceptInvite(roomID: String) async throws {
        let client = try await activeClient()
        let invited = try room(roomID, in: client)
        guard invited.membership() == .invited else {
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

    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String
    ) async throws -> String {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        guard matrixRoom.membership() == .joined else {
            throw MatrixSessionFoundationError.unavailable
        }
        guard !(await matrixRoom.isEncrypted()) else {
            throw MatrixNativeRtcError.encryptedMediaNotVerified
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
        caption: String?
    ) async throws {
        let client = try await activeClient()
        let matrixRoom = try room(roomID, in: client)
        let maximum = try await client.getMaxMediaUploadSize()
        try MatrixNativeMediaPolicy.validate(uploads, serverMaximumBytes: maximum)
        // Timeline attachment APIs inspect the room encryption state and
        // upload encrypted file descriptors when required. Keeping this on
        // MatrixRustSDK avoids exposing media keys to Westreem.
        let timeline = try await matrixRoom.timeline()

        if uploads.count > 1 {
            let items = uploads.map(MatrixNativeGalleryFactory.item)
            let handle = try timeline.sendGallery(
                params: GalleryUploadParameters(
                    caption: normalizedCaption(caption),
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: nil
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
                inReplyTo: nil
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
                handle = try timeline.sendVoiceMessage(
                    params: params,
                    audioInfo: MatrixNativeGalleryFactory.audioInfo(upload),
                    waveform: []
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
        options: [String]
    ) async throws {
        let validated = try MatrixNativeMediaPolicy.validatePoll(
            question: question,
            options: options
        )
        let client = try await activeClient()
        let timeline = try await room(roomID, in: client).timeline()
        try await timeline.createPoll(
            question: validated.0,
            answers: validated.1,
            maxSelections: 1,
            pollKind: .disclosed
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
        serviceUserID: String
    ) -> CreateRoomParameters {
        let isPublic = creation.visibility == .publicVibe
        return CreateRoomParameters(
            name: creation.name,
            topic: creation.topic,
            // Spaces carry hierarchy state but no message history. Community
            // Wave encryption is an explicit policy choice because encrypted
            // rooms cannot participate in public discovery, bridges,
            // moderation projections, or Lounges.
            isEncrypted: creation.isEncrypted && !isSpace,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat,
            invite: [serviceUserID],
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
            joinRuleOverride: isPublic ? .public : .invite,
            historyVisibilityOverride: isPublic ? .shared : .invited,
            isSpace: isSpace
        )
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

    func onUpdate(diff: [TimelineDiff]) {
        lock.withLock {
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
        }
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
        return MatrixWaveDirectoryPage(rooms: try await sdk.childRooms(spaceID: spaceID))
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
        history: MatrixNativeWaveHistory
    ) async throws {
        try requireEnabled()
        try await sdk.updateWaveAccess(
            roomID: roomID,
            access: access,
            history: history
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
        return MatrixTimelinePage(
            roomID: roomID,
            items: try await sdk.timelineItems(
                roomID: roomID,
                paginateBackwards: token != nil
            ),
            nextToken: nil
        )
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
        return MatrixTimelinePage(
            roomID: roomID,
            items: try await sdk.threadItems(
                roomID: roomID,
                rootEventID: rootEventID,
                paginateBackwards: paginateBackwards
            ),
            nextToken: nil
        )
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

    func createPoll(
        question: String,
        options: [String],
        roomID: String,
        transactionID: String
    ) async throws {
        try requireEnabled()
        try await sdk.createPoll(
            roomID: roomID,
            question: question,
            options: options,
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

    func acceptInvite(roomID: String) async throws {
        try requireEnabled()
        try await sdk.acceptInvite(roomID: roomID)
    }

    func declineInvite(roomID: String) async throws {
        try requireEnabled()
        try await sdk.declineInvite(roomID: roomID)
    }

    func beginRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent,
        livekitServiceURL: String
    ) async throws -> String {
        try requireEnabled()
        return try await sdk.beginRtcMembership(
            roomID: roomID,
            intent: intent,
            livekitServiceURL: livekitServiceURL
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
                    readReceiptCount: item.readReceipts.count,
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
            presentation = MatrixNativeMessagePresentation(content.kind)
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
            readReceiptCount: item.readReceipts.count,
            threadReplyCount: threadSummary?.numReplies() ?? 0,
            replyPreviews: preview.map { [$0] } ?? [],
            actions: actions,
            media: presentation.media,
            poll: presentation.poll,
            westreemReference: westreemReference
        )
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

    init(_ content: MsgLikeKind) {
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
                hasEnded: endTime != nil
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
        self.init(
            id: content.source.url(),
            kind: .image,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: content.info?.width,
            height: content.info?.height,
            duration: nil,
            sourceJSON: content.source.toJson()
        )
    }

    init(_ content: AudioMessageContent) {
        self.init(
            id: content.source.url(),
            kind: content.voice == nil ? .audio : .voice,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: nil,
            height: nil,
            duration: content.info?.duration,
            sourceJSON: content.source.toJson()
        )
    }

    init(_ content: VideoMessageContent) {
        self.init(
            id: content.source.url(),
            kind: .video,
            filename: content.filename,
            mimeType: content.info?.mimetype,
            size: content.info?.size,
            width: content.info?.width,
            height: content.info?.height,
            duration: content.info?.duration,
            sourceJSON: content.source.toJson()
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
