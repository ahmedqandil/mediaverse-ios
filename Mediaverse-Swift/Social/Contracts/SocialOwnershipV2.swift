import Foundation

/// Domains that remain authoritative in Westreem after Vibes moves to Matrix.
///
/// This v2 contract intentionally lives beside `SocialAuthorityContract`:
/// v1 describes the protected hybrid rollback behavior while v2 describes the
/// target, domain-scoped ownership model.
public enum WestreemPublicSocialDomain: String, CaseIterable, Codable, Sendable {
    case identity = "IDENTITY"
    case profile = "PROFILE"
    case personalAtmo = "PERSONAL_ATMO"
    case atmoPosts = "ATMO_POSTS"
    case atmoComments = "ATMO_COMMENTS"
    case atmoEnergy = "ATMO_ENERGY"
    case atmoEchoes = "ATMO_ECHOES"
    case userFollowing = "USER_FOLLOWING"
    case channelFollowing = "CHANNEL_FOLLOWING"
    case showFollowing = "SHOW_FOLLOWING"
    case atmosphereFeed = "ATMOSPHERE_FEED"
    case feedRanking = "FEED_RANKING"
    case publicDiscovery = "PUBLIC_DISCOVERY"
    case publicSocialCuration = "PUBLIC_SOCIAL_CURATION"
    case notificationPresentation = "NOTIFICATION_PRESENTATION"
    case channels = "CHANNELS"
    case shows = "SHOWS"
    case networks = "NETWORKS"
    case events = "EVENTS"
    case collections = "COLLECTIONS"
    case clippings = "CLIPPINGS"
    case videos = "VIDEOS"
    case shorts = "SHORTS"
    case playback = "PLAYBACK"
    case ads = "ADS"
    case rights = "RIGHTS"
    case analytics = "ANALYTICS"
    case partners = "PARTNERS"
    case affiliations = "AFFILIATIONS"
    case platformConfiguration = "PLATFORM_CONFIGURATION"
}

/// Community domains whose canonical record is a Matrix event, relation,
/// membership, room state, Space, room, or account-data record.
public enum MatrixVibesDomain: String, CaseIterable, Codable, Sendable {
    case vibesSpaces = "VIBES_SPACES"
    case wavesRooms = "WAVES_ROOMS"
    case ripplesEvents = "RIPPLES_EVENTS"
    case threadsReplies = "THREADS_REPLIES"
    case reactionsEnergy = "REACTIONS_ENERGY"
    case echoRelations = "ECHO_RELATIONS"
    case mentions = "MENTIONS"
    case polls = "POLLS"
    case stickers = "STICKERS"
    case matrixMediaMessages = "MATRIX_MEDIA_MESSAGES"
    case editsRedactions = "EDITS_REDACTIONS"
    case membershipInvitations = "MEMBERSHIP_INVITATIONS"
    case rolesPowerLevels = "ROLES_POWER_LEVELS"
    case moderation = "MODERATION"
    case presenceTyping = "PRESENCE_TYPING"
    case readReceipts = "READ_RECEIPTS"
    case unreadState = "UNREAD_STATE"
    case pushRules = "PUSH_RULES"
    case directMessages = "DIRECT_MESSAGES"
    case matrixRTC = "MATRIX_RTC"
    case encryptionIdentity = "ENCRYPTION_IDENTITY"
    case e2ee = "E2EE"
    case roomHistory = "ROOM_HISTORY"
    case roomSearch = "ROOM_SEARCH"
    case federationPolicy = "FEDERATION_POLICY"
    case bridgeEvents = "BRIDGE_EVENTS"
}

/// Rebuildable or operational Matrix data Westreem may retain without becoming
/// a competing source of truth for Vibes.
public enum WestreemMatrixOperationalProjection: String, CaseIterable, Codable, Sendable {
    case identityBindings = "IDENTITY_BINDINGS"
    case spaceRoomEventMappings = "SPACE_ROOM_EVENT_MAPPINGS"
    case publicSearchProjections = "PUBLIC_SEARCH_PROJECTIONS"
    case publicFeedProjections = "PUBLIC_FEED_PROJECTIONS"
    case aggregateCounts = "AGGREGATE_COUNTS"
    case curationReferences = "CURATION_REFERENCES"
    case bridgeDeliveries = "BRIDGE_DELIVERIES"
    case moderationCases = "MODERATION_CASES"
    case auditRecords = "AUDIT_RECORDS"
    case analyticsProjections = "ANALYTICS_PROJECTIONS"
    case migrationCheckpoints = "MIGRATION_CHECKPOINTS"
}

public struct MatrixNativeSocialOwnershipInvariants: Equatable, Sendable {
    public let matrixUserIdSource = "IMMUTABLE_WESTREEM_USER_ID"
    public let prismaFirstVibeWritesAllowed = false
    public let ordinaryVibeMessagesInAtmosphere = false
    public let encryptedOrPrivateContentPubliclyProjected = false
    public let indefiniteDualWriteAllowed = false
}

/// Swift mirror of the server's Matrix-native ownership contract.
///
/// It is deliberately compile-time and fail-closed. A future wire contract can
/// be compared against these exact sets before enabling a Matrix-native client.
public struct MatrixNativeSocialOwnershipContract: Equatable, Sendable {
    public let version = 2
    public let identityAuthority = SocialAuthority.westreem
    public let publicSocialAuthority = SocialAuthority.westreem
    public let vibesAuthority = SocialAuthority.matrix
    public let westreemOwns = Set(WestreemPublicSocialDomain.allCases)
    public let matrixOwns = Set(MatrixVibesDomain.allCases)
    public let westreemMayProject = Set(WestreemMatrixOperationalProjection.allCases)
    public let invariants = MatrixNativeSocialOwnershipInvariants()

    public static let current = MatrixNativeSocialOwnershipContract()

    public func authority(for domain: WestreemPublicSocialDomain) -> SocialAuthority {
        .westreem
    }

    public func authority(for domain: MatrixVibesDomain) -> SocialAuthority {
        .matrix
    }

    public func allowsProjection(_ projection: WestreemMatrixOperationalProjection) -> Bool {
        westreemMayProject.contains(projection)
    }
}
