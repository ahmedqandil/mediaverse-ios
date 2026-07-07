import Foundation

struct StoryItem: Codable, Identifiable, Equatable {
    let id: String
    let mediaUrl: String
    let mediaType: String
    let duration: Int
    let caption: String?
    let ctaLabel: String?
    let ctaUrl: String?
    let expiresAt: Date
    let createdAt: Date
    let viewCount: Int
    var seen: Bool

    private enum CodingKeys: String, CodingKey {
        case id, mediaUrl, mediaType, duration, caption, ctaLabel, ctaUrl, expiresAt, createdAt, viewCount, seen
    }

    init(
        id: String,
        mediaUrl: String,
        mediaType: String,
        duration: Int,
        caption: String?,
        ctaLabel: String?,
        ctaUrl: String?,
        expiresAt: Date,
        createdAt: Date,
        viewCount: Int,
        seen: Bool
    ) {
        self.id = id
        self.mediaUrl = mediaUrl
        self.mediaType = mediaType
        self.duration = duration
        self.caption = caption
        self.ctaLabel = ctaLabel
        self.ctaUrl = ctaUrl
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.viewCount = viewCount
        self.seen = seen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mediaUrl = try c.decode(String.self, forKey: .mediaUrl)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType) ?? "image"
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 5
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        ctaLabel = try c.decodeIfPresent(String.self, forKey: .ctaLabel)
        ctaUrl = try c.decodeIfPresent(String.self, forKey: .ctaUrl)
        expiresAt = try FlexibleISODate.decode(from: c, forKey: .expiresAt) ?? Date()
        createdAt = try FlexibleISODate.decode(from: c, forKey: .createdAt) ?? Date()
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaUrl, forKey: .mediaUrl)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encodeIfPresent(ctaLabel, forKey: .ctaLabel)
        try c.encodeIfPresent(ctaUrl, forKey: .ctaUrl)
        try c.encode(FlexibleISODate.string(from: expiresAt), forKey: .expiresAt)
        try c.encode(FlexibleISODate.string(from: createdAt), forKey: .createdAt)
        try c.encode(viewCount, forKey: .viewCount)
        try c.encode(seen, forKey: .seen)
    }
}

struct StoryGroup: Codable, Identifiable, Equatable {
    var id: String { "\(publisherType):\(publisherId)" }
    let publisherType: String
    let publisherId: String
    let publisherName: String
    let publisherImageUrl: String?
    var stories: [StoryItem]
    var hasUnseen: Bool

    private enum CodingKeys: String, CodingKey {
        case publisherType, publisherId, publisherName, publisherImageUrl, stories, hasUnseen
    }

    init(
        publisherType: String,
        publisherId: String,
        publisherName: String,
        publisherImageUrl: String?,
        stories: [StoryItem],
        hasUnseen: Bool
    ) {
        self.publisherType = publisherType
        self.publisherId = publisherId
        self.publisherName = publisherName
        self.publisherImageUrl = publisherImageUrl
        self.stories = stories
        self.hasUnseen = hasUnseen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publisherType = try c.decode(String.self, forKey: .publisherType)
        publisherId = try c.decode(String.self, forKey: .publisherId)
        publisherName = try c.decode(String.self, forKey: .publisherName)
        publisherImageUrl = try c.decodeIfPresent(String.self, forKey: .publisherImageUrl)
        stories = try c.decodeIfPresent([StoryItem].self, forKey: .stories) ?? []
        hasUnseen = try c.decodeIfPresent(Bool.self, forKey: .hasUnseen) ?? stories.contains { !$0.seen }
    }
}

struct UploadUrlRequest: Encodable {
    let mimeType: String
}

struct UploadUrlResponse: Codable {
    let uploadUrl: String
    let mediaUrl: String
    let mediaType: String
    /// When true, the upload endpoint returns { mediaUrl } in its response body.
    /// publishStory should use that URL instead of the placeholder mediaUrl above.
    let directUpload: Bool?
}

/// Response body returned by /api/stories/upload-media (Vercel Blob fallback)
struct UploadMediaResponse: Decodable {
    let mediaUrl: String
}

struct CreateStoryRequest: Codable {
    let publisherType: String
    let publisherId: String
    let mediaUrl: String
    let mediaType: String
    let duration: Int
    let caption: String?
    let ctaLabel: String?
    let ctaUrl: String?
    let expiresInHours: Int?
}

enum FlexibleISODate {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let regularFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decode<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> Date? {
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return fractionalFormatter.date(from: value) ?? regularFormatter.date(from: value)
    }

    static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }
}
