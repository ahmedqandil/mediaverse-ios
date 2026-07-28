import Foundation

// MARK: - Story Overlays

/// Base fields shared by every overlay kind.
struct StoryOverlayBase: Codable, Equatable {
    let x:        Double   // 0 left → 1 right (normalised canvas position)
    let y:        Double   // 0 top  → 1 bottom
    let scale:    Double?
    let rotation: Double?
}

// ── Individual overlay payloads ───────────────────────────────────────────────

struct MentionOverlayData: Codable, Equatable {
    let entityType:  String    // "user" | "channel" | "show"
    let entityId:    String
    let handle:      String
    let displayName: String
    let avatarUrl:   String?
}

struct LocationOverlayData: Codable, Equatable {
    let name: String
    let lat:  Double?
    let lng:  Double?
}

struct PollOverlayData: Codable, Equatable {
    let question: String
    let options:  [String]     // 2-4 choices
    let votes: [Int]?
    let totalVotes: Int?
    let userVote: Int?
}

struct QuizOverlayData: Codable, Equatable {
    let question:     String
    let options:      [String]
    let correctIndex: Int
    let userAnswer: Int?
    let isCorrect: Bool?
}

struct CountdownOverlayData: Codable, Equatable {
    let label:  String
    let endsAt: Date
}

struct LinkOverlayData: Codable, Equatable {
    let url:   String
    let label: String?
}

struct QuestionOverlayData: Codable, Equatable {
    let prompt: String
    let replyCount: Int?
    let userReplied: Bool?
}

// ── Discriminated union ───────────────────────────────────────────────────────

enum StoryOverlay: Codable, Equatable, Identifiable {
    case mention(   base: StoryOverlayBase, data: MentionOverlayData)
    case location(  base: StoryOverlayBase, data: LocationOverlayData)
    case poll(      base: StoryOverlayBase, data: PollOverlayData)
    case quiz(      base: StoryOverlayBase, data: QuizOverlayData)
    case countdown( base: StoryOverlayBase, data: CountdownOverlayData)
    case link(      base: StoryOverlayBase, data: LinkOverlayData)
    case question(  base: StoryOverlayBase, data: QuestionOverlayData)
    case unknown(   base: StoryOverlayBase, kind: String)

    var id: String {
        switch self {
        case .mention(_, let d):  return "mention:\(d.entityId)"
        case .location(let b, let d): return "location:\(d.name):\(b.x):\(b.y)"
        case .poll(let b, _):     return "poll:\(b.x):\(b.y)"
        case .quiz(let b, _):     return "quiz:\(b.x):\(b.y)"
        case .countdown(_, let d): return "countdown:\(d.label)"
        case .link(_, let d):     return "link:\(d.url)"
        case .question(let b, _): return "question:\(b.x):\(b.y)"
        case .unknown(let b, let k): return "\(k):\(b.x):\(b.y)"
        }
    }

    var base: StoryOverlayBase {
        switch self {
        case .mention(let b, _):   return b
        case .location(let b, _):  return b
        case .poll(let b, _):      return b
        case .quiz(let b, _):      return b
        case .countdown(let b, _): return b
        case .link(let b, _):      return b
        case .question(let b, _):  return b
        case .unknown(let b, _):   return b
        }
    }

    // ── Codable ───────────────────────────────────────────────────────────────

    private enum TopLevelKey: String, CodingKey {
        case kind, x, y, scale, rotation
        // mention
        case entityType, entityId, handle, displayName, avatarUrl
        // location
        case name, lat, lng
        // poll / quiz / question
        case question, options, votes, totalVotes, userVote, correctIndex, userAnswer, isCorrect, prompt, replyCount, userReplied
        // countdown
        case label, endsAt
        // link
        case url
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: TopLevelKey.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        let base = StoryOverlayBase(
            x:        try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5,
            y:        try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5,
            scale:    try c.decodeIfPresent(Double.self, forKey: .scale),
            rotation: try c.decodeIfPresent(Double.self, forKey: .rotation)
        )
        switch kind {
        case "mention":
            self = .mention(base: base, data: MentionOverlayData(
                entityType:  try c.decodeIfPresent(String.self, forKey: .entityType) ?? "user",
                entityId:    try c.decode(String.self, forKey: .entityId),
                handle:      try c.decode(String.self, forKey: .handle),
                displayName: try c.decodeIfPresent(String.self, forKey: .displayName) ?? "",
                avatarUrl:   try c.decodeIfPresent(String.self, forKey: .avatarUrl)
            ))
        case "location":
            self = .location(base: base, data: LocationOverlayData(
                name: try c.decode(String.self, forKey: .name),
                lat:  try c.decodeIfPresent(Double.self, forKey: .lat),
                lng:  try c.decodeIfPresent(Double.self, forKey: .lng)
            ))
        case "poll":
            self = .poll(base: base, data: PollOverlayData(
                question: try c.decode(String.self, forKey: .question),
                options:  try c.decode([String].self, forKey: .options),
                votes: try c.decodeIfPresent([Int].self, forKey: .votes),
                totalVotes: try c.decodeIfPresent(Int.self, forKey: .totalVotes),
                userVote: try c.decodeIfPresent(Int.self, forKey: .userVote)
            ))
        case "quiz":
            self = .quiz(base: base, data: QuizOverlayData(
                question:     try c.decode(String.self, forKey: .question),
                options:      try c.decode([String].self, forKey: .options),
                correctIndex: try c.decodeIfPresent(Int.self, forKey: .correctIndex) ?? 0,
                userAnswer: try c.decodeIfPresent(Int.self, forKey: .userAnswer),
                isCorrect: try c.decodeIfPresent(Bool.self, forKey: .isCorrect)
            ))
        case "countdown":
            let endsAt = try FlexibleISODate.decode(from: c, forKey: .endsAt) ?? Date()
            self = .countdown(base: base, data: CountdownOverlayData(
                label:  try c.decode(String.self, forKey: .label),
                endsAt: endsAt
            ))
        case "link":
            self = .link(base: base, data: LinkOverlayData(
                url:   try c.decode(String.self, forKey: .url),
                label: try c.decodeIfPresent(String.self, forKey: .label)
            ))
        case "question":
            self = .question(base: base, data: QuestionOverlayData(
                prompt: try c.decodeIfPresent(String.self, forKey: .prompt) ?? "",
                replyCount: try c.decodeIfPresent(Int.self, forKey: .replyCount),
                userReplied: try c.decodeIfPresent(Bool.self, forKey: .userReplied)
            ))
        default:
            self = .unknown(base: base, kind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TopLevelKey.self)
        try c.encode(base.x, forKey: .x)
        try c.encode(base.y, forKey: .y)
        try c.encodeIfPresent(base.scale,    forKey: .scale)
        try c.encodeIfPresent(base.rotation, forKey: .rotation)
        switch self {
        case .mention(_, let d):
            try c.encode("mention",     forKey: .kind)
            try c.encode(d.entityType,  forKey: .entityType)
            try c.encode(d.entityId,    forKey: .entityId)
            try c.encode(d.handle,      forKey: .handle)
            try c.encode(d.displayName, forKey: .displayName)
            try c.encodeIfPresent(d.avatarUrl, forKey: .avatarUrl)
        case .location(_, let d):
            try c.encode("location", forKey: .kind)
            try c.encode(d.name,     forKey: .name)
            try c.encodeIfPresent(d.lat, forKey: .lat)
            try c.encodeIfPresent(d.lng, forKey: .lng)
        case .poll(_, let d):
            try c.encode("poll",      forKey: .kind)
            try c.encode(d.question,  forKey: .question)
            try c.encode(d.options,   forKey: .options)
            try c.encodeIfPresent(d.votes, forKey: .votes)
            try c.encodeIfPresent(d.totalVotes, forKey: .totalVotes)
            try c.encodeIfPresent(d.userVote, forKey: .userVote)
        case .quiz(_, let d):
            try c.encode("quiz",           forKey: .kind)
            try c.encode(d.question,       forKey: .question)
            try c.encode(d.options,        forKey: .options)
            try c.encode(d.correctIndex,   forKey: .correctIndex)
            try c.encodeIfPresent(d.userAnswer, forKey: .userAnswer)
            try c.encodeIfPresent(d.isCorrect, forKey: .isCorrect)
        case .countdown(_, let d):
            try c.encode("countdown",                        forKey: .kind)
            try c.encode(d.label,                            forKey: .label)
            try c.encode(FlexibleISODate.string(from: d.endsAt), forKey: .endsAt)
        case .link(_, let d):
            try c.encode("link",  forKey: .kind)
            try c.encode(d.url,   forKey: .url)
            try c.encodeIfPresent(d.label, forKey: .label)
        case .question(_, let d):
            try c.encode("question", forKey: .kind)
            try c.encode(d.prompt,   forKey: .prompt)
            try c.encodeIfPresent(d.replyCount, forKey: .replyCount)
            try c.encodeIfPresent(d.userReplied, forKey: .userReplied)
        case .unknown(_, let k):
            try c.encode(k, forKey: .kind)
        }
    }
}

// Convenience: keep legacy StoryMentionMetadata as a typealias / helper
typealias StoryMentionMetadata = MentionOverlayData

// MARK: - StoryItem

struct StoryItem: Codable, Identifiable, Equatable {
    let id:          String
    let mediaUrl:    String
    let mediaType:   String
    let duration:    Int
    let caption:     String?
    let captionHtml: String?
    let overlays:    [StoryOverlay]
    let ctaLabel:    String?
    let ctaUrl:      String?
    let expiresAt:   Date
    let createdAt:   Date
    let viewCount:   Int
    var likeCount:   Int
    var userLiked:   Bool
    var energyCount: Int
    var energyTotal: Int
    var energyTags:  [String: Int]
    var seen:        Bool

    /// Convenience: all mention overlays
    var mentionOverlays: [MentionOverlayData] {
        overlays.compactMap {
            guard case .mention(_, let d) = $0 else { return nil }
            return d
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaUrl, mediaType, duration, caption, captionHtml
        case overlays, mentions, storyMentions   // accept all forms
        case ctaLabel, ctaUrl, expiresAt, createdAt, viewCount, likeCount, userLiked, liked, myLike
        case energyCount, energyTotal, energyTags, seen
    }

    init(
        id: String, mediaUrl: String, mediaType: String, duration: Int,
        caption: String?, captionHtml: String? = nil, overlays: [StoryOverlay] = [],
        ctaLabel: String?, ctaUrl: String?,
        expiresAt: Date, createdAt: Date, viewCount: Int, likeCount: Int = 0, userLiked: Bool = false,
        energyCount: Int = 0, energyTotal: Int = 0, energyTags: [String: Int] = [:], seen: Bool
    ) {
        self.id = id; self.mediaUrl = mediaUrl; self.mediaType = mediaType
        self.duration = duration; self.caption = caption; self.captionHtml = captionHtml
        self.overlays = overlays; self.ctaLabel = ctaLabel; self.ctaUrl = ctaUrl
        self.expiresAt = expiresAt; self.createdAt = createdAt
        self.viewCount = viewCount; self.likeCount = likeCount; self.userLiked = userLiked; self.seen = seen
        self.energyCount = energyCount; self.energyTotal = energyTotal; self.energyTags = energyTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        mediaUrl    = try c.decode(String.self, forKey: .mediaUrl)
        mediaType   = try c.decodeIfPresent(String.self, forKey: .mediaType)   ?? "image"
        duration    = try c.decodeIfPresent(Int.self,    forKey: .duration)    ?? 5
        caption     = try c.decodeIfPresent(String.self, forKey: .caption)
        captionHtml = try c.decodeIfPresent(String.self, forKey: .captionHtml)
        ctaLabel    = try c.decodeIfPresent(String.self, forKey: .ctaLabel)
        ctaUrl      = try c.decodeIfPresent(String.self, forKey: .ctaUrl)
        expiresAt   = try FlexibleISODate.decode(from: c, forKey: .expiresAt)  ?? Date()
        createdAt   = try FlexibleISODate.decode(from: c, forKey: .createdAt)  ?? Date()
        viewCount   = try c.decodeIfPresent(Int.self,    forKey: .viewCount)   ?? 0
        likeCount   = try c.decodeIfPresent(Int.self,    forKey: .likeCount)   ?? 0
        userLiked   = try c.decodeIfPresent(Bool.self,   forKey: .userLiked)
            ?? c.decodeIfPresent(Bool.self, forKey: .liked)
            ?? c.decodeIfPresent(Bool.self, forKey: .myLike)
            ?? false
        energyCount = try c.decodeIfPresent(Int.self, forKey: .energyCount) ?? 0
        energyTotal = try c.decodeIfPresent(Int.self, forKey: .energyTotal) ?? 0
        energyTags = try c.decodeIfPresent([String: Int].self, forKey: .energyTags) ?? [:]
        seen        = try c.decodeIfPresent(Bool.self,   forKey: .seen)        ?? false

        // Decode overlays from the new `overlays` field, fall back to legacy `mentions`
        if let ov = try c.decodeIfPresent([StoryOverlay].self, forKey: .overlays) {
            overlays = ov
        } else if let ov = try c.decodeIfPresent([StoryOverlay].self, forKey: .mentions) {
            overlays = ov
        } else if let ov = try c.decodeIfPresent([StoryOverlay].self, forKey: .storyMentions) {
            overlays = ov
        } else {
            overlays = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,          forKey: .id)
        try c.encode(mediaUrl,    forKey: .mediaUrl)
        try c.encode(mediaType,   forKey: .mediaType)
        try c.encode(duration,    forKey: .duration)
        try c.encodeIfPresent(caption,     forKey: .caption)
        try c.encodeIfPresent(captionHtml, forKey: .captionHtml)
        if !overlays.isEmpty { try c.encode(overlays, forKey: .overlays) }
        try c.encodeIfPresent(ctaLabel, forKey: .ctaLabel)
        try c.encodeIfPresent(ctaUrl,   forKey: .ctaUrl)
        try c.encode(FlexibleISODate.string(from: expiresAt), forKey: .expiresAt)
        try c.encode(FlexibleISODate.string(from: createdAt), forKey: .createdAt)
        try c.encode(viewCount, forKey: .viewCount)
        try c.encode(likeCount, forKey: .likeCount)
        try c.encode(userLiked, forKey: .userLiked)
        try c.encode(energyCount, forKey: .energyCount)
        try c.encode(energyTotal, forKey: .energyTotal)
        try c.encode(energyTags, forKey: .energyTags)
        try c.encode(seen,      forKey: .seen)
    }
}

// MARK: - StoryGroup

struct StoryGroup: Codable, Identifiable, Equatable {
    var id: String { "\(publisherType):\(publisherId)" }
    let publisherType:     String
    let publisherId:       String
    let publisherName:     String
    let publisherHandle:   String?
    let publisherImageUrl: String?
    var stories:           [StoryItem]
    var hasUnseen:         Bool

    private enum CodingKeys: String, CodingKey {
        case publisherType, publisherId, publisherName, publisherHandle, handle, channelHandle, publisherImageUrl, stories, hasUnseen
        case publisherAvatarUrl, publisherImage, avatarUrl, imageUrl, image
        case publisher, channel, user
    }

    private struct PublisherSource: Decodable {
        let handle: String?
        let image: String?
        let imageUrl: String?
        let avatarUrl: String?
        let bannerUrl: String?
    }

    init(publisherType: String, publisherId: String, publisherName: String,
         publisherHandle: String? = nil, publisherImageUrl: String?, stories: [StoryItem], hasUnseen: Bool) {
        self.publisherType = publisherType; self.publisherId = publisherId
        self.publisherName = publisherName; self.publisherHandle = publisherHandle
        self.publisherImageUrl = publisherImageUrl
        self.stories = stories; self.hasUnseen = hasUnseen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publisherType     = try c.decode(String.self, forKey: .publisherType)
        publisherId       = try c.decode(String.self, forKey: .publisherId)
        publisherName     = try c.decode(String.self, forKey: .publisherName)
        publisherHandle   = try Self.decodePublisherHandle(from: c)
        publisherImageUrl = try Self.decodePublisherImage(from: c)
        stories           = try c.decodeIfPresent([StoryItem].self, forKey: .stories) ?? []
        hasUnseen         = try c.decodeIfPresent(Bool.self, forKey: .hasUnseen) ?? stories.contains { !$0.seen }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(publisherType, forKey: .publisherType)
        try c.encode(publisherId,   forKey: .publisherId)
        try c.encode(publisherName, forKey: .publisherName)
        try c.encodeIfPresent(publisherHandle, forKey: .publisherHandle)
        try c.encodeIfPresent(publisherImageUrl, forKey: .publisherImageUrl)
        try c.encode(stories,   forKey: .stories)
        try c.encode(hasUnseen, forKey: .hasUnseen)
    }

    private static func decodePublisherHandle(from c: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        for key in [CodingKeys.publisherHandle, .channelHandle, .handle] {
            if let v = try c.decodeIfPresent(String.self, forKey: key), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        for key in [CodingKeys.publisher, .channel, .user] {
            if let source = try c.decodeIfPresent(PublisherSource.self, forKey: key),
               let handle = source.handle,
               !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return handle
            }
        }
        return nil
    }

    private static func decodePublisherImage(from c: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        for key in [CodingKeys.publisherImageUrl, .publisherAvatarUrl, .publisherImage, .avatarUrl, .imageUrl, .image] {
            if let v = try c.decodeIfPresent(String.self, forKey: key), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
        }
        for key in [CodingKeys.publisher, .channel, .user] {
            if let s = try c.decodeIfPresent(PublisherSource.self, forKey: key) {
                for v in [s.avatarUrl, s.image, s.imageUrl, s.bannerUrl] {
                    if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
                }
            }
        }
        return nil
    }
}

// MARK: - API request / response types

struct UploadUrlRequest:  Encodable { let mimeType: String }

struct UploadUrlResponse: Codable {
    let uploadUrl: String
    let objectKey: String?
    let deliveryUrl: String?
    let mediaUrl: String?
    let mediaType: String?
    let needsTranscode: Bool?

    var resolvedDeliveryUrl: String? {
        [deliveryUrl, mediaUrl]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct TranscodeStoryMediaRequest:  Encodable  { let objectKey: String }
struct TranscodeStoryMediaResponse: Decodable  { let mediaUrl:  String }

struct CreateStoryRequest: Codable {
    let publisherType:  String
    let publisherId:    String
    let mediaUrl:       String
    let thumbnailUrl:   String?
    let mediaType:      String
    let duration:       Int
    let caption:        String?
    let captionHtml:    String?
    let overlays:       [StoryOverlay]?
    let ctaLabel:       String?
    let ctaUrl:         String?
    let expiresInHours: Int?
}

// MARK: - Date helpers

enum FlexibleISODate {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let regularFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func decode<Key: CodingKey>(from c: KeyedDecodingContainer<Key>, forKey key: Key) throws -> Date? {
        if let d = try? c.decode(Date.self, forKey: key) { return d }
        guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return fractionalFormatter.date(from: s) ?? regularFormatter.date(from: s)
    }

    static func string(from date: Date) -> String { fractionalFormatter.string(from: date) }
}
