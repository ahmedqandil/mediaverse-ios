import Foundation

struct VibeEventIdentity: Codable, Hashable, Sendable {
    let id: String?
    let slug: String?
    let name: String
    let avatarUrl: String?
}

struct VibeEventAffiliation: Codable, Hashable, Sendable {
    let id: String?
    let title: String?
    let name: String?
    let handle: String?
}

struct VibeEventCardModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let title: String
    let summary: String
    let coverUrl: String?
    let coverFocus: String?
    let startsAt: String
    let endsAt: String
    let timeZone: String
    let visibility: String
    let status: String
    let goingCount: Int
    let interestedCount: Int
    let waitlistCount: Int
    let capacity: Int?
    let replayUrl: String?
    let club: VibeEventIdentity
    let affiliatedShow: VibeEventAffiliation?
    let affiliatedChannel: VibeEventAffiliation?
}

struct VibeEventHostIdentity: Codable, Hashable, Sendable {
    let id: String
    let name: String?
    let handle: String?
    let image: String?
}

struct VibeEventHostModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let role: String
    let user: VibeEventHostIdentity
}

struct VibeEventDetailModel: Codable, Identifiable, Sendable {
    let id: String
    let slug: String
    let title: String
    let summary: String
    let description: String?
    let coverUrl: String?
    let coverFocus: String?
    let startsAt: String
    let endsAt: String
    let timeZone: String
    let visibility: String
    let status: String
    let onlineUrl: String?
    let accessInstructions: String?
    let replayUrl: String?
    let rsvpDeadline: String?
    let agenda: [VibeEventAgendaItem]
    let topics: [String]
    let goingCount: Int
    let interestedCount: Int
    let waitlistCount: Int
    let capacity: Int?
    let club: VibeEventIdentity
    let hosts: [VibeEventHostModel]
    let affiliatedShow: VibeEventAffiliation?
    let affiliatedChannel: VibeEventAffiliation?
    let rsvps: [VibeEventRSVP]
    let associatedPost: VibeEventRippleSummary?
}

struct VibeEventAgendaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = value
            title = value
            detail = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? "Agenda item"
        detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        id = (try? container.decode(String.self, forKey: .id)) ?? title
    }

    private enum CodingKeys: String, CodingKey { case id, title, detail }
}

struct VibeEventRippleSummary: Codable, Hashable, Sendable {
    let id: String
    let commentCount: Int
    let echoCount: Int
    let energyCount: Int
    let energyTotal: Int
}

struct VibeEventRSVP: Codable, Sendable {
    let status: String
}

struct VibeEventCapabilities: Codable, Sendable {
    let canManage: Bool
    let canRsvp: Bool
    let canShare: Bool
}

struct VibeEventListResponse: Codable, Sendable { let events: [VibeEventCardModel] }
struct VibeEventDetailResponse: Codable, Sendable {
    let event: VibeEventDetailModel
    let capabilities: VibeEventCapabilities
}
struct VibeEventRSVPResponse: Codable, Sendable { let rsvp: VibeEventRSVP }

struct VibeEventTemplateModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let name: String
    let description: String
    let category: String
    let icon: String?
    let previewImageUrl: String?
    let previewAccent: String?
    let recommended: Bool
    let position: Int
    let allowedVisibility: [String]
    let defaultDuration: Int
    let version: Int
}
struct VibeEventTemplatesResponse: Codable, Sendable { let templates: [VibeEventTemplateModel] }

struct CreateVibeEventRequest: Encodable, Sendable {
    let templateId: String?
    let clubId: String
    let title: String
    let summary: String
    let description: String?
    let coverUrl: String?
    let coverFocus: String?
    let startsAt: String
    let endsAt: String
    let timeZone: String
    let onlineUrl: String?
    let accessInstructions: String?
    let visibility: String
    let capacity: Int?
    let rsvpDeadline: String?
    let topics: [String]
    let agenda: [VibeEventAgendaInput]
    let affiliatedShowId: String?
    let affiliatedChannelId: String?
    let replayUrl: String?
    let status: String
}
struct VibeEventAgendaInput: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var detail: String?
}
struct CreateVibeEventResponse: Decodable, Sendable { let event: CreatedVibeEvent }
struct CreatedVibeEvent: Decodable, Sendable { let id: String; let slug: String }

struct UpdateVibeEventResponse: Decodable, Sendable { let event: CreatedVibeEvent }

struct VibeEventInviteModel: Decodable, Identifiable, Sendable {
    let id: String
    let invitedEmail: String?
    let status: String
    let maxUses: Int
    let useCount: Int
    let expiresAt: String?
    let invitedUser: VibeEventHostIdentity?
}
struct VibeEventInvitesResponse: Decodable, Sendable { let invites: [VibeEventInviteModel] }
struct VibeEventCreateInviteResponse: Decodable, Sendable {
    let invite: VibeEventInviteModel
    let inviteUrl: String
}
struct VibeEventMutationResponse: Decodable, Sendable {
    let removed: Bool?
    let revoked: Bool?
}

struct VibeEventAttendeeModel: Decodable, Identifiable, Sendable {
    let id: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let user: VibeEventHostIdentity
}
struct VibeEventAttendeesResponse: Decodable, Sendable { let attendees: [VibeEventAttendeeModel] }
struct VibeEventHostsResponse: Decodable, Sendable { let hosts: [VibeEventHostModel] }
struct VibeEventHostMutation: Decodable, Sendable {
    let id: String
    let role: String
    let userId: String
}
struct VibeEventHostResponse: Decodable, Sendable { let host: VibeEventHostMutation }
struct VibeEventInvitePreviewResponse: Decodable, Sendable { let invite: VibeEventInvitePreview }
struct VibeEventInvitePreview: Decodable, Sendable {
    let id: String
    let status: String
    let event: VibeEventInviteEvent
}
struct VibeEventInviteEvent: Decodable, Sendable {
    let slug: String
    let title: String
    let summary: String
    let coverUrl: String?
    let startsAt: String
    let club: VibeEventIdentity
}
struct VibeEventInviteDecisionResponse: Decodable, Sendable {
    let accepted: Bool
    let eventSlug: String
}

struct VibeEventAnalyticsSummary: Decodable, Sendable {
    let viewCount: Int
    let joinCount: Int
    let goingCount: Int
    let interestedCount: Int
    let waitlistCount: Int
    let commentCount: Int
    let echoCount: Int
    let energyCount: Int

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        viewCount = try values.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        joinCount = try values.decodeIfPresent(Int.self, forKey: .joinCount) ?? 0
        goingCount = try values.decodeIfPresent(Int.self, forKey: .goingCount) ?? 0
        interestedCount = try values.decodeIfPresent(Int.self, forKey: .interestedCount) ?? 0
        waitlistCount = try values.decodeIfPresent(Int.self, forKey: .waitlistCount) ?? 0
        commentCount = try values.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        echoCount = try values.decodeIfPresent(Int.self, forKey: .echoCount) ?? 0
        energyCount = try values.decodeIfPresent(Int.self, forKey: .energyCount) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case viewCount, joinCount, goingCount, interestedCount, waitlistCount
        case commentCount, echoCount, energyCount
    }
}

struct VibeEventAnalyticsResponse: Decodable, Sendable {
    let analytics: VibeEventAnalyticsSummary

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        analytics = try values.decodeIfPresent(VibeEventAnalyticsSummary.self, forKey: .analytics)
            ?? VibeEventAnalyticsSummary(from: decoder)
    }

    private enum CodingKeys: String, CodingKey { case analytics }
}

extension ISO8601DateFormatter {
    static let vibeEvent: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension String {
    var vibeEventDate: Date? {
        ISO8601DateFormatter.vibeEvent.date(from: self) ?? ISO8601DateFormatter().date(from: self)
    }
}
