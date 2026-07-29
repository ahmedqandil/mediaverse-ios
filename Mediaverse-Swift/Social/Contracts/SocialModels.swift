import Foundation

public struct SocialPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public let restricted: Bool

    public init(items: [Item], nextCursor: String?, restricted: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.restricted = restricted
    }
}

public struct SocialIdentity: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
}

public struct VibeSummary: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let description: String?
    public let avatarURL: String?
    public let bannerURL: String?
    public let avatarFocus: String?
    public let bannerFocus: String?
    public let visibility: String?
    public let joinPolicy: String?
    public let postingPolicy: String?
    public let language: String?
    public let country: String?
    public let commentsEnabled: Bool
    public let followersOnly: Bool
    public let membersCanInvite: Bool
    public let moderatorsCanInvite: Bool
    public let moderatorsCanBan: Bool
    public let topics: [String]
    public let memberCount: Int
    public let followerCount: Int
    public let postCount: Int
    public let isPersonal: Bool
    public let owner: SocialIdentity?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, visibility, topics
        case avatarURL = "avatarUrl"
        case bannerURL = "bannerUrl"
        case avatarFocus, bannerFocus, joinPolicy, postingPolicy, language, country
        case commentsEnabled, followersOnly, membersCanInvite, moderatorsCanInvite, moderatorsCanBan
        case memberCount, followerCount, postCount, isPersonal, owner
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        slug = try values.decode(String.self, forKey: .slug)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        avatarURL = try values.decodeIfPresent(String.self, forKey: .avatarURL)
        bannerURL = try values.decodeIfPresent(String.self, forKey: .bannerURL)
        avatarFocus = try values.decodeIfPresent(String.self, forKey: .avatarFocus)
        bannerFocus = try values.decodeIfPresent(String.self, forKey: .bannerFocus)
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
        joinPolicy = try values.decodeIfPresent(String.self, forKey: .joinPolicy)
        postingPolicy = try values.decodeIfPresent(String.self, forKey: .postingPolicy)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        country = try values.decodeIfPresent(String.self, forKey: .country)
        commentsEnabled = try values.decodeIfPresent(Bool.self, forKey: .commentsEnabled) ?? true
        followersOnly = try values.decodeIfPresent(Bool.self, forKey: .followersOnly) ?? false
        membersCanInvite = try values.decodeIfPresent(Bool.self, forKey: .membersCanInvite) ?? false
        moderatorsCanInvite = try values.decodeIfPresent(Bool.self, forKey: .moderatorsCanInvite) ?? false
        moderatorsCanBan = try values.decodeIfPresent(Bool.self, forKey: .moderatorsCanBan) ?? false
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        memberCount = try values.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        followerCount = try values.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        postCount = try values.decodeIfPresent(Int.self, forKey: .postCount) ?? 0
        isPersonal = try values.decodeIfPresent(Bool.self, forKey: .isPersonal) ?? false
        owner = try values.decodeIfPresent(SocialIdentity.self, forKey: .owner)
    }
}

public enum VibeVisibility: String, Codable, Sendable, CaseIterable {
    case publicVibe = "PUBLIC"
    case inviteOnly = "INVITE_ONLY"

    public var label: String { self == .publicVibe ? "Public" : "Invite only" }
}

public enum VibeJoinPolicy: String, Codable, Sendable, CaseIterable {
    case open = "OPEN"
    case requestApproval = "REQUEST_APPROVAL"
    case inviteOnly = "INVITE_ONLY"

    public var label: String {
        switch self {
        case .open: "Open"
        case .requestApproval: "Request approval"
        case .inviteOnly: "Invite only"
        }
    }
}

public enum VibePostingPolicy: String, Codable, Sendable, CaseIterable {
    case members = "MEMBERS"
    case membersWithReview = "MEMBERS_WITH_REVIEW"
    case moderators = "MODERATORS"
    case admins = "ADMINS"

    public var label: String {
        switch self {
        case .members: "Members"
        case .membersWithReview: "Members with review"
        case .moderators: "Moderators"
        case .admins: "Administrators"
        }
    }
}

public struct VibeMutationResponse: Decodable, Sendable {
    public let club: VibeSummary
}

public struct VibeSettingsUpdate: Encodable, Sendable {
    public let name: String
    public let description: String
    public let visibility: VibeVisibility
    public let joinPolicy: VibeJoinPolicy
    public let postingPolicy: VibePostingPolicy
    public let commentsEnabled: Bool
    public let followersOnly: Bool
    public let membersCanInvite: Bool
    public let moderatorsCanInvite: Bool
    public let moderatorsCanBan: Bool
    public let topics: [String]
    public let language: String?
    public let country: String?
    public let avatarURL: String?
    public let avatarFocus: String?
    public let bannerURL: String?
    public let bannerFocus: String?

    enum CodingKeys: String, CodingKey {
        case name, description, visibility, joinPolicy, postingPolicy
        case commentsEnabled, followersOnly, membersCanInvite
        case moderatorsCanInvite, moderatorsCanBan, topics, language, country
        case avatarURL = "avatarUrl"
        case avatarFocus
        case bannerURL = "bannerUrl"
        case bannerFocus
    }
}

public struct VibeCapabilities: Decodable, Equatable, Sendable {
    public let canView: Bool
    public let canViewContent: Bool
    public let canPost: Bool
    public let canComment: Bool
    public let canVote: Bool
    public let canFollow: Bool
    public let canJoin: Bool
    public let canRequestJoin: Bool
    public let canLeave: Bool
    public let canManageClub: Bool
    public let canModerateContent: Bool
    public let canModerateMembers: Bool
    public let canBanMembers: Bool
    public let canManageRoles: Bool
    public let canInvite: Bool
    public let canManageAffiliations: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case canView, canViewContent, canPost, canComment, canVote, canFollow
        case canJoin, canRequestJoin, canLeave, canManageClub
        case canModerateContent, canModerateMembers, canBanMembers, canManageRoles
        case canInvite, canManageAffiliations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canView = try values.decodeIfPresent(Bool.self, forKey: .canView) ?? false
        canViewContent = try values.decodeIfPresent(Bool.self, forKey: .canViewContent) ?? false
        canPost = try values.decodeIfPresent(Bool.self, forKey: .canPost) ?? false
        canComment = try values.decodeIfPresent(Bool.self, forKey: .canComment) ?? false
        canVote = try values.decodeIfPresent(Bool.self, forKey: .canVote) ?? false
        canFollow = try values.decodeIfPresent(Bool.self, forKey: .canFollow) ?? false
        canJoin = try values.decodeIfPresent(Bool.self, forKey: .canJoin) ?? false
        canRequestJoin = try values.decodeIfPresent(Bool.self, forKey: .canRequestJoin) ?? false
        canLeave = try values.decodeIfPresent(Bool.self, forKey: .canLeave) ?? false
        canManageClub = try values.decodeIfPresent(Bool.self, forKey: .canManageClub) ?? false
        canModerateContent = try values.decodeIfPresent(Bool.self, forKey: .canModerateContent) ?? false
        canModerateMembers = try values.decodeIfPresent(Bool.self, forKey: .canModerateMembers) ?? false
        canBanMembers = try values.decodeIfPresent(Bool.self, forKey: .canBanMembers) ?? false
        canManageRoles = try values.decodeIfPresent(Bool.self, forKey: .canManageRoles) ?? false
        canInvite = try values.decodeIfPresent(Bool.self, forKey: .canInvite) ?? false
        canManageAffiliations = try values.decodeIfPresent(Bool.self, forKey: .canManageAffiliations) ?? false
    }
}

public struct VibeMembership: Decodable, Equatable, Sendable {
    public let role: String
    public let status: String
    public let muted: Bool
    public let notifyOnPost: Bool?
}

public struct VibeDetailResponse: Decodable, Sendable {
    public let club: VibeSummary
    public let capabilities: VibeCapabilities
    public let membership: VibeMembership?
    public let following: Bool
}

public enum VibeInviteRole: String, Codable, Sendable, CaseIterable {
    case member = "MEMBER"
    case moderator = "MODERATOR"
    case admin = "ADMIN"

    public var label: String {
        switch self {
        case .member: "Member"
        case .moderator: "Moderator"
        case .admin: "Administrator"
        }
    }
}

public struct VibeInvite: Decodable, Identifiable, Sendable {
    public let id: String
    public let invitedEmail: String?
    public let role: VibeInviteRole
    public let maxUses: Int
    public let useCount: Int
    public let expiresAt: String?
    public let revokedAt: String?
    public let acceptedAt: String?
    public let createdAt: String
    public let invitedUser: SocialIdentity?
    public let invitedBy: SocialIdentity
}

public struct VibeInvitesResponse: Decodable, Sendable {
    public let invites: [VibeInvite]
}

public struct VibeInviteCreatedResponse: Decodable, Sendable {
    public let invite: VibeInvite
    public let token: String
}

public struct VibeInviteAcceptanceResponse: Decodable, Sendable {
    public let membership: VibeMembership
    public let slug: String
}

public enum VibeAffiliationEntityType: String, Codable, Sendable, CaseIterable {
    case show = "SHOW"
    case channel = "CHANNEL"
}

public enum VibeAffiliationStatus: String, Decodable, Sendable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case revoked = "REVOKED"
    case cancelled = "CANCELLED"
}

public enum VibeAffiliationRelationship: String, Codable, Sendable {
    case official = "OFFICIAL"
    case affiliatedCommunity = "AFFILIATED_COMMUNITY"
}

public enum AffiliationReviewAction: String, Encodable, Sendable {
    case approve
    case reject
    case revoke
}

public struct VibeAffiliationTarget: Decodable, Identifiable, Sendable {
    public let id: String
    public let type: VibeAffiliationEntityType
    public let name: String
    public let handle: String?
    public let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, type, name, handle
        case imageURL = "imageUrl"
    }
}

public struct VibeAffiliation: Decodable, Identifiable, Sendable {
    public let id: String
    public let entityType: VibeAffiliationEntityType
    public let relationshipType: VibeAffiliationRelationship
    public let status: VibeAffiliationStatus
    public let requestMessage: String?
    public let reviewNote: String?
    public let isPrimary: Bool
    public let show: VibeAffiliationEntity?
    public let channel: VibeAffiliationEntity?
    public let club: AffiliationVibe?
    public let requestedBy: SocialIdentity?

    public var entity: VibeAffiliationEntity? { show ?? channel }
}

public struct AffiliationVibe: Decodable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let ownerId: String?
}

public struct VibeAffiliationEntity: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let name: String?
    public let handle: String?
    public let coverURL: String?
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, handle
        case coverURL = "coverUrl"
        case avatarURL = "avatarUrl"
    }

    public var displayName: String { title ?? name ?? handle ?? "Unknown" }
    public var imageURL: String? { coverURL ?? avatarURL }
}

public struct VibeAffiliationTargetsResponse: Decodable, Sendable {
    public let results: [VibeAffiliationTarget]
}

public struct VibeAffiliationsResponse: Decodable, Sendable {
    public let affiliations: [VibeAffiliation]
}

public struct VibeAffiliationResponse: Decodable, Sendable {
    public let affiliation: VibeAffiliation
}

public struct AffiliationReviewCounts: Decodable, Sendable {
    public let total: Int
    public let pending: Int
    public let approved: Int
}

public struct AffiliationReviewQueueResponse: Decodable, Sendable {
    public let affiliations: [VibeAffiliation]
    public let counts: AffiliationReviewCounts
}

public struct AffiliationReviewDecisionResponse: Decodable, Sendable {
    public let ok: Bool
    public let status: VibeAffiliationStatus
    public let relationshipType: VibeAffiliationRelationship
}

public struct SocialOKResponse: Decodable, Sendable {
    public let ok: Bool
}

public struct EditedRipplePost: Decodable, Sendable {
    public let id: String
    public let body: String?
    public let isSpoiler: Bool
    public let commentsDisabled: Bool
}

public struct EditedRippleResponse: Decodable, Sendable {
    public let post: EditedRipplePost
}

public struct VibeReportReceipt: Decodable, Sendable {
    public let id: String
    public let status: String
}

public struct VibeReportResponse: Decodable, Sendable {
    public let report: VibeReportReceipt
}

public struct ModerationRipple: Decodable, Identifiable, Sendable {
    public let id: String
    public let body: String?
    public let status: String
    public let hiddenReason: String?
    public let author: SocialIdentity
}

public struct ModerationRippleResponse: Decodable, Sendable {
    public let posts: [ModerationRipple]
}

public struct ModerationReportTarget: Decodable, Sendable {
    public let id: String
    public let body: String?
    public let content: String?
}

public struct ModerationReport: Decodable, Identifiable, Sendable {
    public let id: String
    public let targetType: String
    public let reason: String
    public let details: String?
    public let status: String
    public let severity: String?
    public let post: ModerationReportTarget?
    public let comment: ModerationReportTarget?
    public let reportedUser: SocialIdentity?
}

public struct ModerationReportsResponse: Decodable, Sendable {
    public let reports: [ModerationReport]
}

public struct VibePendingJoinRequest: Decodable, Identifiable, Sendable {
    public let id: String
    public let user: SocialIdentity
    public let message: String?
    public let createdAt: String?
}

public struct VibeJoinRequestsResponse: Decodable, Sendable {
    public let requests: [VibePendingJoinRequest]
}

public struct VibeMember: Decodable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let joinedAt: String?
    public let user: SocialIdentity
}

public struct VibeMembersResponse: Decodable, Sendable {
    public let members: [VibeMember]
    public let nextCursor: String?
}

public struct UpdatedVibeMember: Decodable, Sendable {
    public let id: String
    public let role: String
    public let status: String
}

public struct UpdatedVibeMemberResponse: Decodable, Sendable {
    public let member: UpdatedVibeMember
}

public struct VibeListResponse: Decodable, Sendable {
    public let clubs: [VibeSummary]
    public let nextCursor: String?
}

public enum VibeWaveType: Hashable, Sendable {
    case general, announcements, questions, events, resources, media, staff, custom
    case unknown(String)
}

extension VibeWaveType: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value.uppercased() {
        case "GENERAL": self = .general
        case "ANNOUNCEMENTS": self = .announcements
        case "QUESTIONS": self = .questions
        case "EVENTS": self = .events
        case "RESOURCES": self = .resources
        case "MEDIA": self = .media
        case "STAFF": self = .staff
        case "CUSTOM": self = .custom
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .general: value = "GENERAL"
        case .announcements: value = "ANNOUNCEMENTS"
        case .questions: value = "QUESTIONS"
        case .events: value = "EVENTS"
        case .resources: value = "RESOURCES"
        case .media: value = "MEDIA"
        case .staff: value = "STAFF"
        case .custom: value = "CUSTOM"
        case .unknown(let raw): value = raw
        }
        try container.encode(value)
    }
}

public struct VibeWaveCapabilities: Decodable, Equatable, Sendable {
    public let canView: Bool
    public let canPost: Bool
    public let canCreateEvent: Bool
    public let canManage: Bool
    public let canArchive: Bool

    private enum CodingKeys: String, CodingKey {
        case canView, canPost, canCreateEvent, canManage, canArchive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canView = try values.decodeIfPresent(Bool.self, forKey: .canView) ?? false
        canPost = try values.decodeIfPresent(Bool.self, forKey: .canPost) ?? false
        canCreateEvent = try values.decodeIfPresent(Bool.self, forKey: .canCreateEvent) ?? false
        canManage = try values.decodeIfPresent(Bool.self, forKey: .canManage) ?? false
        canArchive = try values.decodeIfPresent(Bool.self, forKey: .canArchive) ?? false
    }

    private init(
        canView: Bool,
        canPost: Bool,
        canCreateEvent: Bool,
        canManage: Bool,
        canArchive: Bool
    ) {
        self.canView = canView
        self.canPost = canPost
        self.canCreateEvent = canCreateEvent
        self.canManage = canManage
        self.canArchive = canArchive
    }

    fileprivate static let denied = VibeWaveCapabilities(
        canView: false,
        canPost: false,
        canCreateEvent: false,
        canManage: false,
        canArchive: false
    )
}

public struct VibeWaveCounts: Decodable, Equatable, Sendable {
    public let posts: Int
    public let events: Int

    private enum CodingKeys: String, CodingKey { case posts, events }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        posts = try values.decodeIfPresent(Int.self, forKey: .posts) ?? 0
        events = try values.decodeIfPresent(Int.self, forKey: .events) ?? 0
    }
}

public struct VibeWaveDirectorySummary: Decodable, Equatable, Sendable {
    public let latestRippleId: String?
    public let preview: String?
    public let participant: SocialIdentity?
    public let lastActivityAt: String?
    public let unreadCount: Int
    public let rippleCount: Int

    private enum CodingKeys: String, CodingKey {
        case latestRippleId, preview, participant, lastActivityAt, unreadCount, rippleCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latestRippleId = try values.decodeIfPresent(String.self, forKey: .latestRippleId)
        preview = try values.decodeIfPresent(String.self, forKey: .preview)
        participant = try values.decodeIfPresent(SocialIdentity.self, forKey: .participant)
        lastActivityAt = try values.decodeIfPresent(String.self, forKey: .lastActivityAt)
        unreadCount = max(0, try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        rippleCount = max(0, try values.decodeIfPresent(Int.self, forKey: .rippleCount) ?? 0)
    }
}

public struct VibeWave: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let slug: String
    public let description: String?
    public let type: VibeWaveType
    public let visibility: String
    public let postingPolicy: String
    public let position: Int
    public let isSystem: Bool
    public let isDefault: Bool
    public let commentsEnabled: Bool
    public let requiresPostApproval: Bool
    public let allowPolls: Bool
    public let allowPhotos: Bool
    public let allowLinks: Bool
    public let allowEchoes: Bool
    public let archivedAt: String?
    public let capabilities: VibeWaveCapabilities
    public let _count: VibeWaveCounts?
    public let subscription: VibeWaveSubscription?
    public let unreadCount: Int
    public let lastActivityAt: String?
    public let activeConversationCount: Int
    public let lastParticipant: SocialIdentity?
    public let directoryPreview: String?
    public let realtimeCapabilities: SocialRealtimeCapabilities?

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, description, type, visibility, postingPolicy, position
        case isSystem, isDefault, commentsEnabled, requiresPostApproval
        case allowPolls, allowPhotos, allowLinks, allowEchoes, archivedAt
        case capabilities, _count, subscription
        case unreadCount, lastActivityAt, activeConversationCount, conversationCount, lastParticipant
        case directorySummary, realtimeCapabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        slug = try values.decode(String.self, forKey: .slug)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        type = try values.decodeIfPresent(VibeWaveType.self, forKey: .type) ?? .custom
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility) ?? "MEMBERS"
        postingPolicy = try values.decodeIfPresent(String.self, forKey: .postingPolicy) ?? "ADMINS"
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        isSystem = try values.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        commentsEnabled = try values.decodeIfPresent(Bool.self, forKey: .commentsEnabled) ?? false
        requiresPostApproval = try values.decodeIfPresent(Bool.self, forKey: .requiresPostApproval) ?? true
        allowPolls = try values.decodeIfPresent(Bool.self, forKey: .allowPolls) ?? false
        allowPhotos = try values.decodeIfPresent(Bool.self, forKey: .allowPhotos) ?? false
        allowLinks = try values.decodeIfPresent(Bool.self, forKey: .allowLinks) ?? false
        allowEchoes = try values.decodeIfPresent(Bool.self, forKey: .allowEchoes) ?? false
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        capabilities = try values.decodeIfPresent(VibeWaveCapabilities.self, forKey: .capabilities)
            ?? VibeWaveCapabilities.denied
        _count = try values.decodeIfPresent(VibeWaveCounts.self, forKey: ._count)
        subscription = try values.decodeIfPresent(VibeWaveSubscription.self, forKey: .subscription)
        let directorySummary = try values.decodeIfPresent(
            VibeWaveDirectorySummary.self,
            forKey: .directorySummary
        )
        let flatUnreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount)
        let flatLastActivityAt = try values.decodeIfPresent(String.self, forKey: .lastActivityAt)
        let flatActiveConversationCount = try values.decodeIfPresent(
            Int.self,
            forKey: .activeConversationCount
        )
        let flatConversationCount = try values.decodeIfPresent(Int.self, forKey: .conversationCount)
        let flatLastParticipant = try values.decodeIfPresent(
            SocialIdentity.self,
            forKey: .lastParticipant
        )
        unreadCount = max(
            0,
            directorySummary?.unreadCount
                ?? flatUnreadCount
                ?? 0
        )
        lastActivityAt = directorySummary?.lastActivityAt
            ?? flatLastActivityAt
        activeConversationCount = max(
            0,
            directorySummary?.rippleCount
                ?? flatActiveConversationCount
                ?? flatConversationCount
                ?? 0
        )
        lastParticipant = directorySummary?.participant
            ?? flatLastParticipant
        directoryPreview = directorySummary?.preview
        realtimeCapabilities = try values.decodeIfPresent(
            SocialRealtimeCapabilities.self,
            forKey: .realtimeCapabilities
        )
    }
}

public struct VibeWavesResponse: Decodable, Sendable {
    public let waves: [VibeWave]
}

public struct VibeRule: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let position: Int
    public let enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, description, position, enabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Rule"
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

public struct VibeRulesResponse: Decodable, Sendable {
    public let rules: [VibeRule]
    public let rolloutPending: Bool

    private enum CodingKeys: String, CodingKey { case rules, rolloutPending }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([VibeRule].self, forKey: .rules) ?? []
        rolloutPending = try values.decodeIfPresent(Bool.self, forKey: .rolloutPending) ?? false
    }
}

public struct VibeWaveSettings: Encodable, Sendable {
    public let name: String
    public let slug: String
    public let description: String?
    public let type: VibeWaveType
    public let visibility: String
    public let postingPolicy: String
    public let position: Int
    public let commentsEnabled: Bool
    public let requiresPostApproval: Bool
    public let allowPolls: Bool
    public let allowPhotos: Bool
    public let allowLinks: Bool
    public let allowEchoes: Bool

    public init(
        name: String,
        slug: String,
        description: String?,
        type: VibeWaveType,
        visibility: String,
        postingPolicy: String,
        position: Int,
        commentsEnabled: Bool,
        requiresPostApproval: Bool,
        allowPolls: Bool,
        allowPhotos: Bool,
        allowLinks: Bool,
        allowEchoes: Bool
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.type = type
        self.visibility = visibility
        self.postingPolicy = postingPolicy
        self.position = position
        self.commentsEnabled = commentsEnabled
        self.requiresPostApproval = requiresPostApproval
        self.allowPolls = allowPolls
        self.allowPhotos = allowPhotos
        self.allowLinks = allowLinks
        self.allowEchoes = allowEchoes
    }
}

/// Mirrors the server's Wave invariants so management UI never promises a
/// setting that the API will silently normalize.
public enum VibeWaveManagementPolicy {
    public static func normalized(_ settings: VibeWaveSettings) -> VibeWaveSettings {
        var visibility = settings.visibility
        var postingPolicy = settings.postingPolicy
        var commentsEnabled = settings.commentsEnabled
        var requiresPostApproval = settings.requiresPostApproval
        var allowPolls = settings.allowPolls
        var allowLinks = settings.allowLinks

        switch settings.type {
        case .announcements, .events:
            postingPolicy = "ADMINS"
            requiresPostApproval = false
            allowPolls = false
        case .staff:
            visibility = "STAFF"
            postingPolicy = "MODERATORS"
        case .questions:
            commentsEnabled = true
        case .resources:
            allowLinks = true
        case .general, .media, .custom, .unknown:
            break
        }

        return VibeWaveSettings(
            name: settings.name,
            slug: settings.slug,
            description: settings.description,
            type: settings.type,
            visibility: visibility,
            postingPolicy: postingPolicy,
            position: max(0, settings.position),
            commentsEnabled: commentsEnabled,
            requiresPostApproval: requiresPostApproval,
            allowPolls: allowPolls,
            allowPhotos: settings.allowPhotos,
            allowLinks: allowLinks,
            allowEchoes: settings.allowEchoes
        )
    }

    public static func canArchive(
        isSystem: Bool,
        isDefault: Bool,
        isArchived: Bool,
        serverAllowsArchive: Bool
    ) -> Bool {
        serverAllowsArchive && !isSystem && !isDefault && !isArchived
    }

    public static func canRestore(
        isSystem: Bool,
        isDefault: Bool,
        isArchived: Bool,
        serverAllowsManagement: Bool
    ) -> Bool {
        serverAllowsManagement && !isSystem && !isDefault && isArchived
    }
}

public struct VibeWaveSubscription: Codable, Equatable, Sendable {
    public let notificationLevel: String
    /// `nil` means the Wave inherits the delivery channel from its Vibe.
    public let pushEnabled: Bool?
    /// `nil` means the Wave inherits the delivery channel from its Vibe.
    public let emailEnabled: Bool?
    public let lastReadAt: String?
    public let inherited: Bool?

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notificationLevel = try values.decodeIfPresent(String.self, forKey: .notificationLevel) ?? "INHERIT"
        pushEnabled = try values.decodeIfPresent(Bool.self, forKey: .pushEnabled)
        emailEnabled = try values.decodeIfPresent(Bool.self, forKey: .emailEnabled)
        lastReadAt = try values.decodeIfPresent(String.self, forKey: .lastReadAt)
        inherited = try values.decodeIfPresent(Bool.self, forKey: .inherited)
    }

    /// Resolves the Wave override without guessing a server-side Vibe value.
    public func effectiveNotificationLevel(inheriting parentLevel: String) -> String {
        notificationLevel == "INHERIT" ? parentLevel : notificationLevel
    }

    public func effectivePushEnabled(inheriting parentValue: Bool) -> Bool {
        pushEnabled ?? parentValue
    }

    public func effectiveEmailEnabled(inheriting parentValue: Bool) -> Bool {
        emailEnabled ?? parentValue
    }
}

/// A three-state editor value for a Wave delivery channel.
/// The API represents `.inherit` as JSON `null`.
public enum WaveDeliveryOverride: String, CaseIterable, Identifiable, Sendable {
    case inherit
    case enabled
    case disabled

    public var id: String { rawValue }

    public init(_ value: Bool?) {
        self = value.map { $0 ? .enabled : .disabled } ?? .inherit
    }

    public var apiValue: Bool? {
        switch self {
        case .inherit: nil
        case .enabled: true
        case .disabled: false
        }
    }
}

public struct VibeWaveNotificationSettingsResponse: Decodable, Sendable {
    public let settings: VibeWaveSubscription
}

public struct PostableVibe: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let avatarURL: String?
    public let postingPolicy: String?
    public let isPersonal: Bool

    enum CodingKeys: String, CodingKey {
        case id, slug, name, postingPolicy, isPersonal
        case avatarURL = "avatarUrl"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        slug = try values.decode(String.self, forKey: .slug)
        name = try values.decode(String.self, forKey: .name)
        avatarURL = try values.decodeIfPresent(String.self, forKey: .avatarURL)
        postingPolicy = try values.decodeIfPresent(String.self, forKey: .postingPolicy)
        isPersonal = try values.decodeIfPresent(Bool.self, forKey: .isPersonal) ?? false
    }
}

public struct PostableVibesResponse: Decodable, Sendable {
    public let vibes: [PostableVibe]
}

public struct RippleAuthor: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
}

private struct RippleEnergyTags: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let tags = try? container.decode([String].self) {
            values = tags
            return
        }
        if let counts = try? container.decode([String: Int].self) {
            values = counts
                .filter { $0.value > 0 }
                .sorted {
                    $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
                }
                .map(\.key)
            return
        }
        values = []
    }
}

public struct Ripple: Decodable, Identifiable, Sendable {
    public let id: String
    public let clubId: String?
    public let club: VibeSummary?
    public let body: String?
    public let status: String?
    public let isSpoiler: Bool
    public let commentsDisabled: Bool
    public let likeCount: Int
    public let commentCount: Int
    public let shareCount: Int
    public let echoCount: Int
    public let energyCount: Int
    public let energyTotal: Int
    public let energyTags: [String]
    public let pinnedAt: String?
    public let publishedAt: String?
    public let createdAt: String
    public let liked: Bool
    public let author: RippleAuthor
    public let attachments: [RippleAttachment]
    public let poll: RipplePoll?
    public let wave: RippleWaveIdentity?
    public let commentPreview: [RippleComment]
    public let conversationSummary: RippleConversationSummary?
    public let questionStatus: String?
    public let acceptedAnswerId: String?
    public let acceptedAnswerAt: String?
    public let resourceCategory: String?
    public let bookmarked: Bool

    enum CodingKeys: String, CodingKey {
        case id, clubId, club, body, status, isSpoiler, commentsDisabled
        case likeCount, commentCount, shareCount, echoCount
        case energyCount, energyTotal, energyTags
        case pinnedAt, publishedAt, createdAt, liked, author, attachments, poll, wave, commentPreview
        case conversationSummary
        case questionStatus, acceptedAnswerId, acceptedAnswerAt, resourceCategory, bookmarked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        clubId = try values.decodeIfPresent(String.self, forKey: .clubId)
        club = try values.decodeIfPresent(VibeSummary.self, forKey: .club)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        isSpoiler = try values.decodeIfPresent(Bool.self, forKey: .isSpoiler) ?? false
        commentsDisabled = try values.decodeIfPresent(Bool.self, forKey: .commentsDisabled) ?? false
        likeCount = try values.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try values.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        shareCount = try values.decodeIfPresent(Int.self, forKey: .shareCount) ?? 0
        echoCount = try values.decodeIfPresent(Int.self, forKey: .echoCount) ?? 0
        energyCount = try values.decodeIfPresent(Int.self, forKey: .energyCount) ?? 0
        energyTotal = try values.decodeIfPresent(Int.self, forKey: .energyTotal) ?? 0
        energyTags = try values.decodeIfPresent(RippleEnergyTags.self, forKey: .energyTags)?.values ?? []
        pinnedAt = try values.decodeIfPresent(String.self, forKey: .pinnedAt)
        publishedAt = try values.decodeIfPresent(String.self, forKey: .publishedAt)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        liked = try values.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        author = try values.decode(RippleAuthor.self, forKey: .author)
        attachments = try values.decodeIfPresent([RippleAttachment].self, forKey: .attachments) ?? []
        poll = try values.decodeIfPresent(RipplePoll.self, forKey: .poll)
        wave = try values.decodeIfPresent(RippleWaveIdentity.self, forKey: .wave)
        commentPreview = try values.decodeIfPresent([RippleComment].self, forKey: .commentPreview) ?? []
        conversationSummary = try values.decodeIfPresent(
            RippleConversationSummary.self,
            forKey: .conversationSummary
        )
        questionStatus = try values.decodeIfPresent(String.self, forKey: .questionStatus)
        acceptedAnswerId = try values.decodeIfPresent(String.self, forKey: .acceptedAnswerId)
        acceptedAnswerAt = try values.decodeIfPresent(String.self, forKey: .acceptedAnswerAt)
        resourceCategory = try values.decodeIfPresent(String.self, forKey: .resourceCategory)
        bookmarked = try values.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
    }
}

public struct RippleConversationReply: Decodable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let parentId: String?
    public let createdAt: String
    public let user: SocialIdentity
}

public struct RippleConversationCapabilities: Decodable, Equatable, Sendable {
    public let canReply: Bool
    public let canOpenDiscussion: Bool

    enum CodingKeys: CodingKey {
        case canReply, canOpenDiscussion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canReply = try values.decodeIfPresent(Bool.self, forKey: .canReply) ?? false
        canOpenDiscussion = try values.decodeIfPresent(Bool.self, forKey: .canOpenDiscussion) ?? true
    }
}

public struct RippleConversationSummary: Decodable, Sendable {
    public let latestReplies: [RippleConversationReply]
    public let participants: [SocialIdentity]
    public let replyCount: Int
    public let lastActivityAt: String?
    public let unreadCount: Int
    public let firstUnreadReplyId: String?
    public let state: String
    public let locked: Bool
    public let capabilities: RippleConversationCapabilities

    enum CodingKeys: CodingKey {
        case latestReplies, participants, replyCount, lastActivityAt, unreadCount
        case firstUnreadReplyId, state, locked, capabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latestReplies = Array(
            (try values.decodeIfPresent([RippleConversationReply].self, forKey: .latestReplies) ?? [])
                .prefix(3)
        )
        participants = Array(
            (try values.decodeIfPresent([SocialIdentity].self, forKey: .participants) ?? [])
                .reduce(into: [SocialIdentity]()) { result, participant in
                    if !result.contains(where: { $0.id == participant.id }) {
                        result.append(participant)
                    }
                }
                .prefix(3)
        )
        replyCount = max(0, try values.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0)
        lastActivityAt = try values.decodeIfPresent(String.self, forKey: .lastActivityAt)
        unreadCount = max(0, try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        firstUnreadReplyId = try values.decodeIfPresent(String.self, forKey: .firstUnreadReplyId)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? "OPEN"
        locked = (try values.decodeIfPresent(Bool.self, forKey: .locked)) ?? (state == "LOCKED")
        capabilities = try values.decodeIfPresent(
            RippleConversationCapabilities.self,
            forKey: .capabilities
        ) ?? RippleConversationCapabilities()
    }
}

private extension RippleConversationCapabilities {
    init() {
        canReply = false
        canOpenDiscussion = true
    }
}

public struct RippleWaveIdentity: Decodable, Equatable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let type: VibeWaveType
}

public struct RippleBookmarkResponse: Decodable, Equatable, Sendable {
    public let bookmarked: Bool
}

public struct AcceptedAnswerResponse: Decodable, Equatable, Sendable {
    public let acceptedAnswerId: String?
    public let questionStatus: String
}

/// Pure presentation policy shared by the native Question and Resource views.
public enum SpecializedWaveUIRules {
    public static func canManageQuestionAnswer(isAuthor: Bool, canModerate: Bool) -> Bool {
        isAuthor || canModerate
    }

    public static func canPublishResource(category: String, hasAttachment: Bool) -> Bool {
        !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasAttachment
    }
}

public struct RipplePinMutation: Decodable, Sendable {
    public struct Post: Decodable, Sendable {
        public let id: String
        public let pinnedAt: String?
    }

    public let post: Post
}

public enum RippleAttachmentKind: String, Decodable, Sendable {
    case photo = "PHOTO"
    case voice = "VOICE"
    case videoMessage = "VIDEO_MESSAGE"
    case link = "LINK"
    case westreemVideo = "WESTREEM_VIDEO"
    case westreemCollection = "WESTREEM_COLLECTION"
    case westreemClip = "WESTREEM_CLIP"
    case westreemRipple = "WESTREEM_RIPPLE"
    case westreemEvent = "WESTREEM_EVENT"
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = RippleAttachmentKind(rawValue: value) ?? .unknown
    }
}

public struct RippleAttachment: Decodable, Identifiable, Sendable {
    public let id: String
    public let type: RippleAttachmentKind
    public let position: Int?
    public let imageURL: String?
    public let externalURL: String?
    public let linkTitle: String?
    public let linkDescription: String?
    public let linkImageURL: String?
    public let linkFaviconURL: String?
    public let linkDomain: String?
    public let likeCount: Int
    public let commentCount: Int
    public let shareCount: Int
    public let viewerLikedPhoto: Bool
    public let video: RippleVideoAttachment?
    public let collection: RippleCollectionAttachment?
    public let userPost: RippleClippingAttachment?
    public let fanClubPost: EmbeddedRipple?
    public let vibeEvent: RippleEventAttachment?
    public let conversationalMedia: ConversationalMedia?

    enum CodingKeys: String, CodingKey {
        case id, type, position, imageURL = "imageUrl", externalURL = "externalUrl"
        case linkTitle, linkDescription, linkImageURL = "linkImageUrl"
        case linkFaviconURL = "linkFaviconUrl", linkDomain
        case likeCount, commentCount, shareCount, likes
        case video, collection, userPost, fanClubPost, vibeEvent, conversationalMedia
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(RippleAttachmentKind.self, forKey: .type)
        position = try values.decodeIfPresent(Int.self, forKey: .position)
        imageURL = try values.decodeIfPresent(String.self, forKey: .imageURL)
        externalURL = try values.decodeIfPresent(String.self, forKey: .externalURL)
        linkTitle = try values.decodeIfPresent(String.self, forKey: .linkTitle)
        linkDescription = try values.decodeIfPresent(String.self, forKey: .linkDescription)
        linkImageURL = try values.decodeIfPresent(String.self, forKey: .linkImageURL)
        linkFaviconURL = try values.decodeIfPresent(String.self, forKey: .linkFaviconURL)
        linkDomain = try values.decodeIfPresent(String.self, forKey: .linkDomain)
        likeCount = try values.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try values.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        shareCount = try values.decodeIfPresent(Int.self, forKey: .shareCount) ?? 0
        viewerLikedPhoto = (try? values.decodeIfPresent([IdentifierOnly].self, forKey: .likes))??.isEmpty == false
        video = try values.decodeIfPresent(RippleVideoAttachment.self, forKey: .video)
        collection = try values.decodeIfPresent(RippleCollectionAttachment.self, forKey: .collection)
        userPost = try values.decodeIfPresent(RippleClippingAttachment.self, forKey: .userPost)
        fanClubPost = try values.decodeIfPresent(EmbeddedRipple.self, forKey: .fanClubPost)
        vibeEvent = try values.decodeIfPresent(RippleEventAttachment.self, forKey: .vibeEvent)
        conversationalMedia = try values.decodeIfPresent(
            ConversationalMedia.self,
            forKey: .conversationalMedia
        )
    }
}

public struct RippleEventAttachment: Decodable, Sendable {
    public let id: String
    public let slug: String?
    public let title: String?
    public let summary: String?
    public let coverURL: String?
    public let startsAt: String?
    public let status: String?
    public let visibility: String?
    public let goingCount: Int
    public let interestedCount: Int
    public let club: RippleEventIdentity?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, summary, startsAt, status, visibility, goingCount, interestedCount, club
        case coverURL = "coverUrl"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        slug = try values.decodeIfPresent(String.self, forKey: .slug)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        coverURL = try values.decodeIfPresent(String.self, forKey: .coverURL)
        startsAt = try values.decodeIfPresent(String.self, forKey: .startsAt)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
        goingCount = try values.decodeIfPresent(Int.self, forKey: .goingCount) ?? 0
        interestedCount = try values.decodeIfPresent(Int.self, forKey: .interestedCount) ?? 0
        club = try values.decodeIfPresent(RippleEventIdentity.self, forKey: .club)
    }
}

public struct RippleEventIdentity: Decodable, Sendable {
    public let name: String?
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case avatarURL = "avatarUrl"
    }
}

private struct IdentifierOnly: Decodable {
    let id: String?
}

public struct RippleVideoAttachment: Decodable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailURL: String?
    public let thumbnailFocus: String?
    public let videoURL: String?
    public let duration: Double?
    public let type: String?
    public let width: Int?
    public let height: Int?
    public let views: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, type, width, height, views
        case thumbnailURL = "thumbnailUrl"
        case thumbnailFocus
        case videoURL = "videoUrl"
    }
}

public struct RippleCollectionAttachment: Decodable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let visibility: String?
}

public struct RippleClippingAttachment: Decodable, Sendable {
    public let id: String
    public let caption: String?
    public let markIn: Double?
    public let markOut: Double?
    public let videoId: String?
    public let episodeId: String?
    public let video: RippleVideoAttachment?
    public let episode: RippleEpisodeAttachment?
}

public struct RippleEpisodeAttachment: Decodable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailUrl: String?
    public let videoUrl: String?
    public let duration: Double?
}

public struct EmbeddedRipple: Decodable, Sendable {
    public let id: String
    public let body: String?
    public let isSpoiler: Bool
    public let commentsDisabled: Bool
    public let commentCount: Int
    public let shareCount: Int
    public let echoCount: Int
    public let energyCount: Int
    public let energyTotal: Int
    public let energyTags: [String]
    public let author: RippleAuthor
    public let attachments: [RippleAttachment]

    enum CodingKeys: String, CodingKey {
        case id, body, isSpoiler, commentsDisabled, commentCount, shareCount
        case echoCount, energyCount, energyTotal, energyTags, author, attachments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        isSpoiler = try values.decodeIfPresent(Bool.self, forKey: .isSpoiler) ?? false
        commentsDisabled = try values.decodeIfPresent(Bool.self, forKey: .commentsDisabled) ?? false
        commentCount = try values.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        shareCount = try values.decodeIfPresent(Int.self, forKey: .shareCount) ?? 0
        echoCount = try values.decodeIfPresent(Int.self, forKey: .echoCount) ?? 0
        energyCount = try values.decodeIfPresent(Int.self, forKey: .energyCount) ?? 0
        energyTotal = try values.decodeIfPresent(Int.self, forKey: .energyTotal) ?? 0
        energyTags = try values.decodeIfPresent(RippleEnergyTags.self, forKey: .energyTags)?.values ?? []
        author = try values.decode(RippleAuthor.self, forKey: .author)
        attachments = try values.decodeIfPresent([RippleAttachment].self, forKey: .attachments) ?? []
    }
}

public struct RipplePoll: Decodable, Sendable {
    public let id: String
    public let question: String
    public let allowsMultiple: Bool
    public let maxSelections: Int
    public let allowsVoteChanges: Bool
    public let resultsVisibility: String
    public let closesAt: String?
    public let closedAt: String?
    public let options: [RipplePollOption]
    public let votes: [RipplePollVote]
    public let totalVoters: Int

    enum CodingKeys: String, CodingKey {
        case id, question, allowsMultiple, maxSelections, allowsVoteChanges
        case resultsVisibility, closesAt, closedAt, options, votes, totalVoters
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        question = try values.decode(String.self, forKey: .question)
        allowsMultiple = try values.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
        maxSelections = try values.decodeIfPresent(Int.self, forKey: .maxSelections) ?? 1
        allowsVoteChanges = try values.decodeIfPresent(Bool.self, forKey: .allowsVoteChanges) ?? false
        resultsVisibility = try values.decodeIfPresent(String.self, forKey: .resultsVisibility) ?? "AFTER_VOTE"
        closesAt = try values.decodeIfPresent(String.self, forKey: .closesAt)
        closedAt = try values.decodeIfPresent(String.self, forKey: .closedAt)
        options = try values.decodeIfPresent([RipplePollOption].self, forKey: .options) ?? []
        votes = try values.decodeIfPresent([RipplePollVote].self, forKey: .votes) ?? []
        totalVoters = try values.decodeIfPresent(Int.self, forKey: .totalVoters)
            ?? options.reduce(0) { $0 + $1.voteCount }
    }
}

public struct RipplePollOption: Decodable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let position: Int
    public let voteCount: Int

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        voteCount = try values.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, label, position, voteCount
    }
}

public struct RipplePollVote: Decodable, Sendable {
    public let optionId: String
}

public struct RipplePageResponse: Decodable, Sendable {
    public let posts: [Ripple]
    public let nextCursor: String?
    public let restricted: Bool
    public let resourceCategories: [String]

    enum CodingKeys: String, CodingKey {
        case posts, nextCursor, restricted, resourceCategories
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        posts = try values.decodeIfPresent([Ripple].self, forKey: .posts) ?? []
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        restricted = try values.decodeIfPresent(Bool.self, forKey: .restricted) ?? false
        resourceCategories = try values.decodeIfPresent([String].self, forKey: .resourceCategories) ?? []
    }
}

public struct RippleDetailResponse: Decodable, Sendable {
    public let post: Ripple
}

public struct RippleComment: Decodable, Identifiable, Sendable {
    public let id: String
    public let userId: String
    public let content: String
    public let contentHTML: String?
    public let parentId: String?
    public let likeCount: Int
    public let createdAt: String
    public let editedAt: String?
    public let user: SocialIdentity
    public let replies: [RippleComment]
    public let viewerLiked: Bool

    enum CodingKeys: String, CodingKey {
        case id, userId, content, parentId, likeCount, createdAt, editedAt, user, replies, likes
        case contentHTML = "contentHtml"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        user = try values.decode(SocialIdentity.self, forKey: .user)
        // Canonical conversation previews already carry the author identity and
        // intentionally omit the redundant legacy userId field.
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? user.id
        content = try values.decode(String.self, forKey: .content)
        contentHTML = try values.decodeIfPresent(String.self, forKey: .contentHTML)
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        likeCount = try values.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        createdAt = try values.decode(String.self, forKey: .createdAt)
        editedAt = try values.decodeIfPresent(String.self, forKey: .editedAt)
        replies = try values.decodeIfPresent([RippleComment].self, forKey: .replies) ?? []
        viewerLiked = (try? values.decodeIfPresent([IdentifierOnly].self, forKey: .likes))??.isEmpty == false
    }
}

public struct RippleCommentsResponse: Decodable, Sendable {
    public let comments: [RippleComment]
}

public struct RippleCommentResponse: Decodable, Sendable {
    public let comment: RippleComment
}

public struct RippleCommentLikeResponse: Decodable, Equatable, Sendable {
    public let liked: Bool
    public let likeCount: Int
}

public struct CreateRippleResponse: Decodable, Sendable {
    public let post: Ripple
}

public struct PersonalVibeResponse: Decodable, Sendable {
    public let vibe: VibeSummary
}

public struct VibeFollowResponse: Decodable, Equatable, Sendable {
    public let following: Bool
}

public struct VibeJoinResponse: Decodable, Sendable {
    public let membership: VibeMembership?
    public let alreadyMember: Bool
    public let pending: Bool

    enum CodingKeys: String, CodingKey {
        case membership, alreadyMember, pending
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        membership = try values.decodeIfPresent(VibeMembership.self, forKey: .membership)
        alreadyMember = try values.decodeIfPresent(Bool.self, forKey: .alreadyMember) ?? false
        pending = try values.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

public enum RippleCreateAttachment: Encodable, Equatable, Sendable {
    case photo(imageURL: String)
    case voice(mediaId: String)
    case videoMessage(mediaId: String)
    case link(externalURL: String)
    case video(id: String)
    case collection(id: String)
    case clip(id: String)
    case ripple(id: String)

    enum CodingKeys: String, CodingKey {
        case type, imageURL = "imageUrl", externalURL = "externalUrl"
        case videoId, collectionId, userPostId, fanClubPostId, mediaId
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .photo(let imageURL):
            try values.encode("PHOTO", forKey: .type)
            try values.encode(imageURL, forKey: .imageURL)
        case .voice(let mediaId):
            try values.encode("VOICE", forKey: .type)
            try values.encode(mediaId, forKey: .mediaId)
        case .videoMessage(let mediaId):
            try values.encode("VIDEO_MESSAGE", forKey: .type)
            try values.encode(mediaId, forKey: .mediaId)
        case .link(let externalURL):
            try values.encode("LINK", forKey: .type)
            try values.encode(externalURL, forKey: .externalURL)
        case .video(let id):
            try values.encode("WESTREEM_VIDEO", forKey: .type)
            try values.encode(id, forKey: .videoId)
        case .collection(let id):
            try values.encode("WESTREEM_COLLECTION", forKey: .type)
            try values.encode(id, forKey: .collectionId)
        case .clip(let id):
            try values.encode("WESTREEM_CLIP", forKey: .type)
            try values.encode(id, forKey: .userPostId)
        case .ripple(let id):
            try values.encode("WESTREEM_RIPPLE", forKey: .type)
            try values.encode(id, forKey: .fanClubPostId)
        }
    }
}

public struct RipplePollDraft: Encodable, Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let allowsMultiple: Bool
    public let maxSelections: Int
    public let allowsVoteChanges: Bool
    public let resultsVisibility: String

    public init(
        question: String,
        options: [String],
        allowsMultiple: Bool = false,
        maxSelections: Int = 1,
        allowsVoteChanges: Bool = true,
        resultsVisibility: String = "AFTER_VOTE"
    ) {
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.maxSelections = maxSelections
        self.allowsVoteChanges = allowsVoteChanges
        self.resultsVisibility = resultsVisibility
    }
}

public struct ResolvedRippleAttachmentResponse: Decodable, Sendable {
    public let attachment: ResolvedRippleAttachment
    public let preview: RippleAttachmentPreview?
}

public struct ResolvedRippleAttachment: Decodable, Sendable {
    public let type: String
    public let imageURL: String?
    public let externalURL: String?
    public let videoId: String?
    public let collectionId: String?
    public let userPostId: String?
    public let fanClubPostId: String?

    enum CodingKeys: String, CodingKey {
        case type, videoId, collectionId, userPostId, fanClubPostId
        case imageURL = "imageUrl"
        case externalURL = "externalUrl"
    }

    public var createAttachment: RippleCreateAttachment? {
        switch type {
        case "PHOTO":
            imageURL.map(RippleCreateAttachment.photo)
        case "LINK":
            externalURL.map(RippleCreateAttachment.link)
        case "WESTREEM_VIDEO":
            videoId.map(RippleCreateAttachment.video)
        case "WESTREEM_COLLECTION":
            collectionId.map(RippleCreateAttachment.collection)
        case "WESTREEM_CLIP":
            userPostId.map(RippleCreateAttachment.clip)
        case "WESTREEM_RIPPLE":
            fanClubPostId.map(RippleCreateAttachment.ripple)
        default:
            nil
        }
    }
}

public struct RippleAttachmentPreview: Decodable, Sendable {
    public let kind: String?
    public let title: String?
    public let subtitle: String?
    public let thumbnailURL: String?
    public let faviconURL: String?
    public let domain: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, domain
        case thumbnailURL = "thumbnailUrl"
        case faviconURL = "faviconUrl"
    }
}

public struct RipplePhotoUploadPreparation: Decodable, Sendable {
    public let uploadURL: String
    public let objectKey: String?
    public let deliveryURL: String?
    public let mediaURL: String?

    enum CodingKeys: String, CodingKey {
        case objectKey
        case uploadURL = "uploadUrl"
        case deliveryURL = "deliveryUrl"
        case mediaURL = "mediaUrl"
    }
}

public struct RipplePhotoUploadResult: Decodable, Sendable {
    public let mediaURL: String?

    enum CodingKeys: String, CodingKey {
        case mediaURL = "mediaUrl"
    }
}

public struct UploadedRipplePhoto: Equatable, Sendable {
    public let imageURL: String
    public let objectKey: String?
}

public struct DiscoverRipplePageResponse: Decodable, Sendable {
    public let version: Int
    public let mode: String
    public let posts: [Ripple]
    public let nextCursor: String?
}

public enum AtmosphereFeedItem: Sendable {
    case ripple(Ripple)
    case video(AtmosphereVideo)
    case excludedEpisode
    case excludedShort
    case unsupported(kind: String?)
}

extension AtmosphereFeedItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind = "_kind"
        case type
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decodeIfPresent(String.self, forKey: .kind)
        let type = try values.decodeIfPresent(String.self, forKey: .type)?.lowercased()

        switch kind {
        case "fan_club_post":
            self = .ripple(try Ripple(from: decoder))
        case "video" where type == "short":
            self = .excludedShort
        case "video":
            self = .video(try AtmosphereVideo(from: decoder))
        case "episode":
            self = .excludedEpisode
        default:
            self = .unsupported(kind: kind)
        }
    }
}

public struct AtmosphereVideo: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailURL: String?
    public let thumbnailFocus: String?
    public let videoURL: String?
    public let duration: Double?
    public let views: Int
    public let type: String
    public let description: String?
    public let publishedAt: String?
    public let createdAt: String
    public let channel: AtmosphereChannel?
    public let show: AtmosphereShow?
    public let contentRatings: [AtmosphereContentRating]?
    public let counts: AtmosphereVideoCounts?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, views, type, description, publishedAt, createdAt
        case thumbnailURL = "thumbnailUrl"
        case thumbnailFocus
        case videoURL = "videoUrl"
        case channel, show, contentRatings
        case counts = "_count"
    }
}

public struct AtmosphereContentRating: Decodable, Sendable {
    public let overall: Int
    public let tags: [String]?
}

public struct AtmosphereVideoCounts: Decodable, Sendable {
    public let comments: Int?
    public let fanClubAttachments: Int?
}

public struct AtmosphereChannel: Decodable, Sendable {
    public let id: String
    public let name: String
    public let handle: String
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, handle
        case avatarURL = "avatarUrl"
    }
}

public struct AtmosphereShow: Decodable, Sendable {
    public let id: String
    public let title: String
    public let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverURL = "coverUrl"
    }
}

public struct AtmosphereFeed: Decodable, Sendable {
    public let items: [AtmosphereFeedItem]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawItems = try container.decode([AtmosphereFeedItem].self)
        items = rawItems.filter {
            switch $0 {
            case .ripple, .video: true
            case .excludedEpisode, .excludedShort, .unsupported: false
            }
        }
    }
}
