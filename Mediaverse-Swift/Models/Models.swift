import Foundation

private let movieShowTypes: Set<String> = ["movie", "special", "documentary"]

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
    let showType: String?

    var isMovie: Bool {
        movieShowTypes.contains(showType?.lowercased() ?? "")
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, image, avatarUrl, avatar_url, imageUrl, image_url, profileImage, profile_image
    }

    init(id: String, name: String?, image: String?) {
        self.id = id
        self.name = name
        self.image = image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        image = try c.decodeFirstPresentString(forKeys: [
            .image,
            .avatarUrl,
            .avatar_url,
            .imageUrl,
            .image_url,
            .profileImage,
            .profile_image
        ])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(image, forKey: .image)
    }
}

struct Comment: Codable, Identifiable {
    let id: String
    let content: String?      // nil when isRemoved == true
    let contentHtml: String?
    let isRemoved: Bool?
    let deletedAt: String?
    let removedAt: String?
    let likes: Int?
    let createdAt: String
    let parentId: String?
    let user: CommentUser?
    let actorChannel: ChannelStub?
    let actorShow: ShowStub?
    let replies: [Comment]?
    let replyCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, content, contentHtml, isRemoved, deletedAt, removedAt, likes, createdAt, parentId, user
        case actorChannel, actor_channel, actorShow, actor_show, replies
        case count = "_count"
    }

    private struct CountWrapper: Decodable {
        let replies: Int?
    }

    init(
        id: String,
        content: String?,
        contentHtml: String? = nil,
        isRemoved: Bool?,
        deletedAt: String? = nil,
        removedAt: String? = nil,
        likes: Int?,
        createdAt: String,
        parentId: String?,
        user: CommentUser?,
        actorChannel: ChannelStub? = nil,
        actorShow: ShowStub? = nil,
        replies: [Comment]?,
        replyCount: Int?
    ) {
        self.id = id
        self.content = content
        self.contentHtml = contentHtml
        self.isRemoved = isRemoved
        self.deletedAt = deletedAt
        self.removedAt = removedAt
        self.likes = likes
        self.createdAt = createdAt
        self.parentId = parentId
        self.user = user
        self.actorChannel = actorChannel
        self.actorShow = actorShow
        self.replies = replies
        self.replyCount = replyCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        contentHtml = try c.decodeIfPresent(String.self, forKey: .contentHtml)
        isRemoved = try c.decodeIfPresent(Bool.self, forKey: .isRemoved)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        removedAt = try c.decodeIfPresent(String.self, forKey: .removedAt)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        user = try c.decodeIfPresent(CommentUser.self, forKey: .user)
        actorChannel = try c.decodeIfPresent(ChannelStub.self, forKey: .actorChannel)
            ?? c.decodeIfPresent(ChannelStub.self, forKey: .actor_channel)
        actorShow = try c.decodeIfPresent(ShowStub.self, forKey: .actorShow)
            ?? c.decodeIfPresent(ShowStub.self, forKey: .actor_show)
        replies = try c.decodeIfPresent([Comment].self, forKey: .replies)
        replyCount = try c.decodeIfPresent(CountWrapper.self, forKey: .count)?.replies
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(contentHtml, forKey: .contentHtml)
        try c.encodeIfPresent(isRemoved, forKey: .isRemoved)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(removedAt, forKey: .removedAt)
        try c.encodeIfPresent(likes, forKey: .likes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(actorChannel, forKey: .actorChannel)
        try c.encodeIfPresent(actorShow, forKey: .actorShow)
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
    let aspectRatio: Double?
    let width: Int?
    let height: Int?
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

enum AnyJSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyJSON].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }
}

struct CurationPageResponse: Decodable {
    let ok: Bool
    let pageKey: String
    let data: AssembledPage
}

struct AssembledPage: Decodable {
    let pageKey: String
    let rankMode: String
    let listings: [AssembledListing]
    let sections: [PageSection]
}

struct AssembledListing: Decodable, Identifiable {
    let listingId: String
    let listingTitle: String?
    let badge: String?
    let seeAllUrl: String?
    let accentColor: String?
    let sponsoredBy: String?
    let templateType: String
    let contentTypeHint: String?
    let infiniteLoad: Bool
    let items: [ContentItem]
    let feedSlots: [AssembledListing]?
    let feedConfig: FeedConfig?

    private enum CodingKeys: String, CodingKey {
        case listingId
        case listingTitle
        case badge
        case seeAllUrl
        case accentColor
        case sponsoredBy
        case templateType
        case contentTypeHint
        case infiniteLoad
        case items
        case feedSlots
        case feedConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listingId = try container.decode(String.self, forKey: .listingId)
        listingTitle = try container.decodeIfPresent(String.self, forKey: .listingTitle)
        badge = try container.decodeIfPresent(String.self, forKey: .badge)
        seeAllUrl = try container.decodeIfPresent(String.self, forKey: .seeAllUrl)
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        sponsoredBy = try container.decodeIfPresent(String.self, forKey: .sponsoredBy)
        templateType = try container.decode(String.self, forKey: .templateType)
        contentTypeHint = try container.decodeIfPresent(String.self, forKey: .contentTypeHint)
        infiniteLoad = try container.decodeIfPresent(Bool.self, forKey: .infiniteLoad) ?? false
        items = try container.decodeIfPresent([ContentItem].self, forKey: .items) ?? []
        feedSlots = try container.decodeIfPresent([AssembledListing].self, forKey: .feedSlots)
        feedConfig = try container.decodeIfPresent(FeedConfig.self, forKey: .feedConfig)
    }

    var id: String { listingId }
}

extension AssembledListing {
    var normalizedTemplateType: String {
        templateType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct FeedConfig: Decodable {
    let mobileEvery: Int
    let mobileCount: Int

    private enum CodingKeys: String, CodingKey {
        case mobileEvery
        case mobileCount
    }

    init(mobileEvery: Int = 5, mobileCount: Int = 3) {
        self.mobileEvery = mobileEvery
        self.mobileCount = mobileCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mobileEvery = try container.decodeIfPresent(Int.self, forKey: .mobileEvery) ?? 5
        mobileCount = try container.decodeIfPresent(Int.self, forKey: .mobileCount) ?? 3
    }
}

struct PageSection: Decodable, Identifiable {
    let id: String
    let name: String
    let order: Int
    let type: String
    let assembled: [AssembledListing]?
}

extension AssembledPage {
    var hasCurationSurface: Bool {
        !listings.isEmpty || sections.contains { $0.assembled?.isEmpty == false }
    }

    var sortedSections: [PageSection] {
        sections.sorted { $0.order < $1.order }
    }

    var activeListings: [AssembledListing] {
        if !listings.isEmpty { return listings }
        return sortedSections
            .flatMap { $0.assembled ?? [] }
    }

    func listings(forSectionID sectionID: String?) -> [AssembledListing] {
        if let sectionID,
           let listings = sections.first(where: { $0.id == sectionID || $0.name == sectionID })?.assembled {
            return listings
        }
        if let listings = sortedSections.first?.assembled {
            return listings
        }
        return listings
    }

    var curationItems: [ContentItem] {
        let listingItems = listings.flatMap(\.items)
        let sectionItems = sections
            .compactMap(\.assembled)
            .flatMap { $0 }
            .flatMap(\.items)
        return listingItems + sectionItems
    }
}

struct ContentItem: Decodable, Identifiable {
    let entityType: String
    let entityId: String
    let title: String
    let thumbnailUrl: String?
    let coverUrl: String?
    let meta: [String: AnyJSON]?

    var id: String { "\(entityType)-\(entityId)" }

    func metaString(_ key: String) -> String? { meta?[key]?.stringValue }
    func metaInt(_ key: String) -> Int? { meta?[key]?.intValue }
    func metaDouble(_ key: String) -> Double? { meta?[key]?.doubleValue }
    func metaBool(_ key: String) -> Bool? { meta?[key]?.boolValue }
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
    let adPolicy: EffectiveAdPolicy?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, videoUrl, thumbnailUrl, views, likes, duration
        case channelId, showId, channel, linkedClipId, linkedEpisodeId, linkedClip, linkedEpisode, adPolicy
    }

    init(
        id: String,
        title: String,
        description: String?,
        videoUrl: String?,
        thumbnailUrl: String?,
        views: Int,
        likes: Int,
        duration: Double?,
        channelId: String?,
        showId: String?,
        channel: ChannelStub?,
        linkedClipId: String?,
        linkedEpisodeId: String?,
        linkedClip: ShortLinkedClip?,
        linkedEpisode: ShortLinkedEpisode?,
        adPolicy: EffectiveAdPolicy? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.videoUrl = videoUrl
        self.thumbnailUrl = thumbnailUrl
        self.views = views
        self.likes = likes
        self.duration = duration
        self.channelId = channelId
        self.showId = showId
        self.channel = channel
        self.linkedClipId = linkedClipId
        self.linkedEpisodeId = linkedEpisodeId
        self.linkedClip = linkedClip
        self.linkedEpisode = linkedEpisode
        self.adPolicy = adPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        views = try container.decodeIfPresent(Int.self, forKey: .views) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId)
        showId = try container.decodeIfPresent(String.self, forKey: .showId)
        channel = try container.decodeIfPresent(ChannelStub.self, forKey: .channel)
        linkedClipId = try container.decodeIfPresent(String.self, forKey: .linkedClipId)
        linkedEpisodeId = try container.decodeIfPresent(String.self, forKey: .linkedEpisodeId)
        linkedClip = try container.decodeIfPresent(ShortLinkedClip.self, forKey: .linkedClip)
        linkedEpisode = try container.decodeIfPresent(ShortLinkedEpisode.self, forKey: .linkedEpisode)
        adPolicy = try container.decodeIfPresent(EffectiveAdPolicy.self, forKey: .adPolicy)
    }
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
    let adPolicy: EffectiveAdPolicy?
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
    let showType: String?
    let genre: String?
    let language: String?
    let contentRating: String?
    let seasons: [EpisodeSeason]?

    var isMovie: Bool {
        movieShowTypes.contains(showType?.lowercased() ?? "")
    }
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
    let comingSoon: Bool?
    let likes: [LikeRecord]    // all Like rows for this episode (userId + type)
    let comments: [Comment]
    let season: EpisodeSeason
    let prevEp: EpisodeNavItem?
    let nextEp: EpisodeNavItem?
    let isFollowing: Bool
    let followerCount: Int
    let paywallInfo: PaywallInfo?
    let rentalInfo: RentalInfo?
    let adPolicy: EffectiveAdPolicy?
}

struct EffectiveAdPolicy: Codable {
    let adsEnabled: Bool
    let reason: String?
    let deliveryMode: String?
    let deliveryByDevice: [String: String]?
    let adLoad: Int?
    let cadenceKind: String?
    let cadenceValue: Int?
    let frequencySec: Int?
    let firstAfter: Int?
    let skippable: Bool?
    let skipAfterSec: Int?
    let minGapSec: Int?
    let maxDurationSec: Int?
    let maxAdDurationSec: Int?
    let pods: AdPolicyPods?
    let adRemoval: AdRemovalOffer?

    static func disabled(reason: String? = nil) -> EffectiveAdPolicy {
        EffectiveAdPolicy(
            adsEnabled: false,
            reason: reason,
            deliveryMode: nil,
            deliveryByDevice: nil,
            adLoad: nil,
            cadenceKind: nil,
            cadenceValue: nil,
            frequencySec: nil,
            firstAfter: nil,
            skippable: nil,
            skipAfterSec: nil,
            minGapSec: nil,
            maxDurationSec: nil,
            maxAdDurationSec: nil,
            pods: nil,
            adRemoval: nil
        )
    }

    func applying(to base: PlatformShortsAdsConfig) -> PlatformShortsAdsConfig {
        PlatformShortsAdsConfig(
            enabled: base.enabled && adsEnabled,
            cadenceKind: cadenceKind ?? base.cadenceKind,
            cadenceValue: cadenceValue ?? frequencySec ?? base.cadenceValue,
            firstAfter: firstAfter ?? base.firstAfter,
            skippable: skippable ?? base.skippable,
            skipAfterSec: skipAfterSec ?? base.skipAfterSec,
            maxAds: adLoad ?? base.maxAds,
            maxDurationSec: maxDurationSec ?? maxAdDurationSec ?? pods?.maxAdDurationSec ?? base.maxDurationSec,
            placements: base.placements
        )
    }
}

struct AdPolicyPods: Codable {
    let prerollMaxAds: Int?
    let prerollMaxBreakSec: Int?
    let midrollMaxAds: Int?
    let midrollMaxBreakSec: Int?
    let maxAdDurationSec: Int?
}

struct PaywallInfo: Codable {
    let productId: String
    let productName: String
    let entitlementType: String  // "PPV" | "SVOD"
    let networkId: String?
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

// ── TV-to-phone handoff ───────────────────────────────────────────────────────

struct DeviceHandoffResponse: Codable, Identifiable {
    let publicId: String
    let kind: String?
    let status: String
    let expiresAt: String?
    let destination: DeviceHandoffDestination?
    let checkoutPath: String?

    var id: String { publicId }
}

struct DeviceHandoffDestination: Codable, Hashable {
    let type: String
    let scope: String?
    let networkId: String?
    let networkSlug: String?
    let showId: String?
    let productId: String?
    let intent: String?
}

struct DeviceHandoffActionResponse: Codable {
    let ok: Bool?
    let status: String?
}

struct EntitlementOffers: Codable {
    let canSubscribe: Bool
    let canRent: Bool

    static let empty = EntitlementOffers(canSubscribe: false, canRent: false)
}

struct EntitlementRentProduct: Codable {
    let id: String
    let name: String?
    let price: Double?
    let currency: String?
    let seasonId: String?
    let networkId: String?
}

/// Response from GET /api/entitlement/check
struct EntitlementCheckResponse: Codable {
    let hasAccess: Bool
    let visible: Bool
    let playable: Bool
    /// "NO_MEDIA" | "NOT_YET_AVAILABLE" | "NO_SCHEDULE" | "SCHEDULE_ENDED" | nil
    let code: String?
    let entitlementType: String?   // "AVOD" | "SVOD" | "PPV"
    let productId: String?
    let offeredTypes: [String]
    let offers: EntitlementOffers
    let rentProduct: EntitlementRentProduct?

    private enum CodingKeys: String, CodingKey {
        case hasAccess, allowed, visible, playable, code, reason, entitlementType, type, productId, offeredTypes, offers, rentProduct
    }

    init(
        hasAccess: Bool,
        visible: Bool = true,
        playable: Bool? = nil,
        code: String?,
        entitlementType: String?,
        productId: String?,
        offeredTypes: [String] = [],
        offers: EntitlementOffers = .empty,
        rentProduct: EntitlementRentProduct? = nil
    ) {
        self.hasAccess = hasAccess
        self.visible = visible
        self.playable = playable ?? hasAccess
        self.code = code
        self.entitlementType = entitlementType
        self.productId = productId
        self.offeredTypes = offeredTypes
        self.offers = offers
        self.rentProduct = rentProduct
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedHasAccess = try c.decodeIfPresent(Bool.self, forKey: .hasAccess)
        let decodedAllowed = try c.decodeIfPresent(Bool.self, forKey: .allowed)
        let decodedVisible = try c.decodeIfPresent(Bool.self, forKey: .visible)
        let decodedPlayable = try c.decodeIfPresent(Bool.self, forKey: .playable)
        let decodedCode = try c.decodeIfPresent(String.self, forKey: .code)
        let decodedReason = try c.decodeIfPresent(String.self, forKey: .reason)
        let decodedEntitlementType = try c.decodeIfPresent(String.self, forKey: .entitlementType)
        let decodedType = try c.decodeIfPresent(String.self, forKey: .type)

        playable = decodedPlayable ?? decodedHasAccess ?? decodedAllowed ?? false
        hasAccess = decodedHasAccess ?? decodedAllowed ?? playable
        visible = decodedVisible ?? true
        code = decodedCode ?? decodedReason
        entitlementType = decodedEntitlementType ?? decodedType
        productId = try c.decodeIfPresent(String.self, forKey: .productId)
        offeredTypes = (try? c.decodeIfPresent([String].self, forKey: .offeredTypes)) ?? []
        offers = (try? c.decodeIfPresent(EntitlementOffers.self, forKey: .offers)) ?? .empty
        rentProduct = try c.decodeIfPresent(EntitlementRentProduct.self, forKey: .rentProduct)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hasAccess, forKey: .hasAccess)
        try c.encode(visible, forKey: .visible)
        try c.encode(playable, forKey: .playable)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(entitlementType, forKey: .entitlementType)
        try c.encodeIfPresent(productId, forKey: .productId)
        try c.encode(offeredTypes, forKey: .offeredTypes)
        try c.encode(offers, forKey: .offers)
        try c.encodeIfPresent(rentProduct, forKey: .rentProduct)
    }
}

/// Response from POST /api/checkout/ppv or /api/checkout/svod
struct CheckoutResponse: Codable {
    let success: Bool
    let orderId: String?
    let networkSubscriptionId: String?
    let clientSecret: String?  // for real payment provider
    let redirectUrl: String?
}

struct UserSubscriptionsResponse: Decodable {
    let subscriptions: [UserSubscription]
}

struct UserSubscription: Decodable, Identifiable {
    struct Network: Decodable {
        let id: String?
        let name: String?
        let logoUrl: String?
    }

    struct Product: Decodable {
        struct PricingTier: Decodable {
            let currency: String?
            let localizedPrices: [String: String]?
        }

        let id: String?
        let name: String?
        let pricingTier: PricingTier?
    }

    let id: String
    let status: String
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let cancelledAt: String?
    let network: Network?
    let product: Product?
}

struct UserRentalsResponse: Decodable {
    let rentals: [UserRental]
}

struct UserRental: Decodable, Identifiable {
    struct Terms: Decodable {
        let entitlementDurationSecs: Int?
        let playbackWindowSecs: Int?
        let maxPlays: Int?
    }

    /// The show/movie a rental belongs to. Present nested under season.show and
    /// episode.season.show in the /api/me/rentals payload.
    struct ShowRef: Decodable {
        let id: String?
        let title: String?
        let coverUrl: String?
    }

    /// episode.season carries the show — needed because a movie's episode title is a
    /// generic "Feature", so the row must fall back to the show/movie title.
    struct NestedSeason: Decodable {
        let seasonNumber: Int?
        let show: ShowRef?
    }

    struct RentalContext: Decodable {
        let id: String?
        let title: String?
        let name: String?
        let thumbnailUrl: String?
        let coverUrl: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let show: ShowRef?          // populated on `season`
        let season: NestedSeason?   // populated on `episode` (carries the show)
    }

    let id: String
    let status: String?
    let validTo: String?
    let firstPlayedAt: String?
    let playbackExpiresAt: String?
    let playsUsed: Int?
    let terms: Terms?
    let season: RentalContext?
    let episode: RentalContext?
    let product: RentalContext?

    /// The show/movie this rental unlocks — season-scoped rentals resolve via season.show,
    /// episode-scoped via episode.season.show. Drives both the row title and its link.
    var resolvedShow: ShowRef? {
        season?.show ?? episode?.season?.show
    }
    var resolvedShowId: String? { resolvedShow?.id }
}

struct VideoPlaylistResponse: Decodable {
    let playlist: VideoPlaylist?
}

struct VideoPlaylist: Decodable, Identifiable {
    let id: String
    let title: String
    let items: [VideoPlaylistItem]
}

struct VideoPlaylistItem: Decodable, Identifiable {
    let id: String
    let position: Int?
    let title: String
    let description: String?
    let videoUrl: String?
    let thumbnailUrl: String?
    let thumbnailFocus: String?
    let duration: Double?
    let views: Int?
    let likes: Int?
    let channelId: String?
    let showId: String?
    let channel: ChannelStub?
    let linkedClipId: String?
    let linkedEpisodeId: String?
    let linkedClip: ShortLinkedClip?
    let linkedEpisode: ShortLinkedEpisode?
}

// ── Active context ────────────────────────────────────────────────────────────

/// Mirrors ActiveContext in active-context.ts
struct ActiveContext: Codable, Identifiable {
    var id: String
    let type: String          // "admin" | "network" | "channel" | "show" | "user"
    let name: String
    var channelId: String? = nil
    var showId: String? = nil
    var networkId: String? = nil
    var networkName: String? = nil
    var damEnabled: Bool? = nil
    var canCreateShows: Bool? = nil
    var canPublishMicrodramas: Bool? = nil
    var avatarUrl: String? = nil
    var image: String? = nil
    var bannerUrl: String? = nil
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
    var avatarUrl: String? = nil
    var channelId: String? = nil
    var showId: String? = nil
    var networkId: String? = nil
    var networkName: String? = nil
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

struct PartnerApplicationStatus: Decodable, Equatable {
    let status: String
    let message: String?
    let notes: String?
    let submittedAt: String?
    let reviewedAt: String?

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let none = PartnerApplicationStatus(
        status: "none",
        message: nil,
        notes: nil,
        submittedAt: nil,
        reviewedAt: nil
    )
}

struct ProfileChannel: Codable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let followerCount: Int?
}

struct BackstageChannelSettings: Codable, Identifiable {
    let id: String
    let name: String
    let handle: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let channelType: String?
    let status: String?
}

struct DevicePairingCodeResponse: Codable {
    let userCode: String
    let deviceCode: String
    let activationUrl: String?
    let qrCodeUrl: String?
    let expiresIn: Int
    let pollInterval: Int
}

struct DevicePairingPollResponse: Codable {
    let status: String
    let token: String?
    let userId: String?
}

struct DevicePairingActivationResponse: Codable {
    let ok: Bool?
    let deviceName: String?
}

struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String
    let deviceName: String
    let deviceType: String
    let lastSeenAt: String?
    let createdAt: String
}

struct PairedDevicesResponse: Codable {
    let devices: [PairedDevice]
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
        let videoUrl: String?
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
    let offeredTypes: [String]
    let schedule: ShowEpisodeSchedule?

    private enum CodingKeys: String, CodingKey {
        case id, episodeNumber, title, description, thumbnailUrl, videoUrl, duration
        case airDate, status, comingSoon, playable, offeredTypes, schedule
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
        offeredTypes = try c.flexStringArray(.offeredTypes)
        schedule = try c.decodeIfPresent(ShowEpisodeSchedule.self, forKey: .schedule)
    }

    struct ShowEpisodeSchedule: Decodable {
        struct Window: Decodable {
            let scope: String
            let premiereAt: String?
            let finaleAt: String?
            let blackout: Bool
            let entitlementType: String?
            let productId: String?

            private enum CodingKeys: String, CodingKey {
                case scope, premiereAt, finaleAt, blackout, entitlementType, productId
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                scope = try c.flexString(.scope) ?? "worldwide"
                premiereAt = try c.flexString(.premiereAt)
                finaleAt = try c.flexString(.finaleAt)
                blackout = try c.flexBool(.blackout) ?? false
                entitlementType = try c.flexString(.entitlementType)
                productId = try c.flexString(.productId)
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
    let offeredTypes: [String]
    let episodes: [ShowEpisodeItem]

    private enum CodingKeys: String, CodingKey {
        case id, seasonNumber, title, description, coverUrl, airDate, endDate, status, comingSoon, offeredTypes, episodes
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
        offeredTypes = try c.flexStringArray(.offeredTypes)
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

    var isMovie: Bool {
        movieShowTypes.contains(showType.lowercased())
    }

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

    var isMovie: Bool {
        movieShowTypes.contains(showType.lowercased())
    }

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
    func decodeFirstPresentString(forKeys keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try flexString(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

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
    let type: String        // "channel" | "show" | "video" | "short" | "episode"
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
    let avatarFocus: String?
    let verified: Bool?
    let followerCount: Int?
    let videoCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, handle, avatarUrl, avatarFocus, verified
        case countWrapper = "_count"
    }
    private struct CountWrapper: Codable {
        let followers: Int?
        let videos: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        handle       = try c.decodeIfPresent(String.self, forKey: .handle)
        avatarUrl    = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        avatarFocus  = try c.decodeIfPresent(String.self, forKey: .avatarFocus)
        verified     = try c.decodeIfPresent(Bool.self, forKey: .verified)
        let cw       = try c.decodeIfPresent(CountWrapper.self, forKey: .countWrapper)
        followerCount = cw?.followers
        videoCount = cw?.videos
    }
}

struct SearchResultShow: Codable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
    let coverFocus: String?
    let genre: String?
    let showType: String?
    let entitlementType: String?
    let contentRating: String?
    let productionYear: String?
    let count: CountWrapper?

    private enum CodingKeys: String, CodingKey {
        case id, title, coverUrl, coverFocus, genre, showType, entitlementType, contentRating, productionYear
        case count = "_count"
    }

    struct CountWrapper: Codable {
        let seasons: Int?
    }

    var isMovie: Bool {
        movieShowTypes.contains(showType?.lowercased() ?? "")
    }

    var seasonCount: Int? {
        count?.seasons
    }
}

struct SearchResultEpisodeSeason: Codable {
    let seasonNumber: Int?
    let show: ShowStub?
}

struct SearchResultEpisode: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let thumbnailFocus: String?
    let episodeNumber: Int?
    let duration: Double?
    let views: Int?
    let season: SearchResultEpisodeSeason?
}

struct SearchResultVideo: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnailUrl: String?
    let thumbnailFocus: String?
    let duration: Double?
    let views: Int?
    let type: String?
    let channel: ChannelStub?
}

struct SearchResultPerson: Decodable, Identifiable {
    let id: String
    let name: String?
    let handle: String?
    let image: String?
    let bio: String?
}

struct SearchResultVibe: Decodable, Identifiable {
    let id: String
    let slug: String
    let name: String
    let description: String?
    let avatarUrl: String?
    let followerCount: Int?
    let postCount: Int?
}

struct SearchResultRippleAuthor: Decodable {
    let name: String?
    let handle: String?
    let image: String?
}

struct SearchResultRippleClub: Decodable {
    let name: String
    let slug: String
}

struct SearchResultRipple: Decodable, Identifiable {
    let id: String
    let body: String?
    let energyCount: Int?
    let commentCount: Int?
    let author: SearchResultRippleAuthor
    let club: SearchResultRippleClub
    let href: String?
    let imageUrl: String?
}

struct SearchResultCollectionOwner: Decodable {
    let name: String?
    let handle: String?
    let image: String?
}

struct SearchResultCollection: Decodable, Identifiable {
    struct Count: Decodable {
        let items: Int?
        let followers: Int?
    }

    let id: String
    let title: String
    let description: String?
    let type: String?
    let user: SearchResultCollectionOwner?
    let count: Count?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, type, user
        case count = "_count"
    }
}

struct SearchResults: Decodable {
    let channels: [SearchResultChannel]?
    let shows: [SearchResultShow]?
    let episodes: [SearchResultEpisode]?
    let videos: [SearchResultVideo]?
    let people: [SearchResultPerson]?
    let vibes: [SearchResultVibe]?
    let ripples: [SearchResultRipple]?
    let collections: [SearchResultCollection]?

    init(
        channels: [SearchResultChannel]? = nil,
        shows: [SearchResultShow]? = nil,
        episodes: [SearchResultEpisode]? = nil,
        videos: [SearchResultVideo]? = nil,
        people: [SearchResultPerson]? = nil,
        vibes: [SearchResultVibe]? = nil,
        ripples: [SearchResultRipple]? = nil,
        collections: [SearchResultCollection]? = nil
    ) {
        self.channels = channels
        self.shows = shows
        self.episodes = episodes
        self.videos = videos
        self.people = people
        self.vibes = vibes
        self.ripples = ripples
        self.collections = collections
    }

    var isEmpty: Bool {
        (channels?.isEmpty ?? true)
            && (shows?.isEmpty ?? true)
            && (episodes?.isEmpty ?? true)
            && (videos?.isEmpty ?? true)
            && (people?.isEmpty ?? true)
            && (vibes?.isEmpty ?? true)
            && (ripples?.isEmpty ?? true)
            && (collections?.isEmpty ?? true)
    }

    var totalCount: Int {
        (channels?.count ?? 0)
            + (shows?.count ?? 0)
            + (episodes?.count ?? 0)
            + (videos?.count ?? 0)
            + (people?.count ?? 0)
            + (vibes?.count ?? 0)
            + (ripples?.count ?? 0)
            + (collections?.count ?? 0)
    }
}

// ── Like response ─────────────────────────────────────────────────────────────

struct LikeVideoResponse: Codable {
    let likes: Int
    let dislikes: Int
    let userLike: String?   // "like" | "dislike" | null
}

struct ContentEnergySelection: Decodable {
    let overall: Int
    let tags: [String]
    let review: String?
}

struct ContentEnergyAggregate: Decodable {
    let avg: Double?
    let count: Int
    let distribution: [String: Int]?
    let topTags: [String]

    private enum CodingKeys: String, CodingKey {
        case avg, count, distribution, topTags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        avg = try values.decodeIfPresent(Double.self, forKey: .avg)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        distribution = try values.decodeIfPresent([String: Int].self, forKey: .distribution)
        if let strings = try? values.decode([String].self, forKey: .topTags) {
            topTags = strings
        } else if let keywords = try? values.decode([ContentEnergyKeyword].self, forKey: .topTags) {
            topTags = keywords.map(\.tag)
        } else if let counts = try? values.decode([String: Int].self, forKey: .topTags) {
            topTags = counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
        } else {
            topTags = []
        }
    }
}

private struct ContentEnergyKeyword: Decodable {
    let tag: String
    let count: Int?
}

struct ContentEnergyResponse: Decodable {
    let userRating: ContentEnergySelection?
    let aggregate: ContentEnergyAggregate
}

// ── Posts (clip reactions) ────────────────────────────────────────────────────

/// Minimal user stub shared by posts and post comments
struct PostUser: Decodable {
    let id: String
    let name: String?
    let image: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, image, avatarUrl, avatar_url, imageUrl, image_url, profileImage, profile_image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        image = try c.decodeFirstPresentString(forKeys: [
            .image,
            .avatarUrl,
            .avatar_url,
            .imageUrl,
            .image_url,
            .profileImage,
            .profile_image
        ])
    }
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
    let captionHtml: String?
    let thumbnailUrl: String?
    let isSpoiler: Bool
    let createdAt: String
    let likeCount: Int       // server: _count.likes mapped to likeCount
    let commentCount: Int?   // server: _count.comments when included
    let myLike: Bool
    let user: PostUser?
    let video: MediaVideo?
    let episode: MediaEpisode?

    private enum CodingKeys: String, CodingKey {
        case id, userId, markIn, markOut, caption, captionHtml, thumbnailUrl, isSpoiler, createdAt, likeCount, commentCount, myLike, user, video, episode
        case count = "_count"
    }

    private struct CountWrapper: Decodable {
        let likes: Int?
        let comments: Int?
    }

    init(
        id: String,
        userId: String,
        markIn: Int,
        markOut: Int,
        caption: String?,
        captionHtml: String? = nil,
        thumbnailUrl: String? = nil,
        isSpoiler: Bool,
        createdAt: String,
        likeCount: Int,
        commentCount: Int? = nil,
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
        self.captionHtml = captionHtml
        self.thumbnailUrl = thumbnailUrl
        self.isSpoiler = isSpoiler
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.myLike = myLike
        self.user = user
        self.video = video
        self.episode = episode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        markIn = try c.decode(Int.self, forKey: .markIn)
        markOut = try c.decode(Int.self, forKey: .markOut)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        captionHtml = try c.decodeIfPresent(String.self, forKey: .captionHtml)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        isSpoiler = try c.decode(Bool.self, forKey: .isSpoiler)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        let count = try c.decodeIfPresent(CountWrapper.self, forKey: .count)
        let decodedLikeCount = try c.decodeIfPresent(Int.self, forKey: .likeCount)
        let decodedCommentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount)
        likeCount = count?.likes ?? decodedLikeCount ?? 0
        commentCount = count?.comments ?? decodedCommentCount
        myLike = try c.decodeIfPresent(Bool.self, forKey: .myLike) ?? false
        user = try c.decodeIfPresent(PostUser.self, forKey: .user)
        video = try c.decodeIfPresent(MediaVideo.self, forKey: .video)
        episode = try c.decodeIfPresent(MediaEpisode.self, forKey: .episode)
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
    let contentHtml: String?
    let likes: Int           // direct integer field on PostComment model
    let parentId: String?
    let createdAt: String
    let user: PostUser?
    let replies: [PostComment]?

    init(
        id: String,
        userId: String,
        content: String,
        contentHtml: String? = nil,
        likes: Int,
        parentId: String?,
        createdAt: String,
        user: PostUser?,
        replies: [PostComment]?
    ) {
        self.id = id
        self.userId = userId
        self.content = content
        self.contentHtml = contentHtml
        self.likes = likes
        self.parentId = parentId
        self.createdAt = createdAt
        self.user = user
        self.replies = replies
    }
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

    var isMovie: Bool {
        movieShowTypes.contains(showType?.lowercased() ?? "")
    }

    init(
        id: String,
        title: String,
        description: String?,
        coverUrl: String?,
        bannerUrl: String?,
        genre: String?,
        entitlementType: String?,
        productionYear: String?,
        language: String?,
        contentRating: String?,
        movieDuration: Double?,
        seasonCount: Int,
        showType: String?,
        trailerUrl: String?
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.coverUrl = coverUrl
        self.bannerUrl = bannerUrl
        self.genre = genre
        self.entitlementType = entitlementType
        self.productionYear = productionYear
        self.language = language
        self.contentRating = contentRating
        self.movieDuration = movieDuration
        self.seasonCount = seasonCount
        self.showType = showType
        self.trailerUrl = trailerUrl
    }

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

extension ContentItem {
    var curationDisplayTitle: String {
        let display = metaString("displayTitle") ?? metaString("displayName") ?? metaString("name")
        if let display = display?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        return title
    }

    var trailerURL: URL? {
        C.mediaURL(metaString("trailerUrl") ?? metaString("trailerURL") ?? metaString("previewUrl"))
    }

    var appRoute: AppRoute {
        if let href = metaString("href"),
           let route = AppRoute.route(link: href) {
            return route
        }

        let normalizedEntityType = entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedContentType = (metaString("showType") ?? metaString("type") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isExplicitMicrodrama = normalizedEntityType == "microdrama"
            || normalizedEntityType == "microdramas"
            || normalizedEntityType == "micro-drama"
            || normalizedEntityType == "micro-dramas"
        let isMicrodramaShow = normalizedEntityType == "show"
            && (normalizedContentType.contains("microdrama") || normalizedContentType.contains("micro-drama"))

        if isExplicitMicrodrama || isMicrodramaShow {
            return .microdramaShow(entityId)
        }

        switch normalizedEntityType {
        case "show":
            return .show(entityId)
        case "season":
            return .showSeason(showId: metaString("showId") ?? entityId, seasonId: entityId)
        case "short":
            return .short(entityId, showId: metaString("showId"), channelId: metaString("channelId"))
        case "episode":
            return .episode(entityId)
        case "channel":
            return .channel(metaString("channelHandle") ?? metaString("handle") ?? entityId)
        case "ripple":
            return .ripple(entityId)
        case "person":
            return .atmo(metaString("handle") ?? entityId)
        case "vibe":
            return .vibe(metaString("slug") ?? entityId)
        case "topic":
            return .search(metaString("value") ?? title)
        default:
            return .media(id: entityId, type: metaString("type") ?? entityType, showId: metaString("showId"), channelId: metaString("channelId"))
        }
    }

    var asFeedVideo: FeedVideo {
        FeedVideo(
            id: entityId,
            title: curationDisplayTitle,
            thumbnailUrl: thumbnailUrl ?? coverUrl,
            videoUrl: metaString("videoUrl"),
            duration: metaDouble("duration"),
            aspectRatio: metaDouble("aspectRatio"),
            width: metaInt("width"),
            height: metaInt("height"),
            views: metaInt("views") ?? 0,
            type: metaString("type") ?? entityType,
            publishedAt: metaString("publishedAt"),
            createdAt: metaString("createdAt") ?? "",
            channel: asChannelStub,
            show: asShowStub
        )
    }

    var asShowBrowseCard: ShowBrowseCard {
        ShowBrowseCard(
            id: entityId,
            title: curationDisplayTitle,
            description: metaString("description"),
            coverUrl: thumbnailUrl ?? coverUrl,
            bannerUrl: coverUrl ?? thumbnailUrl,
            genre: metaString("genre"),
            entitlementType: metaString("entitlementType"),
            productionYear: metaString("productionYear"),
            language: metaString("language"),
            contentRating: metaString("contentRating"),
            movieDuration: metaDouble("duration"),
            seasonCount: metaInt("seasons") ?? 0,
            showType: metaString("showType"),
            trailerUrl: metaString("trailerUrl")
        )
    }

    var asChannelBrowseCard: ChannelBrowseCard {
        let displayName = curationDisplayTitle
        return ChannelBrowseCard(
            id: entityId,
            name: displayName,
            handle: metaString("handle") ?? metaString("channelHandle") ?? entityId,
            description: metaString("description"),
            avatarUrl: thumbnailUrl,
            bannerUrl: coverUrl,
            verified: metaBool("verified") ?? false,
            channelType: metaString("channelType"),
            status: metaString("status"),
            _count: ChannelBrowseCard.Count(followers: metaInt("followers") ?? 0, videos: metaInt("videos") ?? 0)
        )
    }

    var asMicrodramaListShow: MicrodramaListShow {
        MicrodramaListShow(
            id: entityId,
            title: curationDisplayTitle,
            description: metaString("description"),
            coverUrl: thumbnailUrl ?? coverUrl,
            bannerUrl: coverUrl ?? thumbnailUrl,
            genre: metaString("genre"),
            network: nil,
            seasonCount: metaInt("seasons") ?? 0,
            followerCount: metaInt("followers") ?? 0
        )
    }

    var asShort: Short {
        Short(
            id: entityId,
            title: curationDisplayTitle,
            description: metaString("description"),
            videoUrl: metaString("videoUrl"),
            thumbnailUrl: thumbnailUrl ?? coverUrl,
            views: metaInt("views") ?? 0,
            likes: metaInt("likes") ?? 0,
            duration: metaDouble("duration"),
            channelId: metaString("channelId"),
            showId: metaString("showId"),
            channel: asChannelStub,
            linkedClipId: nil,
            linkedEpisodeId: nil,
            linkedClip: nil,
            linkedEpisode: nil
        )
    }

    var asChannelStub: ChannelStub? {
        guard let channelName = metaString("channelName") else { return nil }
        return ChannelStub(
            id: metaString("channelId") ?? metaString("channelHandle") ?? channelName,
            name: channelName,
            handle: metaString("channelHandle"),
            avatarUrl: metaString("channelAvatarUrl")
        )
    }

    var asShowStub: ShowStub? {
        guard let showTitle = metaString("showTitle") else { return nil }
        return ShowStub(
            id: metaString("showId") ?? entityId,
            title: showTitle,
            coverUrl: coverUrl ?? thumbnailUrl,
            showType: metaString("showType")
        )
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

    init(
        id: String,
        title: String,
        description: String?,
        coverUrl: String?,
        bannerUrl: String?,
        genre: String?,
        network: MicrodramaNetwork?,
        seasonCount: Int,
        followerCount: Int
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.coverUrl = coverUrl
        self.bannerUrl = bannerUrl
        self.genre = genre
        self.network = network
        self.seasonCount = seasonCount
        self.followerCount = followerCount
    }

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
    let accessState: String    // "free"|"svod"|"ppv"|"locked"
    let adUnlockAvailable: Bool?
}

struct MicrodramaConfig: Codable {
    let freeEpisodeCount: Int
    let adUnlockEnabled: Bool
    let adUnlockStartEpisode: Int
    let adUnlockDailyLimit: Int

    private enum CodingKeys: String, CodingKey {
        case freeEpisodeCount, adUnlockEnabled, adUnlockStartEpisode, adUnlockDailyLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        freeEpisodeCount = try container.decodeIfPresent(Int.self, forKey: .freeEpisodeCount) ?? 0
        adUnlockEnabled = try container.decodeIfPresent(Bool.self, forKey: .adUnlockEnabled) ?? false
        adUnlockStartEpisode = try container.decodeIfPresent(Int.self, forKey: .adUnlockStartEpisode) ?? 1
        adUnlockDailyLimit = try container.decodeIfPresent(Int.self, forKey: .adUnlockDailyLimit) ?? 0
    }
}

struct MicrodramaOffers: Codable {
    let canSubscribe: Bool
    let canRent: Bool
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

    var isMovie: Bool {
        movieShowTypes.contains(showType.lowercased())
    }
}

struct MicrodramaEpisodesResponse: Codable {
    let show: MicrodramaShowDetail
    let config: MicrodramaConfig?
    let episodes: [MicrodramaEpisode]
    let offers: MicrodramaOffers?
    let remainingAdUnlocks: Int?
    let dailyCap: Int?
    let adUnlockPlacement: String?
    let adUnlockPolicy: MicrodramaAdUnlockPolicy?
}

struct MicrodramaAdUnlockPolicy: Codable {
    let placement: String?
    let maxAdDurationSec: Int?
    let skippable: Bool?
    let skipAfterSec: Int?
}

struct MicrodramaAdUnlockGrant: Codable {
    let granted: Bool
    let remainingToday: Int?
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
    let contentType: String?
    let videoId: String?
    let shortId: String?
    let episodeId: String?
    let episodeNumber: Int?
    let showId: String?
    let microdramaId: String?
    let channelId: String?
    let channelHandle: String?
    let playlistId: String?
    let collectionId: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, title, message, linkUrl, link_url, imageUrl, image_url, image, thumbnailUrl, thumbnail_url
        case avatarUrl, avatar_url, profileImage, profile_image, actorImageUrl, actor_image_url, actorAvatarUrl, actor_avatar_url
        case channelAvatarUrl, channel_avatar_url, showCoverUrl, show_cover_url, coverUrl, cover_url
        case read, createdAt, created_at, contextType, context_type, contextId, context_id
        case contentType, content_type, mediaType, media_type, kind
        case videoId, video_id, targetVideoId, target_video_id
        case shortId, short_id, targetShortId, target_short_id
        case episodeId, episode_id, targetEpisodeId, target_episode_id
        case episodeNumber, episode_number, targetEpisodeNumber, target_episode_number
        case showId, show_id, targetShowId, target_show_id
        case microdramaId, microdrama_id, targetMicrodramaId, target_microdrama_id
        case channelId, channel_id, targetChannelId, target_channel_id
        case channelHandle, channel_handle, targetChannelHandle, target_channel_handle
        case playlistId, playlist_id, targetPlaylistId, target_playlist_id
        case collectionId, collection_id, targetCollectionId, target_collection_id
    }

    init(
        id: String,
        type: String,
        title: String,
        message: String,
        linkUrl: String?,
        imageUrl: String?,
        read: Bool,
        createdAt: String,
        contextType: String?,
        contextId: String?,
        contentType: String? = nil,
        videoId: String? = nil,
        shortId: String? = nil,
        episodeId: String? = nil,
        episodeNumber: Int? = nil,
        showId: String? = nil,
        microdramaId: String? = nil,
        channelId: String? = nil,
        channelHandle: String? = nil,
        playlistId: String? = nil,
        collectionId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.linkUrl = linkUrl
        self.imageUrl = imageUrl
        self.read = read
        self.createdAt = createdAt
        self.contextType = contextType
        self.contextId = contextId
        self.contentType = contentType
        self.videoId = videoId
        self.shortId = shortId
        self.episodeId = episodeId
        self.episodeNumber = episodeNumber
        self.showId = showId
        self.microdramaId = microdramaId
        self.channelId = channelId
        self.channelHandle = channelHandle
        self.playlistId = playlistId
        self.collectionId = collectionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "info"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Notification"
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        linkUrl = try c.decodeFirstPresentString(forKeys: [.linkUrl, .link_url])
        imageUrl = try c.decodeFirstPresentString(forKeys: [
            .imageUrl,
            .image_url,
            .image,
            .thumbnailUrl,
            .thumbnail_url,
            .avatarUrl,
            .avatar_url,
            .profileImage,
            .profile_image,
            .actorImageUrl,
            .actor_image_url,
            .actorAvatarUrl,
            .actor_avatar_url,
            .channelAvatarUrl,
            .channel_avatar_url,
            .showCoverUrl,
            .show_cover_url,
            .coverUrl,
            .cover_url
        ])
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        createdAt = try c.decodeFirstPresentString(forKeys: [.createdAt, .created_at]) ?? ""
        contextType = try c.decodeFirstPresentString(forKeys: [.contextType, .context_type])
        contextId = try c.decodeFirstPresentString(forKeys: [.contextId, .context_id])
        contentType = try c.decodeFirstPresentString(forKeys: [.contentType, .content_type, .mediaType, .media_type, .kind])
        videoId = try c.decodeFirstPresentString(forKeys: [.videoId, .video_id, .targetVideoId, .target_video_id])
        shortId = try c.decodeFirstPresentString(forKeys: [.shortId, .short_id, .targetShortId, .target_short_id])
        episodeId = try c.decodeFirstPresentString(forKeys: [.episodeId, .episode_id, .targetEpisodeId, .target_episode_id])
        episodeNumber = try c.decodeFirstPresentString(forKeys: [.episodeNumber, .episode_number, .targetEpisodeNumber, .target_episode_number])
            .flatMap(Int.init)
        showId = try c.decodeFirstPresentString(forKeys: [.showId, .show_id, .targetShowId, .target_show_id])
        microdramaId = try c.decodeFirstPresentString(forKeys: [.microdramaId, .microdrama_id, .targetMicrodramaId, .target_microdrama_id])
        channelId = try c.decodeFirstPresentString(forKeys: [.channelId, .channel_id, .targetChannelId, .target_channel_id])
        channelHandle = try c.decodeFirstPresentString(forKeys: [.channelHandle, .channel_handle, .targetChannelHandle, .target_channel_handle])
        playlistId = try c.decodeFirstPresentString(forKeys: [.playlistId, .playlist_id, .targetPlaylistId, .target_playlist_id])
        collectionId = try c.decodeFirstPresentString(forKeys: [.collectionId, .collection_id, .targetCollectionId, .target_collection_id])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(linkUrl, forKey: .linkUrl)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encode(read, forKey: .read)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(contextType, forKey: .contextType)
        try c.encodeIfPresent(contextId, forKey: .contextId)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(videoId, forKey: .videoId)
        try c.encodeIfPresent(shortId, forKey: .shortId)
        try c.encodeIfPresent(episodeId, forKey: .episodeId)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(showId, forKey: .showId)
        try c.encodeIfPresent(microdramaId, forKey: .microdramaId)
        try c.encodeIfPresent(channelId, forKey: .channelId)
        try c.encodeIfPresent(channelHandle, forKey: .channelHandle)
        try c.encodeIfPresent(playlistId, forKey: .playlistId)
        try c.encodeIfPresent(collectionId, forKey: .collectionId)
    }
}

extension AppNotification {
    var appRoute: AppRoute? {
        let normalizedContentType = C.normalizedContentType(contentType ?? type)
        let contextShowId = contextType?.lowercased() == "show" ? contextId : nil
        let contextChannelId = contextType?.lowercased() == "channel" ? contextId : nil

        if let shortId {
            return .short(shortId, showId: showId ?? contextShowId, channelId: channelId ?? contextChannelId)
        }
        if let videoId {
            return AppRoute.media(
                id: videoId,
                type: normalizedContentType,
                showId: showId ?? contextShowId,
                channelId: channelId ?? contextChannelId
            )
        }
        if let episodeId {
            return .episode(episodeId)
        }

        let microdramaTargetId = microdramaId ?? (normalizedContentType.contains("micro") ? showId : nil)
        if let microdramaTargetId {
            if let episodeNumber {
                return .microdramaWatchEp(microdramaTargetId, episodeNumber)
            }
            return .microdramaShow(microdramaTargetId)
        }
        if let showId {
            return .show(showId)
        }
        if let channel = channelHandle ?? channelId {
            return .channel(channel)
        }
        if let playlistId {
            return .playlist(playlistId)
        }
        if let collectionId {
            return .collection(collectionId)
        }
        if let linkUrl {
            return AppRoute.route(link: linkUrl, notificationType: contentType ?? type)
        }
        return nil
    }
}

struct SwitchContextBody: Encodable {
    let id: String
    let type: String
    let name: String
    let channelId: String?
    let showId: String?
}

struct SwitchContextResponse: Codable {
    let ok: Bool
    let context: ActiveContext?
}
