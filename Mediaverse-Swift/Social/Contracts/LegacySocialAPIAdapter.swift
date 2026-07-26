import Foundation

/// Minimal transport seam implemented by the existing authenticated API client.
/// The social layer owns no cookies, tokens, retry policy, or backend behavior.
public protocol LegacySocialTransport: Sendable {
    func socialData(path: String) async throws -> Data
    func socialPostData(path: String, body: Data) async throws -> Data
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
