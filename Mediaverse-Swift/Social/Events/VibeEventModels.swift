import Foundation

/// Additive bridge between the canonical Westreem Event and its optional
/// Matrix-backed live conversation. Absent data preserves the existing Event
/// experience and never provisions or joins a room from the client.
struct VibeEventRealtimeExperience: Codable, Hashable, Sendable {
    let transport: String
    let schemaVersion: Int
    let roomMode: String?
    let liveMode: String?
    let provisioningStatus: String?
    let conversationEnabled: Bool
    let presenceEnabled: Bool
    let voiceLoungeEnabled: Bool
    let watchPartyEnabled: Bool
    let opensAt: String?
    let closesAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "LEGACY"
        schemaVersion = max(0, try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0)
        roomMode = try c.decodeIfPresent(String.self, forKey: .roomMode)
        liveMode = try c.decodeIfPresent(String.self, forKey: .liveMode)
        provisioningStatus = try c.decodeIfPresent(String.self, forKey: .provisioningStatus)
        conversationEnabled = try c.decodeIfPresent(Bool.self, forKey: .conversationEnabled) ?? false
        presenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .presenceEnabled) ?? false
        voiceLoungeEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceLoungeEnabled) ?? false
        watchPartyEnabled = try c.decodeIfPresent(Bool.self, forKey: .watchPartyEnabled) ?? false
        opensAt = try c.decodeIfPresent(String.self, forKey: .opensAt)
        closesAt = try c.decodeIfPresent(String.self, forKey: .closesAt)
    }

    var isMatrixReady: Bool {
        transport.caseInsensitiveCompare("MATRIX") == .orderedSame
            && schemaVersion > 0
            && provisioningStatus == "READY"
    }
}

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

struct VibeEventWaveIdentity: Codable, Hashable, Sendable {
    let id: String
    let slug: String
    let name: String
    let type: String
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
    let viewerRsvpStatus: String?
    let capacity: Int?
    let replayUrl: String?
    let realtimeExperience: VibeEventRealtimeExperience?
    let club: VibeEventIdentity
    let wave: VibeEventWaveIdentity?
    let affiliatedShow: VibeEventAffiliation?
    let affiliatedChannel: VibeEventAffiliation?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        coverFocus = try c.decodeIfPresent(String.self, forKey: .coverFocus)
        startsAt = try c.decode(String.self, forKey: .startsAt)
        endsAt = try c.decodeIfPresent(String.self, forKey: .endsAt) ?? startsAt
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? "UTC"
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "PUBLIC"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "SCHEDULED"
        goingCount = try c.decodeIfPresent(Int.self, forKey: .goingCount) ?? 0
        interestedCount = try c.decodeIfPresent(Int.self, forKey: .interestedCount) ?? 0
        waitlistCount = try c.decodeIfPresent(Int.self, forKey: .waitlistCount) ?? 0
        viewerRsvpStatus = try c.decodeIfPresent(String.self, forKey: .viewerRsvpStatus)
        capacity = try c.decodeIfPresent(Int.self, forKey: .capacity)
        replayUrl = try c.decodeIfPresent(String.self, forKey: .replayUrl)
        realtimeExperience = try c.decodeIfPresent(
            VibeEventRealtimeExperience.self,
            forKey: .realtimeExperience
        )
        club = try c.decode(VibeEventIdentity.self, forKey: .club)
        wave = try c.decodeIfPresent(VibeEventWaveIdentity.self, forKey: .wave)
        affiliatedShow = try c.decodeIfPresent(VibeEventAffiliation.self, forKey: .affiliatedShow)
        affiliatedChannel = try c.decodeIfPresent(VibeEventAffiliation.self, forKey: .affiliatedChannel)
    }
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
    let joinOpensAt: String?
    let joinClosesAt: String?
    let replayUrl: String?
    let rsvpDeadline: String?
    let agenda: [VibeEventAgendaItem]
    let topics: [String]
    let goingCount: Int
    let interestedCount: Int
    let waitlistCount: Int
    let capacity: Int?
    let club: VibeEventIdentity
    let wave: VibeEventWaveIdentity?
    let hosts: [VibeEventHostModel]
    let affiliatedShow: VibeEventAffiliation?
    let affiliatedChannel: VibeEventAffiliation?
    let rsvps: [VibeEventRSVP]
    let associatedPost: VibeEventRippleSummary?
    let realtimeExperience: VibeEventRealtimeExperience?
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
    let canJoin: Bool
    let joinWindowOpen: Bool
    let joinWindowState: String
    let joinOpensAt: String?
    let joinClosesAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canManage = try c.decodeIfPresent(Bool.self, forKey: .canManage) ?? false
        canRsvp = try c.decodeIfPresent(Bool.self, forKey: .canRsvp) ?? false
        canShare = try c.decodeIfPresent(Bool.self, forKey: .canShare) ?? false
        canJoin = try c.decodeIfPresent(Bool.self, forKey: .canJoin) ?? false
        joinWindowOpen = try c.decodeIfPresent(Bool.self, forKey: .joinWindowOpen) ?? false
        joinWindowState = try c.decodeIfPresent(String.self, forKey: .joinWindowState) ?? "unavailable"
        joinOpensAt = try c.decodeIfPresent(String.self, forKey: .joinOpensAt)
        joinClosesAt = try c.decodeIfPresent(String.self, forKey: .joinClosesAt)
    }
}

struct VibeEventListResponse: Codable, Sendable {
    let events: [VibeEventCardModel]
    let nextCursor: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([VibeEventCardModel].self, forKey: .events) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}
struct VibeEventDetailResponse: Codable, Sendable {
    let event: VibeEventDetailModel
    let capabilities: VibeEventCapabilities
}
struct VibeEventRSVPResponse: Codable, Sendable { let rsvp: VibeEventRSVP }
struct VibeEventRSVPCounts: Codable, Sendable {
    let goingCount: Int
    let interestedCount: Int
    let waitlistCount: Int

    init(goingCount: Int, interestedCount: Int, waitlistCount: Int) {
        self.goingCount = goingCount
        self.interestedCount = interestedCount
        self.waitlistCount = waitlistCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goingCount = try c.decodeIfPresent(Int.self, forKey: .goingCount) ?? 0
        interestedCount = try c.decodeIfPresent(Int.self, forKey: .interestedCount) ?? 0
        waitlistCount = try c.decodeIfPresent(Int.self, forKey: .waitlistCount) ?? 0
    }
}
struct VibeEventRSVPMutation: Sendable {
    let rsvp: VibeEventRSVP
    let counts: VibeEventRSVPCounts?
}

struct VibeEventReminder: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let leadMinutes: Int
    let channel: String
    let sentAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 15
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? "push"
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt)
    }
}

struct VibeEventRemindersResponse: Codable, Sendable {
    let reminders: [VibeEventReminder]
}

struct VibeEventReminderResponse: Codable, Sendable {
    let reminder: VibeEventReminder
}

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
    let waveId: String?
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
    let joinOpensAt: String?
    let joinClosesAt: String?
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
