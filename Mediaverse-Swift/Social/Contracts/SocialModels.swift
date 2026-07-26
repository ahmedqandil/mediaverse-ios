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

    enum CodingKeys: String, CodingKey {
        case id, clubId, club, body, status, isSpoiler, commentsDisabled
        case likeCount, commentCount, shareCount, echoCount
        case energyCount, energyTotal, energyTags
        case pinnedAt, publishedAt, createdAt, liked, author, attachments, poll
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
    case link = "LINK"
    case westreemVideo = "WESTREEM_VIDEO"
    case westreemCollection = "WESTREEM_COLLECTION"
    case westreemClip = "WESTREEM_CLIP"
    case westreemRipple = "WESTREEM_RIPPLE"
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

    enum CodingKeys: String, CodingKey {
        case id, type, position, imageURL = "imageUrl", externalURL = "externalUrl"
        case linkTitle, linkDescription, linkImageURL = "linkImageUrl"
        case linkFaviconURL = "linkFaviconUrl", linkDomain
        case likeCount, commentCount, shareCount, likes
        case video, collection, userPost, fanClubPost
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

    enum CodingKeys: String, CodingKey {
        case posts, nextCursor, restricted
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        posts = try values.decodeIfPresent([Ripple].self, forKey: .posts) ?? []
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        restricted = try values.decodeIfPresent(Bool.self, forKey: .restricted) ?? false
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
        userId = try values.decode(String.self, forKey: .userId)
        content = try values.decode(String.self, forKey: .content)
        contentHTML = try values.decodeIfPresent(String.self, forKey: .contentHTML)
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        likeCount = try values.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        createdAt = try values.decode(String.self, forKey: .createdAt)
        editedAt = try values.decodeIfPresent(String.self, forKey: .editedAt)
        user = try values.decode(SocialIdentity.self, forKey: .user)
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
    case link(externalURL: String)
    case video(id: String)
    case collection(id: String)
    case clip(id: String)
    case ripple(id: String)

    enum CodingKeys: String, CodingKey {
        case type, imageURL = "imageUrl", externalURL = "externalUrl"
        case videoId, collectionId, userPostId, fanClubPostId
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .photo(let imageURL):
            try values.encode("PHOTO", forKey: .type)
            try values.encode(imageURL, forKey: .imageURL)
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
