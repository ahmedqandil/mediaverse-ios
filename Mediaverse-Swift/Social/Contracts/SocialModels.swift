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
    public let visibility: String?
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
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        memberCount = try values.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        followerCount = try values.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        postCount = try values.decodeIfPresent(Int.self, forKey: .postCount) ?? 0
        isPersonal = try values.decodeIfPresent(Bool.self, forKey: .isPersonal) ?? false
        owner = try values.decodeIfPresent(SocialIdentity.self, forKey: .owner)
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
    public let canInvite: Bool
    public let canManageAffiliations: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case canView, canViewContent, canPost, canComment, canVote, canFollow
        case canJoin, canRequestJoin, canLeave, canManageClub
        case canModerateContent, canModerateMembers, canInvite, canManageAffiliations
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
        energyTags = try values.decodeIfPresent([String].self, forKey: .energyTags) ?? []
        pinnedAt = try values.decodeIfPresent(String.self, forKey: .pinnedAt)
        publishedAt = try values.decodeIfPresent(String.self, forKey: .publishedAt)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        liked = try values.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        author = try values.decode(RippleAuthor.self, forKey: .author)
        attachments = try values.decodeIfPresent([RippleAttachment].self, forKey: .attachments) ?? []
        poll = try values.decodeIfPresent(RipplePoll.self, forKey: .poll)
    }
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
}

public struct RipplePoll: Decodable, Sendable {
    public let id: String
    public let question: String
    public let allowsMultiple: Bool
    public let maxSelections: Int
    public let allowsVoteChanges: Bool
    public let resultsVisibility: String
    public let closesAt: String?
    public let options: [RipplePollOption]
    public let votes: [RipplePollVote]

    enum CodingKeys: String, CodingKey {
        case id, question, allowsMultiple, maxSelections, allowsVoteChanges
        case resultsVisibility, closesAt, options, votes
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
        options = try values.decodeIfPresent([RipplePollOption].self, forKey: .options) ?? []
        votes = try values.decodeIfPresent([RipplePollVote].self, forKey: .votes) ?? []
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

    enum CodingKeys: String, CodingKey {
        case id, title, duration, views, type, description, publishedAt, createdAt
        case thumbnailURL = "thumbnailUrl"
        case thumbnailFocus
        case videoURL = "videoUrl"
        case channel, show
    }
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
