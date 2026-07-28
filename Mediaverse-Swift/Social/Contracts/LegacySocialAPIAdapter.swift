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

public enum SocialDiscoverMode: String, CaseIterable, Identifiable, Sendable {
    case forYou = "FOR_YOU"
    case trending = "TRENDING"
    case latest = "LATEST"
    case affiliated = "AFFILIATED"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forYou: "For You"
        case .trending: "Trending"
        case .latest: "Latest"
        case .affiliated: "Affiliated"
        }
    }
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

    public func createVibe(
        name: String,
        slug: String?,
        description: String,
        visibility: VibeVisibility,
        joinPolicy: VibeJoinPolicy,
        topics: [String],
        language: String? = nil,
        country: String? = nil
    ) async throws -> VibeSummary {
        let body = VibeCreateRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: slug?.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: visibility,
            joinPolicy: joinPolicy,
            topics: normalizedTopics(topics),
            language: nonempty(language),
            country: nonempty(country)?.uppercased()
        )
        return try await post(
            VibeMutationResponse.self,
            path: "/api/fan-clubs",
            body: try JSONEncoder().encode(body)
        ).club
    }

    public func updateVibe(slug: String, settings: VibeSettingsUpdate) async throws -> VibeSummary {
        let data = try await transport.socialPatchData(
            path: "/api/fan-clubs/\(try segment(slug))",
            body: try JSONEncoder().encode(settings)
        )
        return try decoder.decode(VibeMutationResponse.self, from: data).club
    }

    public func uploadVibeProfileImage(
        toVibe slug: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRipplePhoto {
        try await uploadVibeImage(toVibe: slug, purpose: "profile", data: data, mimeType: mimeType)
    }

    public func vibeRipples(slug: String, cursor: String? = nil, wave: String? = nil) async throws -> RipplePageResponse {
        let base = "/api/fan-clubs/\(try segment(slug))/posts"
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let wave { query.append(URLQueryItem(name: "wave", value: wave)) }
        return try await decode(RipplePageResponse.self, path: try path(base, query: query))
    }

    public func vibeWaves(slug: String) async throws -> [VibeWave] {
        try await decode(
            VibeWavesResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/waves"
        ).waves
    }

    public func waveNotificationSettings(vibeSlug: String, waveSlug: String) async throws -> VibeWaveSubscription {
        try await decode(
            VibeWaveNotificationSettingsResponse.self,
            path: "/api/fan-clubs/\(try segment(vibeSlug))/waves/\(try segment(waveSlug))/notification-settings"
        ).settings
    }

    public func updateWaveNotificationSettings(
        vibeSlug: String,
        waveSlug: String,
        notificationLevel: String,
        pushEnabled: Bool,
        emailEnabled: Bool
    ) async throws -> VibeWaveSubscription {
        let path = "/api/fan-clubs/\(try segment(vibeSlug))/waves/\(try segment(waveSlug))/notification-settings"
        let data = try await transport.socialPatchData(
            path: path,
            body: try JSONEncoder().encode(WaveNotificationSettingsRequest(
                notificationLevel: notificationLevel,
                pushEnabled: pushEnabled,
                emailEnabled: emailEnabled
            ))
        )
        return try decoder.decode(VibeWaveNotificationSettingsResponse.self, from: data).settings
    }

    public func vibeInvites(slug: String) async throws -> [VibeInvite] {
        try await decode(
            VibeInvitesResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/invites"
        ).invites
    }

    public func createVibeInvite(
        slug: String,
        invitedEmail: String? = nil,
        role: VibeInviteRole = .member,
        expiresInDays: Int = 7,
        maxUses: Int = 1
    ) async throws -> VibeInviteCreatedResponse {
        let normalizedEmail = invitedEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONEncoder().encode(
            VibeInviteCreateRequest(
                invitedEmail: normalizedEmail?.isEmpty == false ? normalizedEmail : nil,
                role: role,
                expiresInDays: min(max(expiresInDays, 1), 30),
                maxUses: min(max(maxUses, 1), 100)
            )
        )
        return try await post(
            VibeInviteCreatedResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/invites",
            body: body
        )
    }

    public func revokeVibeInvite(slug: String, inviteID: String) async throws {
        _ = try await transport.socialDeleteData(
            path: "/api/fan-clubs/\(try segment(slug))/invites/\(try segment(inviteID))"
        )
    }

    public func acceptVibeInvite(token: String) async throws -> VibeInviteAcceptanceResponse {
        try await post(
            VibeInviteAcceptanceResponse.self,
            path: "/api/fan-club-invites/\(try segment(token))/accept",
            body: Data("{}".utf8)
        )
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

    public func editRipple(
        postId: String,
        body: String,
        isSpoiler: Bool,
        commentsDisabled: Bool
    ) async throws -> EditedRipplePost {
        let data = try await transport.socialPatchData(
            path: "/api/fan-club-posts/\(try segment(postId))",
            body: try JSONEncoder().encode(
                EditRippleRequest(
                    body: body,
                    isSpoiler: isSpoiler,
                    commentsDisabled: commentsDisabled
                )
            )
        )
        return try decoder.decode(EditedRippleResponse.self, from: data).post
    }

    public func deleteRipple(postId: String) async throws {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-club-posts/\(try segment(postId))"
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
    }

    public func reportRipple(
        postId: String,
        vibeSlug: String,
        reason: String,
        details: String? = nil
    ) async throws -> VibeReportReceipt {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONEncoder().encode(
            VibeReportRequest(
                targetType: "POST",
                postId: postId,
                reason: normalizedReason,
                details: normalizedDetails?.isEmpty == false ? normalizedDetails : nil
            )
        )
        return try await post(
            VibeReportResponse.self,
            path: "/api/fan-clubs/\(try segment(vibeSlug))/reports",
            body: body
        ).report
    }

    public func moderationRipples(vibeSlug: String) async throws -> [ModerationRipple] {
        try await decode(
            ModerationRippleResponse.self,
            path: "/api/fan-clubs/\(try segment(vibeSlug))/moderation"
        ).posts
    }

    public func moderationReports(vibeSlug: String) async throws -> [ModerationReport] {
        try await decode(
            ModerationReportsResponse.self,
            path: "/api/fan-clubs/\(try segment(vibeSlug))/moderation?view=reports"
        ).reports
    }

    public func moderateRipple(
        postId: String,
        action: String,
        reason: String? = nil
    ) async throws {
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await transport.socialPostData(
            path: "/api/fan-club-posts/\(try segment(postId))/moderate",
            body: try JSONEncoder().encode(
                ModerationActionRequest(
                    action: action,
                    reason: normalizedReason?.isEmpty == false ? normalizedReason : nil
                )
            )
        )
    }

    public func resolveReport(
        vibeSlug: String,
        reportId: String,
        status: String,
        note: String? = nil
    ) async throws {
        let data = try await transport.socialPatchData(
            path: "/api/fan-clubs/\(try segment(vibeSlug))/reports/\(try segment(reportId))",
            body: try JSONEncoder().encode(
                ResolveReportRequest(
                    status: status,
                    resolutionNote: note?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
    }

    public func joinRequests(vibeSlug: String) async throws -> [VibePendingJoinRequest] {
        try await decode(
            VibeJoinRequestsResponse.self,
            path: "/api/fan-clubs/\(try segment(vibeSlug))/join-requests"
        ).requests
    }

    public func decideJoinRequest(
        vibeSlug: String,
        requestId: String,
        approve: Bool,
        note: String? = nil
    ) async throws {
        let data = try await transport.socialPatchData(
            path: "/api/fan-clubs/\(try segment(vibeSlug))/join-requests/\(try segment(requestId))",
            body: try JSONEncoder().encode(
                JoinRequestDecision(
                    decision: approve ? "approve" : "reject",
                    note: note?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
    }

    public func vibeMembers(
        vibeSlug: String,
        query: String? = nil,
        cursor: String? = nil
    ) async throws -> VibeMembersResponse {
        var items: [URLQueryItem] = []
        if let query {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { items.append(URLQueryItem(name: "q", value: normalized)) }
        }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await decode(
            VibeMembersResponse.self,
            path: try path(
                "/api/fan-clubs/\(try segment(vibeSlug))/members",
                query: items
            )
        )
    }

    public func updateVibeMember(
        vibeSlug: String,
        userId: String,
        role: String? = nil,
        status: String? = nil,
        reason: String? = nil,
        suspendedUntil: String? = nil
    ) async throws -> UpdatedVibeMember {
        let data = try await transport.socialPatchData(
            path: "/api/fan-clubs/\(try segment(vibeSlug))/members/\(try segment(userId))",
            body: try JSONEncoder().encode(
                UpdateVibeMemberRequest(
                    role: role,
                    status: status,
                    reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                    suspendedUntil: suspendedUntil
                )
            )
        )
        return try decoder.decode(UpdatedVibeMemberResponse.self, from: data).member
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

    public func editRippleComment(commentId: String, content: String) async throws -> RippleComment {
        let data = try await transport.socialPatchData(
            path: "/api/fan-club-comments/\(try segment(commentId))",
            body: try JSONEncoder().encode(RippleCommentEditRequest(content: content))
        )
        return try decoder.decode(RippleCommentResponse.self, from: data).comment
    }

    public func deleteRippleComment(commentId: String) async throws {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-club-comments/\(try segment(commentId))"
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
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

    public func editRipplePhotoComment(commentId: String, content: String) async throws -> RippleComment {
        let data = try await transport.socialPatchData(
            path: "/api/fan-club-attachment-comments/\(try segment(commentId))",
            body: try JSONEncoder().encode(RippleCommentEditRequest(content: content))
        )
        return try decoder.decode(RippleCommentResponse.self, from: data).comment
    }

    public func deleteRipplePhotoComment(commentId: String) async throws {
        let data = try await transport.socialDeleteData(
            path: "/api/fan-club-attachment-comments/\(try segment(commentId))"
        )
        _ = try decoder.decode(SocialOKResponse.self, from: data)
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
        commentsDisabled: Bool = false,
        waveId: String? = nil
    ) async throws -> Ripple {
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateRippleRequest(
            body: trimmedBody?.isEmpty == false ? trimmedBody : nil,
            isSpoiler: isSpoiler,
            commentsDisabled: commentsDisabled,
            attachments: attachments,
            poll: poll,
            waveId: waveId
        )
        return try await post(
            CreateRippleResponse.self,
            path: "/api/fan-clubs/\(try segment(slug))/posts",
            body: try JSONEncoder().encode(request)
        ).post
    }

    public func setRipplePinned(postId: String, pinned: Bool) async throws -> RipplePinMutation.Post {
        struct Request: Encodable { let pinned: Bool }
        let data = try await transport.socialPatchData(
            path: "/api/fan-club-posts/\(try segment(postId))",
            body: try JSONEncoder().encode(Request(pinned: pinned))
        )
        return try decoder.decode(RipplePinMutation.self, from: data).post
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
        try await uploadVibeImage(toVibe: slug, purpose: "post", data: data, mimeType: mimeType)
    }

    private func uploadVibeImage(
        toVibe slug: String,
        purpose: String,
        data: Data,
        mimeType: String
    ) async throws -> UploadedRipplePhoto {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw LegacySocialAPIError.invalidPhoto
        }
        let prepared = try await post(
            RipplePhotoUploadPreparation.self,
            path: "/api/fan-clubs/\(try segment(slug))/images/upload-url?purpose=\(purpose)",
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

    public func removeEnergy(fromRipple postId: String) async throws {
        _ = try await transport.socialDeleteData(
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

    private enum CodingKeys: String, CodingKey {
        case avg, count, distribution, topTags
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        avg = try values.decodeIfPresent(Double.self, forKey: .avg)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        distribution = try values.decodeIfPresent([String: Int].self, forKey: .distribution) ?? [:]
        if let strings = try? values.decode([String].self, forKey: .topTags) {
            topTags = strings
        } else if let keywords = try? values.decode([RippleEnergyKeyword].self, forKey: .topTags) {
            topTags = keywords.map(\.tag)
        } else if let counts = try? values.decode([String: Int].self, forKey: .topTags) {
            topTags = counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
        } else {
            topTags = []
        }
    }
}

private struct RippleEnergyKeyword: Decodable {
    let tag: String
    let count: Int?
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

private struct VibeCreateRequest: Encodable {
    let name: String
    let slug: String?
    let description: String
    let visibility: VibeVisibility
    let joinPolicy: VibeJoinPolicy
    let topics: [String]
    let language: String?
    let country: String?
}

private struct VibeInviteCreateRequest: Encodable {
    let invitedEmail: String?
    let role: VibeInviteRole
    let expiresInDays: Int
    let maxUses: Int
}

private struct AffiliationReviewRequest: Encodable {
    let affiliationId: String
    let action: AffiliationReviewAction
    let note: String?
    let relationshipType: VibeAffiliationRelationship
}

private struct EditRippleRequest: Encodable {
    let body: String
    let isSpoiler: Bool
    let commentsDisabled: Bool
}

private struct VibeReportRequest: Encodable {
    let targetType: String
    let postId: String
    let reason: String
    let details: String?
}

private struct ModerationActionRequest: Encodable {
    let action: String
    let reason: String?
}

private struct ResolveReportRequest: Encodable {
    let status: String
    let resolutionNote: String?
}

private struct JoinRequestDecision: Encodable {
    let decision: String
    let note: String?
}

private struct RippleCommentEditRequest: Encodable {
    let content: String
}

private struct UpdateVibeMemberRequest: Encodable {
    let role: String?
    let status: String?
    let reason: String?
    let suspendedUntil: String?
}


private struct CreateRippleRequest: Encodable {
    let body: String?
    let isSpoiler: Bool
    let commentsDisabled: Bool
    let attachments: [RippleCreateAttachment]
    let poll: RipplePollDraft?
    let waveId: String?
}

private struct WaveNotificationSettingsRequest: Encodable {
    let notificationLevel: String
    let pushEnabled: Bool
    let emailEnabled: Bool
}

private struct ResolveAttachmentRequest: Encodable {
    let url: String
}

private struct RipplePhotoUploadRequest: Encodable {
    let mimeType: String
    let size: Int
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizedTopics(_ values: [String]) -> [String] {
    Array(
        Set(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    )
    .sorted()
    .prefix(12)
    .map { $0 }
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
