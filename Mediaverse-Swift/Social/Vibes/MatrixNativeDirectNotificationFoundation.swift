import Foundation
import MatrixRustSDK

enum MatrixDirectMessageError: LocalizedError {
    case ignoredUser
    case existingRoomIsNotSecure

    var errorDescription: String? {
        switch self {
        case .ignoredUser:
            return "You cannot message an ignored user."
        case .existingRoomIsNotSecure:
            return "This older conversation does not meet secure WeStreem direct-message requirements."
        }
    }
}

struct MatrixDirectRoomSummary: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarURL: String?
    let memberMatrixID: String?
    let membership: MatrixNativeMembership
    let unreadCount: UInt64
    let lastMessage: String?
    let lastActivity: Date?

    var timelineRoom: MatrixWaveSummary {
        MatrixWaveSummary(
            id: id,
            name: name,
            topic: "Direct message",
            avatarURL: avatarURL,
            joinedMemberCount: 2,
            membership: membership,
            isNestedSpace: false,
            isDirect: true,
            isEncrypted: true
        )
    }
}

struct MatrixNotificationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let room: MatrixWaveSummary
    let eventID: String?
    let senderName: String
    let senderAvatarURL: String?
    let message: String
    let createdAt: Date
    let hasMention: Bool
    let isDirect: Bool
    let unreadCount: UInt64
}

struct MatrixNativePushRoute: Equatable, Sendable {
    let roomID: String
    let eventID: String?
}

@MainActor
final class MatrixNativePushRouteStore {
    static let shared = MatrixNativePushRouteStore()

    private var pending: MatrixNativePushRoute?

    private init() {}

    func stage(_ route: MatrixNativePushRoute) {
        pending = route
    }

    func consume() -> MatrixNativePushRoute? {
        defer { pending = nil }
        return pending
    }
}

/// MatrixRustSDK is the only transport and authority for direct rooms,
/// unread state and Vibe notifications. Westreem search is used only to
/// discover the immutable Westreem identity before asking Matrix to open or
/// create the room.
actor MatrixRustSDKDirectNotificationProvider {
    private let sessionCoordinator: MatrixSessionCoordinator
    private let notificationBuffer = MatrixSyncNotificationBuffer()
    private var registeredClientKey: String?

    init(sessionCoordinator: MatrixSessionCoordinator) {
        self.sessionCoordinator = sessionCoordinator
    }

    func directRooms() async throws -> [MatrixDirectRoomSummary] {
        let client = try await activeClient()
        let currentUserID = try client.userId()
        let ignoredUserIDs = Set(try await client.ignoredUsers())
        var summaries: [MatrixDirectRoomSummary] = []

        for room in client.rooms() {
            let info = try await room.roomInfo()
            guard !info.isSpace, info.membership == .joined || info.membership == .invited else {
                continue
            }
            let isDirectRoom = info.isDirect || info.isDm
            let sdkReportsDirect = isDirectRoom ? false : await room.isDirect()
            guard isDirectRoom || sdkReportsDirect else { continue }
            let summary = await directSummary(room: room, info: info, currentUserID: currentUserID)
            guard
                let memberMatrixID = summary.memberMatrixID,
                MatrixDirectMessageContract.mayPresentExistingRoom(
                    isEncrypted: await room.isEncrypted(),
                    isDirect: isDirectRoom || sdkReportsDirect,
                    peerMatrixUserID: memberMatrixID
                ),
                !ignoredUserIDs.contains(memberMatrixID)
            else {
                continue
            }
            summaries.append(summary)
        }

        return summaries.sorted { left, right in
            if left.lastActivity != right.lastActivity {
                return (left.lastActivity ?? .distantPast) > (right.lastActivity ?? .distantPast)
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    func openOrCreateDirectRoom(
        westreemUserID: String,
        displayName: String?,
        avatarURL: String?
    ) async throws -> MatrixDirectRoomSummary {
        let client = try await activeClient()
        let currentUserID = try client.userId()
        let target = try MatrixCanonicalIdentity(westreemUserID: westreemUserID)
        let ignoredUserIDs = Set(try await client.ignoredUsers())
        guard MatrixDirectMessageContract.mayCreate(
            currentMatrixUserID: currentUserID,
            targetMatrixUserID: target.matrixUserID,
            ignoredMatrixUserIDs: ignoredUserIDs
        ) else {
            if ignoredUserIDs.contains(target.matrixUserID) {
                throw MatrixDirectMessageError.ignoredUser
            }
            throw MatrixSessionFoundationError.identityMismatch(
                expected: "another verified WeStreem user",
                received: target.matrixUserID
            )
        }

        if let existing = try client.getDmRoom(userId: target.matrixUserID) {
            let info = try await existing.roomInfo()
            let infoIsDirect = info.isDirect || info.isDm
            let sdkReportsDirect = infoIsDirect ? false : await existing.isDirect()
            guard MatrixDirectMessageContract.mayPresentExistingRoom(
                isEncrypted: await existing.isEncrypted(),
                isDirect: infoIsDirect || sdkReportsDirect,
                peerMatrixUserID: target.matrixUserID
            ) else {
                throw MatrixDirectMessageError.existingRoomIsNotSecure
            }
            _ = try await sessionCoordinator.requireCryptoReadyForEncryptedAction()
            return await directSummary(
                room: existing,
                info: info,
                currentUserID: currentUserID
            )
        }

        // Do not create an encrypted room until this device can recover every
        // key it is about to produce. The UI handles the typed readiness error
        // by presenting the SDK-owned setup/recovery flow.
        _ = try await sessionCoordinator.requireCryptoReadyForEncryptedAction()
        let roomID = try await client.createRoom(
            request: CreateRoomParameters(
                name: nil,
                isEncrypted: true,
                isDirect: true,
                visibility: .private,
                preset: .privateChat,
                invite: [target.matrixUserID],
                historyVisibilityOverride: .joined
            )
        )

        return MatrixDirectRoomSummary(
            id: roomID,
            name: normalized(displayName) ?? "Direct message",
            avatarURL: avatarURL,
            memberMatrixID: target.matrixUserID,
            membership: .joined,
            unreadCount: 0,
            lastMessage: nil,
            lastActivity: Date()
        )
    }

    func roomSummary(roomID: String) async throws -> MatrixWaveSummary {
        let client = try await activeClient()
        let (room, info) = try await validatedRoom(roomID: roomID, client: client)
        return MatrixWaveSummary(
            id: room.id(),
            name: normalized(info.displayName) ?? "Vibes message",
            topic: info.topic,
            avatarURL: info.avatarUrl,
            joinedMemberCount: info.joinedMembersCount,
            membership: matrixMembership(info.membership),
            isNestedSpace: info.isSpace
        )
    }

    func validateRoomAccess(roomID: String) async throws {
        let client = try await activeClient()
        _ = try await validatedRoom(roomID: roomID, client: client)
    }

    func notifications() async throws -> [MatrixNotificationSummary] {
        let client = try await activeClient()
        try await ensureNotificationListener(client: client)
        let current = notificationBuffer.snapshot()
        let roomsWithDetailedNotifications = Set(current.map(\.room.id))
        var items = current
        var fallbacks = 0

        for room in client.rooms() {
            guard fallbacks < MatrixNotificationPresentationContract.maximumUnreadRoomFallbacks else {
                break
            }
            let info = try await room.roomInfo()
            guard
                !info.isSpace,
                info.membership == .joined,
                info.numUnreadNotifications > 0,
                !roomsWithDetailedNotifications.contains(info.id)
            else {
                continue
            }
            fallbacks += 1
            let latest = await latestPresentation(room: room)
            let eventID: String? = nil
            let roomSummary = MatrixWaveSummary(
                id: info.id,
                name: normalized(info.displayName) ?? "Vibes",
                topic: info.topic,
                avatarURL: info.avatarUrl,
                joinedMemberCount: info.joinedMembersCount,
                membership: .joined,
                isNestedSpace: false
            )
            items.append(
                MatrixNotificationSummary(
                    id: MatrixNotificationPresentationContract.canonicalID(
                        roomID: info.id,
                        eventID: eventID
                    ),
                    room: roomSummary,
                    eventID: eventID,
                    senderName: latest.senderName,
                    senderAvatarURL: latest.senderAvatarURL,
                    message: latest.message,
                    createdAt: latest.createdAt,
                    hasMention: info.numUnreadMentions > 0,
                    isDirect: info.isDirect || info.isDm,
                    unreadCount: info.numUnreadNotifications
                )
            )
        }

        var unique: [String: MatrixNotificationSummary] = [:]
        for item in items {
            guard (try? await validatedRoom(roomID: item.room.id, client: client)) != nil else {
                continue
            }
            if let previous = unique[item.id], previous.createdAt >= item.createdAt { continue }
            unique[item.id] = item
        }
        return unique.values.sorted { $0.createdAt > $1.createdAt }
    }

    func markRead(roomID: String) async throws {
        let client = try await activeClient()
        guard let room = client.rooms().first(where: { $0.id() == roomID }) else {
            throw MatrixSessionFoundationError.unavailable
        }
        let timeline = try await room.timeline()
        try await timeline.markAsRead(receiptType: .read)
        notificationBuffer.remove(roomID: roomID)
    }

    private func activeClient() async throws -> Client {
        guard let client = await sessionCoordinator.activeClient() else {
            throw MatrixSessionFoundationError.unavailable
        }
        return client
    }

    private func validatedRoom(
        roomID: String,
        client: Client
    ) async throws -> (Room, RoomInfo) {
        guard let room = client.rooms().first(where: { $0.id() == roomID }) else {
            throw MatrixSessionFoundationError.unavailable
        }
        let info = try await room.roomInfo()
        if await room.isEncrypted() {
            _ = try await sessionCoordinator.requireCryptoReadyForEncryptedAction()
        }
        let infoIsDirect = info.isDirect || info.isDm
        let sdkReportsDirect = infoIsDirect ? false : await room.isDirect()
        guard infoIsDirect || sdkReportsDirect else {
            return (room, info)
        }

        let currentUserID = try client.userId()
        let peerMatrixUserID = info.heroes.first(where: {
            $0.userId != currentUserID
        })?.userId ?? info.inviter?.userId
        let ignoredUserIDs = Set(try await client.ignoredUsers())
        guard let peerMatrixUserID else {
            throw MatrixDirectMessageError.existingRoomIsNotSecure
        }
        guard !ignoredUserIDs.contains(peerMatrixUserID) else {
            throw MatrixDirectMessageError.ignoredUser
        }
        guard MatrixDirectMessageContract.mayPresentExistingRoom(
            isEncrypted: await room.isEncrypted(),
            isDirect: true,
            peerMatrixUserID: peerMatrixUserID
        ) else {
            throw MatrixDirectMessageError.existingRoomIsNotSecure
        }
        return (room, info)
    }

    private func ensureNotificationListener(client: Client) async throws {
        let key = "\(try client.userId())|\(try client.deviceId())"
        guard registeredClientKey != key else { return }
        notificationBuffer.reset()
        await client.registerNotificationHandler(listener: notificationBuffer)
        registeredClientKey = key
    }

    private func directSummary(
        room: Room,
        info: RoomInfo,
        currentUserID: String
    ) async -> MatrixDirectRoomSummary {
        let hero = info.heroes.first(where: { $0.userId != currentUserID })
        let inviter = info.inviter
        let latest = await latestPresentation(room: room)
        return MatrixDirectRoomSummary(
            id: room.id(),
            name: normalized(hero?.displayName)
                ?? normalized(inviter?.displayName)
                ?? normalized(info.displayName)
                ?? "Direct message",
            avatarURL: hero?.avatarUrl ?? inviter?.avatarUrl ?? info.avatarUrl,
            memberMatrixID: hero?.userId ?? inviter?.userId,
            membership: matrixMembership(info.membership),
            unreadCount: max(info.numUnreadMessages, info.numUnreadNotifications),
            lastMessage: latest.message,
            lastActivity: latest.createdAt == .distantPast ? nil : latest.createdAt
        )
    }

    private func latestPresentation(room: Room) async -> (
        senderName: String,
        senderAvatarURL: String?,
        message: String,
        createdAt: Date
    ) {
        switch await room.latestEvent() {
        case let .remote(timestamp, sender, _, profile, content),
             let .local(timestamp, sender, profile, content, _):
            return (
                profile.displayName ?? sender,
                profile.avatarURL,
                MatrixSDKNotificationCopy.message(for: content),
                Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            )
        case let .remoteInvite(timestamp, inviter, profile):
            return (
                profile.displayName ?? inviter ?? "Vibes",
                profile.avatarURL,
                "Invited you",
                Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            )
        case .none:
            return ("Vibes", nil, "New activity", .distantPast)
        }
    }

    private func matrixMembership(_ membership: Membership) -> MatrixNativeMembership {
        switch membership {
        case .joined: .joined
        case .invited: .invited
        case .left, .knocked, .banned: .left
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private final class MatrixSyncNotificationBuffer: SyncNotificationListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MatrixNotificationSummary] = []

    func onNotification(notification: NotificationItem, roomId: String) {
        guard let summary = MatrixSDKNotificationCopy.summary(
            notification: notification,
            roomID: roomId
        ) else {
            return
        }
        lock.withLock {
            items.removeAll { $0.id == summary.id }
            items.insert(summary, at: 0)
            if items.count > MatrixNotificationPresentationContract.maximumBufferedItems {
                items.removeLast(
                    items.count - MatrixNotificationPresentationContract.maximumBufferedItems
                )
            }
        }
    }

    func snapshot() -> [MatrixNotificationSummary] {
        lock.withLock { items }
    }

    func remove(roomID: String) {
        lock.withLock { items.removeAll { $0.room.id == roomID } }
    }

    func reset() {
        lock.withLock { items.removeAll(keepingCapacity: false) }
    }
}

private enum MatrixSDKNotificationCopy {
    static func summary(
        notification: NotificationItem,
        roomID: String
    ) -> MatrixNotificationSummary? {
        let eventID: String?
        let senderID: String
        let timestamp: Date
        let presentationMessage: String

        switch notification.event {
        case let .timeline(event):
            eventID = event.eventId()
            senderID = event.senderId()
            timestamp = Date(timeIntervalSince1970: Double(event.timestamp()) / 1_000)
            presentationMessage = (try? message(for: event.content())) ?? "New Vibes activity"
        case let .invite(sender):
            eventID = nil
            senderID = sender
            timestamp = Date()
            presentationMessage = "Invited you"
        }

        let senderName = notification.senderInfo.displayName ?? senderID
        let roomName = notification.roomInfo.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let room = MatrixWaveSummary(
            id: roomID,
            name: roomName.isEmpty ? "Vibes" : roomName,
            topic: notification.roomInfo.topic,
            avatarURL: notification.roomInfo.avatarUrl,
            joinedMemberCount: notification.roomInfo.joinedMembersCount,
            membership: .joined,
            isNestedSpace: false
        )
        return MatrixNotificationSummary(
            id: MatrixNotificationPresentationContract.canonicalID(
                roomID: roomID,
                eventID: eventID
            ),
            room: room,
            eventID: eventID,
            senderName: senderName,
            senderAvatarURL: notification.senderInfo.avatarUrl,
            message: presentationMessage,
            createdAt: timestamp,
            hasMention: notification.hasMention == true,
            isDirect: notification.roomInfo.isDirect || notification.roomInfo.isDm,
            unreadCount: 1
        )
    }

    static func message(for content: TimelineEventContent) -> String {
        switch content {
        case let .messageLike(content):
            switch content {
            case let .roomMessage(messageType, _):
                return message(for: messageType)
            case let .poll(question):
                return "Poll: \(question)"
            case .sticker:
                return "Sticker"
            case .reactionContent:
                return "Added Energy"
            case .roomEncrypted:
                return "Encrypted message"
            case .callInvite, .rtcNotification:
                return "Incoming call"
            case .callHangup:
                return "Call ended"
            case .roomRedaction:
                return "Message removed"
            default:
                return "New Vibes activity"
            }
        case .state:
            return "Vibe updated"
        }
    }

    static func message(for content: TimelineItemContent) -> String {
        switch content {
        case let .msgLike(content):
            switch content.kind {
            case let .message(message):
                return message.body
            case let .poll(question, _, _, _, _, _, _):
                return "Poll: \(question)"
            case .sticker:
                return "Sticker"
            case .redacted:
                return "Message removed"
            case .unableToDecrypt:
                return "Encrypted message"
            case .liveLocation:
                return "Shared a location"
            case .other:
                return "New Vibes activity"
            }
        case .callInvite, .rtcNotification:
            return "Incoming call"
        case .roomMembership:
            return "Membership updated"
        case .profileChange:
            return "Profile updated"
        case .state:
            return "Vibe updated"
        case .failedToParseMessageLike, .failedToParseState:
            return "New Vibes activity"
        }
    }

    private static func message(for type: MessageType) -> String {
        switch type {
        case let .text(content): content.body
        case let .notice(content): content.body
        case let .emote(content): content.body
        case let .other(_, body): body
        case .image: "Photo"
        case .audio: "Voice or audio message"
        case .video: "Video message"
        case .file: "File"
        case .gallery: "Photos"
        case .location: "Shared a location"
        }
    }
}

private extension ProfileDetails {
    var displayName: String? {
        if case let .ready(displayName, _, _, _, _) = self {
            return displayName
        }
        return nil
    }

    var avatarURL: String? {
        if case let .ready(_, _, avatarURL, _, _) = self {
            return avatarURL
        }
        return nil
    }
}
