import Foundation

// ── Shared sub-types ──────────────────────────────────────────────────────────

struct ChannelStub: Codable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
}

struct ShowStub: Codable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
}

struct SeasonStub: Codable, Identifiable {
    let id: String
    let seasonNumber: Int
    let title: String?
}

struct CommentUser: Codable, Identifiable {
    let id: String
    let name: String?
    let image: String?
}

struct Comment: Codable, Identifiable {
    let id: String
    let content: String?      // nil when isRemoved == true
    let isRemoved: Bool?
    let likes: Int?
    let createdAt: String
    let parentId: String?
    let user: CommentUser?
    let replies: [Comment]?
    let replyCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, content, isRemoved, likes, createdAt, parentId, user, replies
        case count = "_count"
    }

    private struct CountWrapper: Decodable {
        let replies: Int?
    }

    init(
        id: String,
        content: String?,
        isRemoved: Bool?,
        likes: Int?,
        createdAt: String,
        parentId: String?,
        user: CommentUser?,
        replies: [Comment]?,
        replyCount: Int?
    ) {
        self.id = id
        self.content = content
        self.isRemoved = isRemoved
        self.likes = likes
        self.createdAt = createdAt
        self.parentId = parentId
        self.user = user
        self.replies = replies
        self.replyCount = replyCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        isRemoved = try c.decodeIfPresent(Bool.self, forKey: .isRemoved)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        user = try c.decodeIfPresent(CommentUser.self, forKey: .user)
        replies = try c.decodeIfPresent([Comment].self, forKey: .replies)
        replyCount = try c.decodeIfPresent(CountWrapper.self, forKey: .count)?.replies
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(isRemoved, forKey: .isRemoved)
        try c.encodeIfPresent(likes, forKey: .likes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(replies, forKey: .replies)
    }
}

// ── Feed ─────────────────────────────────────────────────────────────────────

struct FeedVideo: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let videoUrl: String?
    let duration: Double?
    let views: Int
    let type: String?
    let publishedAt: String?
    let createdAt: String
    let channel: ChannelStub?
    let show: ShowStub?
}

struct FeedResponse: Codable {
    let videos: [FeedVideo]
    let nextCursor: String?
}

// ── Home feed config (from /api/feed-config) ──────────────────────────────────
// Mirrors the backend HomeFeedConfig so the iOS app drives carousel ordering,
// interleave interval, and slot count from the same admin settings as the web
// (HomeFeedClient.tsx uses the same mobileCarouselEvery / carouselSlots).

struct HomeFeedConfig: Decodable {
    let mobileCarouselEvery: Int    // insert a carousel after every N videos
    let mobileCarouselCount: Int    // max number of carousel slots to show
    let carouselSlots: [CarouselSlotDef]

    /// A single carousel strip — type ∈ { "shows", "channels", "shorts", "videos", "microdramas" }
    struct CarouselSlotDef: Decodable, Identifiable {
        let id:    String
        let type:  String
        let label: String
    }

    /// Offline / API-unavailable fallback — matches backend DEFAULT constant exactly.
    static let `default` = HomeFeedConfig(
        mobileCarouselEvery: 3,
        mobileCarouselCount: 3,
        carouselSlots: [
            CarouselSlotDef(id: "slot_1", type: "shows",    label: "TV Shows & Series"),
            CarouselSlotDef(id: "slot_2", type: "channels", label: "Channels"),
            CarouselSlotDef(id: "slot_3", type: "shorts",   label: "Shorts"),
        ]
    )
}

// ── Shorts ────────────────────────────────────────────────────────────────────

struct ShortLinkedClip: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
}

struct ShortLinkedEpisode: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let season: ShortSeason?
}

struct ShortSeason: Codable {
    let seasonNumber: Int
    let show: ShowStub?
}

struct Short: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let videoUrl: String?
    let thumbnailUrl: String?
    let views: Int
    let likes: Int
    let duration: Double?
    let channelId: String?
    let showId: String?
    let channel: ChannelStub?
    let linkedClipId: String?
    let linkedEpisodeId: String?
    let linkedClip: ShortLinkedClip?
    let linkedEpisode: ShortLinkedEpisode?
}

struct ShortsResponse: Codable {
    let shorts: [Short]
    let nextCursor: String?
    let reason: String?       // "not_logged_in" | "no_follows" for empty Following feed
}

// ── Video detail ──────────────────────────────────────────────────────────────

struct VideoChannel: Decodable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
    let followerCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, handle, avatarUrl
        case countWrapper = "_count"
    }
    private struct CountWrapper: Codable {
        let followers: Int
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        handle     = try c.decodeIfPresent(String.self, forKey: .handle)
        avatarUrl  = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        let cw     = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        followerCount = cw?.followers
    }
}

struct LikeRecord: Codable {
    let userId: String
    let type: String  // "like" | "dislike"
}

/// Minimal channel info returned in the upNext list.
/// The /api/videos/[id] upNext query selects channel WITHOUT id (only name/handle/avatarUrl),
/// so we cannot reuse ChannelStub (which requires id). This struct matches the actual response.
struct VideoUpNextChannel: Codable {
    let name: String
    let handle: String?
    let avatarUrl: String?
}

struct VideoUpNext: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int
    let channel: VideoUpNextChannel?
}

struct LinkedClip: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
}

struct LinkedEpisode: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let season: LinkedEpisodeSeason?
}

struct LinkedEpisodeSeason: Codable {
    let seasonNumber: Int
    let show: ShowStub?
}

struct VideoDetail: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let videoUrl: String?
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int
    let publishedAt: String?   // ISO 8601, optional — not set until video is published
    let createdAt: String?
    let type: String
    let channel: VideoChannel?
    let show: ShowStub?
    let likes: [LikeRecord]
    let comments: [Comment]
    let upNext: [VideoUpNext]
    let isSubscribed: Bool
    let userLike: String?   // "like" | "dislike" | null
    let isFollowingShow: Bool
    let showFollowerCount: Int
    let linkedClip: LinkedClip?
    let linkedEpisode: LinkedEpisode?
}

// ── Episode detail ────────────────────────────────────────────────────────────

struct EpisodeNavItem: Codable, Identifiable {
    let id: String
    let episodeNumber: Int
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let status: String?
    let videoUrl: String?
    let comingSoon: Bool?
    let seasonNumber: Int?
}

struct EpisodeSeason: Codable, Identifiable {
    let id: String
    let seasonNumber: Int
    let title: String?
    let episodes: [EpisodeListItem]
    let show: EpisodeShow?
}

struct EpisodeListItem: Codable, Identifiable {
    let id: String
    let episodeNumber: Int
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let status: String?
    let videoUrl: String?
    let comingSoon: Bool?
}

struct EpisodeShow: Codable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
    let genre: String?
    let language: String?
    let contentRating: String?
    let seasons: [EpisodeSeason]?
}

struct EpisodeDetail: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let videoUrl: String?
    let thumbnailUrl: String?
    let duration: Double?
    let episodeNumber: Int
    let seasonId: String
    let views: Int?
    let likes: [LikeRecord]    // all Like rows for this episode (userId + type)
    let comments: [Comment]
    let season: EpisodeSeason
    let prevEp: EpisodeNavItem?
    let nextEp: EpisodeNavItem?
    let isFollowing: Bool
    let followerCount: Int
    let paywallInfo: PaywallInfo?
    let rentalInfo: RentalInfo?
}

struct PaywallInfo: Codable {
    let productId: String
    let productName: String
    let entitlementType: String  // "PPV" | "SVOD"
    let networkId: String
    let price: Double?           // in cents
    let currency: String?
    let seasonId: String?
    let episodeId: String?
    let showId: String?
    let showTitle: String?
}

/// Shown to users who HAVE a valid PPV rental — displays countdown + plays remaining.
struct RentalInfo: Codable {
    /// Hard expiry of the rental before first play (ISO 8601)
    let validTo: String?
    /// Expiry of playback window after first play (ISO 8601)
    let playbackExpiresAt: String?
    /// nil = not yet started
    let firstPlayedAt: String?
    let playsUsed: Int
    let maxPlays: Int?
    let playbackWindowSecs: Int?
    let productName: String
}

/// Response from GET /api/entitlement/check
struct EntitlementCheckResponse: Codable {
    let hasAccess: Bool
    /// "NO_MEDIA" | "NOT_YET_AVAILABLE" | "NO_SCHEDULE" | "SCHEDULE_ENDED" | nil
    let code: String?
    let entitlementType: String?   // "AVOD" | "SVOD" | "PPV"
    let productId: String?
}

/// Response from POST /api/checkout/ppv or /api/checkout/svod
struct CheckoutResponse: Codable {
    let success: Bool
    let orderId: String?
    let networkSubscriptionId: String?
    let clientSecret: String?  // for real payment provider
    let redirectUrl: String?
}

// ── Active context ────────────────────────────────────────────────────────────

/// Mirrors ActiveContext in active-context.ts
struct ActiveContext: Codable, Identifiable {
    var id: String
    let type: String          // "admin" | "network" | "channel" | "user"
    let name: String
    let channelId: String?
    let damEnabled: Bool?
    let canCreateShows: Bool?
    let canPublishMicrodramas: Bool?
}

struct ContextsResponse: Codable {
    let contexts: [ActiveContext]
    let active: ActiveContext
    let user: ContextUser
}

struct ContextUser: Codable {
    let role: String
    let name: String?
    let image: String?
}

// ── Upload ────────────────────────────────────────────────────────────────────

struct UploadContext: Codable, Identifiable {
    let type: String          // "channel" | "show"
    let id: String
    let name: String
    let avatarUrl: String?
    let networkName: String?
}

struct UploadContextsResponse: Codable {
    let channels: [UploadContext]
    let shows: [UploadContext]
}

struct UploadPlaylistOption: Codable, Identifiable {
    struct Count: Codable { let items: Int }
    let id: String
    let title: String
    let type: String
    let visibility: String
    let count: Count

    private enum CodingKeys: String, CodingKey {
        case id, title, type, visibility
        case count = "_count"
    }
}

struct CfStreamUploadResponse: Codable {
    let uploadUrl: String
    let streamId: String
    let uploadLimitBytes: Int?
}

struct UploadCreateResponse: Codable, Identifiable {
    let id: String
    let title: String?
    let status: String?
}

struct UploadStreamStatus: Codable {
    let ready: Bool
    let pct: Int
    let hlsUrl: String?
}

struct UploadLinkItem: Codable, Identifiable {
    let id: String
    let title: String
    let duration: Double?
    let episodeNumber: Int?

    var displayTitle: String {
        if let episodeNumber {
            return "\(title) · Ep. \(episodeNumber)"
        }
        if let duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(title) · \(minutes):\(String(format: "%02d", seconds))"
        }
        return title
    }
}

// ── Profile ───────────────────────────────────────────────────────────────────

struct UserProfile: Codable {
    let id: String
    let name: String?
    let email: String?
    let image: String?
}

struct FullProfile: Codable {
    let id: String
    let name: String?
    let email: String?
    let image: String?
    let bio: String?
    let bannerUrl: String?
    let role: String?
    let handle: String?
    let channel: ProfileChannel?
}

struct ProfileChannel: Codable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let followerCount: Int?
}

struct ProfileResponse: Decodable {
    let profile: FullProfile

    private enum CodingKeys: String, CodingKey {
        case profile
        case user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let profile = try c.decodeIfPresent(FullProfile.self, forKey: .profile) {
            self.profile = profile
        } else {
            self.profile = try c.decode(FullProfile.self, forKey: .user)
        }
    }
}

// ── Continue watching ─────────────────────────────────────────────────────────

struct ProgressVideoItem: Decodable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let type: String?
    let channel: ChannelStub?
}

struct ProgressEpisodeItem: Decodable, Identifiable {
    struct Season: Decodable {
        let seasonNumber: Int?
        let show: ShowStub?
    }

    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let episodeNumber: Int?
    let season: Season?
}

struct ProgressItem: Decodable, Identifiable {
    let id: String
    let videoId: String?
    let episodeId: String?
    let seconds: Int?
    let percent: Double      // 0-1, backend key is percent
    let video: ProgressVideoItem?
    let episode: ProgressEpisodeItem?

    var progress: Double { percent }

    private enum CodingKeys: String, CodingKey {
        case id, videoId, episodeId, seconds, percent, video, episode
        case legacyProgress = "progress"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
            ?? c.decodeIfPresent(Double.self, forKey: .legacyProgress)
            ?? 0
        video = try c.decodeIfPresent(ProgressVideoItem.self, forKey: .video)
        episode = try c.decodeIfPresent(ProgressEpisodeItem.self, forKey: .episode)
    }
}

struct ContinueWatchingResponse: Decodable {
    let items: [ProgressItem]

    init(items: [ProgressItem]) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        if let items = try? [ProgressItem](from: decoder) {
            self.items = items
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([ProgressItem].self, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey { case items }
}

// ── Player markers ────────────────────────────────────────────────────────────

struct PlayerMarker: Codable, Identifiable {
    let id: String
    let timestampSec: Int
    let label: String
    let url: String
}

// ── Channel page ──────────────────────────────────────────────────────────────

struct ChannelDetail: Decodable, Identifiable {
    let id: String
    let name: String
    let handle: String
    let description: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let channelType: String?
    let verified: Bool
    let status: String
    let createdAt: String
    let followerCount: Int          // unwrapped from _count.followers

    struct VideoItem: Codable, Identifiable {
        let id: String
        let title: String
        let thumbnailUrl: String?
        let views: Int
        let duration: Double?
        let publishedAt: String?
        let createdAt: String
    }

    let videos: [VideoItem]

    private enum CodingKeys: String, CodingKey {
        case id, name, handle, description, avatarUrl, bannerUrl
        case channelType, verified, status, createdAt, videos
        case countWrapper = "_count"
    }
    private struct CountWrapper: Codable { let followers: Int }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self,              forKey: .id)
        name        = try c.decode(String.self,              forKey: .name)
        handle      = try c.decode(String.self,              forKey: .handle)
        description = try c.decodeIfPresent(String.self,    forKey: .description)
        avatarUrl   = try c.decodeIfPresent(String.self,    forKey: .avatarUrl)
        bannerUrl   = try c.decodeIfPresent(String.self,    forKey: .bannerUrl)
        channelType = try c.decodeIfPresent(String.self,    forKey: .channelType)
        verified    = try c.decode(Bool.self,                forKey: .verified)
        status      = try c.decode(String.self,              forKey: .status)
        createdAt   = try c.decode(String.self,              forKey: .createdAt)
        videos      = try c.decode([VideoItem].self,         forKey: .videos)
        let cw      = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        followerCount = cw?.followers ?? 0
    }
}

struct ChannelBrowseCard: Decodable, Identifiable {
    struct Count: Decodable {
        let followers: Int
        let videos: Int
    }

    let id: String
    let name: String
    let handle: String
    let description: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let verified: Bool
    let channelType: String?
    let status: String?
    let _count: Count?
}

struct ChannelPlaylist: Codable, Identifiable {
    struct PlaylistItem: Codable {
        struct PlaylistVideo: Codable {
            let id: String?
            let thumbnailUrl: String?
        }
        let video: PlaylistVideo?
    }
    struct Count: Codable { let items: Int }

    let id: String
    let title: String
    let description: String?
    let type: String           // "short" | "video"
    let _count: Count
    let items: [PlaylistItem]  // up to 4 items for thumbnail mosaic
}

struct FollowStatus: Codable {
    let subscribed: Bool
    let count: Int
    let notifyOnPublish: Bool
}

// ── Show page ─────────────────────────────────────────────────────────────────

struct ShowProductInfo: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String           // "SVOD" | "TRANSACTIONAL"
    let networkId: String
    let cycleFrequency: Int?
    let cycleUnit: String?
    let price: Int?            // in cents
    let currency: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, networkId, cycleFrequency, cycleUnit, price, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id) ?? UUID().uuidString
        name = try c.flexString(.name) ?? "Plan"
        type = try c.flexString(.type) ?? "SVOD"
        networkId = try c.flexString(.networkId) ?? ""
        cycleFrequency = try c.flexInt(.cycleFrequency)
        cycleUnit = try c.flexString(.cycleUnit)
        price = try c.flexInt(.price)
        currency = try c.flexString(.currency)
    }
}

struct ShowEpisodeItem: Decodable, Identifiable {
    let id: String
    let episodeNumber: Int
    let title: String
    let description: String?
    let thumbnailUrl: String?
    let videoUrl: String?
    let duration: Double?
    let airDate: String?
    let status: String
    let comingSoon: Bool
    let playable: Bool?
    let schedule: ShowEpisodeSchedule?

    private enum CodingKeys: String, CodingKey {
        case id, episodeNumber, title, description, thumbnailUrl, videoUrl, duration
        case airDate, status, comingSoon, playable, schedule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id) ?? UUID().uuidString
        episodeNumber = try c.flexInt(.episodeNumber) ?? 0
        title = try c.flexString(.title) ?? "Episode \(episodeNumber)"
        description = try c.flexString(.description)
        thumbnailUrl = try c.flexString(.thumbnailUrl)
        videoUrl = try c.flexString(.videoUrl)
        duration = try c.flexDouble(.duration)
        airDate = try c.flexString(.airDate)
        status = try c.flexString(.status) ?? "published"
        comingSoon = try c.flexBool(.comingSoon) ?? false
        playable = try c.flexBool(.playable)
        schedule = try c.decodeIfPresent(ShowEpisodeSchedule.self, forKey: .schedule)
    }

    struct ShowEpisodeSchedule: Decodable {
        struct Window: Decodable {
            let scope: String
            let premiereAt: String?

            private enum CodingKeys: String, CodingKey {
                case scope, premiereAt
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                scope = try c.flexString(.scope) ?? "worldwide"
                premiereAt = try c.flexString(.premiereAt)
            }
        }
        let templateId: String?
        let windows: [Window]

        private enum CodingKeys: String, CodingKey {
            case templateId, windows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            templateId = try c.flexString(.templateId)
            windows = (try? c.decodeIfPresent([Window].self, forKey: .windows)) ?? []
        }
    }
}

struct ShowSeasonData: Decodable, Identifiable {
    let id: String
    let seasonNumber: Int
    let title: String?
    let description: String?
    let coverUrl: String?
    let airDate: String?
    let endDate: String?
    let status: String
    let comingSoon: Bool
    let episodes: [ShowEpisodeItem]

    private enum CodingKeys: String, CodingKey {
        case id, seasonNumber, title, description, coverUrl, airDate, endDate, status, comingSoon, episodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id) ?? UUID().uuidString
        seasonNumber = try c.flexInt(.seasonNumber) ?? 0
        title = try c.flexString(.title)
        description = try c.flexString(.description)
        coverUrl = try c.flexString(.coverUrl)
        airDate = try c.flexString(.airDate)
        endDate = try c.flexString(.endDate)
        status = try c.flexString(.status) ?? "published"
        comingSoon = try c.flexBool(.comingSoon) ?? false
        episodes = (try? c.decodeIfPresent([ShowEpisodeItem].self, forKey: .episodes)) ?? []
    }
}

struct ShowData: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let bannerUrl: String?
    let trailerUrl: String?
    let showType: String       // "series"|"movie"|"film"|"anime"|"reality"|etc.
    let genre: String?
    let tags: [String]
    let language: String
    let country: String?
    let studio: String?
    let contentRating: String?
    let status: String
    let seasons: [ShowSeasonData]
    let entitlementType: String?    // "AVOD"|"SVOD"|"PPV"|nil
    let networkId: String?
    let svodProducts: [ShowProductInfo]
    let ppvProducts: [ShowProductInfo]
    let ppvProductIdBySeason: [String: String]   // seasonId → productId
    let userSubscribed: Bool
    let userSeasonRentals: [String]              // seasonIds with active rentals
    let isFollowing: Bool?
    let followerCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, coverUrl, bannerUrl, trailerUrl, showType, genre
        case tags, language, country, studio, contentRating, status, seasons
        case entitlementType, networkId, svodProducts, ppvProducts, ppvProductIdBySeason
        case userSubscribed, userSeasonRentals, isFollowing, followerCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id) ?? UUID().uuidString
        title = try c.flexString(.title) ?? "Untitled show"
        description = try c.flexString(.description)
        coverUrl = try c.flexString(.coverUrl)
        bannerUrl = try c.flexString(.bannerUrl)
        trailerUrl = try c.flexString(.trailerUrl)
        showType = (try c.flexString(.showType) ?? "series").lowercased()
        genre = try c.flexString(.genre)
        tags = try c.flexStringArray(.tags)
        language = try c.flexString(.language) ?? ""
        country = try c.flexString(.country)
        studio = try c.flexString(.studio)
        contentRating = try c.flexString(.contentRating)
        status = try c.flexString(.status) ?? "published"
        seasons = (try? c.decodeIfPresent([ShowSeasonData].self, forKey: .seasons)) ?? []
        entitlementType = try c.flexString(.entitlementType)
        networkId = try c.flexString(.networkId)
        svodProducts = (try? c.decodeIfPresent([ShowProductInfo].self, forKey: .svodProducts)) ?? []
        ppvProducts = (try? c.decodeIfPresent([ShowProductInfo].self, forKey: .ppvProducts)) ?? []
        ppvProductIdBySeason = (try? c.decodeIfPresent([String: String].self, forKey: .ppvProductIdBySeason)) ?? [:]
        userSubscribed = try c.flexBool(.userSubscribed) ?? false
        userSeasonRentals = try c.flexStringArray(.userSeasonRentals)
        isFollowing = try c.flexBool(.isFollowing)
        followerCount = try c.flexInt(.followerCount)
    }
}

struct RelatedShow: Decodable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
    let genre: String?
    let showType: String
    let contentRating: String?
    let status: String
    let entitlementType: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, coverUrl, genre, showType, contentRating, status, entitlementType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id) ?? UUID().uuidString
        title = try c.flexString(.title) ?? "Untitled show"
        coverUrl = try c.flexString(.coverUrl)
        genre = try c.flexString(.genre)
        showType = try c.flexString(.showType) ?? "series"
        contentRating = try c.flexString(.contentRating)
        status = try c.flexString(.status) ?? "published"
        entitlementType = try c.flexString(.entitlementType)
    }
}

struct ShowPageResponse: Decodable {
    let show: ShowData
    let relatedShows: [RelatedShow]

    private enum CodingKeys: String, CodingKey {
        case show, relatedShows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = try c.decode(ShowData.self, forKey: .show)
        relatedShows = (try? c.decodeIfPresent([RelatedShow].self, forKey: .relatedShows)) ?? []
    }
}

private extension KeyedDecodingContainer {
    func flexString(_ key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func flexInt(_ key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            if let intValue = Int(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return Int(doubleValue.rounded())
            }
        }
        return nil
    }

    func flexDouble(_ key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    func flexBool(_ key: Key) throws -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func flexStringArray(_ key: Key) throws -> [String] {
        if let value = try? decodeIfPresent([String].self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

struct ShowClip: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let videoUrl: String?
    let duration: Double?
    let views: Int
    let type: String           // "short" | "video"
    let publishedAt: String?
}

// ── Search ────────────────────────────────────────────────────────────────────

struct SuggestItem: Codable, Identifiable {
    let id: String
    let type: String        // "channel" | "show" | "video" | "episode"
    let title: String
    let imageUrl: String?
    let meta: String?       // e.g. "S1 · 12 eps" for shows
    let href: String
}

struct SearchResultChannel: Decodable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
    let followerCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, handle, avatarUrl
        case countWrapper = "_count"
    }
    private struct CountWrapper: Codable { let followers: Int }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        handle       = try c.decodeIfPresent(String.self, forKey: .handle)
        avatarUrl    = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        let cw       = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        followerCount = cw?.followers
    }
}

struct SearchResultShow: Codable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
    let genre: String?
    let showType: String?
    let entitlementType: String?
}

struct SearchResultEpisodeSeason: Codable {
    let seasonNumber: Int?
    let show: ShowStub?
}

struct SearchResultEpisode: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let episodeNumber: Int?
    let season: SearchResultEpisodeSeason?
}

struct SearchResultVideo: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int?
    let type: String?
    let channel: ChannelStub?
}

struct SearchResults: Decodable {
    let channels: [SearchResultChannel]?
    let shows: [SearchResultShow]?
    let episodes: [SearchResultEpisode]?
    let videos: [SearchResultVideo]?
}

// ── Like response ─────────────────────────────────────────────────────────────

struct LikeVideoResponse: Codable {
    let likes: Int
    let dislikes: Int
    let userLike: String?   // "like" | "dislike" | null
}

// ── Posts (clip reactions) ────────────────────────────────────────────────────

/// Minimal user stub shared by posts and post comments
struct PostUser: Decodable {
    let id: String
    let name: String?
    let image: String?
}

/// A user-created clip post — markIn..markOut on a video or episode
struct UserPost: Identifiable, Decodable {
    struct MediaVideo: Decodable {
        let id: String
        let title: String?
        let thumbnailUrl: String?
        let videoUrl: String?
    }

    struct MediaEpisode: Decodable {
        struct Season: Decodable {
            let seasonNumber: Int?
            let show: ShowStub?
        }

        let id: String
        let title: String?
        let thumbnailUrl: String?
        let videoUrl: String?
        let episodeNumber: Int?
        let season: Season?
    }

    let id: String
    let userId: String
    let markIn: Int          // seconds
    let markOut: Int         // seconds
    let caption: String?
    let isSpoiler: Bool
    let createdAt: String
    let likeCount: Int       // server: _count.likes mapped to likeCount
    let myLike: Bool
    let user: PostUser?
    let video: MediaVideo?
    let episode: MediaEpisode?

    init(
        id: String,
        userId: String,
        markIn: Int,
        markOut: Int,
        caption: String?,
        isSpoiler: Bool,
        createdAt: String,
        likeCount: Int,
        myLike: Bool,
        user: PostUser?,
        video: MediaVideo? = nil,
        episode: MediaEpisode? = nil
    ) {
        self.id = id
        self.userId = userId
        self.markIn = markIn
        self.markOut = markOut
        self.caption = caption
        self.isSpoiler = isSpoiler
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.myLike = myLike
        self.user = user
        self.video = video
        self.episode = episode
    }
}

/// Toggle-like response for a post
struct PostLikeResponse: Decodable {
    let liked: Bool
    let likeCount: Int
}

/// Comment on a post (supports nested replies)
struct PostComment: Identifiable, Decodable {
    let id: String
    let userId: String
    let content: String
    let likes: Int           // direct integer field on PostComment model
    let parentId: String?
    let createdAt: String
    let user: PostUser?
    let replies: [PostComment]?
}

/// Response from POST /api/posts/[id]/comments/[commentId]/like
struct PostCommentLikeResponse: Decodable {
    let likes: Int
}

// ── Moment likes (heatmap) ─────────────────────────────────────────────────────

/// GET /api/videos/[id]/moment-likes or /api/episodes/[id]/moment-likes
/// buckets: raw like counts per 5-second window (up to 120 entries = 600 s)
/// userLikedSeconds: integer seconds the current user has liked (empty if unauthed)
struct MomentLikesResponse: Decodable {
    let buckets: [Int]
    let userLikedSeconds: [Int]
}

/// Response from POST /api/videos/[id]/moment-likes or /api/episodes/[id]/moment-likes
struct MomentLikeToggleResponse: Decodable {
    let liked: Bool
}

// ── Browse (shows / movies) ───────────────────────────────────────────────────

struct ShowBrowseCard: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let bannerUrl: String?
    let genre: String?
    let entitlementType: String?
    let productionYear: String?
    let language: String?
    let contentRating: String?
    let movieDuration: Double?
    let seasonCount: Int        // unwrapped from _count.seasons
    let showType: String?
    let trailerUrl: String?     // clips[0].videoUrl when ?withClips=1

    private enum CodingKeys: String, CodingKey {
        case id, title, description, coverUrl, bannerUrl, genre, entitlementType, productionYear
        case language, contentRating, showType
        case countWrapper = "_count"
        case clips, seasons
    }
    private struct CountWrapper: Codable { let seasons: Int }
    private struct ClipStub: Decodable { let id: String; let videoUrl: String? }
    private struct SeasonDurationStub: Decodable { let episodes: [EpisodeDurationStub]? }
    private struct EpisodeDurationStub: Decodable { let duration: Double? }

    init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self,           forKey: .id)
        title         = try c.decode(String.self,           forKey: .title)
        description   = try c.decodeIfPresent(String.self,  forKey: .description)
        coverUrl      = try c.decodeIfPresent(String.self,  forKey: .coverUrl)
        bannerUrl     = try c.decodeIfPresent(String.self,  forKey: .bannerUrl)
        genre         = try c.decodeIfPresent(String.self,  forKey: .genre)
        entitlementType = try c.decodeIfPresent(String.self, forKey: .entitlementType)
        productionYear = try c.decodeIfPresent(String.self, forKey: .productionYear)
        language      = try c.decodeIfPresent(String.self,  forKey: .language)
        contentRating = try c.decodeIfPresent(String.self,  forKey: .contentRating)
        showType      = try c.decodeIfPresent(String.self,  forKey: .showType)
        let seasons   = try c.decodeIfPresent([SeasonDurationStub].self, forKey: .seasons)
        movieDuration = seasons?.first?.episodes?.first?.duration
        let cw        = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        seasonCount   = cw?.seasons ?? 0
        let clips     = try c.decodeIfPresent([ClipStub].self, forKey: .clips)
        trailerUrl    = clips?.first?.videoUrl
    }
}

// ── Microdramas ───────────────────────────────────────────────────────────────

struct MicrodramaNetwork: Codable {
    let name: String
}

struct MicrodramaListShow: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let bannerUrl: String?
    let genre: String?
    let network: MicrodramaNetwork?
    let seasonCount: Int      // _count.seasons
    let followerCount: Int    // _count.followers

    private enum CodingKeys: String, CodingKey {
        case id, title, description, coverUrl, bannerUrl, genre, network
        case countWrapper = "_count"
    }
    private struct CountWrapper: Codable { let seasons: Int; let followers: Int }

    init(from decoder: Decoder) throws {
        let c           = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self,           forKey: .id)
        title           = try c.decode(String.self,           forKey: .title)
        description     = try c.decodeIfPresent(String.self,  forKey: .description)
        coverUrl        = try c.decodeIfPresent(String.self,  forKey: .coverUrl)
        bannerUrl       = try c.decodeIfPresent(String.self,  forKey: .bannerUrl)
        genre           = try c.decodeIfPresent(String.self,  forKey: .genre)
        network         = try c.decodeIfPresent(MicrodramaNetwork.self, forKey: .network)
        let cw          = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        seasonCount     = cw?.seasons   ?? 0
        followerCount   = cw?.followers ?? 0
    }
}

struct MicrodramaEpisode: Codable, Identifiable {
    let id: String
    let episodeNumber: Int
    let title: String
    let description: String?
    let thumbnailUrl: String?
    let videoUrl: String?      // nil if locked
    let duration: Double?
    let accessState: String    // "free"|"svod"|"ppv"|"ad_unlock"|"locked"
    let adUnlockAvailable: Bool?
}

struct MicrodramaConfig: Codable {
    let freeEpisodeCount: Int
    let adUnlockEnabled: Bool
    let adUnlockStartEpisode: Int
}

struct MicrodramaShowDetail: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let bannerUrl: String?
    let genre: String?
    let language: String?
    let country: String?
    let studio: String?
    let contentRating: String?
    let tags: [String]
    let status: String
    let showType: String
    let network: MicrodramaNetwork?
}

struct MicrodramaEpisodesResponse: Codable {
    let show: MicrodramaShowDetail
    let config: MicrodramaConfig?
    let episodes: [MicrodramaEpisode]
}

struct AdUnlockResponse: Codable {
    let granted: Bool
    let remainingToday: Int
    let error: String?
}

// ── Following feed ────────────────────────────────────────────────────────────

struct FollowingFeedSeason: Codable {
    let seasonNumber: Int
    let show: ShowStub?
}

/// Item from GET /api/subscriptions/feed
/// Videos carry `type` ("video"|"short"); episodes carry `_kind = "episode"`.
struct FollowingFeedItem: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int?
    let type: String?          // "video"|"short"|nil (episodes have no type)
    let publishedAt: String?
    let createdAt: String?
    let channel: ChannelStub?
    let _kind: String?         // "episode" for episode items
    let season: FollowingFeedSeason?
}

// ── Collections ───────────────────────────────────────────────────────────────

struct CollectionCount: Codable {
    let items: Int
    let followers: Int

    init(items: Int, followers: Int) {
        self.items = items
        self.followers = followers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent(Int.self, forKey: .items) ?? 0
        followers = try c.decodeIfPresent(Int.self, forKey: .followers) ?? 0
    }
}

struct CollectionShowPreview: Codable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
}

struct CollectionVideoPreview: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let type: String
}

struct CollectionItemPreview: Codable {
    let show: CollectionShowPreview?
    let video: CollectionVideoPreview?
    // Raw FK fields — present alongside the nested objects in Prisma's `include` response.
    // Used to check "is this video/show already in this collection?" without traversing nested objects.
    let videoId: String?
    let showId: String?
}

struct Collection: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let type: String           // "shows"|"clips"|"shorts"
    let visibility: String     // "private"|"public"
    let createdAt: String
    let updatedAt: String
    let user: CollectionUser?
    let _count: CollectionCount
    let items: [CollectionItemPreview]   // up to 4 for mosaic
    let isFollowing: Bool

    // POST /api/collections returns a bare collection without _count or items.
    // This custom init provides defaults so both GET and POST responses decode cleanly.
    private enum CodingKeys: String, CodingKey {
        case id, title, description, type, visibility, createdAt, updatedAt, user, items, isFollowing
        case _count = "_count"
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self,           forKey: .id)
        title       = try c.decode(String.self,           forKey: .title)
        description = try c.decodeIfPresent(String.self,  forKey: .description)
        type        = try c.decode(String.self,           forKey: .type)
        visibility  = try c.decode(String.self,           forKey: .visibility)
        createdAt   = try c.decode(String.self,           forKey: .createdAt)
        updatedAt   = try c.decode(String.self,           forKey: .updatedAt)
        user        = try c.decodeIfPresent(CollectionUser.self, forKey: .user)
        _count      = (try c.decodeIfPresent(CollectionCount.self,          forKey: ._count)) ?? CollectionCount(items: 0, followers: 0)
        items       = (try c.decodeIfPresent([CollectionItemPreview].self,   forKey: .items))  ?? []
        isFollowing = (try c.decodeIfPresent(Bool.self, forKey: .isFollowing)) ?? false
    }
}

struct CollectionUser: Codable, Identifiable {
    let id: String
    let name: String?
    let image: String?
}

struct CollectionDetailShow: Codable, Identifiable {
    struct Count: Codable { let seasons: Int }
    let id: String
    let title: String
    let coverUrl: String?
    let genre: String?
    let productionYear: String?
    let _count: Count?
}

struct CollectionDetailVideo: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let type: String
    let duration: Double?
    let views: Int?
}

struct CollectionDetailItem: Codable, Identifiable {
    let id: String
    let position: Int
    let show: CollectionDetailShow?
    let video: CollectionDetailVideo?
}

struct CollectionDetail: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let type: String
    let visibility: String
    let updatedAt: String
    let user: CollectionUser?
    let _count: CollectionCount
    let items: [CollectionDetailItem]
    let isFollowing: Bool
    let isOwner: Bool
}

struct CollectionFollowResponse: Codable {
    let following: Bool
}

struct CollectionItemCreateResponse: Codable {
    let id: String
    let position: Int
}

struct CreateCollectionBody: Encodable {
    let title: String
    let description: String?
    let type: String
    let visibility: String
}

// ── Playlists ─────────────────────────────────────────────────────────────────

// Shared helper — decodes { "items": N } from the _count Prisma wrapper.
private struct _PlaylistCount: Decodable { let items: Int }

struct PlaylistThumbVideo: Decodable {
    let thumbnailUrl: String?
}

struct PlaylistThumbItem: Decodable {
    let video: PlaylistThumbVideo?
}

/// Playlist returned by GET /api/playlists (list endpoint).
/// Contains up to 4 thumb items for the mosaic thumbnail.
struct Playlist: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let visibility: String      // "public" | "unlisted" | "private"
    let type: String            // "video" | "short"
    let createdAt: String?
    let itemCount: Int          // from _count.items
    let thumbItems: [PlaylistThumbItem]

    // Programmatic init (used after a successful PATCH to rebuild the row)
    init(id: String, title: String, description: String?, visibility: String,
         type: String, createdAt: String?, itemCount: Int, thumbItems: [PlaylistThumbItem]) {
        self.id = id; self.title = title; self.description = description
        self.visibility = visibility; self.type = type; self.createdAt = createdAt
        self.itemCount = itemCount; self.thumbItems = thumbItems
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, visibility, type, createdAt, items
        case count = "_count"
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self,            forKey: .id)
        title       = try c.decode(String.self,            forKey: .title)
        description = try c.decodeIfPresent(String.self,   forKey: .description)
        visibility  = try c.decodeIfPresent(String.self,   forKey: .visibility) ?? "public"
        type        = try c.decodeIfPresent(String.self,   forKey: .type) ?? "video"
        createdAt   = try c.decodeIfPresent(String.self,   forKey: .createdAt)
        let cnt     = try c.decodeIfPresent(_PlaylistCount.self, forKey: .count)
        itemCount   = cnt?.items ?? 0
        thumbItems  = (try? c.decodeIfPresent([PlaylistThumbItem].self, forKey: .items)) ?? []
    }
}

/// Full video info inside a playlist item (from GET /api/playlists/[id]).
struct PlaylistDetailVideo: Decodable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let type: String?
    let status: String?
    let views: Int?
    let duration: Double?
}

/// One item in a playlist detail response.
struct PlaylistDetailItem: Decodable, Identifiable {
    let id: String
    let position: Int
    let video: PlaylistDetailVideo?
}

/// Full playlist returned by GET /api/playlists/[id] — includes all items with video info.
struct PlaylistDetail: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let visibility: String
    let type: String
    let isOwner: Bool
    let itemCount: Int
    let items: [PlaylistDetailItem]

    enum CodingKeys: String, CodingKey {
        case id, title, description, visibility, type, isOwner, items
        case count = "_count"
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self,            forKey: .id)
        title       = try c.decode(String.self,            forKey: .title)
        description = try c.decodeIfPresent(String.self,   forKey: .description)
        visibility  = try c.decodeIfPresent(String.self,   forKey: .visibility) ?? "public"
        type        = try c.decodeIfPresent(String.self,   forKey: .type) ?? "video"
        isOwner     = try c.decodeIfPresent(Bool.self,     forKey: .isOwner) ?? false
        let cnt     = try c.decodeIfPresent(_PlaylistCount.self, forKey: .count)
        itemCount   = cnt?.items ?? 0
        items       = try c.decodeIfPresent([PlaylistDetailItem].self, forKey: .items) ?? []
    }
}

// ── Watch history ─────────────────────────────────────────────────────────────

struct HistoryChannelStub: Decodable {
    let id: String
    let name: String
    let handle: String?
}

struct HistoryVideoStub: Decodable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int?
    let createdAt: String?
    let type: String?
    let channel: HistoryChannelStub?
}

struct HistoryShowStub: Decodable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
}

struct HistorySeasonStub: Decodable {
    let seasonNumber: Int
    let show: HistoryShowStub?
}

struct HistoryEpisodeStub: Decodable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?
    let views: Int?
    let createdAt: String?
    let episodeNumber: Int
    let season: HistorySeasonStub?
}

struct HistoryItem: Identifiable, Decodable {
    let id: String
    let watchedAt: String
    let seconds: Double?
    let percent: Double?
    let videoId: String?
    let episodeId: String?
    let video: HistoryVideoStub?
    let episode: HistoryEpisodeStub?
}

// ── Notifications ─────────────────────────────────────────────────────────────

struct AppNotification: Codable, Identifiable {
    let id: String
    let type: String        // "info" | etc.
    let title: String
    let message: String
    let linkUrl: String?
    let imageUrl: String?
    let read: Bool
    let createdAt: String
    let contextType: String?
    let contextId: String?
}

struct SwitchContextBody: Encodable {
    let id: String
    let type: String
    let name: String
    let channelId: String?
}

struct SwitchContextResponse: Codable {
    let ok: Bool
    let context: ActiveContext?
}
