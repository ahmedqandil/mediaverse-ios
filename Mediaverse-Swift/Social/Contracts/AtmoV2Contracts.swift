import Foundation

public enum AtmoV2Authority {
    public static let value = "WESTREEM"
    public static let version = 2
    public static let basePath = "/api/v2/atmo"
    public static let permitsMatrix = false
    public static let permitsLegacySocialAdapter = false
}

public enum AtmoV2HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public protocol AtmoV2Transport: Sendable {
    func atmoV2Data(
        path: String,
        method: AtmoV2HTTPMethod,
        body: Data?
    ) async throws -> Data
}

public enum AtmoV2RepositoryError: Error, Equatable {
    case disabled
    case invalidAuthority
    case invalidPayload
}

public struct AtmoV2Rollout: Equatable, Sendable {
    public let localEnabled: Bool
    public init(localEnabled: Bool) { self.localEnabled = localEnabled }
    public var mayProbeServer: Bool { localEnabled }
}

public struct AtmoV2Author: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
    public let verified: Bool?
}

public struct AtmoV2Profile: Codable, Equatable, Sendable {
    public let visibility: String
    public let commentsEnabled: Bool
    public let followerCount: Int
    public let postCount: Int
}

public struct AtmoV2Viewer: Codable, Equatable, Sendable {
    public let owner: Bool
    public let following: Bool
}

public struct AtmoV2PublicUser: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let handle: String?
    public let image: String?
    public let bannerUrl: String?
    public let bio: String?
}

public struct AtmoV2ProfileResponse: Decodable, Equatable, Sendable {
    public let authority: String
    public let version: Int
    public let user: AtmoV2PublicUser
    public let profile: AtmoV2Profile
    public let viewer: AtmoV2Viewer
}

public struct AtmoV2PostCounts: Codable, Equatable, Sendable {
    public let comments: Int
    public let echoes: Int
    public let energy: Int
    public let shares: Int
}

public struct AtmoV2EnergyViewer: Codable, Equatable, Sendable {
    public let overall: Int
    public let tags: [String]
}

public struct AtmoV2Energy: Codable, Equatable, Sendable {
    public let average: Double
    public let tags: [String: Int]
    public let viewer: AtmoV2EnergyViewer?
}

public struct AtmoV2Attachment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let position: Int
    public let entityId: String?
    public let canonicalUrl: String?
    public let imageUrl: String?
    public let mediaUrl: String?
    public let mediaThumbnailUrl: String?
    public let externalUrl: String?
    public let linkTitle: String?
    public let linkDescription: String?
    public let linkImageUrl: String?
    public let linkFaviconUrl: String?
    public let linkDomain: String?
    public let markIn: Int?
    public let markOut: Int?
}

public struct AtmoV2PollOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let position: Int
    public let voteCount: Int?
    public let selected: Bool
}

public struct AtmoV2Poll: Codable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let allowsMultiple: Bool
    public let maxSelections: Int
    public let allowsVoteChanges: Bool
    public let resultsVisibility: String
    public let closesAt: String?
    public let closedAt: String?
    public let totalVoters: Int?
    public let options: [AtmoV2PollOption]
}

public struct AtmoV2Echo: Codable, Equatable, Sendable {
    public let id: String
    public let sourceType: String
    public let sourceId: String
    public let sourceUrl: String?
    public let quote: String?
    public let createdAt: String?
}

public struct AtmoV2Post: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let body: String?
    public let status: String
    public let isSpoiler: Bool
    public let commentsDisabled: Bool
    public let pinnedAt: String?
    public let editedAt: String?
    public let publishedAt: String?
    public let createdAt: String
    public let updatedAt: String
    public let author: AtmoV2Author
    public let counts: AtmoV2PostCounts
    public let energy: AtmoV2Energy?
    public let attachments: [AtmoV2Attachment]
    public let poll: AtmoV2Poll?
    public let echo: AtmoV2Echo?
}

public struct AtmoV2PostPage: Decodable, Equatable, Sendable {
    public let authority: String
    public let version: Int
    public let posts: [AtmoV2Post]
    public let nextCursor: String?
}

public struct AtmoV2Comment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let postId: String
    public let parentId: String?
    public let content: String
    public let likeCount: Int
    public let likedByViewer: Bool
    public let editedAt: String?
    public let createdAt: String
    public let author: AtmoV2Author?
}

public struct AtmoV2CommentPage: Decodable, Equatable, Sendable {
    public let comments: [AtmoV2Comment]
    public let nextCursor: String?
}

public struct AtmoV2AttachmentDraft: Encodable, Equatable, Sendable {
    public let type: String
    public let entityId: String?
    public let canonicalUrl: String?
    public let imageUrl: String?
    public let mediaUrl: String?
    public let mediaObjectKey: String?
    public let mediaMimeType: String?
    public let mediaBytes: Int?
    public let externalUrl: String?
    public let linkTitle: String?
    public let linkDescription: String?
    public let linkImageUrl: String?
    public let linkFaviconUrl: String?
    public let linkDomain: String?
    public let markIn: Int?
    public let markOut: Int?

    public init(
        type: String, entityId: String? = nil, canonicalUrl: String? = nil,
        imageUrl: String? = nil, mediaUrl: String? = nil,
        mediaObjectKey: String? = nil, mediaMimeType: String? = nil,
        mediaBytes: Int? = nil, externalUrl: String? = nil,
        linkTitle: String? = nil, linkDescription: String? = nil,
        linkImageUrl: String? = nil, linkFaviconUrl: String? = nil,
        linkDomain: String? = nil, markIn: Int? = nil, markOut: Int? = nil
    ) {
        self.type = type; self.entityId = entityId; self.canonicalUrl = canonicalUrl
        self.imageUrl = imageUrl; self.mediaUrl = mediaUrl; self.externalUrl = externalUrl
        self.mediaObjectKey = mediaObjectKey; self.mediaMimeType = mediaMimeType
        self.mediaBytes = mediaBytes
        self.linkTitle = linkTitle; self.linkDescription = linkDescription
        self.linkImageUrl = linkImageUrl; self.linkFaviconUrl = linkFaviconUrl
        self.linkDomain = linkDomain; self.markIn = markIn; self.markOut = markOut
    }
}

public struct AtmoV2UploadTicket: Decodable, Equatable, Sendable {
    public let authority: String
    public let version: Int
    public let uploadUrl: String
    public let objectKey: String
    public let deliveryUrl: String
    public let mediaType: String
    public let needsTranscode: Bool
    public let maxBytes: Int
}

public struct AtmoV2PollDraft: Encodable, Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let allowsMultiple: Bool
    public let maxSelections: Int
    public let allowsVoteChanges: Bool
    public let resultsVisibility: String
    public let closesAt: String?
}

public struct AtmoV2EchoDraft: Encodable, Equatable, Sendable {
    public let sourceType: String
    public let sourceId: String
    public let sourceUrl: String?
    public let quote: String?
}

public struct AtmoV2PostDraft: Encodable, Equatable, Sendable {
    public let clientRequestId: String
    public let body: String?
    public let isSpoiler: Bool
    public let commentsDisabled: Bool
    public let attachments: [AtmoV2AttachmentDraft]
    public let poll: AtmoV2PollDraft?
    public let echo: AtmoV2EchoDraft?

    public init(
        clientRequestId: String = UUID().uuidString, body: String? = nil,
        isSpoiler: Bool = false, commentsDisabled: Bool = false,
        attachments: [AtmoV2AttachmentDraft] = [], poll: AtmoV2PollDraft? = nil,
        echo: AtmoV2EchoDraft? = nil
    ) {
        self.clientRequestId = clientRequestId; self.body = body
        self.isSpoiler = isSpoiler; self.commentsDisabled = commentsDisabled
        self.attachments = attachments; self.poll = poll; self.echo = echo
    }
}

public struct AtmoV2EnergyDraft: Encodable, Equatable, Sendable {
    public let overall: Int
    public let tags: [String]
    public let review: String?
}

private struct AtmoV2PostEnvelope: Decodable { let authority: String?; let version: Int?; let post: AtmoV2Post }
private struct AtmoV2CreateEnvelope: Decodable { let authority: String; let version: Int; let created: Bool; let post: AtmoV2Post }
private struct AtmoV2CommentEnvelope: Decodable { let comment: AtmoV2Comment }
private struct AtmoV2FollowEnvelope: Decodable { let following: Bool }
private struct AtmoV2PinEnvelope: Decodable { let pinned: Bool }
private struct AtmoV2CommentLikeEnvelope: Decodable { let liked: Bool; let likeCount: Int }
private struct AtmoV2DeletedEnvelope: Decodable { let deleted: Bool }

public actor WestreemAtmoV2Repository {
    public static let authority = "WESTREEM"
    private let transport: any AtmoV2Transport
    private let rollout: AtmoV2Rollout
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: any AtmoV2Transport, rollout: AtmoV2Rollout) {
        self.transport = transport
        self.rollout = rollout
    }

    public func profile(userID: String) async throws -> AtmoV2ProfileResponse {
        try enabled()
        let value: AtmoV2ProfileResponse = try await request("/profiles/\(escaped(userID))")
        try validate(value.authority, value.version)
        return value
    }

    public func profile(handle: String) async throws -> AtmoV2ProfileResponse {
        try enabled()
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@").lowercased()
        let value: AtmoV2ProfileResponse = try await request(
            "/profiles/by-handle/\(escaped(normalized))"
        )
        try validate(value.authority, value.version)
        return value
    }

    public func posts(userID: String, cursor: String? = nil, limit: Int = 20) async throws -> AtmoV2PostPage {
        try enabled()
        var path = "/profiles/\(escaped(userID))/posts?limit=\(min(max(limit, 1), 50))"
        if let cursor { path += "&cursor=\(escaped(cursor))" }
        let value: AtmoV2PostPage = try await request(path)
        try validate(value.authority, value.version)
        return value
    }

    public func create(_ draft: AtmoV2PostDraft) async throws -> AtmoV2Post {
        let value: AtmoV2CreateEnvelope = try await request("/posts", method: .post, body: draft)
        try validate(value.authority, value.version)
        return value.post
    }

    public func requestPhotoUpload(mimeType: String, bytes: Int) async throws -> AtmoV2UploadTicket {
        struct Input: Encodable { let mimeType: String; let bytes: Int }
        let value: AtmoV2UploadTicket = try await request(
            "/media/upload-url", method: .post,
            body: Input(mimeType: mimeType, bytes: bytes)
        )
        try validate(value.authority, value.version)
        return value
    }

    public func edit(postID: String, body: String?, isSpoiler: Bool, commentsDisabled: Bool) async throws -> AtmoV2Post {
        struct Input: Encodable { let body: String?; let isSpoiler: Bool; let commentsDisabled: Bool }
        return try await postMutation(
            "/posts/\(escaped(postID))", method: .patch,
            body: Input(body: body, isSpoiler: isSpoiler, commentsDisabled: commentsDisabled)
        )
    }

    public func delete(postID: String) async throws {
        let _: AtmoV2DeletedEnvelope = try await request("/posts/\(escaped(postID))", method: .delete)
    }

    public func setFollowing(userID: String, following: Bool) async throws -> Bool {
        let value: AtmoV2FollowEnvelope = try await request(
            "/profiles/\(escaped(userID))/follow", method: following ? .put : .delete
        )
        return value.following
    }

    public func comments(postID: String, cursor: String? = nil) async throws -> AtmoV2CommentPage {
        var path = "/posts/\(escaped(postID))/comments?limit=20"
        if let cursor { path += "&cursor=\(escaped(cursor))" }
        return try await request(path)
    }

    public func addComment(postID: String, content: String, parentID: String? = nil) async throws -> AtmoV2Comment {
        struct Input: Encodable { let content: String; let parentId: String? }
        let value: AtmoV2CommentEnvelope = try await request(
            "/posts/\(escaped(postID))/comments", method: .post,
            body: Input(content: content, parentId: parentID)
        )
        return value.comment
    }

    public func editComment(commentID: String, content: String) async throws -> AtmoV2Comment {
        struct Input: Encodable { let content: String }
        let value: AtmoV2CommentEnvelope = try await request(
            "/comments/\(escaped(commentID))", method: .patch, body: Input(content: content)
        )
        return value.comment
    }

    public func deleteComment(commentID: String) async throws {
        let _: AtmoV2DeletedEnvelope = try await request("/comments/\(escaped(commentID))", method: .delete)
    }

    public func setCommentLiked(commentID: String, liked: Bool) async throws -> (Bool, Int) {
        let value: AtmoV2CommentLikeEnvelope = try await request(
            "/comments/\(escaped(commentID))/like", method: liked ? .put : .delete
        )
        return (value.liked, value.likeCount)
    }

    public func setEnergy(postID: String, energy: AtmoV2EnergyDraft?) async throws -> AtmoV2Post {
        if let energy {
            return try await postMutation("/posts/\(escaped(postID))/energy", method: .put, body: energy)
        }
        return try await postMutation("/posts/\(escaped(postID))/energy", method: .delete)
    }

    public func setPinned(postID: String, pinned: Bool) async throws -> Bool {
        let value: AtmoV2PinEnvelope = try await request(
            "/posts/\(escaped(postID))/pin", method: pinned ? .put : .delete
        )
        return value.pinned
    }

    public func vote(postID: String, optionIDs: [String]) async throws -> AtmoV2Post {
        struct Input: Encodable { let optionIds: [String] }
        return try await postMutation(
            "/posts/\(escaped(postID))/poll/vote", method: .put,
            body: Input(optionIds: optionIDs)
        )
    }

    public func recordShare(postID: String, channel: String) async throws {
        struct Input: Encodable { let channel: String }
        struct Envelope: Decodable { let share: Share }
        struct Share: Decodable { let id: String }
        let _: Envelope = try await request(
            "/posts/\(escaped(postID))/share", method: .post, body: Input(channel: channel)
        )
    }

    private func postMutation<T: Encodable>(
        _ path: String, method: AtmoV2HTTPMethod, body: T
    ) async throws -> AtmoV2Post {
        let value: AtmoV2PostEnvelope = try await request(path, method: method, body: body)
        return value.post
    }

    private func postMutation(_ path: String, method: AtmoV2HTTPMethod) async throws -> AtmoV2Post {
        let value: AtmoV2PostEnvelope = try await request(path, method: method)
        return value.post
    }

    private func request<Response: Decodable>(
        _ suffix: String, method: AtmoV2HTTPMethod = .get
    ) async throws -> Response {
        try enabled()
        let data = try await transport.atmoV2Data(path: AtmoV2Authority.basePath + suffix, method: method, body: nil)
        return try decoder.decode(Response.self, from: data)
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ suffix: String, method: AtmoV2HTTPMethod, body: Body
    ) async throws -> Response {
        try enabled()
        let data = try await transport.atmoV2Data(
            path: AtmoV2Authority.basePath + suffix, method: method, body: try encoder.encode(body)
        )
        return try decoder.decode(Response.self, from: data)
    }

    private func enabled() throws {
        guard rollout.mayProbeServer else { throw AtmoV2RepositoryError.disabled }
    }

    private func validate(_ authority: String, _ version: Int) throws {
        guard authority == AtmoV2Authority.value, version == AtmoV2Authority.version else {
            throw AtmoV2RepositoryError.invalidAuthority
        }
    }

    private func escaped(_ value: String) -> String {
        // One encoder is deliberately strict enough for both opaque query
        // cursors and path segments: separators must never escape their field.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}

// MARK: - The Atmosphere v2

/// The root feed is a distinct Westreem-owned aggregate. It intentionally
/// does not share the Personal Atmo path prefix and never falls back to the
/// retired Fan Club subscriptions feed.
public enum AtmosphereV2Authority {
    public static let value = AtmoV2Authority.value
    public static let version = AtmoV2Authority.version
    public static let feedPath = "/api/v2/atmosphere/feed"
    public static let maximumPageSize = 40
}

public struct AtmosphereV2HighlightAuthor: Decodable, Equatable, Sendable {
    public let matrixUserId: String
    public let westreemUserId: String?
    public let name: String?
    public let handle: String?
    public let image: String?
}

public struct AtmosphereV2HighlightPresentation: Decodable, Equatable, Sendable {
    public let body: String
    public let roomName: String?
    public let canonicalUrl: String?
    public let author: AtmosphereV2HighlightAuthor
}

public struct AtmosphereV2PublicHighlight: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authority: String
    public let kind: String
    public let explicitHighlight: Bool
    public let roomId: String
    public let eventId: String
    public let visibility: String
    public let encrypted: Bool
    public let redacted: Bool
    public let deleted: Bool
    public let moderated: Bool
    public let shareAllowed: Bool
    public let occurredAt: String
    public let presentation: AtmosphereV2HighlightPresentation
}

public enum AtmosphereV2FeedItem: Identifiable, Sendable {
    case atmoPost(
        id: String,
        occurredAt: String,
        reason: String,
        post: AtmoV2Post
    )
    case video(
        id: String,
        occurredAt: String,
        reason: String,
        video: AtmosphereVideo
    )
    case publicVibeHighlight(
        id: String,
        occurredAt: String,
        highlight: AtmosphereV2PublicHighlight
    )

    public var id: String {
        switch self {
        case .atmoPost(let id, _, _, _),
             .video(let id, _, _, _),
             .publicVibeHighlight(let id, _, _):
            id
        }
    }

    public var occurredAt: String {
        switch self {
        case .atmoPost(_, let occurredAt, _, _),
             .video(_, let occurredAt, _, _),
             .publicVibeHighlight(_, let occurredAt, _):
            occurredAt
        }
    }
}

private struct AtmosphereV2RawFeedItem: Decodable {
    let id: String
    let kind: String
    let occurredAt: String
    let reason: String
    let post: AtmoV2Post?
    let video: AtmosphereVideo?
    let highlight: AtmosphereV2PublicHighlight?

    func validated() -> AtmosphereV2FeedItem? {
        guard id.count <= 1_024, Self.validDate(occurredAt) else { return nil }
        switch kind {
        case "ATMO_POST":
            guard
                let post,
                id == "atmo:\(post.id)",
                post.status == "PUBLISHED",
                !post.id.isEmpty,
                !post.author.id.isEmpty,
                ["OWN_POST", "FOLLOWED_USER", "RECOMMENDED", "CURATED"].contains(reason)
            else { return nil }
            return .atmoPost(
                id: id,
                occurredAt: occurredAt,
                reason: reason,
                post: post
            )
        case "VIDEO":
            guard
                let video,
                id == "video:\(video.id)",
                video.type.lowercased() == "video",
                (
                    reason == "FOLLOWED_CHANNEL" && video.channel != nil
                    || reason == "FOLLOWED_SHOW" && video.show != nil
                )
            else { return nil }
            return .video(
                id: id,
                occurredAt: occurredAt,
                reason: reason,
                video: video
            )
        case "MATRIX_HIGHLIGHT":
            guard
                let highlight,
                reason == "EXPLICIT_VIBE_HIGHLIGHT",
                id == "matrix:\(highlight.roomId):\(highlight.eventId)",
                highlight.schemaVersion == 1,
                highlight.authority == "MATRIX",
                highlight.kind == "PUBLIC_HIGHLIGHT",
                highlight.explicitHighlight,
                highlight.visibility == "PUBLIC",
                !highlight.encrypted,
                !highlight.redacted,
                !highlight.deleted,
                !highlight.moderated,
                highlight.shareAllowed,
                highlight.occurredAt == occurredAt,
                !highlight.roomId.isEmpty,
                !highlight.eventId.isEmpty,
                !highlight.presentation.author.matrixUserId.isEmpty,
                !highlight.presentation.body.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            else { return nil }
            return .publicVibeHighlight(
                id: id,
                occurredAt: occurredAt,
                highlight: highlight
            )
        default:
            // Future server item types stay invisible until the native client
            // has an explicit safe presentation and authority contract.
            return nil
        }
    }

    private static func validDate(_ value: String) -> Bool {
        let standard = ISO8601DateFormatter()
        if standard.date(from: value) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil
    }
}

public struct AtmosphereV2FeedPage: Decodable, Sendable {
    public let authority: String
    public let version: Int
    public let items: [AtmosphereV2FeedItem]
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case authority, version, items, nextCursor
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        authority = try values.decode(String.self, forKey: .authority)
        version = try values.decode(Int.self, forKey: .version)
        let raw = try values.decode(
            [AtmosphereV2RawFeedItem].self,
            forKey: .items
        )
        items = raw.compactMap { $0.validated() }
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

public actor WestreemAtmosphereV2Repository {
    public static let authority = AtmosphereV2Authority.value

    private let transport: any AtmoV2Transport
    private let rollout: AtmoV2Rollout
    private let decoder = JSONDecoder()

    public init(transport: any AtmoV2Transport, rollout: AtmoV2Rollout) {
        self.transport = transport
        self.rollout = rollout
    }

    public func page(
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> AtmosphereV2FeedPage {
        guard rollout.mayProbeServer else {
            throw AtmoV2RepositoryError.disabled
        }
        guard cursor.map(Self.validCursor) ?? true else {
            throw AtmoV2RepositoryError.invalidPayload
        }
        let boundedLimit = min(
            max(limit, 1),
            AtmosphereV2Authority.maximumPageSize
        )
        var path = "\(AtmosphereV2Authority.feedPath)?limit=\(boundedLimit)"
        if let cursor {
            path += "&cursor=\(Self.escape(cursor))"
        }
        let data = try await transport.atmoV2Data(
            path: path,
            method: .get,
            body: nil
        )
        let value = try decoder.decode(AtmosphereV2FeedPage.self, from: data)
        guard
            value.authority == AtmosphereV2Authority.value,
            value.version == AtmosphereV2Authority.version
        else {
            throw AtmoV2RepositoryError.invalidAuthority
        }
        guard value.nextCursor.map(Self.validCursor) ?? true else {
            throw AtmoV2RepositoryError.invalidPayload
        }
        return value
    }

    private static func validCursor(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 4_096
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
                ).contains($0)
            }
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn:
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
            )
        ) ?? ""
    }
}
