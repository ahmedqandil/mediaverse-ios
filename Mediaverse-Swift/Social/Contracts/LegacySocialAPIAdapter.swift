import Foundation

/// Minimal transport seam implemented by the existing authenticated API client.
/// The social layer owns no cookies, tokens, retry policy, or backend behavior.
public protocol LegacySocialTransport: Sendable {
    func socialData(path: String) async throws -> Data
    func socialPostData(path: String, body: Data) async throws -> Data
    func socialPatchData(path: String, body: Data) async throws -> Data
    func socialDeleteData(path: String) async throws -> Data
    func socialUploadData(path: String, body: Data, contentType: String) async throws -> Data
}

public enum SocialDiscoverMode: String, Sendable {
    case forYou = "FOR_YOU"
    case trending = "TRENDING"
    case latest = "LATEST"
    case affiliated = "AFFILIATED"
}

public enum SocialProfileTab: String, Sendable {
    case atmosphere = "ATMO"
    case echoed = "ECHOED"
    case mentions = "MENTIONS"
}

public enum LegacySocialAPIError: Error, Equatable {
    case invalidPath
    case invalidEnergy
    case invalidPollSelection
    case invalidPhoto
}

/// Adapter for the currently deployed, intentionally frozen social endpoints.
///
/// Each endpoint keeps its own envelope and pagination scheme. The adapter
/// prevents those legacy differences from leaking into native feature views.
public actor LegacySocialAPIAdapter {
    private let transport: any LegacySocialTransport
    private let decoder: JSONDecoder

    public init(transport: any LegacySocialTransport, decoder: JSONDecoder = JSONDecoder()) {
        self.transport = transport
        self.decoder = decoder
    }

    public func atmosphere() async throws -> AtmosphereFeed {
        try await decode(AtmosphereFeed.self, path: "/api/subscriptions/feed")
    }

    public func discover(
        mode: SocialDiscoverMode,
        cursor: String? = nil,
        limit: Int = 20,
        authorHandle: String? = nil,
        profileTab: SocialProfileTab? = nil
    ) async throws -> DiscoverRipplePageResponse {
        var query = [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 40)))
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let authorHandle {
            let normalized = authorHandle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "@", with: "")
            if !normalized.isEmpty {
                query.append(URLQueryItem(name: "author", value: normalized))
            }
        }
        if let profileTab {
            query.append(URLQueryItem(name: "profileTab", value: profileTab.rawValue))
        }
        return try await decode(
            DiscoverRipplePageResponse.self,
            path: try path("/api/fan-clubs/discover", query: query)
        )
    }

    public func vibe(slug: String) async throws -> VibeDetailResponse {
        try await decode(
            VibeDetailResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))"
        )
    }

    public func vibeRipples(slug: String, cursor: String? = nil) async throws -> RipplePageResponse {
        let base = "/api/fan-clubs/\(try segment(slug))/posts"
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await decode(RipplePageResponse.self, path: try path(base, query: query))
    }

    public func vibeAffiliations(slug: String) async throws -> [VibeAffiliation] {
        try await decode(
            VibeAffiliationsResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/affiliations"
        ).affiliations
    }

    public func affiliationTargets(
        slug: String,
        type: VibeAffiliationEntityType,
        query: String
    ) async throws -> [VibeAffiliationTarget] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await decode(
            VibeAffiliationTargetsResponse.self,
            path: try path(
                "/api/fan-clubs/\(try segment(slug))/affiliation-targets",
                query: [
                    URLQueryItem(name: "type", value: type.rawValue),
                    URLQueryItem(name: "q", value: normalized)
                ]
            )
        ).results
    }

    public func requestAffiliation(
        slug: String,
        entityType: VibeAffiliationEntityType,
        entityId: String,
        message: String? = nil,
        isPrimary: Bool = false
    ) async throws -> VibeAffiliation {
        let normalizedMessage = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONEncoder().encode(
            VibeAffiliationRequest(
                entityType: entityType,
                entityId: entityId,
                requestMessage: normalizedMessage?.isEmpty == false ? normalizedMessage : nil,
                isPrimary: isPrimary
            )
        )
        return try await post(
            VibeAffiliationResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/affiliations",
            body: body
        ).affiliation
    }

    public func cancelAffiliation(slug: String, affiliationId: String) async throws {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-clubs/\(try segment(slug))/affiliations/\(try segment(affiliationId))"
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
    }

    public func reviewableAffiliations(
        status: VibeAffiliationStatus? = nil
    ) async throws -> AffiliationReviewQueueResponse {
        let query = status.map { [URLQueryItem(name: "status", value: $0.rawValue)] } ?? []
        return try await decode(
            AffiliationReviewQueueResponse.self,
            path: try path("/api/backstage/affiliations", query: query)
        )
    }

    public func reviewAffiliation(
        id: String,
        action: AffiliationReviewAction,
        note: String? = nil,
        relationship: VibeAffiliationRelationship = .affiliatedCommunity
    ) async throws -> AffiliationReviewDecisionResponse {
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONEncoder().encode(
            AffiliationReviewRequest(
                affiliationId: id,
                action: action,
                note: normalizedNote?.isEmpty == false ? normalizedNote : nil,
                relationshipType: relationship
            )
        )
        let data = try await transport.socialPatchData(
            path: "/api/backstage/affiliations",
            body: body
        )
        return try decoder.decode(AffiliationReviewDecisionResponse.self, from: data)
    }

    public func ripple(postId: String) async throws -> Ripple {
        try await decode(
            RippleDetailResponse.self,
            path: "/api/fan-club-posts/\(try segment(postId))"
        ).post
    }

    public func rippleComments(postId: String) async throws -> [RippleComment] {
        try await decode(
            RippleCommentsResponse.self,
            path: "/api/fan-club-posts/\(try segment(postId))/comments"
        ).comments
    }

    public func createRippleComment(
        postId: String,
        content: String,
        parentId: String?
    ) async throws -> RippleComment {
        let body = try JSONEncoder().encode(
            RippleCommentRequest(content: content, parentId: parentId)
        )
        return try await post(
            RippleCommentResponse.self,
            path: "/api/fan-club-posts/\(try segment(postId))/comments",
            body: body
        ).comment
    }

    public func toggleRippleCommentLike(commentId: String) async throws -> RippleCommentLikeResponse {
        try await post(
            RippleCommentLikeResponse.self,
            path: "/api/fan-club-comments/\(try segment(commentId))/like",
            body: Data("{}".utf8)
        )
    }

    public func ripplePhotoComments(attachmentId: String) async throws -> [RippleComment] {
        try await decode(
            RippleCommentsResponse.self,
            path: "/api/fan-club-attachments/\(try segment(attachmentId))/comments"
        ).comments
    }

    public func createRipplePhotoComment(
        attachmentId: String,
        content: String,
        parentId: String?
    ) async throws -> RippleComment {
        let body = try JSONEncoder().encode(
            RippleCommentRequest(content: content, parentId: parentId)
        )
        return try await post(
            RippleCommentResponse.self,
            path: "/api/fan-club-attachments/\(try segment(attachmentId))/comments",
            body: body
        ).comment
    }

    public func toggleRipplePhotoCommentLike(commentId: String) async throws -> RippleCommentLikeResponse {
        try await post(
            RippleCommentLikeResponse.self,
            path: "/api/fan-club-attachment-comments/\(try segment(commentId))/like",
            body: Data("{}".utf8)
        )
    }

    public func ripplePhotoEnergy(attachmentId: String) async throws -> RippleEnergyResponse {
        try await decode(
            RippleEnergyResponse.self,
            path: "/api/fan-club-attachments/\(try segment(attachmentId))/rating"
        )
    }

    public func addEnergy(
        toPhoto attachmentId: String,
        overall: Int,
        tags: [String]
    ) async throws -> RippleEnergySelection {
        guard (1...5).contains(overall) else { throw LegacySocialAPIError.invalidEnergy }
        let normalizedTags = Array(
            Set(tags.compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
            })
        )
        .sorted()
        .prefix(10)
        return try await post(
            RippleEnergySelection.self,
            path: "/api/fan-club-attachments/\(try segment(attachmentId))/rating",
            body: try JSONEncoder().encode(
                RippleEnergyRequest(overall: overall, tags: Array(normalizedTags))
            )
        )
    }

    public func removeEnergy(fromPhoto attachmentId: String) async throws {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-club-attachments/\(try segment(attachmentId))/rating"
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
    }

    public func myVibes(cursor: String? = nil, limit: Int = 24) async throws -> VibeListResponse {
        var query = [
            URLQueryItem(name: "mine", value: "1"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await decode(
            VibeListResponse.self,
            path: try path("/api/fan-clubs", query: query)
        )
    }

    public func ensurePersonalVibe() async throws -> VibeSummary {
        try await post(
            PersonalVibeResponse.self,
            path: "/api/me/personal-vibe",
            body: Data("{}".utf8)
        ).vibe
    }

    public func postableVibes() async throws -> [PostableVibe] {
        try await decode(PostableVibesResponse.self, path: "/api/fan-clubs/postable").vibes
    }

    public func createRipple(
        inVibe slug: String,
        body: String?,
        attachments: [RippleCreateAttachment],
        poll: RipplePollDraft? = nil,
        isSpoiler: Bool = false,
        commentsDisabled: Bool = false
    ) async throws -> Ripple {
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateRippleRequest(
            body: trimmedBody?.isEmpty == false ? trimmedBody : nil,
            isSpoiler: isSpoiler,
            commentsDisabled: commentsDisabled,
            attachments: attachments,
            poll: poll
        )
        return try await post(
            CreateRippleResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/posts",
            body: try JSONEncoder().encode(request)
        ).post
    }

    public func resolveAttachment(url: String) async throws -> ResolvedRippleAttachmentResponse {
        try await post(
            ResolvedRippleAttachmentResponse.self,
            path: "/api/fan-clubs/resolve-attachment",
            body: try JSONEncoder().encode(ResolveAttachmentRequest(url: url))
        )
    }

    public func uploadRipplePhoto(
        toVibe slug: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRipplePhoto {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw LegacySocialAPIError.invalidPhoto
        }
        let prepared = try await post(
            RipplePhotoUploadPreparation.self,
            path: "/api/fan-clubs/\(try segment(slug))/images/upload-url?purpose=post",
            body: try JSONEncoder().encode(
                RipplePhotoUploadRequest(mimeType: mimeType, size: data.count)
            )
        )
        let uploaded = try decoder.decode(
            RipplePhotoUploadResult.self,
            from: try await transport.socialUploadData(
                path: prepared.uploadURL,
                body: data,
                contentType: mimeType
            )
        )
        guard let imageURL = uploaded.mediaURL ?? prepared.mediaURL ?? nonempty(prepared.deliveryURL)
        else {
            throw LegacySocialAPIError.invalidPhoto
        }
        return UploadedRipplePhoto(
            imageURL: imageURL,
            objectKey: prepared.objectKey
        )
    }

    public func followVibe(slug: String) async throws -> VibeFollowResponse {
        try await post(
            VibeFollowResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/follow",
            body: Data("{}".utf8)
        )
    }

    public func unfollowVibe(slug: String) async throws -> VibeFollowResponse {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-clubs/\(try segment(slug))/follow"
        )
        return try decoder.decode(VibeFollowResponse.self, from: data)
    }

    public func joinVibe(slug: String, message: String? = nil) async throws -> VibeJoinResponse {
        let body = try JSONEncoder().encode(VibeJoinRequest(message: message))
        return try await post(
            VibeJoinResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/join",
            body: body
        )
    }

    public func leaveVibe(slug: String) async throws {
        _ = try await transport.socialDeleteData(
            path: "/api/fan-clubs/\(try segment(slug))/join"
        )
    }

    public func addEnergy(
        toRipple postId: String,
        overall: Int,
        tags: [String]
    ) async throws -> RippleEnergySelection {
        guard (1...5).contains(overall) else { throw LegacySocialAPIError.invalidEnergy }
        let normalizedTags = Array(
            Set(tags.compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
            })
        )
        .sorted()
        .prefix(10)
        let body = try JSONEncoder().encode(
            RippleEnergyRequest(overall: overall, tags: Array(normalizedTags))
        )
        return try await post(
            RippleEnergySelection.self,
            path: "/api/fan-club-posts/\(try segment(postId))/rating",
            body: body
        )
    }

    public func rippleEnergy(postId: String) async throws -> RippleEnergyResponse {
        try await decode(
            RippleEnergyResponse.self,
            path: "/api/fan-club-posts/\(try segment(postId))/rating"
        )
    }

    public func vote(
        inPoll pollId: String,
        optionIds: [String]
    ) async throws -> RipplePollVoteResponse {
        let options = Array(Set(optionIds.filter { !$0.isEmpty })).sorted()
        guard !options.isEmpty else { throw LegacySocialAPIError.invalidPollSelection }
        let body = try JSONEncoder().encode(RipplePollVoteRequest(optionIds: options))
        return try await post(
            RipplePollVoteResponse.self,
            path: "/api/fan-club-polls/\(try segment(pollId))/vote",
            body: body
        )
    }

    public func recordShare(
        ofRipple postId: String,
        channel: RippleShareChannel
    ) async throws -> RippleShareResult {
        let body = try JSONEncoder().encode(RippleShareRequest(channel: channel.rawValue))
        return try await post(
            RippleShareResult.self,
            path: "/api/fan-club-posts/\(try segment(postId))/share",
            body: body
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await transport.socialData(path: path)
        return try decoder.decode(type, from: data)
    }

    private func post<T: Decodable>(_ type: T.Type, path: String, body: Data) async throws -> T {
        let data = try await transport.socialPostData(path: path, body: body)
        return try decoder.decode(type, from: data)
    }

    private func segment(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .socialPathSegment)
        else {
            throw LegacySocialAPIError.invalidPath
        }
        return encoded
    }

    private func path(_ path: String, query: [URLQueryItem]) throws -> String {
        guard !query.isEmpty else { return path }
        let pairs = try query.map { item -> String in
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: .socialQueryComponent),
                  let rawValue = item.value,
                  let value = rawValue.addingPercentEncoding(withAllowedCharacters: .socialQueryComponent)
            else {
                throw LegacySocialAPIError.invalidPath
            }
            return "\(name)=\(value)"
        }
        return "\(path)?\(pairs.joined(separator: "&"))"
    }
}

public enum RippleShareChannel: String, Sendable {
    case copyLink = "copy_link"
    case native
    case internalEcho = "internal"
}

public struct RippleEnergySelection: Codable, Equatable, Sendable {
    public let overall: Int
    public let tags: [String]
    public let review: String?
}

public struct RippleEnergyResponse: Decodable, Sendable {
    public let userRating: RippleEnergySelection?
    public let aggregate: RippleEnergyAggregate
}

public struct RippleEnergyAggregate: Decodable, Sendable {
    public let avg: Double?
    public let count: Int
    public let distribution: [String: Int]
    public let topTags: [String]
}

public struct RippleShareResult: Decodable, Equatable, Sendable {
    public let shareCount: Int
}

public struct RipplePollVoteResponse: Decodable, Sendable {
    public let poll: RipplePoll
}

private struct RippleEnergyRequest: Encodable {
    let overall: Int
    let tags: [String]
}

private struct RipplePollVoteRequest: Encodable {
    let optionIds: [String]
}

private struct RippleShareRequest: Encodable {
    let channel: String
}

private struct RippleCommentRequest: Encodable {
    let content: String
    let parentId: String?
}

private struct VibeAffiliationRequest: Encodable {
    let entityType: VibeAffiliationEntityType
    let entityId: String
    let requestMessage: String?
    let isPrimary: Bool
}

private struct AffiliationReviewRequest: Encodable {
    let affiliationId: String
    let action: AffiliationReviewAction
    let note: String?
    let relationshipType: VibeAffiliationRelationship
}

private struct CreateRippleRequest: Encodable {
    let body: String?
    let isSpoiler: Bool
    let commentsDisabled: Bool
    let attachments: [RippleCreateAttachment]
    let poll: RipplePollDraft?
}

private struct ResolveAttachmentRequest: Encodable {
    let url: String
}

private struct RipplePhotoUploadRequest: Encodable {
    let mimeType: String
    let size: Int
}

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private struct VibeJoinRequest: Encodable {
    let message: String?
}

private extension CharacterSet {
    static let socialPathSegment: CharacterSet = {
        var value = CharacterSet.urlPathAllowed
        value.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value
    }()

    static let socialQueryComponent: CharacterSet = {
        var value = CharacterSet.urlQueryAllowed
        value.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return value
    }()
}
