import CryptoKit
import Foundation

/// Machine-checkable acceptance boundary for the first production-native
/// Matrix Vibes UI cutover. The user's strongest-model prompt remains the
/// normative source; this slice claims only the capabilities represented here.
public enum MatrixNativeVibesUISurface: String, CaseIterable, Sendable {
    case joinedSpaces
    case spaceInvitations
    case publicSpaceDirectory
    case publicSpaceSearch
    case publicSpacePagination
    case publicSpaceJoin
    case createSpace
    case createRoomInSpace
    case matrixUserInvitations
    case powerLevelPermissionGates
    case structuredWaveRules
    case typedWestreemEventReferences
    case nestedSpaceNavigation
    case waveDirectory
    case roomTimeline
    case textComposer
    case nativeAttachmentComposer
    case polls
    case stickers
    case multiplePhotos
    case files
    case voiceCapture
    case voicePlayback
    case videoCapture
    case videoPlayback
    case mediaViewer
    case attachmentValidationAndLimits
    case legacyEncryptedMediaIsolation
    case sdkLocalSendState
    case sdkRetry
    case readReceipts
    case outgoingTypingNotice
    case incomingTypingAndStatus
    case matrixMessageEcho
    case matrixMessageShare
    case safeLinkPreviews
    case loadingState
    case errorState
    case offlineState
    case legacyRouteFailClosed
    case accessibilityLabels
}

public struct MatrixNativeWaveRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let locale: String?
    public let order: Int

    public init(id: String, text: String, locale: String? = nil, order: Int) {
        self.id = id
        self.text = text
        self.locale = locale
        self.order = order
    }
}

public struct MatrixNativeWaveRulesState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let rules: [MatrixNativeWaveRule]
    public let updatedAt: String
    public let updatedByWestreemUserID: String

    public init(
        schemaVersion: Int = 1,
        revision: Int,
        rules: [MatrixNativeWaveRule],
        updatedAt: String,
        updatedByWestreemUserID: String
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.rules = rules
        self.updatedAt = updatedAt
        self.updatedByWestreemUserID = updatedByWestreemUserID
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case rules
        case updatedAt = "updated_at"
        case updatedByWestreemUserID = "updated_by_westreem_user_id"
    }
}

public enum MatrixNativeWaveRulesValidationError: Error, Equatable, Sendable {
    case invalidSchema
    case invalidRevision
    case tooManyRules
    case invalidRuleID
    case duplicateRuleID
    case invalidRuleText
    case invalidRuleOrder
    case duplicateRuleOrder
    case invalidLocale
    case invalidUpdatedAt
    case invalidUpdater
}

public enum MatrixNativeWaveRulesReadError: Error, Equatable, Sendable {
    /// The newest canonical state event exists but does not satisfy the
    /// versioned Westreem schema. Never fall back to an older valid revision.
    case invalidCanonicalState
    /// MatrixRustSDK has not exposed the room's complete state/history yet, so
    /// the client cannot safely claim that no rules exist.
    case incompleteHistory
    /// Another moderator published a newer revision after this editor loaded.
    case staleRevision
}

public enum MatrixNativeWaveRulesContract {
    public static let eventType = "com.westreem.room.rules.v1"
    public static let maximumRules = 50
    public static let maximumRuleTextLength = 1_000

    public static func validate(
        _ state: MatrixNativeWaveRulesState
    ) throws -> MatrixNativeWaveRulesState {
        guard state.schemaVersion == 1 else {
            throw MatrixNativeWaveRulesValidationError.invalidSchema
        }
        guard state.revision >= 1 else {
            throw MatrixNativeWaveRulesValidationError.invalidRevision
        }
        guard state.rules.count <= maximumRules else {
            throw MatrixNativeWaveRulesValidationError.tooManyRules
        }
        guard
            !state.updatedByWestreemUserID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            state.updatedByWestreemUserID.count <= 192
        else {
            throw MatrixNativeWaveRulesValidationError.invalidUpdater
        }
        guard ISO8601DateFormatter().date(from: state.updatedAt) != nil else {
            throw MatrixNativeWaveRulesValidationError.invalidUpdatedAt
        }

        var ids = Set<String>()
        var orders = Set<Int>()
        for rule in state.rules {
            guard
                !rule.id.isEmpty,
                rule.id.count <= 64,
                rule.id.unicodeScalars.allSatisfy({
                    CharacterSet(
                        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"
                    ).contains($0)
                })
            else {
                throw MatrixNativeWaveRulesValidationError.invalidRuleID
            }
            guard ids.insert(rule.id).inserted else {
                throw MatrixNativeWaveRulesValidationError.duplicateRuleID
            }
            let text = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, rule.text.count <= maximumRuleTextLength else {
                throw MatrixNativeWaveRulesValidationError.invalidRuleText
            }
            guard rule.order >= 0 else {
                throw MatrixNativeWaveRulesValidationError.invalidRuleOrder
            }
            guard orders.insert(rule.order).inserted else {
                throw MatrixNativeWaveRulesValidationError.duplicateRuleOrder
            }
            if let locale = rule.locale {
                guard
                    locale.count <= 35,
                    locale.range(
                        of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#,
                        options: .regularExpression
                    ) != nil
                else {
                    throw MatrixNativeWaveRulesValidationError.invalidLocale
                }
            }
        }
        return state
    }

    public static func decode(contentJSON: String) throws
        -> MatrixNativeWaveRulesState {
        let data = Data(contentJSON.utf8)
        let state = try JSONDecoder().decode(
            MatrixNativeWaveRulesState.self,
            from: data
        )
        return try validate(state)
    }

    public static func encode(
        _ state: MatrixNativeWaveRulesState
    ) throws -> String {
        let validated = try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixNativeWaveRulesValidationError.invalidSchema
        }
        return json
    }
}

public struct MatrixNativeWestreemProvenanceHopV1:
    Codable,
    Equatable,
    Sendable
{
    public let roomID: String
    public let eventID: String
    public let senderMatrixUserID: String

    public init(
        roomID: String,
        eventID: String,
        senderMatrixUserID: String
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.senderMatrixUserID = senderMatrixUserID
    }

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case eventID = "event_id"
        case senderMatrixUserID = "sender_matrix_user_id"
    }
}

public struct MatrixNativeWestreemProvenanceV1: Codable, Equatable, Sendable {
    public let sourceProduct: String
    public let actorWestreemUserID: String
    public let operatorWestreemUserID: String?
    public let sourceRoomID: String?
    public let sourceEventID: String?
    public let sourceSenderMatrixUserID: String?
    public let hopTrace: [MatrixNativeWestreemProvenanceHopV1]?

    public init(
        sourceProduct: String,
        actorWestreemUserID: String,
        operatorWestreemUserID: String? = nil,
        sourceRoomID: String? = nil,
        sourceEventID: String? = nil,
        sourceSenderMatrixUserID: String? = nil,
        hopTrace: [MatrixNativeWestreemProvenanceHopV1]? = nil
    ) {
        self.sourceProduct = sourceProduct
        self.actorWestreemUserID = actorWestreemUserID
        self.operatorWestreemUserID = operatorWestreemUserID
        self.sourceRoomID = sourceRoomID
        self.sourceEventID = sourceEventID
        self.sourceSenderMatrixUserID = sourceSenderMatrixUserID
        self.hopTrace = hopTrace
    }

    enum CodingKeys: String, CodingKey {
        case sourceProduct = "source_product"
        case actorWestreemUserID = "actor_westreem_user_id"
        case operatorWestreemUserID = "operator_westreem_user_id"
        case sourceRoomID = "source_room_id"
        case sourceEventID = "source_event_id"
        case sourceSenderMatrixUserID = "source_sender_matrix_user_id"
        case hopTrace = "hop_trace"
    }
}

public struct MatrixNativeWestreemReferenceV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let entityType: String
    public let entityID: String
    public let canonicalURL: String
    public let title: String
    public let summary: String?
    public let thumbnail: String?
    public let durationMilliseconds: Int?
    public let provenance: MatrixNativeWestreemProvenanceV1
    public let idempotencyKey: String

    public init(
        schemaVersion: Int = 1,
        entityType: String,
        entityID: String,
        canonicalURL: String,
        title: String,
        summary: String? = nil,
        thumbnail: String? = nil,
        durationMilliseconds: Int? = nil,
        provenance: MatrixNativeWestreemProvenanceV1,
        idempotencyKey: String
    ) {
        self.schemaVersion = schemaVersion
        self.entityType = entityType
        self.entityID = entityID
        self.canonicalURL = canonicalURL
        self.title = title
        self.summary = summary
        self.thumbnail = thumbnail
        self.durationMilliseconds = durationMilliseconds
        self.provenance = provenance
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case canonicalURL = "canonical_url"
        case title
        case summary
        case thumbnail
        case durationMilliseconds = "duration_ms"
        case provenance
        case idempotencyKey = "idempotency_key"
    }
}

public enum MatrixNativeWestreemShareEntityType: String, CaseIterable, Codable, Sendable {
    case video
    case short
    case clipping
    case collection
    case show
    case channel
    case event
    case user
    case atmoPost = "atmo_post"
    case matrixEvent = "matrix_event"
}

public struct MatrixNativeWestreemReferenceEnvelope: Decodable, Equatable, Sendable {
    public let authority: String
    public let eventType: String
    public let content: MatrixNativeWestreemReferenceV1

    enum CodingKeys: String, CodingKey {
        case authority
        case eventType
        case content
    }

    public init(
        authority: String,
        eventType: String,
        content: MatrixNativeWestreemReferenceV1
    ) throws {
        guard authority == "MATRIX" else {
            throw CocoaError(.coderInvalidValue)
        }
        self.authority = authority
        self.eventType = eventType
        self.content = try MatrixNativeWestreemReferenceContract.validate(
            eventType: eventType,
            value: content
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            authority: values.decode(String.self, forKey: .authority),
            eventType: values.decode(String.self, forKey: .eventType),
            content: values.decode(
                MatrixNativeWestreemReferenceV1.self,
                forKey: .content
            )
        )
    }
}

public enum MatrixNativeWestreemReferenceContract {
    public static let shareEventType = "com.westreem.share.v1"
    public static let eventReferenceType = "com.westreem.event_ref.v1"
    public static let allowedEntityTypes = Set(
        MatrixNativeWestreemShareEntityType.allCases.map(\.rawValue)
    )

    public static func decode(
        eventType: String,
        contentJSON: String
    ) throws -> MatrixNativeWestreemReferenceV1 {
        let value = try JSONDecoder().decode(
            MatrixNativeWestreemReferenceV1.self,
            from: Data(contentJSON.utf8)
        )
        return try validate(eventType: eventType, value: value)
    }

    public static func validate(
        eventType: String,
        value: MatrixNativeWestreemReferenceV1
    ) throws -> MatrixNativeWestreemReferenceV1 {
        guard value.schemaVersion == 1,
              allowedEntityTypes.contains(value.entityType),
              (eventType == eventReferenceType
                  ? value.entityType == "event"
                  : eventType == shareEventType && value.entityType != "event"),
              !value.entityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.entityID.count <= 512,
              !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.title.count <= 500,
              safeWestreemURL(value.canonicalURL) != nil,
              !value.idempotencyKey.isEmpty,
              value.idempotencyKey.count <= 255,
              value.idempotencyKey.range(
                  of: #"^[A-Za-z0-9._:~-]+$"#,
                  options: .regularExpression
              ) != nil,
              ["westreem", "vibes"].contains(value.provenance.sourceProduct),
              !value.provenance.actorWestreemUserID.isEmpty,
              value.provenance.actorWestreemUserID.count <= 192
        else {
            throw CocoaError(.coderInvalidValue)
        }
        if let summary = value.summary {
            guard
                !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                summary.count <= 10_000
            else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        if let thumbnail = value.thumbnail {
            guard safeThumbnail(thumbnail) else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        if let duration = value.durationMilliseconds {
            guard duration >= 0 else { throw CocoaError(.coderInvalidValue) }
        }
        if let operatorID = value.provenance.operatorWestreemUserID {
            guard
                !operatorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                operatorID.count <= 192
            else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        if value.entityType == "matrix_event" {
            guard
                let sourceRoomID = value.provenance.sourceRoomID,
                sourceRoomID.first == "!",
                sourceRoomID.count <= 512,
                let sourceEventID = value.provenance.sourceEventID,
                sourceEventID.first == "$",
                sourceEventID.count <= 512,
                value.provenance.sourceProduct == "vibes",
                let senderID = value.provenance.sourceSenderMatrixUserID,
                senderID.first == "@",
                senderID.count <= 512,
                let trace = value.provenance.hopTrace,
                (1...8).contains(trace.count),
                trace.last?.roomID == sourceRoomID,
                trace.last?.eventID == sourceEventID,
                trace.last?.senderMatrixUserID == senderID
            else {
                throw CocoaError(.coderInvalidValue)
            }
            var seen = Set<String>()
            for hop in trace {
                guard hop.roomID.first == "!",
                      hop.roomID.count <= 512,
                      hop.eventID.first == "$",
                      hop.eventID.count <= 512,
                      hop.senderMatrixUserID.first == "@",
                      hop.senderMatrixUserID.count <= 512,
                      seen.insert("\(hop.roomID)\n\(hop.eventID)").inserted
                else {
                    throw CocoaError(.coderInvalidValue)
                }
            }
        } else {
            if let senderID = value.provenance.sourceSenderMatrixUserID {
                guard senderID.first == "@", senderID.count <= 512 else {
                    throw CocoaError(.coderInvalidValue)
                }
            }
            if let trace = value.provenance.hopTrace {
                guard (1...8).contains(trace.count) else {
                    throw CocoaError(.coderInvalidValue)
                }
                var seen = Set<String>()
                for hop in trace {
                    guard hop.roomID.first == "!",
                          hop.roomID.count <= 512,
                          hop.eventID.first == "$",
                          hop.eventID.count <= 512,
                          hop.senderMatrixUserID.first == "@",
                          hop.senderMatrixUserID.count <= 512,
                          seen.insert("\(hop.roomID)\n\(hop.eventID)").inserted
                    else {
                        throw CocoaError(.coderInvalidValue)
                    }
                }
            }
        }
        return value
    }

    public static func encode(
        eventType: String,
        value: MatrixNativeWestreemReferenceV1
    ) throws -> String {
        let validated = try validate(eventType: eventType, value: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    public static func safeWestreemURL(_ rawValue: String) -> URL? {
        guard
            let components = URLComponents(string: rawValue),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            let host = components.host?.lowercased(),
            host == "westreem.com" || host.hasSuffix(".westreem.com")
        else {
            return nil
        }
        return components.url
    }

    private static func safeThumbnail(_ rawValue: String) -> Bool {
        if safeWestreemURL(rawValue) != nil {
            return true
        }
        guard
            let components = URLComponents(string: rawValue),
            components.scheme?.lowercased() == "mxc",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.host?.isEmpty == false,
            !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else {
            return false
        }
        return true
    }
}

public struct MatrixNativeLinkPreviewMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let description: String?
    public let imageURL: String?
    public let faviconURL: String?
    public let domain: String
    public let finalURL: String

    public init(
        title: String?,
        description: String?,
        imageURL: String?,
        faviconURL: String?,
        domain: String,
        finalURL: String
    ) throws {
        guard let safeURL = MatrixNativeLinkPreviewContract.safePublicHTTPURL(finalURL),
              !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              domain.count <= 255,
              title?.count ?? 0 <= 500,
              description?.count ?? 0 <= 2_000
        else {
            throw CocoaError(.coderInvalidValue)
        }
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageURL = imageURL
        self.faviconURL = faviconURL
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.finalURL = safeURL.absoluteString
    }
}

/// Short-lived preview metadata owned by one immutable account scope.
/// Successful metadata only is inserted; callers keep failures/unavailable
/// states outside this cache so network errors cannot become sticky.
public struct MatrixNativeLinkPreviewCache: Sendable {
    private struct Entry: Sendable {
        let expiresAt: Date
        let value: MatrixNativeLinkPreviewMetadata
    }

    public static let timeToLive: TimeInterval = 10 * 60
    public static let maximumEntriesPerAccount = 100
    private var entries: [String: [String: Entry]] = [:]
    private var order: [String: [String]] = [:]

    public init() {}

    public mutating func value(
        accountScope: String,
        url: String,
        now: Date = Date()
    ) -> MatrixNativeLinkPreviewMetadata? {
        guard let entry = entries[accountScope]?[url] else { return nil }
        guard entry.expiresAt > now else {
            remove(accountScope: accountScope, url: url)
            return nil
        }
        touch(accountScope: accountScope, url: url)
        return entry.value
    }

    public mutating func insert(
        _ value: MatrixNativeLinkPreviewMetadata,
        accountScope: String,
        url: String,
        now: Date = Date()
    ) {
        guard !accountScope.isEmpty else { return }
        entries[accountScope, default: [:]][url] = Entry(
            expiresAt: now.addingTimeInterval(Self.timeToLive),
            value: value
        )
        touch(accountScope: accountScope, url: url)
        while (order[accountScope]?.count ?? 0) > Self.maximumEntriesPerAccount,
              let oldest = order[accountScope]?.first {
            remove(accountScope: accountScope, url: oldest)
        }
    }

    public mutating func remove(accountScope: String, url: String) {
        entries[accountScope]?.removeValue(forKey: url)
        order[accountScope]?.removeAll { $0 == url }
        if entries[accountScope]?.isEmpty == true {
            entries.removeValue(forKey: accountScope)
            order.removeValue(forKey: accountScope)
        }
    }

    public mutating func clear(accountScope: String) {
        entries.removeValue(forKey: accountScope)
        order.removeValue(forKey: accountScope)
    }

    private mutating func touch(accountScope: String, url: String) {
        order[accountScope, default: []].removeAll { $0 == url }
        order[accountScope, default: []].append(url)
    }
}

public enum MatrixNativeLinkPreviewContract {
    public static let endpoint = "/api/matrix/link-preview"
    public static let imageProxyPath = "/api/link-preview/image"
    public static let maximumURLLength = 2_048

    public static func firstPublicHTTPURL(in body: String) -> String? {
        for token in body.split(whereSeparator: \.isWhitespace).prefix(100) {
            let candidate = String(token).trimmingCharacters(
                in: CharacterSet(charactersIn: ".,;:!?)]}>\"'")
            )
            if let url = safePublicHTTPURL(candidate) {
                return url.absoluteString
            }
        }
        return nil
    }

    public static func safePublicHTTPURL(_ rawValue: String) -> URL? {
        guard rawValue.count <= maximumURLLength,
              let components = URLComponents(string: rawValue),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              isAllowedPort(components.port, scheme: components.scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !isPrivateLiteralHost(host)
        else {
            return nil
        }
        return components.url
    }

    private static func isAllowedPort(_ port: Int?, scheme: String?) -> Bool {
        guard let port else { return true }
        switch scheme?.lowercased() {
        case "http": return port == 80
        case "https": return port == 443
        default: return false
        }
    }

    private static func isPrivateLiteralHost(_ host: String) -> Bool {
        if host == "::1" || host == "0.0.0.0" || host == "127.0.0.1" {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && 16...31 ~= parts[1])
            || (parts[0] == 192 && parts[1] == 168)
    }
}

public enum MatrixNativeMatrixEchoContract {
    public static let maximumDestinations = 20

    public static func stableTransactionID(
        requestID: String,
        destinationRoomID: String
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in destinationRoomID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let cleanRequest = requestID
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "westreem-ios-echo-\(String(cleanRequest.prefix(80)))-\(String(hash, radix: 16))"
    }

    public static func boundedDestinationRoomIDs(
        _ values: [String]
    ) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let roomID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard roomID.first == "!",
                  roomID.count <= 512,
                  seen.insert(roomID).inserted
            else {
                return nil
            }
            return roomID
        }
        .prefix(maximumDestinations)
        .map(\.self)
    }

    public static func reference(
        sourceRoomID: String,
        sourceEventID: String,
        sourceSenderMatrixUserID: String,
        sourceSenderName: String,
        sourceBody: String,
        actorWestreemUserID: String,
        existingReference: MatrixNativeWestreemReferenceV1? = nil,
        idempotencyKey: String
    ) throws -> MatrixNativeWestreemReferenceV1 {
        let sender = sourceSenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = sourceBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceRoomID.first == "!",
              sourceEventID.first == "$",
              sourceSenderMatrixUserID.first == "@",
              !sender.isEmpty,
              !actorWestreemUserID.isEmpty,
              !body.isEmpty
        else {
            throw CocoaError(.coderInvalidValue)
        }
        let inheritedTrace: [MatrixNativeWestreemProvenanceHopV1]
        if let existingReference,
           existingReference.entityType
            == MatrixNativeWestreemShareEntityType.matrixEvent.rawValue {
            let validated = try MatrixNativeWestreemReferenceContract.validate(
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                value: existingReference
            )
            inheritedTrace = validated.provenance.hopTrace ?? []
        } else {
            inheritedTrace = []
        }
        let immediateHop = MatrixNativeWestreemProvenanceHopV1(
            roomID: sourceRoomID,
            eventID: sourceEventID,
            senderMatrixUserID: sourceSenderMatrixUserID
        )
        let trace = inheritedTrace + [immediateHop]
        guard trace.count <= 8,
              Set(trace.map { "\($0.roomID)\n\($0.eventID)" }).count
                == trace.count
        else {
            throw CocoaError(.coderInvalidValue)
        }
        var components = URLComponents(
            string: "https://www.westreem.com"
        )
        components?.path = "/vibes/rooms/\(sourceRoomID)"
        components?.queryItems = [
            URLQueryItem(name: "event", value: sourceEventID)
        ]
        guard let canonicalURL = components?.url?.absoluteString else {
            throw CocoaError(.coderInvalidValue)
        }
        return try MatrixNativeWestreemReferenceContract.validate(
            eventType: MatrixNativeWestreemReferenceContract.shareEventType,
            value: MatrixNativeWestreemReferenceV1(
                entityType: MatrixNativeWestreemShareEntityType.matrixEvent.rawValue,
                entityID: sourceEventID,
                canonicalURL: canonicalURL,
                title: String("\(sender): \(body)".prefix(500)),
                summary: String(body.prefix(10_000)),
                provenance: MatrixNativeWestreemProvenanceV1(
                    sourceProduct: "vibes",
                    actorWestreemUserID: actorWestreemUserID,
                    sourceRoomID: sourceRoomID,
                    sourceEventID: sourceEventID,
                    sourceSenderMatrixUserID: sourceSenderMatrixUserID,
                    hopTrace: trace
                ),
                idempotencyKey: idempotencyKey
            )
        )
    }

    public static func canEcho(
        existingReference: MatrixNativeWestreemReferenceV1?,
        to destinationRoomID: String
    ) -> Bool {
        guard destinationRoomID.first == "!" else { return false }
        guard let existingReference,
              existingReference.entityType
                == MatrixNativeWestreemShareEntityType.matrixEvent.rawValue
        else {
            return true
        }
        guard let validated = try? MatrixNativeWestreemReferenceContract
            .validate(
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                value: existingReference
            ),
            (validated.provenance.hopTrace?.count ?? 0) < 8
        else {
            return false
        }
        return validated.provenance.hopTrace?.contains {
            $0.roomID == destinationRoomID
        } != true
    }
}

public enum MatrixNativeVibeVisibility: String, CaseIterable, Sendable {
    case publicVibe
    case privateVibe
    case knock
    case restricted
}

public struct MatrixNativeRoomCreationAvatar: Equatable, Sendable {
    public let data: Data
    public let filename: String
    public let mimeType: String
    public let width: UInt64?
    public let height: UInt64?

    public init(
        data: Data,
        filename: String,
        mimeType: String,
        width: UInt64? = nil,
        height: UInt64? = nil
    ) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

public struct MatrixNativeRoomCreationDraft: Equatable, Sendable {
    public let name: String
    public let topic: String
    public let visibility: MatrixNativeVibeVisibility
    public let inviteUserIDs: [String]
    public let isEncrypted: Bool
    public let canonicalAlias: String?
    public let avatar: MatrixNativeRoomCreationAvatar?

    public init(
        name: String,
        topic: String,
        visibility: MatrixNativeVibeVisibility,
        inviteUserIDs: [String],
        isEncrypted: Bool = false,
        canonicalAlias: String? = nil,
        avatar: MatrixNativeRoomCreationAvatar? = nil
    ) {
        self.name = name
        self.topic = topic
        self.visibility = visibility
        self.inviteUserIDs = inviteUserIDs
        self.isEncrypted = isEncrypted
        self.canonicalAlias = canonicalAlias
        self.avatar = avatar
    }
}

public struct MatrixNativeValidatedRoomCreation: Equatable, Sendable {
    public let name: String
    public let topic: String?
    public let visibility: MatrixNativeVibeVisibility
    public let inviteUserIDs: [String]
    public let isEncrypted: Bool
    public let canonicalAlias: String?
    public let avatar: MatrixNativeRoomCreationAvatar?
}

public enum MatrixNativeCreationValidationError: Error, Equatable, Sendable {
    case invalidName
    case topicTooLong
    case tooManyInvitations
    case invalidMatrixUserID(String)
    case invalidCanonicalAlias
    case invalidAvatar
}

public enum MatrixNativeCreationContract {
    public static let maximumNameLength = 255
    public static let maximumTopicLength = 4_000
    public static let maximumInitialInvitations = 100
    public static let maximumAvatarBytes = 10 * 1_024 * 1_024

    public static func validate(
        _ draft: MatrixNativeRoomCreationDraft
    ) throws -> MatrixNativeValidatedRoomCreation {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumNameLength else {
            throw MatrixNativeCreationValidationError.invalidName
        }

        let topic = draft.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topic.count <= maximumTopicLength else {
            throw MatrixNativeCreationValidationError.topicTooLong
        }

        let canonicalAlias = draft.canonicalAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.visibility == .publicVibe {
            guard let canonicalAlias,
                  canonicalAlias.utf8.count <= 255,
                  canonicalAlias.first == "#",
                  let separator = canonicalAlias.dropFirst().firstIndex(of: ":"),
                  separator > canonicalAlias.index(after: canonicalAlias.startIndex),
                  separator < canonicalAlias.index(before: canonicalAlias.endIndex),
                  !canonicalAlias.contains(where: \.isWhitespace)
            else {
                throw MatrixNativeCreationValidationError.invalidCanonicalAlias
            }
        }

        if let avatar = draft.avatar {
            let mimeType = avatar.mimeType.lowercased()
            guard !avatar.data.isEmpty,
                  avatar.data.count <= maximumAvatarBytes,
                  mimeType.hasPrefix("image/"),
                  !mimeType.contains(where: \.isWhitespace),
                  !avatar.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MatrixNativeCreationValidationError.invalidAvatar
            }
        }

        var inviteUserIDs: [String] = []
        var seen = Set<String>()
        for rawValue in draft.inviteUserIDs {
            let userID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isStructurallyValidMatrixUserID(userID) else {
                throw MatrixNativeCreationValidationError.invalidMatrixUserID(userID)
            }
            if seen.insert(userID).inserted {
                inviteUserIDs.append(userID)
            }
        }
        guard inviteUserIDs.count <= maximumInitialInvitations else {
            throw MatrixNativeCreationValidationError.tooManyInvitations
        }

        return MatrixNativeValidatedRoomCreation(
            name: name,
            topic: topic.isEmpty ? nil : topic,
            visibility: draft.visibility,
            inviteUserIDs: inviteUserIDs,
            // Application-level E2EE is retired for all newly created Vibes
            // and Waves. The input remains temporarily decodable for older
            // callers, but cannot affect creation.
            isEncrypted: false,
            canonicalAlias: draft.visibility == .publicVibe ? canonicalAlias : nil,
            avatar: draft.avatar
        )
    }

    public static func parseInviteUserIDs(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map(String.init)
    }

    /// Matrix `createRoom.room_alias_name` is the alias localpart, even when
    /// product state keeps the complete canonical Matrix alias.
    public static func roomAliasLocalpart(_ canonicalAlias: String?) -> String? {
        guard let canonicalAlias,
              canonicalAlias.first == "#",
              let separator = canonicalAlias.dropFirst().firstIndex(of: ":"),
              separator > canonicalAlias.index(after: canonicalAlias.startIndex)
        else {
            return nil
        }
        return String(
            canonicalAlias[canonicalAlias.index(after: canonicalAlias.startIndex)..<separator]
        )
    }

    public static func isStructurallyValidMatrixUserID(_ value: String) -> Bool {
        guard value.first == "@", value.utf8.count <= 255 else { return false }
        let body = value.dropFirst()
        guard let separator = body.firstIndex(of: ":") else { return false }
        let localpart = body[..<separator]
        let serverName = body[body.index(after: separator)...]
        return !localpart.isEmpty
            && !serverName.isEmpty
            && !value.contains(where: \.isWhitespace)
    }
}

public struct MatrixNativeSpacePermissionSnapshot: Equatable, Sendable {
    public let isJoined: Bool
    public let isSpace: Bool
    public let maySendSpaceChild: Bool
    public let mayInvite: Bool

    public init(
        isJoined: Bool,
        isSpace: Bool,
        maySendSpaceChild: Bool,
        mayInvite: Bool
    ) {
        self.isJoined = isJoined
        self.isSpace = isSpace
        self.maySendSpaceChild = maySendSpaceChild
        self.mayInvite = mayInvite
    }

    public static let unavailable = Self(
        isJoined: false,
        isSpace: false,
        maySendSpaceChild: false,
        mayInvite: false
    )

    public var mayCreateWave: Bool {
        isJoined && isSpace && maySendSpaceChild
    }

    public var mayInviteMembers: Bool {
        isJoined && mayInvite
    }

    public var mayOpenVibeManagement: Bool {
        isJoined && isSpace
    }
}

/// Customer-facing Vibe invitations search WeStreem accounts, while the
/// selected account's immutable bound identity remains an internal transport
/// detail used by the room SDK.
public enum WestreemVibeInviteSearchContract {
    public static let minimumQueryLength = 2
    public static let maximumQueryLength = 64
    public static let maximumResults = 10
    public static let maximumSelection = 100

    public static func normalizedQuery(_ value: String) -> String? {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            query.count >= minimumQueryLength,
            query.count <= maximumQueryLength
        else {
            return nil
        }
        return query
    }

    public static func uniqueSelection(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    public static func canSubmit(_ values: [String]) -> Bool {
        let selection = uniqueSelection(values)
        return !selection.isEmpty && selection.count <= maximumSelection
    }
}

public enum WestreemVibeContactDiscoveryContract {
    public static let maximumHashesPerKind = 500

    public static func normalizedEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard
            !email.isEmpty,
            email.utf8.count <= 320,
            email.contains("@")
        else {
            return nil
        }
        return email
    }

    public static func normalizedPhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLeadingPlus = trimmed.first == "+"
        let digits = trimmed.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        return (hasLeadingPlus ? "+" : "") + digits
    }

    public static func boundedHashes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let hashes: [String] = values.compactMap { value in
            let hash = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard
                hash.count == 64,
                hash.allSatisfy({ $0.isHexDigit }),
                seen.insert(hash).inserted
            else {
                return nil
            }
            return hash
        }
        return Array(hashes.prefix(maximumHashesPerKind))
    }
}

public enum MatrixNativeMemberPresentationContract {
    public static let fallbackDisplayName = "WeStreem member"
    public static let fallbackDirectRoomName = "Personal Wave"

    private static func safeLabel(
        _ candidate: String?,
        fallback: String,
        forbiddenIdentifier: String? = nil
    ) -> String {
        guard let value = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value != forbiddenIdentifier,
            let firstCharacter = value.first,
            !["@","!","#"].contains(String(firstCharacter))
        else {
            return fallback
        }
        return value
    }

    public static func displayName(
        _ displayName: String?,
        matrixUserID: String
    ) -> String {
        let matrixLocalpart = matrixUserID
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return safeLabel(
            displayName,
            fallback: fallbackDisplayName,
            forbiddenIdentifier: displayName == matrixLocalpart
                ? displayName
                : matrixUserID
        )
    }

    public static func roomName(
        _ displayName: String?,
        fallback: String
    ) -> String {
        safeLabel(displayName, fallback: fallback)
    }

    /// Direct rooms are presented as the peer identity, never as the SDK's
    /// synthetic empty-room title or an internal Matrix identifier.
    public static func directRoomName(
        peerDisplayName: String?,
        roomDisplayName: String?,
        peerMatrixUserID: String
    ) -> String {
        let peerName = displayName(peerDisplayName, matrixUserID: peerMatrixUserID)
        if peerName != fallbackDisplayName {
            return peerName
        }

        let roomName = roomName(roomDisplayName, fallback: fallbackDirectRoomName)
        let normalized = roomName.lowercased()
        guard
            !normalized.hasPrefix("empty room"),
            !normalized.contains("(was u_")
        else {
            return fallbackDirectRoomName
        }
        return roomName
    }
}

public enum MatrixNativeSpaceDirectoryFailureDisposition: Equatable, Sendable {
    case ignoreStalePurgedSpace
    case reportFailure
}

public enum MatrixNativeSpaceDirectoryFailureContract {
    /// A block/purge or membership revocation can leave a Space marked joined
    /// in the SDK store until Sliding Sync applies the tombstone. In this
    /// joined-Space directory context, not-found and forbidden both prove that
    /// the local entry is no longer accessible. Transport, rate-limit, session
    /// and generic failures remain user-visible and retryable.
    public static func disposition(
        matrixErrorCode: String?,
        matrixKindIsNotFound: Bool = false
    ) -> MatrixNativeSpaceDirectoryFailureDisposition {
        matrixKindIsNotFound
            || matrixErrorCode == "M_NOT_FOUND"
            || matrixErrorCode == "M_FORBIDDEN"
            ? .ignoreStalePurgedSpace
            : .reportFailure
    }
}

public enum MatrixNativeVibesUIContract {
    public static let authority = SocialAuthority.matrix
    public static let normativeSource = MatrixNativeGoverningContract.normativeSource
    public static let required = Set(MatrixNativeVibesUISurface.allCases)

    /// Application-level E2EE capabilities are intentionally absent. Legacy
    /// crypto storage may remain isolated during the migration window only.
    public static let implementedAndContractQAVerified: Set<MatrixNativeCapability> = [
        .directMessages,
    ]

    /// Implemented code whose production/device behavior still requires the
    /// signed physical-device and cross-client release gate.
    public static let runtimeVerificationPending: Set<MatrixNativeCapability> = [
        .directMessages,
        .matrixRTC,
    ]

    /// Wave RTC uses standard WebRTC DTLS-SRTP transport protection without
    /// application-level media E2EE. Direct-call UX remains a separate gap.
    public static let supportsWaveMatrixRTC = true
    public static let supportsEncryptedWaveMatrixRTC = false
    public static let supportsDirectMatrixRTC = false
}

/// Matrix Rust SDK owns native Sliding Sync transport. This policy bounds the
/// product-side room projection and visible-room subscription work without
/// introducing a competing sync implementation.
public enum MatrixNativeSlidingSyncScaleContract {
    public static let initialRooms = 10
    public static let batchRooms = 50
    public static let maximumRooms = 10_000

    public static func initialRange(totalRooms: Int) -> ClosedRange<Int>? {
        let total = min(max(totalRooms, 0), maximumRooms)
        guard total > 0 else { return nil }
        return 0...min(total - 1, initialRooms - 1)
    }

    public static func nextRange(
        totalRooms: Int,
        current: ClosedRange<Int>
    ) -> ClosedRange<Int>? {
        let total = min(max(totalRooms, 0), maximumRooms)
        guard total > 0, current.upperBound < total - 1 else { return nil }
        return 0...min(total - 1, current.upperBound + batchRooms)
    }

    public static func activeSubscription(roomID: String?) -> Set<String> {
        guard let roomID = roomID?.trimmingCharacters(in: .whitespacesAndNewlines),
              roomID.first == "!",
              roomID.contains(":"),
              !roomID.contains(where: { $0.isWhitespace }) else { return [] }
        return [roomID]
    }
}

/// Pure, executable safety rules shared by the native UI and contract tests.
/// Media whose bounded duration cannot be proven must never be sent.
public enum MatrixNativeMediaDurationKind: Sendable {
    case audio
    case voice
    case video
}

public enum MatrixNativeMediaSafetyContract {
    public static let maximumVoiceDuration: TimeInterval = 10 * 60
    public static let maximumVideoDuration: TimeInterval = 10 * 60

    public static func acceptsDuration(
        _ duration: TimeInterval?,
        for kind: MatrixNativeMediaDurationKind
    ) -> Bool {
        switch kind {
        case .audio:
            guard let duration else { return true }
            return duration.isFinite && duration > 0
        case .voice:
            guard let duration else { return false }
            return duration.isFinite
                && duration > 0
                && duration <= maximumVoiceDuration
        case .video:
            guard let duration else { return false }
            return duration.isFinite
                && duration > 0
                && duration <= maximumVideoDuration
        }
    }
}

public enum MatrixNativePollVisibilityContract {
    /// Element reveals disclosed results after the current user has voted;
    /// undisclosed polls reveal nothing until the poll ends.
    public static func showsResults(
        isDisclosed: Bool,
        hasEnded: Bool,
        hasVoted: Bool = false
    ) -> Bool {
        hasEnded || (isDisclosed && hasVoted)
    }
}

public struct MatrixNativeApprovedStickerAsset: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let label: String
    public let mimeType: String
    public let bytes: Int
    public let width: Int?
    public let height: Int?
    public let assetURL: String

    enum CodingKeys: String, CodingKey {
        case id, key, label, mimeType, bytes, width, height
        case assetURL = "assetUrl"
    }
}

public struct MatrixNativeApprovedStickerPack: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    public let version: Int
    public let assets: [MatrixNativeApprovedStickerAsset]
}

public struct MatrixNativeApprovedStickerPacksResponse: Decodable, Equatable, Sendable {
    public let packs: [MatrixNativeApprovedStickerPack]
}

public enum MatrixNativeApprovedStickerContract {
    public static let listingPath = "/api/matrix/stickers"
    public static let maximumBytes = 5 * 1_024 * 1_024
    public static let allowedMIMETypes = Set(["image/png", "image/webp", "image/gif"])

    public static func assetPath(id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "\(listingPath)?asset=\(encoded)"
    }

    public static func accepts(_ asset: MatrixNativeApprovedStickerAsset) -> Bool {
        guard
            !asset.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !asset.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !asset.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            allowedMIMETypes.contains(asset.mimeType.lowercased()),
            (1...maximumBytes).contains(asset.bytes),
            let expectedAssetPath = assetPath(id: asset.id),
            asset.assetURL == expectedAssetPath
        else {
            return false
        }
        if let width = asset.width, width <= 0 { return false }
        if let height = asset.height, height <= 0 { return false }
        return true
    }

    /// The server verifies the governed asset digest before returning bytes.
    /// Native still fails closed on type confusion before the bytes can be
    /// decoded, previewed, or uploaded to Matrix.
    public static func accepts(_ data: Data, mimeType: String) -> Bool {
        guard (1...maximumBytes).contains(data.count) else { return false }
        switch mimeType.lowercased() {
        case "image/png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/gif":
            return data.starts(with: Array("GIF87a".utf8))
                || data.starts(with: Array("GIF89a".utf8))
        case "image/webp":
            guard data.count >= 12 else { return false }
            return data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        default:
            return false
        }
    }

    public static func filename(for asset: MatrixNativeApprovedStickerAsset) -> String {
        let normalizedKey = asset.key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = normalizedKey.isEmpty ? "westreem-sticker" : String(normalizedKey.prefix(120))
        let suffix: String
        switch asset.mimeType.lowercased() {
        case "image/gif": suffix = "gif"
        case "image/webp": suffix = "webp"
        default: suffix = "png"
        }
        return "\(stem).\(suffix)"
    }
}

public enum MatrixNativeDeliveryKind: Sendable {
    case text
    case attachment
    case poll
    case sticker
}

public enum MatrixNativeDurableDeliveryOwner: Equatable, Sendable {
    case liveSDKSendHandle
    case matrixSDKQueue
    case oneShotFailClosed
}

public enum MatrixNativeRetryContract {
    /// Rich sends are never recreated from a Westreem-owned payload. Standard
    /// attachments and polls rely on MatrixRustSDK's persistent send queue.
    /// Raw sticker events are one-shot until the SDK exposes a queued raw-event
    /// handle; a failed sticker is deliberately not advertised as retryable.
    public static func owner(
        for kind: MatrixNativeDeliveryKind,
        hasLiveSendHandle: Bool
    ) -> MatrixNativeDurableDeliveryOwner {
        switch kind {
        case .text where hasLiveSendHandle:
            .liveSDKSendHandle
        case .text, .attachment, .poll:
            .matrixSDKQueue
        case .sticker:
            .oneShotFailClosed
        }
    }

    public static func permitsManualRetry(
        for kind: MatrixNativeDeliveryKind,
        hasLiveSendHandle: Bool
    ) -> Bool {
        kind == .text && hasLiveSendHandle
    }
}

public struct MatrixWaveEstablishmentManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let hashAlgorithm: String
    public let manifestHash: String
    public let roomID: String
    public let parentSpaceID: String
    public let bootstrapEventIDs: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case hashAlgorithm = "hash_algorithm"
        case manifestHash = "manifest_hash"
        case roomID = "room_id"
        case parentSpaceID = "parent_space_id"
        case bootstrapEventIDs = "bootstrap_event_ids"
    }
}

/// Full-fidelity current-state evidence returned by the authenticated
/// Westreem projection boundary. Content remains JSON so newer Matrix state
/// fields are not silently discarded by the native client.
public struct MatrixWaveAuthoritativeStateEvent: Codable, Equatable, Sendable {
    public let roomID: String
    public let eventID: String
    public let sender: String
    public let type: String
    public let stateKey: String
    public let contentJSON: String

    public init(
        roomID: String,
        eventID: String,
        sender: String,
        type: String,
        stateKey: String,
        contentJSON: String
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.sender = sender
        self.type = type
        self.stateKey = stateKey
        self.contentJSON = contentJSON
    }

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case eventID = "event_id"
        case sender
        case type
        case stateKey = "state_key"
        case contentJSON = "content_json"
    }
}

public struct MatrixWaveAuthoritativeParent: Codable, Equatable, Sendable {
    public let spaceRoomID: String
    public let parentEvent: MatrixWaveAuthoritativeStateEvent
    public let childEvent: MatrixWaveAuthoritativeStateEvent

    enum CodingKeys: String, CodingKey {
        case spaceRoomID = "space_room_id"
        case parentEvent = "parent_event"
        case childEvent = "child_event"
    }
}

public struct MatrixWaveAuthoritativeState: Codable, Equatable, Sendable {
    public let roomID: String
    public let marker: MatrixWaveAuthoritativeStateEvent?
    public let parents: [MatrixWaveAuthoritativeParent]

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case marker
        case parents
    }
}

public struct MatrixWaveEstablishmentProjection: Equatable, Sendable {
    public let markerEventID: String
    public let manifest: MatrixWaveEstablishmentManifest

    public var suppressedEventIDs: Set<String> {
        Set(manifest.bootstrapEventIDs).union([markerEventID])
    }

    public var cacheKey: String {
        MatrixWaveEstablishmentContract.cacheKey(
            roomID: manifest.roomID,
            manifestHash: manifest.manifestHash
        )
    }

    public func permitsProjection(of eventID: String) -> Bool {
        !suppressedEventIDs.contains(eventID)
    }
}

public enum MatrixWaveProjectionEventClass: Equatable, Sendable {
    case messageLike
    case recognizedRoomState
    case establishmentOrBootstrap
    case unsupportedOrProtocolMetadata
}

/// Cross-client projection flags frozen by VAC-002. This policy classifies
/// presentation and derived state only; MatrixRustSDK retains every raw event.
public struct MatrixWaveEventEligibility: Equatable, Sendable {
    public let displayInTimeline: Bool
    public let displayAsCompactRoomEvent: Bool
    public let updatesPreview: Bool
    public let updatesRecency: Bool
    public let countsUnread: Bool
    public let eligibleForPush: Bool
    public let eligibleForSearch: Bool

    public static func policy(
        for eventClass: MatrixWaveProjectionEventClass
    ) -> MatrixWaveEventEligibility {
        switch eventClass {
        case .messageLike:
            MatrixWaveEventEligibility(
                displayInTimeline: true,
                displayAsCompactRoomEvent: false,
                updatesPreview: true,
                updatesRecency: true,
                countsUnread: true,
                eligibleForPush: true,
                eligibleForSearch: true
            )
        case .recognizedRoomState:
            MatrixWaveEventEligibility(
                displayInTimeline: true,
                displayAsCompactRoomEvent: true,
                updatesPreview: false,
                updatesRecency: false,
                countsUnread: false,
                eligibleForPush: false,
                eligibleForSearch: false
            )
        case .establishmentOrBootstrap, .unsupportedOrProtocolMetadata:
            MatrixWaveEventEligibility(
                displayInTimeline: false,
                displayAsCompactRoomEvent: false,
                updatesPreview: false,
                updatesRecency: false,
                countsUnread: false,
                eligibleForPush: false,
                eligibleForSearch: false
            )
        }
    }
}

/// Exact consumer contract for the trusted, service-authored Wave bootstrap
/// marker. Invalid or absent markers deliberately fail open: raw Matrix
/// history stays owned by MatrixRustSDK and no event is hidden.
public enum MatrixWaveEstablishmentContract {
    public static let eventType = "com.westreem.wave.establishment.v1"
    /// Single-homeserver production authority. Never derive this identity
    /// from the viewing user; a non-production/federated sender mismatch must
    /// fail open until the authenticated bootstrap supplies an explicit value.
    public static let trustedProductionServiceUserID =
        "@westreem_service:vibes.westreem.com"
    public static let version = 1
    public static let hashAlgorithm = "sha256"
    public static let maximumBootstrapEvents = 64
    public static let cacheProjectionVersion = 4

    private static let exactKeys: Set<String> = [
        "version",
        "hash_algorithm",
        "manifest_hash",
        "room_id",
        "parent_space_id",
        "bootstrap_event_ids",
    ]

    public static func verify(
        contentJSON: String,
        markerEventID: String,
        stateKey: String,
        senderID: String,
        trustedServiceUserID: String,
        roomID: String,
        canonicalParentSpaceIDs: Set<String>,
        hasCanonicalReciprocalParentEdge: (String) -> Bool
    ) -> MatrixWaveEstablishmentProjection? {
        guard
            stateKey.isEmpty,
            senderID == trustedServiceUserID,
            validMatrixID(markerEventID, sigil: "$"),
            let data = contentJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == exactKeys,
            let manifest = try? JSONDecoder().decode(
                MatrixWaveEstablishmentManifest.self,
                from: data
            ),
            manifest.version == version,
            manifest.hashAlgorithm == hashAlgorithm,
            manifest.roomID == roomID,
            validMatrixID(manifest.roomID, sigil: "!"),
            validMatrixID(manifest.parentSpaceID, sigil: "!"),
            canonicalParentSpaceIDs.contains(manifest.parentSpaceID),
            hasCanonicalReciprocalParentEdge(manifest.parentSpaceID),
            (1...maximumBootstrapEvents).contains(
                manifest.bootstrapEventIDs.count
            ),
            Set(manifest.bootstrapEventIDs).count
                == manifest.bootstrapEventIDs.count,
            manifest.bootstrapEventIDs.allSatisfy({
                validMatrixID($0, sigil: "$")
            }),
            manifest.manifestHash.count == 64,
            manifest.manifestHash.range(
                of: "^[a-f0-9]{64}$",
                options: .regularExpression
            ) != nil,
            manifest.manifestHash == sha256Hex(canonical(manifest))
        else {
            return nil
        }

        return MatrixWaveEstablishmentProjection(
            markerEventID: markerEventID,
            manifest: MatrixWaveEstablishmentManifest(
                version: manifest.version,
                hashAlgorithm: manifest.hashAlgorithm,
                manifestHash: manifest.manifestHash,
                roomID: manifest.roomID,
                parentSpaceID: manifest.parentSpaceID,
                bootstrapEventIDs: manifest.bootstrapEventIDs.sorted(by: utf8Less)
            )
        )
    }

    /// Verifies the server-authoritative current-state projection used when
    /// the Rust SDK timeline window does not contain the marker or hierarchy.
    /// The server has already proved actor membership and reciprocal edges;
    /// this client still validates event identity, state keys, event types,
    /// and the exact marker bytes before suppressing anything.
    public static func verify(
        authoritative state: MatrixWaveAuthoritativeState,
        roomID: String,
        trustedServiceUserID: String
    ) -> MatrixWaveEstablishmentProjection? {
        guard
            state.roomID == roomID,
            let marker = state.marker,
            marker.roomID == roomID,
            marker.type == eventType,
            marker.stateKey.isEmpty,
            !state.parents.isEmpty
        else { return nil }

        var parentIDs = Set<String>()
        var parentEdges = [String: MatrixWaveAuthoritativeParent]()
        for relation in state.parents {
            guard
                relation.parentEvent.roomID == roomID,
                relation.childEvent.roomID == relation.spaceRoomID,
                relation.parentEvent.type == "m.space.parent",
                relation.parentEvent.stateKey == relation.spaceRoomID,
                relation.childEvent.type == "m.space.child",
                relation.childEvent.stateKey == roomID,
                relation.parentEvent.sender == relation.childEvent.sender,
                isCanonicalParentContent(relation.parentEvent.contentJSON),
                isCanonicalChildContent(relation.childEvent.contentJSON)
            else { return nil }
            parentIDs.insert(relation.spaceRoomID)
            parentEdges[relation.spaceRoomID] = relation
        }

        return verify(
            contentJSON: marker.contentJSON,
            markerEventID: marker.eventID,
            stateKey: marker.stateKey,
            senderID: marker.sender,
            trustedServiceUserID: trustedServiceUserID,
            roomID: roomID,
            canonicalParentSpaceIDs: parentIDs,
            hasCanonicalReciprocalParentEdge: { parentID in
                guard let relation = parentEdges[parentID] else { return false }
                return isCanonicalChildContent(relation.childEvent.contentJSON)
            }
        )
    }

    public static func canonical(
        _ manifest: MatrixWaveEstablishmentManifest
    ) -> String {
        ([
            "westreem-wave-establishment",
            String(manifest.version),
            manifest.roomID,
            manifest.parentSpaceID,
        ] + Array(Set(manifest.bootstrapEventIDs)).sorted(by: utf8Less))
            .joined(separator: "\n")
    }

    private static func utf8Less(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        for (leftByte, rightByte) in zip(a, b) where leftByte != rightByte {
            return leftByte < rightByte
        }
        return a.count < b.count
    }

    public static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func cacheKey(
        roomID: String,
        manifestHash: String?
    ) -> String {
        let encoded = roomID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? roomID
        return "wave-projection:v\(cacheProjectionVersion):\(encoded):\(manifestHash ?? "legacy")"
    }

    public static func isCanonicalParentContent(
        _ contentJSON: String
    ) -> Bool {
        guard
            let data = contentJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let content = object as? [String: Any],
            content["canonical"] as? Bool == true,
            let via = content["via"] as? [Any],
            !via.isEmpty,
            via.allSatisfy({ value in
                guard let string = value as? String else { return false }
                return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            return false
        }
        return true
    }

    private static func isCanonicalChildContent(
        _ contentJSON: String
    ) -> Bool {
        guard
            let data = contentJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let content = object as? [String: Any],
            let via = content["via"] as? [Any]
        else { return false }
        return !via.isEmpty && via.allSatisfy { value in
            guard let string = value as? String else { return false }
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func validMatrixID(
        _ value: String,
        sigil: Character
    ) -> Bool {
        value.count > 1
            && value.first == sigil
            && value.utf8.count <= 255
            && !value.contains(where: { $0.isWhitespace })
    }
}
