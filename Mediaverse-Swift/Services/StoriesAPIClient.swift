import Foundation

enum StoriesRequestPolicy {
    static func shouldRetry(method: String) -> Bool {
        method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "GET"
    }

    static func isAllowedUploadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

actor StoriesAPIClient {
    static let shared = StoriesAPIClient()

    private let session: URLSession
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(
        session: URLSession = StoriesAPIClient.makeSession(),
        baseURL: URL = URL(string: C.baseURL) ?? URL(string: "https://www.westreem.com")!
    ) {
        self.session = session
        self.baseURL = baseURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { @Sendable decoder in
            try Self.decodeDate(from: decoder)
        }
        self.decoder = decoder
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()

        if let timestamp = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: timestamp)
        }

        let string = try container.decode(String.self)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date.")
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    func fetchGroups(
        myChannelId: String? = nil,
        myPublisherType: String? = nil,
        myPublisherId: String? = nil
    ) async throws -> [StoryGroup] {
        var path = "/api/stories"
        if let myPublisherType,
           let myPublisherId,
           !myPublisherType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !myPublisherId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "myPublisherType", value: myPublisherType),
                URLQueryItem(name: "myPublisherId", value: myPublisherId)
            ]
            if let query = components.percentEncodedQuery {
                path += "?\(query)"
            }
        } else if let myChannelId,
           !myChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let encoded = myChannelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?myChannelId=\(encoded)"
        }
        return try await send(path, method: "GET", body: Optional<Data>.none, authenticated: true)
    }

    func markViewed(storyId: String) async throws {
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await send("/api/stories/\(C.pathSegment(storyId))/view", method: "POST", body: Data(), authenticated: true)
    }

    func toggleLike(storyId: String) async throws -> StoryLikeResponse {
        try await send("/api/stories/\(C.pathSegment(storyId))/like", method: "POST", body: Data(), authenticated: true)
    }

    func fetchEnergy(storyId: String) async throws -> StoryEnergyResponse {
        try await send(
            "/api/stories/\(C.pathSegment(storyId))/rating",
            method: "GET",
            body: Optional<Data>.none,
            authenticated: true
        )
    }

    func submitEnergy(storyId: String, overall: Int, tags: [String]) async throws -> StoryEnergyUserRating {
        struct Body: Encodable {
            let overall: Int
            let tags: [String]
        }
        let data = try encoder.encode(Body(overall: min(max(overall, 1), 5), tags: Array(tags.prefix(6))))
        return try await send(
            "/api/stories/\(C.pathSegment(storyId))/rating",
            method: "POST",
            body: data,
            authenticated: true
        )
    }

    func removeEnergy(storyId: String) async throws {
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await send(
            "/api/stories/\(C.pathSegment(storyId))/rating",
            method: "DELETE",
            body: Optional<Data>.none,
            authenticated: true
        )
    }

    func getUploadUrl(mimeType: String) async throws -> UploadUrlResponse {
        let data = try encoder.encode(UploadUrlRequest(mimeType: mimeType))
        return try await send("/api/stories/upload-url", method: "POST", body: data, authenticated: true)
    }

    func uploadMedia(to url: URL, data: Data, mimeType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-upload-\(UUID().uuidString)")
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await uploadMedia(to: url, fileURL: fileURL, mimeType: mimeType, onProgress: onProgress)
    }

    /// Uploads raw media bytes to a presigned R2 URL. R2 returns an empty 2xx response on success.
    func uploadMedia(to url: URL, fileURL: URL, mimeType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let resolvedURL = resolvedUploadURL(from: url)
        var request = URLRequest(url: resolvedURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        // Same-site proxy uploads require the mobile session. Presigned R2
        // destinations are external and intentionally receive no credentials.
        attachAuth(&request)

        await MainActor.run { onProgress(0) }
        let progressDelegate = StoriesUploadProgressDelegate(onProgress: onProgress)
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL, delegate: progressDelegate)
        try validate(response, data: responseData)
        await MainActor.run { onProgress(1) }
    }

    func transcodeStoryMedia(objectKey: String) async throws -> String {
        let data = try encoder.encode(TranscodeStoryMediaRequest(objectKey: objectKey))
        let response: TranscodeStoryMediaResponse = try await send("/api/stories/transcode", method: "POST", body: data, authenticated: true)
        let mediaUrl = response.mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mediaUrl.isEmpty else { throw StoriesError.missingMediaUrl }
        return mediaUrl
    }

    func createStory(_ request: CreateStoryRequest) async throws -> StoryItem {
        let data = try encoder.encode(request)
        return try await send("/api/stories", method: "POST", body: data, authenticated: true)
    }

    func deleteStory(id: String) async throws {
        struct Response: Decodable { let success: Bool }
        let _: Response = try await send("/api/stories/\(C.pathSegment(id))", method: "DELETE", body: Optional<Data>.none, authenticated: true)
    }

    func fetchViewers(storyId: String, cursor: String? = nil, limit: Int = 30) async throws -> StoryViewersResponse {
        var components = URLComponents()
        components.path = "/api/stories/\(C.pathSegment(storyId))/viewers"
        var queryItems = [URLQueryItem(name: "limit", value: "\(min(max(limit, 1), 100))")]
        if let cursor, !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        return try await send(components.string ?? "/api/stories/\(C.pathSegment(storyId))/viewers", method: "GET", body: Optional<Data>.none, authenticated: true)
    }

    func pollVote(storyId: String, overlayIndex: Int, optionIndex: Int) async throws -> PollVoteResponse {
        struct Body: Encodable {
            let overlayIndex: Int
            let optionIndex: Int
        }
        let data = try encoder.encode(Body(overlayIndex: overlayIndex, optionIndex: optionIndex))
        return try await send("/api/stories/\(C.pathSegment(storyId))/poll", method: "POST", body: data, authenticated: true)
    }

    func quizAnswer(storyId: String, overlayIndex: Int, selectedIndex: Int) async throws -> QuizAnswerResponse {
        struct Body: Encodable {
            let overlayIndex: Int
            let selectedIndex: Int
        }
        let data = try encoder.encode(Body(overlayIndex: overlayIndex, selectedIndex: selectedIndex))
        return try await send("/api/stories/\(C.pathSegment(storyId))/quiz", method: "POST", body: data, authenticated: true)
    }

    func questionReply(storyId: String, overlayIndex: Int, text: String) async throws -> QuestionReplyResponse {
        struct Body: Encodable {
            let overlayIndex: Int
            let text: String
        }
        let data = try encoder.encode(Body(overlayIndex: overlayIndex, text: text))
        return try await send("/api/stories/\(C.pathSegment(storyId))/question", method: "POST", body: data, authenticated: true)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?, authenticated: Bool) async throws -> T {
        try await send(path, method: method, body: body, authenticated: authenticated, retrying: true)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?, authenticated: Bool, retrying: Bool) async throws -> T {
        let responseData = try await data(path, method: method, body: body, authenticated: authenticated, retrying: retrying)
        do {
            return try decoder.decode(T.self, from: responseData)
        } catch {
            throw StoriesError.decodingFailed
        }
    }

    private func data(_ path: String, method: String, body: Data?, authenticated: Bool, retrying: Bool) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw StoriesError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil && method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if authenticated {
            attachAuth(&request)
        }

        let (responseData, response) = try await session.data(for: request)
        do {
            try validate(response, data: responseData)
            return responseData
        } catch StoriesError.serverUnavailable where retrying && StoriesRequestPolicy.shouldRetry(method: method) {
            try await Task.sleep(nanoseconds: 350_000_000)
            return try await data(path, method: method, body: body, authenticated: authenticated, retrying: false)
        }
    }

    private func resolvedUploadURL(from url: URL) -> URL {
        if let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        return URL(string: url.absoluteString, relativeTo: baseURL)?.absoluteURL ?? url
    }

    func resolvedAllowedUploadURL(from rawValue: String) -> URL? {
        guard let rawURL = URL(string: rawValue) else { return nil }
        let resolved = resolvedUploadURL(from: rawURL)
        return StoriesRequestPolicy.isAllowedUploadURL(resolved) ? resolved : nil
    }

    private func attachAuth(_ request: inout URLRequest) {
        guard let url = request.url, C.isTrustedBackendURL(url) else {
            return
        }
        if let token = SessionStorage.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    private var cookieHeader: String? {
        var cookies = [String]()
        if let token = SessionStorage.token {
            let cookieNames = [
                "next-auth.session-token",
                "__Secure-next-auth.session-token",
                "authjs.session-token",
                "__Secure-authjs.session-token"
            ]
            cookies.append(contentsOf: cookieNames.map { "\($0)=\(token)" })
        }
        if let activeContext = SessionStorage.activeContextCookieValue {
            cookies.append("mv_active_ctx=\(activeContext)")
        }
        return cookies.isEmpty ? nil : cookies.joined(separator: "; ")
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StoriesError.serverUnavailable()
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let serverMessage = serverErrorMessage(from: data)
        switch http.statusCode {
        case 401:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notSignedIn
        case 403:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notAllowed
        case 404:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notFound
        case 413:
            throw StoriesError.videoTooLong
        case 500..<600:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.serverUnavailable(statusCode: http.statusCode)
        default:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.http(http.statusCode)
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail", "reason"] {
                if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            if let errors = object["errors"] as? [String], let first = errors.first, !first.isEmpty {
                return first
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return nil
    }
}

struct StoryLikeResponse: Decodable {
    let liked: Bool?
    let likeCount: Int?

    private enum CodingKeys: String, CodingKey {
        case liked, userLiked, myLike, likeCount, likes, count, story, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .story))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data))
        let source = nested ?? c

        liked = try source.decodeIfPresent(Bool.self, forKey: .liked)
            ?? source.decodeIfPresent(Bool.self, forKey: .userLiked)
            ?? source.decodeIfPresent(Bool.self, forKey: .myLike)
        likeCount = try source.decodeIfPresent(Int.self, forKey: .likeCount)
            ?? source.decodeIfPresent(Int.self, forKey: .likes)
            ?? source.decodeIfPresent(Int.self, forKey: .count)
    }
}

struct StoryEnergyUserRating: Decodable {
    let overall: Int
    let tags: [String]
    let review: String?
}

struct StoryEnergyAggregate: Decodable {
    let avg: Double?
    let count: Int
    let distribution: [String: Int]
    let topTags: [String]

    private enum CodingKeys: String, CodingKey {
        case avg, count, distribution, topTags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        avg = try values.decodeIfPresent(Double.self, forKey: .avg)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        distribution = try values.decodeIfPresent([String: Int].self, forKey: .distribution) ?? [:]
        if let strings = try? values.decode([String].self, forKey: .topTags) {
            topTags = strings
        } else if let keywords = try? values.decode([StoryEnergyKeyword].self, forKey: .topTags) {
            topTags = keywords.map(\.tag)
        } else if let counts = try? values.decode([String: Int].self, forKey: .topTags) {
            topTags = counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
        } else {
            topTags = []
        }
    }
}

private struct StoryEnergyKeyword: Decodable {
    let tag: String
    let count: Int?
}

struct StoryEnergyResponse: Decodable {
    let userRating: StoryEnergyUserRating?
    let aggregate: StoryEnergyAggregate
}

struct PollVoteResponse: Decodable {
    let overlayIndex: Int
    let votes: [Int]
    let totalVotes: Int
    let userVote: Int
}

struct QuizAnswerResponse: Decodable {
    let overlayIndex: Int
    let selectedIndex: Int
    let correctIndex: Int
    let isCorrect: Bool
    let alreadyAnswered: Bool
}

struct QuestionReplyResponse: Decodable {
    let id: String
    let text: String
    let createdAt: String
}

private final class StoriesUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        Task { @MainActor [onProgress] in
            onProgress(progress)
        }
    }
}

enum StoriesError: LocalizedError {
    case badURL
    case notSignedIn
    case notAllowed
    case notFound
    case serverUnavailable(statusCode: Int? = nil)
    case decodingFailed
    case missingMediaUrl
    case videoTooLong
    case http(Int)
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The flash endpoint is not configured correctly."
        case .notSignedIn:
            return "Sign in to use flashes."
        case .notAllowed:
            return "You do not have permission to manage this flash."
        case .notFound:
            return "This flash is no longer available."
        case .serverUnavailable(let statusCode):
            if let statusCode {
                return "Flashes are temporarily unavailable. Server returned HTTP \(statusCode)."
            }
            return "Flashes are temporarily unavailable."
        case .decodingFailed:
            return "Flashes returned an unexpected response."
        case .missingMediaUrl:
            return "Upload succeeded but no media URL was returned."
        case .videoTooLong:
            return "Video is too long or too large. Flashes can be up to 10 seconds."
        case .http(let code):
            return "Flashes request failed with HTTP \(code)."
        case .serverMessage(let message):
            return message
        }
    }
}
