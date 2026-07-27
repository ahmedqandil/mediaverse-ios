import Foundation

/// Thin URLSession wrapper that authenticates with the stored mobile session JWT.
/// The JWT is stored through SessionStorage and attached to every request as both
/// a bearer token and compatibility cookies.
actor APIClient: LegacySocialTransport {
    static let shared = APIClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "MediaverseURLCache"
        )
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.httpCookieStorage = nil           // We manage cookies ourselves
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    /// Direct-to-storage transfers need a longer budget than interactive API calls,
    /// especially over cellular or when iOS has to resume an interrupted upload.
    private let uploadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private struct CachedResponse {
        let data: Data
        let cachedAt: Date
        let ttl: TimeInterval
    }

    private struct CachedSuggestResponse {
        let items: [SuggestItem]
        let cachedAt: Date
    }

    private struct InFlightDataRequest {
        let id: UUID
        let task: Task<Data, Error>
    }

    private var responseCache: [String: CachedResponse] = [:]
    private var searchSuggestCache: [String: CachedSuggestResponse] = [:]
    private var inFlightGETs: [String: InFlightDataRequest] = [:]
    private var transientInFlightGETs: [String: InFlightDataRequest] = [:]
    private var responseGeneration: UInt64 = 0
    private var allowsLegacyDiskResponseReads = true
    private var freshDiskResponseKeys: Set<String> = []
    private let searchSuggestTTL: TimeInterval = 30

    // MARK: - Auth header

    /// Current mobile session JWT returned by the auth endpoints.
    private var sessionToken: String? {
        SessionStorage.token
    }

    /// Builds the Cookie header value from the stored JWT for older endpoints.
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

    /// Attaches the mobile session token to a request.
    private func attachAuth(_ req: inout URLRequest) {
        guard let url = req.url, C.isTrustedBackendURL(url) else {
            return
        }
        // Every backend request carries its app identity so platform visibility
        // cannot be bypassed by endpoints that do not use query parameters.
        req.setValue("ios", forHTTPHeaderField: "X-Westreem-Platform")
        if let token = sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = cookieHeader {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private func cacheKey(for path: String) -> String {
        "\(SessionStorage.token ?? "anonymous")|\(SessionStorage.activeContextCookieValue ?? "default")|\(path)"
    }

    private func cacheTTL(for path: String) -> TimeInterval? {
        let contentPrefixes = [
            "/api/curation/page",
            "/api/platform-config",
            "/api/shorts",
            "/api/feed",
            "/api/videos/",
            "/api/episodes/",
            "/api/channels",
            "/api/shows",
            "/api/microdramas",
            "/api/collections",
            "/api/playlists",
            "/api/subscriptions/feed"
        ]

        let excludedPrefixes = [
            "/api/auth",
            "/api/me",
            "/api/progress",
            "/api/history",
            "/api/notifications",
            "/api/comments",
            "/api/entitlement",
            "/api/backstage"
        ]

        if excludedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return nil
        }

        guard contentPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return nil
        }

        if path.hasPrefix("/api/curation/page") || path.hasPrefix("/api/platform-config") {
            return 60
        }

        if path.hasPrefix("/api/channels/") || path.hasPrefix("/api/videos/") || path.hasPrefix("/api/shorts") {
            return 45
        }

        return 20
    }

    private func invalidateResponseCache() {
        responseGeneration &+= 1
        allowsLegacyDiskResponseReads = false
        freshDiskResponseKeys.removeAll()
        responseCache.removeAll()
        inFlightGETs.removeAll()
        transientInFlightGETs.removeAll()
    }

    private func invalidateResponseCache(matching shouldInvalidatePath: (String) -> Bool) async {
        responseGeneration &+= 1
        allowsLegacyDiskResponseReads = false
        transientInFlightGETs.removeAll()
        let candidateKeys = Set(responseCache.keys).union(inFlightGETs.keys)
        let keys = candidateKeys.filter { key in
            guard let path = cachedPath(from: key) else { return false }
            return shouldInvalidatePath(path)
        }
        for key in keys {
            responseCache[key] = nil
            inFlightGETs[key] = nil
            let diskKey = "api.response.v1.\(key)"
            freshDiskResponseKeys.remove(diskKey)
            try? await DiskJSONCache.shared.removeValue(forKey: diskKey)
        }
    }

    private func cachedPath(from key: String) -> String? {
        guard let range = key.range(of: "|/api") else { return nil }
        return String(key[range.lowerBound...].dropFirst())
    }

    private func pruneResponseCacheIfNeeded() {
        guard responseCache.count > 80 else { return }
        let sortedKeys = responseCache
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(responseCache.count - 60)
            .map(\.key)
        for key in sortedKeys {
            responseCache[key] = nil
        }
    }

    // MARK: - Convenience

    func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await getData(path)
        return try decoder.decode(T.self, from: data)
    }

    /// Frozen-backend bridge for the social adapter. Keeping this inside the
    /// existing client preserves its JWT, compatibility cookies, trust checks,
    /// caching, and error behavior for every social request.
    func socialData(path: String) async throws -> Data {
        do {
            let data = try await getData(path)
            #if DEBUG
            print("[social-api] GET \(path) bytes=\(data.count) authenticated=\(SessionStorage.token != nil)")
            #endif
            return data
        } catch {
            #if DEBUG
            print("[social-api] GET \(path) failed=\(String(describing: error)) authenticated=\(SessionStorage.token != nil)")
            #endif
            throw error
        }
    }

    func socialPostData(path: String, body: Data) async throws -> Data {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        attachAuth(&request)
        let (data, response) = try await session.data(for: request)
        do {
            try validate(response)
        } catch {
            if let payload = try? JSONDecoder().decode(SocialAPIErrorPayload.self, from: data),
               !payload.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw APIError.invalidResponse(payload.error)
            }
            throw error
        }
        invalidateResponseCache()
        return data
    }

    func socialPatchData(path: String, body: Data) async throws -> Data {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        attachAuth(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        invalidateResponseCache()
        return data
    }

    func socialDeleteData(path: String) async throws -> Data {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        invalidateResponseCache()
        return data
    }

    func socialUploadData(path: String, body: Data, contentType: String) async throws -> Data {
        let url: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            url = URL(string: path)
        } else {
            url = URL(string: C.baseURL + path)
        }
        guard let url else { throw APIError.badURL(path) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        attachAuth(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        invalidateResponseCache()
        return data
    }

    private func get<T: Decodable>(_ path: String, authenticated: Bool) async throws -> T {
        let data = try await getData(path, authenticated: authenticated)
        return try decoder.decode(T.self, from: data)
    }

    private func getData(_ path: String, authenticated: Bool = true) async throws -> Data {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        let generationAtRequestStart = responseGeneration

        if let ttl = cacheTTL(for: path) {
            let key = cacheKey(for: path)
            if let cached = responseCache[key],
               Date().timeIntervalSince(cached.cachedAt) < cached.ttl {
                CacheMetrics.shared.recordHit("api.response")
                return cached.data
            }

            let diskKey = "api.response.v1.\(key)"
            if allowsLegacyDiskResponseReads || freshDiskResponseKeys.contains(diskKey),
               let diskData: Data = try? await DiskJSONCache.shared.value(forKey: diskKey) {
                guard generationAtRequestStart == responseGeneration else {
                    return try await getData(path, authenticated: authenticated)
                }
                CacheMetrics.shared.recordHit("api.response")
                responseCache[key] = CachedResponse(data: diskData, cachedAt: Date(), ttl: ttl)
                pruneResponseCacheIfNeeded()
                return diskData
            }
            CacheMetrics.shared.recordMiss("api.response")

            if let inFlight = inFlightGETs[key] {
                CacheMetrics.shared.recordHit("api.response.inflight")
                let data = try await inFlight.task.value
                guard generationAtRequestStart == responseGeneration else {
                    return try await getData(path, authenticated: authenticated)
                }
                return data
            }

            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if authenticated {
                attachAuth(&req)
            }

            let requestID = UUID()
            let task = Task<Data, Error> {
                let (data, resp) = try await session.data(for: req)
                try validate(resp)
                return data
            }

            inFlightGETs[key] = InFlightDataRequest(id: requestID, task: task)
            do {
                let data = try await task.value
                guard generationAtRequestStart == responseGeneration else {
                    clearCachedInFlightRequest(key: key, id: requestID)
                    return try await getData(path, authenticated: authenticated)
                }
                responseCache[key] = CachedResponse(data: data, cachedAt: Date(), ttl: ttl)
                try? await DiskJSONCache.shared.store(data, forKey: diskKey, ttl: ttl)
                guard generationAtRequestStart == responseGeneration else {
                    return try await getData(path, authenticated: authenticated)
                }
                freshDiskResponseKeys.insert(diskKey)
                CacheMetrics.shared.recordStore("api.response", bytes: UInt64(data.count))
                clearCachedInFlightRequest(key: key, id: requestID)
                pruneResponseCacheIfNeeded()
                return data
            } catch {
                clearCachedInFlightRequest(key: key, id: requestID)
                guard generationAtRequestStart == responseGeneration else {
                    return try await getData(path, authenticated: authenticated)
                }
                if let staleData: Data = try? await DiskJSONCache.shared.staleValue(forKey: diskKey) {
                    guard generationAtRequestStart == responseGeneration else {
                        return try await getData(path, authenticated: authenticated)
                    }
                    CacheMetrics.shared.recordHit("api.response.stale")
                    responseCache[key] = CachedResponse(data: staleData, cachedAt: Date(), ttl: min(ttl, 10))
                    pruneResponseCacheIfNeeded()
                    return staleData
                }
                throw error
            }
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            attachAuth(&req)
        }
        let key = "\(cacheKey(for: path))|\(authenticated ? "authenticated" : "public")"
        if let inFlight = transientInFlightGETs[key] {
            CacheMetrics.shared.recordHit("api.transient.inflight")
            let data = try await inFlight.task.value
            guard generationAtRequestStart == responseGeneration else {
                return try await getData(path, authenticated: authenticated)
            }
            return data
        }

        let requestID = UUID()
        let task = Task<Data, Error> {
            let (data, resp) = try await session.data(for: req)
            try validate(resp)
            return data
        }
        transientInFlightGETs[key] = InFlightDataRequest(id: requestID, task: task)
        do {
            let data = try await task.value
            clearTransientInFlightRequest(key: key, id: requestID)
            guard generationAtRequestStart == responseGeneration else {
                return try await getData(path, authenticated: authenticated)
            }
            return data
        } catch {
            clearTransientInFlightRequest(key: key, id: requestID)
            guard generationAtRequestStart == responseGeneration else {
                return try await getData(path, authenticated: authenticated)
            }
            throw error
        }
    }

    private func clearCachedInFlightRequest(key: String, id: UUID) {
        guard inFlightGETs[key]?.id == id else { return }
        inFlightGETs[key] = nil
    }

    private func clearTransientInFlightRequest(key: String, id: UUID) {
        guard transientInFlightGETs[key]?.id == id else { return }
        transientInFlightGETs[key] = nil
    }

    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await post(path, body: body, invalidatesCache: true)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body, invalidatesCache: Bool) async throws -> T {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        if invalidatesCache {
            invalidateResponseCache()
        }
        return try decoder.decode(T.self, from: data)
    }

    func postEmpty(_ path: String) async throws {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        attachAuth(&req)
        let (_, resp) = try await session.data(for: req)
        try validate(resp)
        invalidateResponseCache()
    }

    func patch<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        invalidateResponseCache()
        return try decoder.decode(T.self, from: data)
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        invalidateResponseCache()
        return try decoder.decode(T.self, from: data)
    }

    func delete<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        invalidateResponseCache()
        return try decoder.decode(T.self, from: data)
    }

    func deleteEmpty(_ path: String) async throws {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        attachAuth(&req)
        let (_, resp) = try await session.data(for: req)
        try validate(resp)
        invalidateResponseCache()
    }

    // MARK: - Auth helpers

    /// Store a JWT — called after magic-link verify or Google OAuth.
    func storeSessionToken(_ jwt: String) {
        SessionStorage.token = jwt
    }

    /// Clear the stored JWT — called on sign-out.
    func clearSessionToken() {
        SessionStorage.token = nil
        SessionStorage.activeContext = nil
    }

    /// Request a magic-link email. In dev/no-email mode the backend can return debug_url.
    func requestMagicLink(email: String) async throws -> String? {
        struct Body: Encodable { let email: String; let mobile: Bool; let appScheme: String }
        struct Resp: Decodable { let ok: Bool?; let debug_url: String? }
        let resp: Resp = try await post(
            "/api/auth/magic",
            body: Body(email: email, mobile: true, appScheme: "westreem")
        )
        return resp.debug_url
    }

    /// Verify a magic-link token and store the returned JWT.
    /// Returns true if the server confirmed authentication.
    func verifyMagicLink(token: String) async throws -> Bool {
        struct Body: Encodable { let token: String }
        struct Resp: Decodable { let sessionToken: String?; let userId: String? }
        let resp: Resp = try await post("/api/auth/mobile/verify", body: Body(token: token))
        if let jwt = resp.sessionToken {
            storeSessionToken(jwt)
            return true
        }
        return false
    }

    /// Refresh the mobile JWT before it expires (Fix 6: tokens now expire in 7 days).
    /// Call when the stored token has ≤24 h remaining. The server issues a fresh
    /// 7-day token; on success the new JWT replaces the old one in Keychain.
    func refreshMobileToken() async throws {
        struct Resp: Decodable { let sessionToken: String? }
        struct EmptyBody: Encodable {}
        let resp: Resp = try await post("/api/auth/mobile/refresh", body: EmptyBody())
        if let jwt = resp.sessionToken {
            storeSessionToken(jwt)
        }
    }

    /// Check current session — returns nil if not authenticated.
    func fetchSession() async throws -> UserProfile? {
        struct Resp: Decodable { let user: UserProfile? }
        let resp: Resp = try await get("/api/auth/session")
        return resp.user
    }

    func signOut() async throws {
        try await postEmpty("/api/auth/signout")
    }

    // MARK: - Device pairing

    func requestDevicePairingCode(deviceName: String, deviceType: String) async throws -> DevicePairingCodeResponse {
        struct Body: Encodable {
            let deviceName: String
            let deviceType: String
        }
        return try await post("/api/auth/device/code", body: Body(deviceName: deviceName, deviceType: deviceType))
    }

    func pollDevicePairing(deviceCode: String) async throws -> DevicePairingPollResponse {
        struct Body: Encodable { let deviceCode: String }
        return try await post("/api/auth/device/poll", body: Body(deviceCode: deviceCode))
    }

    func activateDevicePairing(userCode: String) async throws -> DevicePairingActivationResponse {
        struct Body: Encodable { let userCode: String }
        return try await post("/api/auth/device/activate", body: Body(userCode: userCode))
    }

    func fetchPairedDevices() async throws -> [PairedDevice] {
        let response: PairedDevicesResponse = try await get("/api/me/devices")
        return response.devices
    }

    func revokePairedDevice(id: String) async throws {
        try await deleteEmpty("/api/me/devices/\(C.pathSegment(id))")
    }

    /// GET /api/platform-config — mirrors the web PlatformConfig gate.
    /// Stories default to visible if the endpoint is unavailable so older backends keep working.
    func fetchPlatformConfig() async throws -> PlatformConfig {
        let revision = Int(Date().timeIntervalSince1970)
        return try await get("/api/platform-config?platform=ios&revision=\(revision)")
    }

    func fetchAdminAdConfig() async throws -> AdminAdConfig {
        return try await get("/api/admin/ad-config")
    }

    // MARK: - Feed

    func fetchFeed(cursor: String? = nil) async throws -> FeedResponse {
        var components = URLComponents()
        components.path = "/api/feed"
        components.queryItems = [URLQueryItem(name: "platform", value: "ios")]
        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let path = components.url?.absoluteString else {
            throw APIError.badURL("/api/feed")
        }
        return try await get(path)
    }

    func fetchCurationPage(key: String, section: String? = nil) async throws -> AssembledPage {
        var components = URLComponents()
        components.path = "/api/curation/page/\(C.pathSegment(key))"
        components.queryItems = [
            URLQueryItem(name: "device", value: "mobile"),
            URLQueryItem(name: "platform", value: "ios")
        ]
        if let section, !section.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "section", value: section))
        }
        guard let path = components.url?.absoluteString else {
            throw APIError.badURL("/api/curation/page/\(C.pathSegment(key))")
        }
        let response: CurationPageResponse = try await get(path)
        guard response.ok else {
            throw APIError.invalidResponse("curation page \(key) not ok")
        }
        return response.data
    }

    func trackCurationEvent(
        listingId: String,
        eventType: String,
        contentId: String? = nil,
        sessionId: String? = nil
    ) async {
        struct Body: Encodable {
            let listingId: String
            let eventType: String
            let contentId: String?
            let device: String
            let sessionId: String?
        }
        guard let url = URL(string: C.baseURL + "/api/curation/event"),
              let body = try? JSONEncoder().encode(
                Body(
                    listingId: listingId,
                    eventType: eventType,
                    contentId: contentId,
                    device: "mobile",
                    sessionId: sessionId
                )
              ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        attachAuth(&request)
        _ = try? await session.data(for: request)
    }

    // MARK: - Shorts

    func fetchShorts(
        feed: String = "recommended",
        cursor: String? = nil,
        limit: Int = 10,
        seed: String? = nil,
        source: String? = nil,
        sourceId: String? = nil,
        ids: [String]? = nil,
        forceRefresh: Bool = false
    ) async throws -> ShortsResponse {
        let normalizedFeed = feed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cappedLimit = min(max(limit, 1), 30)
        let trimmedSeed = seed?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestSeed = trimmedSeed?.isEmpty == false ? trimmedSeed! : UUID().uuidString

        var components = URLComponents()
        components.path = "/api/shorts"
        components.queryItems = [
            URLQueryItem(name: "feed", value: normalizedFeed),
            URLQueryItem(name: "limit", value: String(cappedLimit)),
            URLQueryItem(name: "seed", value: requestSeed),
            URLQueryItem(name: "platform", value: "ios")
        ]

        if let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !cursor.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }

        let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedSourceId = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSource, !trimmedSource.isEmpty, let trimmedSourceId, !trimmedSourceId.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "source", value: trimmedSource))
            components.queryItems?.append(URLQueryItem(name: "sourceId", value: trimmedSourceId))
        }

        if let ids {
            let normalizedIDs = ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !normalizedIDs.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "ids", value: normalizedIDs.joined(separator: ",")))
            }
        }

        if forceRefresh {
            components.queryItems?.append(URLQueryItem(name: "_refresh", value: UUID().uuidString))
        }

        guard let path = components.url?.absoluteString else {
            throw APIError.badURL("/api/shorts")
        }

        do {
            let response: ShortsResponse = try await get(path)
            if response.shorts.isEmpty, SessionStorage.token != nil {
                let anonymousResponse: ShortsResponse = try await get(path, authenticated: false)
                if !anonymousResponse.shorts.isEmpty {
                    return anonymousResponse
                }
            }
            return response
        } catch APIError.unauthorized {
            return try await get(path, authenticated: false)
        } catch APIError.http(let status) where status == 403 {
            return try await get(path, authenticated: false)
        }
    }

    func recordShortView(videoId: String) async throws {
        guard let url = URL(string: C.baseURL + "/api/shorts/view") else {
            throw APIError.badURL("/api/shorts/view")
        }
        struct Body: Encodable { let videoId: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(Body(videoId: videoId))
        attachAuth(&req)
        let (_, resp) = try await session.data(for: req)
        try validate(resp)
        await invalidateResponseCache { path in
            path.hasPrefix("/api/shorts")
            || path.hasPrefix("/api/feed")
            || path.hasPrefix("/api/curation/page")
            || path.hasPrefix("/api/videos/\(C.pathSegment(videoId))")
        }
    }

    // MARK: - Video detail

    func fetchVideo(id: String) async throws -> VideoDetail {
        return try await get("/api/videos/\(C.pathSegment(id))")
    }

    // MARK: - Episode detail

    func fetchEpisode(id: String) async throws -> EpisodeDetail {
        return try await get("/api/episodes/\(C.pathSegment(id))")
    }

    // MARK: - Channel

    func fetchChannels() async throws -> [ChannelBrowseCard] {
        return try await get("/api/channels")
    }

    func fetchChannel(handle: String) async throws -> ChannelDetail {
        return try await get("/api/channels/\(C.pathSegment(handle))")
    }

    func fetchChannelShorts(handle: String) async throws -> [ChannelDetail.VideoItem] {
        return try await get("/api/channels/\(C.pathSegment(handle))/shorts")
    }

    func fetchChannelPlaylists(handle: String) async throws -> [ChannelPlaylist] {
        return try await get("/api/channels/\(C.pathSegment(handle))/playlists")
    }

    func fetchChannelFollowStatus(handle: String) async throws -> FollowStatus {
        return try await get("/api/channels/\(C.pathSegment(handle))/subscribe")
    }

    func toggleChannelFollow(handle: String) async throws -> FollowStatus {
        struct Empty: Encodable {}
        return try await post("/api/channels/\(C.pathSegment(handle))/subscribe", body: Empty())
    }

    func setChannelNotify(handle: String, on: Bool) async throws {
        struct Body: Encodable { let notifyOnPublish: Bool }
        struct Resp: Decodable { let notifyOnPublish: Bool }
        let _: Resp = try await patch("/api/channels/\(C.pathSegment(handle))/subscribe", body: Body(notifyOnPublish: on))
    }

    // MARK: - Show

    func fetchShow(id: String) async throws -> ShowPageResponse {
        return try await get("/api/shows/\(C.pathSegment(id))")
    }

    func fetchShowClips(id: String) async throws -> [ShowClip] {
        return try await get("/api/shows/\(C.pathSegment(id))/videos")
    }

    func fetchShowPlaylists(id: String) async throws -> [ChannelPlaylist] {
        return try await get("/api/shows/\(C.pathSegment(id))/playlists")
    }

    func fetchShowFollowStatus(id: String) async throws -> FollowStatus {
        return try await get("/api/shows/\(C.pathSegment(id))/subscribe")
    }

    func toggleShowFollow(id: String) async throws -> FollowStatus {
        struct Empty: Encodable {}
        return try await post("/api/shows/\(C.pathSegment(id))/subscribe", body: Empty())
    }

    func setShowNotify(id: String, on: Bool) async throws {
        struct Body: Encodable { let notifyOnPublish: Bool }
        struct Resp: Decodable { let notifyOnPublish: Bool }
        let _: Resp = try await patch("/api/shows/\(C.pathSegment(id))/subscribe", body: Body(notifyOnPublish: on))
    }

    // MARK: - Contexts

    func fetchContexts() async throws -> ContextsResponse {
        let contextAtRequestStart = SessionStorage.activeContextCookieValue
        let response: ContextsResponse = try await get("/api/me/contexts")
        if SessionStorage.activeContextCookieValue == contextAtRequestStart {
            SessionStorage.activeContext = response.active
        }
        return response
    }

    // MARK: - Profile

    func fetchProfile() async throws -> ProfileResponse {
        return try await get("/api/me/profile")
    }

    func updateProfile(name: String?, bio: String?, image: String?, bannerUrl: String?) async throws -> ProfileResponse {
        struct Body: Encodable {
            let name: String?
            let bio: String?
            let image: String?
            let bannerUrl: String?
        }
        return try await patch(
            "/api/me/profile",
            body: Body(name: name, bio: bio, image: image, bannerUrl: bannerUrl)
        )
    }

    func completeOnboarding(name: String, handle: String, bio: String?, image: String?) async throws -> ProfileResponse {
        struct Body: Encodable {
            let name: String
            let handle: String
            let bio: String?
            let image: String?
        }
        let body = Body(name: name, handle: handle, bio: bio, image: image)
        do {
            return try await post("/api/me/onboarding", body: body)
        } catch APIError.notFound {
            // Keep device builds compatible while the atomic onboarding endpoint
            // rolls out: both of these profile endpoints already exist in production.
            struct LegacyProfileBody: Encodable {
                let name: String
                let bio: String?
                let image: String?
            }
            struct HandleBody: Encodable { let handle: String }
            struct HandleResponse: Decodable { let handle: String }

            let _: FullProfile = try await patch(
                "/api/me/profile",
                body: LegacyProfileBody(name: name, bio: bio, image: image)
            )
            let _: HandleResponse = try await patch(
                "/api/me/handle",
                body: HandleBody(handle: handle)
            )
            // The deployed POST is the existing idempotent personal-Atmo bootstrap.
            try await postEmpty("/api/me/personal-vibe")
            return try await fetchProfile()
        }
    }

    func fetchBackstageChannel(channelId: String) async throws -> BackstageChannelSettings {
        try await get("/api/backstage/channel/\(C.pathSegment(channelId))")
    }

    func updateBackstageChannel(channelId: String, name: String, avatarUrl: String?, bannerUrl: String?) async throws -> BackstageChannelSettings {
        struct Body: Encodable {
            let name: String
            let avatarUrl: String?
            let bannerUrl: String?
        }
        return try await patch(
            "/api/backstage/channel/\(C.pathSegment(channelId))",
            body: Body(name: name, avatarUrl: avatarUrl, bannerUrl: bannerUrl)
        )
    }

    func uploadBackstageImage(channelId: String, type: String, imageData: Data) async throws -> String {
        struct Response: Decodable { let url: String }
        guard let url = URL(string: C.baseURL + "/api/backstage/upload") else {
            throw APIError.badURL("/api/backstage/upload")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        appendMultipartField(name: "channelId", value: channelId, boundary: boundary, to: &body)
        appendMultipartField(name: "type", value: type, boundary: boundary, to: &body)
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(type).jpg\"\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&req)

        let (data, resp) = try await session.upload(for: req, from: body)
        try validate(resp)
        return try decoder.decode(Response.self, from: data).url
    }

    func uploadProfileBlobImage(kind: String, imageData: Data) async throws -> String {
        struct TokenEvent: Encodable {
            struct Payload: Encodable {
                let pathname: String
                let clientPayload: String?
                let multipart: Bool
            }

            let type: String
            let payload: Payload
        }

        struct TokenResponse: Decodable {
            let clientToken: String
        }

        struct BlobResponse: Decodable {
            let url: String
            let downloadUrl: String?
            let pathname: String?
            let contentType: String?
            let contentDisposition: String?
            let etag: String?
        }

        let folder = kind == "banner" ? "banners" : "avatars"
        let filename = "\(Int(Date().timeIntervalSince1970 * 1000))-\(kind).jpg"
        let pathname = "\(folder)/\(filename)"

        guard let tokenURL = URL(string: C.baseURL + "/api/upload/blob-token") else {
            throw APIError.badURL("/api/upload/blob-token")
        }

        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.httpBody = try JSONEncoder().encode(
            TokenEvent(
                type: "blob.generate-client-token",
                payload: TokenEvent.Payload(
                    pathname: pathname,
                    clientPayload: nil,
                    multipart: false
                )
            )
        )
        attachAuth(&tokenRequest)

        let (tokenData, tokenResp) = try await session.data(for: tokenRequest)
        try validate(tokenResp)
        let clientToken = try decoder.decode(TokenResponse.self, from: tokenData).clientToken
        guard let storeId = blobStoreId(fromClientToken: clientToken), !storeId.isEmpty else {
            throw APIError.invalidResponse("Blob upload token did not include a store id.")
        }

        var components = URLComponents(string: "https://vercel.com/api/blob/")
        components?.queryItems = [URLQueryItem(name: "pathname", value: pathname)]
        guard let uploadURL = components?.url else {
            throw APIError.badURL("https://vercel.com/api/blob")
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.timeoutInterval = 120
        uploadRequest.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue("public", forHTTPHeaderField: "x-vercel-blob-access")
        uploadRequest.setValue("image/jpeg", forHTTPHeaderField: "x-content-type")
        uploadRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(imageData.count), forHTTPHeaderField: "x-content-length")
        uploadRequest.setValue(storeId, forHTTPHeaderField: "x-vercel-blob-store-id")
        uploadRequest.setValue("12", forHTTPHeaderField: "x-api-version")
        uploadRequest.setValue("\(storeId):\(Int(Date().timeIntervalSince1970 * 1000)):\(UUID().uuidString)", forHTTPHeaderField: "x-api-blob-request-id")
        uploadRequest.setValue("0", forHTTPHeaderField: "x-api-blob-request-attempt")

        let (blobData, blobResp) = try await uploadSession.upload(for: uploadRequest, from: imageData)
        try validateBlobUploadResponse(blobResp)
        let decoded = try decoder.decode(BlobResponse.self, from: blobData)
        return decoded.url
    }

    // MARK: - Upload

    func fetchUploadContexts() async throws -> UploadContextsResponse {
        return try await get("/api/me/upload-contexts")
    }

    func fetchUploadPlaylists(destination: UploadContext, contentType: String) async throws -> [UploadPlaylistOption] {
        let type = contentType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contentType
        let destinationId = destination.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? destination.id
        if destination.type == "show" {
            return try await get("/api/playlists?showId=\(destinationId)&type=\(type)")
        }
        return try await get("/api/playlists?channelId=\(destinationId)&type=\(type)")
    }

    func createCfStreamUpload(fileSize: Int64, channelId: String?) async throws -> CfStreamUploadResponse {
        var path = "/api/video/cf-stream-upload?fileSize=\(fileSize)"
        if let channelId {
            let enc = channelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelId
            path += "&channelId=\(enc)"
        }
        return try await get(path)
    }

    func uploadThumbnailImage(_ imageData: Data) async throws -> String {
        struct Response: Decodable {
            let url: String?
            let imageUrl: String?
            let thumbnailUrl: String?
        }

        guard let url = URL(string: C.baseURL + "/api/upload/thumbnail") else {
            throw APIError.badURL("/api/upload/thumbnail")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"thumbnail.jpg\"\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&req)

        let (data, resp) = try await session.upload(for: req, from: body)
        try validate(resp)
        let decoded = try decoder.decode(Response.self, from: data)
        if let url = decoded.url ?? decoded.thumbnailUrl ?? decoded.imageUrl, !url.isEmpty {
            return url
        }
        throw APIError.invalidResponse("Thumbnail upload did not return an image URL.")
    }

    private func appendMultipartField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(value.data(using: .utf8) ?? Data())
        body.append("\r\n".data(using: .utf8) ?? Data())
    }

    nonisolated private func blobStoreId(fromClientToken token: String) -> String? {
        let parts = token.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count > 3 else { return nil }
        return String(parts[3])
    }

    nonisolated private func validateBlobUploadResponse(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }
    }

    func uploadToTus(uploadUrl: URL, fileURL: URL, fileSize: Int64, progress: @escaping @Sendable (Double) async -> Void) async throws {
        var offset = try await fetchTusOffset(uploadUrl: uploadUrl)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(offset))
        let chunkSize = 8 * 1024 * 1024

        while offset < fileSize {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }

            var req = URLRequest(url: uploadUrl)
            req.httpMethod = "PATCH"
            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")

            let (_, resp) = try await session.upload(for: req, from: data)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse, http.statusCode == 204 || http.statusCode == 200 else {
                throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let nextOffset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? (offset + Int64(data.count))
            guard nextOffset > offset, nextOffset <= fileSize else {
                throw APIError.invalidResponse("Upload server returned an invalid byte offset.")
            }
            offset = nextOffset
            await progress(min(Double(offset) / Double(max(fileSize, 1)), 1))
        }

        guard offset == fileSize else {
            throw APIError.invalidResponse("The selected video changed before the upload completed.")
        }
    }

    func createUploadedVideo(
        title: String,
        description: String?,
        visibility: String,
        orientation: String,
        type: String,
        destination: UploadContext,
        playlistId: String?,
        linkedClipId: String?,
        linkedEpisodeId: String?,
        cfStreamId: String,
        thumbnailUrl: String?
    ) async throws -> UploadCreateResponse {
        struct Body: Encodable {
            let videoUrl: String?
            let cfStreamId: String?
            let thumbnailUrl: String?
            let title: String
            let description: String?
            let visibility: String
            let orientation: String
            let type: String
            let channelId: String?
            let showId: String?
            let playlistId: String?
            let linkedClipId: String?
            let linkedEpisodeId: String?
        }

        return try await post(
            "/api/upload",
            body: Body(
                videoUrl: nil,
                cfStreamId: cfStreamId,
                thumbnailUrl: thumbnailUrl,
                title: title,
                description: description,
                visibility: visibility,
                orientation: orientation,
                type: type,
                channelId: destination.type == "channel" ? destination.id : nil,
                showId: destination.type == "show" ? destination.id : nil,
                playlistId: playlistId,
                linkedClipId: linkedClipId,
                linkedEpisodeId: linkedEpisodeId
            )
        )
    }

    func fetchUploadStreamStatus(videoId: String) async throws -> UploadStreamStatus {
        return try await get("/api/video/\(C.pathSegment(videoId))/stream-status")
    }

    func fetchUploadLinkVideos(destination: UploadContext) async throws -> [UploadLinkItem] {
        let path = destination.type == "show"
            ? "/api/backstage/show/\(C.pathSegment(destination.id))/videos?type=video"
            : "/api/backstage/channel/\(C.pathSegment(destination.id))/videos?type=video"
        return try await get(path)
    }

    func fetchUploadLinkEpisodes(showId: String) async throws -> [UploadLinkItem] {
        struct Response: Decodable { let episodes: [UploadLinkItem] }
        let response: Response = try await get("/api/backstage/show/\(C.pathSegment(showId))/episodes")
        return response.episodes
    }

    func createNotification(type: String, title: String, message: String, linkUrl: String?) async throws {
        struct Body: Encodable {
            let type: String
            let title: String
            let message: String
            let linkUrl: String?
        }
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await post("/api/notifications", body: Body(type: type, title: title, message: message, linkUrl: linkUrl))
    }

    // MARK: - Entitlement

    func checkEntitlement(episodeId: String) async throws -> EntitlementCheckResponse {
        var components = URLComponents()
        components.path = "/api/entitlement/check"
        components.queryItems = [URLQueryItem(name: "episodeId", value: episodeId)]
        return try await get(components.string ?? "/api/entitlement/check?episodeId=\(episodeId)")
    }

    func checkPlaybackAccess(
        entitlementType: String,
        productId: String? = nil,
        episodeId: String? = nil,
        seasonId: String? = nil
    ) async throws -> EntitlementCheckResponse {
        var components = URLComponents()
        components.path = "/api/me/entitlements/check"
        components.queryItems = [
            URLQueryItem(name: "entitlementType", value: entitlementType),
            productId.map { URLQueryItem(name: "productId", value: $0) },
            episodeId.map { URLQueryItem(name: "episodeId", value: $0) },
            seasonId.map { URLQueryItem(name: "seasonId", value: $0) }
        ].compactMap { $0 }
        return try await get(components.string ?? "/api/me/entitlements/check?entitlementType=\(entitlementType)")
    }

    func fetchDeviceHandoff(publicId: String) async throws -> DeviceHandoffResponse {
        try await get("/api/device/handoff/\(C.pathSegment(publicId))")
    }

    func updateDeviceHandoff(publicId: String, action: String) async throws -> DeviceHandoffActionResponse {
        struct Body: Encodable { let action: String }
        return try await patch("/api/device/handoff/\(C.pathSegment(publicId))", body: Body(action: action))
    }

    func recordPPVPlaybackStart(episodeId: String? = nil, seasonId: String? = nil) async throws {
        struct Body: Encodable {
            let episodeId: String?
            let seasonId: String?
        }
        struct Response: Decodable {
            let recorded: Bool?
        }
        let _: Response = try await post(
            "/api/me/entitlements/check",
            body: Body(episodeId: episodeId, seasonId: seasonId)
        )
    }

    func fetchUserSubscriptions() async throws -> UserSubscriptionsResponse {
        return try await get("/api/me/subscriptions")
    }

    func fetchUserRentals() async throws -> UserRentalsResponse {
        return try await get("/api/me/rentals")
    }

    func cancelSubscription(id: String) async throws {
        try await postEmpty("/api/me/subscriptions/\(C.pathSegment(id))/cancel")
    }

    func submitPartnerRequest(reason: String?) async throws {
        struct Body: Encodable { let reason: String? }
        struct Response: Decodable { let ok: Bool }
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(reason: trimmedReason?.isEmpty == true ? nil : trimmedReason)
        let _: Response = try await post("/api/me/partner-request", body: body)
    }

    func fetchVideoPlaylist(videoId: String, playlistId: String? = nil) async throws -> VideoPlaylistResponse {
        var path = "/api/videos/\(C.pathSegment(videoId))/playlist"
        if let playlistId,
           let encoded = playlistId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?playlistId=\(encoded)"
        }
        return try await get(path)
    }

    // MARK: - Checkout

    func checkoutPPV(
        productId: String,
        networkId: String?,
        seasonId: String?,
        episodeId: String?
    ) async throws -> CheckoutResponse {
        struct Body: Encodable {
            let productId: String; let networkId: String?
            let seasonId: String?; let episodeId: String?
        }
        return try await post(
            "/api/checkout/ppv",
            body: Body(
                productId: productId,
                networkId: networkId,
                seasonId: seasonId,
                episodeId: episodeId
            )
        )
    }

    func checkoutSVOD(
        productId: String,
        networkId: String
    ) async throws -> CheckoutResponse {
        struct Body: Encodable {
            let productId: String
            let networkId: String
        }
        return try await post(
            "/api/checkout/svod",
            body: Body(productId: productId, networkId: networkId)
        )
    }

    // MARK: - Watch progress

    func deleteProgress(videoId: String) async throws {
        let enc = videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoId
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/progress?videoId=\(enc)")
    }

    func deleteProgress(episodeId: String) async throws {
        let enc = episodeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? episodeId
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/progress?episodeId=\(enc)")
    }

    func fetchContinueWatching() async throws -> ContinueWatchingResponse {
        return try await get("/api/progress")
    }

    func fetchProgress(videoId: String) async throws -> ProgressItem? {
        let enc = videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoId
        return try await get("/api/progress?videoId=\(enc)")
    }

    func fetchProgress(episodeId: String) async throws -> ProgressItem? {
        let enc = episodeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? episodeId
        return try await get("/api/progress?episodeId=\(enc)")
    }

    func recordProgress(videoId: String, seconds: Int, percent: Double) async throws {
        struct Body: Encodable { let videoId: String; let seconds: Int; let percent: Double }
        let _: ProgressItem = try await post(
            "/api/progress",
            body: Body(videoId: videoId, seconds: seconds, percent: min(max(percent, 0), 1)),
            invalidatesCache: false
        )
    }

    func recordProgress(episodeId: String, seconds: Int, percent: Double) async throws {
        struct Body: Encodable { let episodeId: String; let seconds: Int; let percent: Double }
        let _: ProgressItem = try await post(
            "/api/progress",
            body: Body(episodeId: episodeId, seconds: seconds, percent: min(max(percent, 0), 1)),
            invalidatesCache: false
        )
    }

    func fetchPlayerMarkers(videoId: String) async throws -> [PlayerMarker] {
        return try await get("/api/videos/\(C.pathSegment(videoId))/markers")
    }

    func fetchPlayerMarkers(episodeId: String) async throws -> [PlayerMarker] {
        return try await get("/api/episodes/\(C.pathSegment(episodeId))/markers")
    }

    // MARK: - Comments

    func fetchComments(videoId: String? = nil, episodeId: String? = nil, collectionId: String? = nil, parentId: String? = "null") async throws -> [Comment] {
        var query = "parentId=null"
        if let parentId { query = "parentId=\(parentId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? parentId)" }
        if let vid = videoId     { query += "&videoId=\(vid)" }
        if let eid = episodeId   { query += "&episodeId=\(eid)" }
        if let cid = collectionId { query += "&collectionId=\(cid)" }
        return try await get("/api/comments?\(query)")
    }

    // POST /api/comments — body field is "content" (not "body"); response is the Comment directly, not wrapped
    func postComment(content: String, videoId: String? = nil, episodeId: String? = nil, collectionId: String? = nil, parentId: String? = nil) async throws -> Comment {
        struct Body: Encodable {
            let content:      String
            let videoId:      String?
            let episodeId:    String?
            let collectionId: String?
            let parentId:     String?
        }
        return try await post("/api/comments", body: Body(content: content, videoId: videoId, episodeId: episodeId, collectionId: collectionId, parentId: parentId))
    }

    func likeComment(commentId: String, liked: Bool) async throws -> Comment {
        struct Body: Encodable { let like: Bool }
        return try await patch("/api/comments/\(C.pathSegment(commentId))", body: Body(like: liked))
    }

    func flagComment(commentId: String) async throws -> Comment {
        struct Body: Encodable { let flag: Bool }
        return try await patch("/api/comments/\(C.pathSegment(commentId))", body: Body(flag: true))
    }

    func editComment(commentId: String, content: String) async throws -> Comment {
        struct Body: Encodable { let content: String }
        return try await patch("/api/comments/\(C.pathSegment(commentId))", body: Body(content: content))
    }

    func deleteComment(commentId: String) async throws {
        try await deleteEmpty("/api/comments/\(C.pathSegment(commentId))")
    }

    // MARK: - Context switch

    func switchContext(_ ctx: ActiveContext) async throws -> SwitchContextResponse {
        guard let url = URL(string: C.baseURL + "/api/me/active-context") else {
            throw APIError.badURL("/api/me/active-context")
        }

        let body = SwitchContextBody(id: ctx.id, type: ctx.type, name: ctx.name, channelId: ctx.channelId, showId: ctx.showId)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        attachAuth(&req)

        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        let response = try decoder.decode(SwitchContextResponse.self, from: data)
        storeSessionStateIfPresent(in: resp, data: data)
        if let canonicalContext = response.context {
            SessionStorage.activeContext = canonicalContext
        }
        invalidateResponseCache()
        await MainActor.run {
            UploadOptionsCache.clear()
        }
        return response
    }

    // MARK: - Search

    func searchSuggest(q: String) async throws -> [SuggestItem] {
        let normalized = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = "q:\(normalized)"
        if let cached = searchSuggestCache[cacheKey], Date().timeIntervalSince(cached.cachedAt) < searchSuggestTTL {
            CacheMetrics.shared.recordHit("search.suggest")
            return cached.items
        }

        CacheMetrics.shared.recordMiss("search.suggest")
        let enc = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalized
        let items: [SuggestItem] = try await get("/api/search/suggest?q=\(enc)&platform=ios")
        searchSuggestCache[cacheKey] = CachedSuggestResponse(items: items, cachedAt: Date())
        CacheMetrics.shared.recordStore("search.suggest")
        return items
    }

    func searchTrendingSuggest() async throws -> [SuggestItem] {
        let cacheKey = "trending"
        if let cached = searchSuggestCache[cacheKey], Date().timeIntervalSince(cached.cachedAt) < searchSuggestTTL {
            CacheMetrics.shared.recordHit("search.suggest")
            return cached.items
        }

        CacheMetrics.shared.recordMiss("search.suggest")
        let items: [SuggestItem] = try await get("/api/search/suggest?trending=1&platform=ios")
        searchSuggestCache[cacheKey] = CachedSuggestResponse(items: items, cachedAt: Date())
        CacheMetrics.shared.recordStore("search.suggest")
        return items
    }

    func fetchSearchHistory() async throws -> [String] {
        struct HistoryEntry: Decodable {
            let query: String

            private enum CodingKeys: String, CodingKey {
                case query
                case title
                case term
                case text
            }

            init(from decoder: Decoder) throws {
                if let value = try? String(from: decoder) {
                    query = value
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                query = (try? c.decode(String.self, forKey: .query))
                    ?? (try? c.decode(String.self, forKey: .title))
                    ?? (try? c.decode(String.self, forKey: .term))
                    ?? (try? c.decode(String.self, forKey: .text))
                    ?? ""
            }
        }

        struct Response: Decodable {
            let entries: [HistoryEntry]

            private enum CodingKeys: String, CodingKey {
                case history
                case queries
                case items
                case data
            }

            init(from decoder: Decoder) throws {
                if let values = try? [HistoryEntry](from: decoder) {
                    entries = values
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                entries = (try? c.decodeIfPresent([HistoryEntry].self, forKey: .history))
                    ?? (try? c.decodeIfPresent([HistoryEntry].self, forKey: .queries))
                    ?? (try? c.decodeIfPresent([HistoryEntry].self, forKey: .items))
                    ?? (try? c.decodeIfPresent([HistoryEntry].self, forKey: .data))
                    ?? []
            }
        }
        let response: Response = try await get("/api/me/search-history")
        return response.entries
            .map { $0.query.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func saveSearchHistory(query: String) async throws {
        struct Body: Encodable { let query: String }
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await post("/api/me/search-history", body: Body(query: query))
    }

    func removeSearchHistory(query: String) async throws {
        struct Body: Encodable { let query: String? }
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await delete("/api/me/search-history", body: Body(query: query))
    }

    func clearSearchHistoryRemote() async throws {
        struct Body: Encodable {}
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await delete("/api/me/search-history", body: Body())
    }

    func searchMentions(q: String, limit: Int = 6) async throws -> MentionSearchResponse {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try await get("/api/mentions/search?q=\(enc)&limit=\(min(max(limit, 1), 20))")
    }

    func search(q: String, type: String = "all") async throws -> SearchResults {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? type
        return try await get("/api/search?q=\(enc)&type=\(encodedType)&platform=ios")
    }

    // MARK: - Browse: Shows

    func fetchShowsBrowse(genre: String? = nil, q: String? = nil) async throws -> [ShowBrowseCard] {
        var parts = [String]()
        parts.append("take=80")
        if let genre = genre, !genre.isEmpty { parts.append("genre=\(genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre)") }
        if let q = q, !q.isEmpty            { parts.append("q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)") }
        let query = parts.joined(separator: "&")
        struct ShowSearchResp: Decodable { let shows: [ShowBrowseCard] }
        let resp: ShowSearchResp = try await get("/api/shows?\(query)")
        return resp.shows
    }

    // MARK: - Posts (clip reactions)

    func fetchPosts(videoId: String) async throws -> [UserPost] {
        return try await get("/api/videos/\(C.pathSegment(videoId))/posts")
    }

    func fetchPosts(episodeId: String) async throws -> [UserPost] {
        return try await get("/api/episodes/\(C.pathSegment(episodeId))/posts")
    }

    func createPost(videoId: String, markIn: Int, markOut: Int, caption: String?, thumbnailUrl: String? = nil) async throws -> UserPost {
        struct Body: Encodable {
            let markIn: Int
            let markOut: Int
            let caption: String?
            let thumbnailUrl: String?
        }
        return try await post(
            "/api/videos/\(C.pathSegment(videoId))/posts",
            body: Body(markIn: markIn, markOut: markOut, caption: caption, thumbnailUrl: thumbnailUrl)
        )
    }

    func createPost(episodeId: String, markIn: Int, markOut: Int, caption: String?, isSpoiler: Bool, thumbnailUrl: String? = nil) async throws -> UserPost {
        struct Body: Encodable {
            let markIn: Int
            let markOut: Int
            let caption: String?
            let isSpoiler: Bool
            let thumbnailUrl: String?
        }
        return try await post(
            "/api/episodes/\(C.pathSegment(episodeId))/posts",
            body: Body(markIn: markIn, markOut: markOut, caption: caption, isSpoiler: isSpoiler, thumbnailUrl: thumbnailUrl)
        )
    }

    func togglePostLike(postId: String) async throws -> PostLikeResponse {
        return try await post("/api/posts/\(C.pathSegment(postId))/like", body: [:] as [String: String])
    }

    func deletePost(postId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/posts/\(C.pathSegment(postId))")
    }

    func fetchPostComments(postId: String) async throws -> [PostComment] {
        return try await get("/api/posts/\(C.pathSegment(postId))/comments")
    }

    func createPostComment(postId: String, content: String, parentId: String? = nil) async throws -> PostComment {
        var body: [String: String] = ["content": content]
        if let parentId = parentId { body["parentId"] = parentId }
        return try await post("/api/posts/\(C.pathSegment(postId))/comments", body: body)
    }

    func likePostComment(postId: String, commentId: String, liked: Bool) async throws -> PostCommentLikeResponse {
        struct Body: Encodable { let liked: Bool }
        return try await post("/api/posts/\(C.pathSegment(postId))/comments/\(C.pathSegment(commentId))/like", body: Body(liked: liked))
    }

    // MARK: - Moment likes (heatmap)

    func fetchMomentLikes(videoId: String) async throws -> MomentLikesResponse {
        return try await get("/api/videos/\(C.pathSegment(videoId))/moment-likes")
    }

    func fetchMomentLikes(episodeId: String) async throws -> MomentLikesResponse {
        return try await get("/api/episodes/\(C.pathSegment(episodeId))/moment-likes")
    }

    func toggleMomentLike(videoId: String, timestampSec: Int) async throws -> MomentLikeToggleResponse {
        struct Body: Encodable { let timestampSec: Int }
        return try await post("/api/videos/\(C.pathSegment(videoId))/moment-likes", body: Body(timestampSec: timestampSec))
    }

    func toggleMomentLike(episodeId: String, timestampSec: Int) async throws -> MomentLikeToggleResponse {
        struct Body: Encodable { let timestampSec: Int }
        return try await post("/api/episodes/\(C.pathSegment(episodeId))/moment-likes", body: Body(timestampSec: timestampSec))
    }

    // MARK: - Browse: Movies

    func fetchMoviesBrowse(genre: String? = nil, q: String? = nil) async throws -> [ShowBrowseCard] {
        var parts = ["take=80"]
        if let genre = genre, !genre.isEmpty {
            parts.append("genre=\(genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre)")
        }
        if let q = q, !q.isEmpty {
            parts.append("q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)")
        }
        struct ShowSearchResp: Decodable { let shows: [ShowBrowseCard] }
        let resp: ShowSearchResp = try await get("/api/shows?\(parts.joined(separator: "&"))")
        let movieTypes: Set<String> = ["movie", "documentary", "special"]
        return resp.shows.filter { movieTypes.contains($0.showType ?? "") }
    }

    // MARK: - Browse: Microdramas

    func fetchMicrodramas(section: String = "trending", limit: Int = 20) async throws -> [MicrodramaListShow] {
        let encodedSection = section.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? section
        return try await get("/api/microdramas?section=\(encodedSection)&limit=\(limit)")
    }

    func fetchMicrodramaEpisodes(showId: String) async throws -> MicrodramaEpisodesResponse {
        return try await get("/api/microdrama/\(C.pathSegment(showId))/episodes")
    }

    func grantMicrodramaAdUnlock(episodeId: String) async throws -> MicrodramaAdUnlockGrant {
        struct Body: Encodable { let episodeId: String }
        return try await post("/api/microdrama/ad-unlock", body: Body(episodeId: episodeId))
    }

    // MARK: - Following feed

    func fetchFollowingFeed() async throws -> [FollowingFeedItem] {
        return try await get("/api/subscriptions/feed")
    }

    // MARK: - Collections

    func fetchCollections() async throws -> [Collection] {
        return try await get("/api/collections")
    }

    func fetchPublicCollections() async throws -> [Collection] {
        return try await get("/api/collections?public=true")
    }

    func fetchCollectionDetail(id: String) async throws -> CollectionDetail {
        return try await get("/api/collections/\(C.pathSegment(id))")
    }

    func createCollection(title: String, description: String?, type: String, visibility: String) async throws -> Collection {
        let body = CreateCollectionBody(title: title, description: description, type: type, visibility: visibility)
        return try await post("/api/collections", body: body)
    }

    func updateCollection(id: String, title: String, description: String?, visibility: String) async throws -> Collection {
        struct Body: Encodable { let title: String; let description: String?; let visibility: String }
        return try await patch("/api/collections/\(C.pathSegment(id))", body: Body(title: title, description: description, visibility: visibility))
    }

    func deleteCollection(id: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/collections/\(C.pathSegment(id))")
    }

    func toggleCollectionFollow(id: String) async throws -> CollectionFollowResponse {
        struct Empty: Encodable {}
        return try await post("/api/collections/\(C.pathSegment(id))/follow", body: Empty())
    }

    func addShowToCollection(collectionId: String, showId: String) async throws -> CollectionItemCreateResponse {
        struct Body: Encodable { let showId: String }
        return try await post("/api/collections/\(C.pathSegment(collectionId))/items", body: Body(showId: showId))
    }

    func addCollectionVideo(collectionId: String, videoId: String) async throws -> CollectionItemCreateResponse {
        struct Body: Encodable { let videoId: String }
        return try await post("/api/collections/\(C.pathSegment(collectionId))/items", body: Body(videoId: videoId))
    }

    func removeCollectionItem(collectionId: String, item: CollectionDetailItem) async throws {
        if let showId = item.show?.id {
            try await removeShowFromCollection(collectionId: collectionId, showId: showId)
            return
        }
        if let videoId = item.video?.id {
            try await removeVideoFromCollection(collectionId: collectionId, videoId: videoId)
        }
    }

    /// POST /api/collections/[id]/items  body: { videoId }
    /// Returns the created CollectionItem (201) or throws APIError.http(409) if already saved.
    func addVideoToCollection(collectionId: String, videoId: String) async throws {
        let _: CollectionItemCreateResponse = try await addCollectionVideo(collectionId: collectionId, videoId: videoId)
    }

    /// DELETE /api/collections/[id]/items?videoId=<id>  → { ok: true }
    func removeVideoFromCollection(collectionId: String, videoId: String) async throws {
        let enc = videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoId
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/collections/\(C.pathSegment(collectionId))/items?videoId=\(enc)")
    }

    func removeShowFromCollection(collectionId: String, showId: String) async throws {
        let enc = showId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? showId
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/collections/\(C.pathSegment(collectionId))/items?showId=\(enc)")
    }

    // MARK: - Playlists

    func fetchPlaylists() async throws -> [Playlist] {
        return try await get("/api/playlists")
    }

    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        return try await get("/api/playlists/\(C.pathSegment(id))")
    }

    func createPlaylist(title: String, description: String?, type: String, visibility: String) async throws -> Playlist {
        struct Body: Encodable { let title: String; let description: String?; let type: String; let visibility: String }
        return try await post("/api/playlists", body: Body(title: title, description: description, type: type, visibility: visibility))
    }

    func updatePlaylist(id: String, title: String, description: String?, visibility: String) async throws -> PlaylistDetail {
        struct Body: Encodable { let title: String; let description: String?; let visibility: String }
        return try await patch("/api/playlists/\(C.pathSegment(id))", body: Body(title: title, description: description, visibility: visibility))
    }

    func deletePlaylist(id: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/playlists/\(C.pathSegment(id))")
    }

    func removePlaylistItem(playlistId: String, itemId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/playlists/\(C.pathSegment(playlistId))/items/\(C.pathSegment(itemId))")
    }

    func addVideoToPlaylist(playlistId: String, videoId: String) async throws {
        struct Body: Encodable { let videoId: String }
        struct Resp: Decodable { let id: String?; let ok: Bool? }
        let _: Resp = try await post("/api/playlists/\(C.pathSegment(playlistId))/items", body: Body(videoId: videoId))
    }

    func reorderPlaylist(playlistId: String, order: [String]) async throws {
        struct Body: Encodable { let order: [String] }
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await post("/api/playlists/\(C.pathSegment(playlistId))/reorder", body: Body(order: order))
    }

    // MARK: - Watch history

    func fetchHistory() async throws -> [HistoryItem] {
        return try await get("/api/history")
    }

    func clearHistory() async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/history")
    }

    // MARK: - Notifications

    func fetchNotifications() async throws -> [AppNotification] {
        return try await get("/api/notifications")
    }

    func markNotificationsRead() async throws {
        guard let url = URL(string: C.baseURL + "/api/notifications") else {
            throw APIError.badURL("/api/notifications")
        }
        struct Resp: Decodable { let ok: Bool? }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        let _: Resp = try decoder.decode(Resp.self, from: data)
    }

    func fetchNotificationPreferences() async throws -> NotificationPreferences {
        let data = try await socialData(path: "/api/me/notification-preferences")
        return try decoder.decode(NotificationPreferences.self, from: data)
    }

    func updateNotificationPreference(
        _ field: NotificationPreferenceField,
        enabled: Bool
    ) async throws -> NotificationPreferences {
        let data = try await socialPatchData(
            path: "/api/me/notification-preferences",
            body: try JSONEncoder().encode([field.rawValue: enabled])
        )
        return try decoder.decode(NotificationPreferences.self, from: data)
    }

    func fetchNotificationCounts() async throws -> [String: Int] {
        return try await get("/api/notifications/counts")
    }

    func registerPushToken(token: String, platform: String = "ios", environment: String, bundleId: String) async throws {
        struct Body: Encodable {
            let token: String
            let platform: String
            let environment: String
            let bundleId: String
        }
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await post(
            "/api/notifications/push-token",
            body: Body(token: token, platform: platform, environment: environment, bundleId: bundleId)
        )
    }

    // MARK: - Like / Subscribe

    /// Send a like/dislike/remove reaction.
    /// - type: "like" | "dislike" | "remove"
    /// Returns updated like count, dislike count, and the user's current reaction.
    @discardableResult
    func likeVideo(videoId: String, type: String) async throws -> LikeVideoResponse {
        struct Body: Encodable { let type: String }
        return try await post("/api/videos/\(C.pathSegment(videoId))/like", body: Body(type: type))
    }

    /// Legacy toggle — kept for callers that don't need the reaction type.
    func toggleLike(videoId: String) async throws {
        try await likeVideo(videoId: videoId, type: "like")
    }

    /// Like/dislike/remove reaction on an episode.
    /// - type: "like" | "dislike" | "remove"
    @discardableResult
    func likeEpisode(episodeId: String, type: String) async throws -> LikeVideoResponse {
        struct Body: Encodable { let type: String }
        return try await post("/api/episodes/\(C.pathSegment(episodeId))/like", body: Body(type: type))
    }

    func fetchContentEnergy(contentPath: String, id: String) async throws -> ContentEnergyResponse {
        try await get("/api/\(contentPath)/\(C.pathSegment(id))/rating")
    }

    func submitContentEnergy(
        contentPath: String,
        id: String,
        overall: Int,
        tags: [String]
    ) async throws -> ContentEnergySelection {
        struct Body: Encodable {
            let overall: Int
            let tags: [String]
        }
        return try await post(
            "/api/\(contentPath)/\(C.pathSegment(id))/rating",
            body: Body(overall: min(max(overall, 1), 5), tags: Array(tags.prefix(10)))
        )
    }

    func removeContentEnergy(contentPath: String, id: String) async throws {
        try await deleteEmpty("/api/\(contentPath)/\(C.pathSegment(id))/rating")
    }

    func toggleSubscribe(channelId: String) async throws {
        struct Body: Encodable {}
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await post("/api/channels/\(C.pathSegment(channelId))/follow", body: Body())
    }

    // MARK: - Private

    nonisolated private func validate(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            SessionStorage.token = nil
            SessionStorage.activeContext = nil
            Task { @MainActor in
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
            }
            throw APIError.unauthorized
        }
        if http.statusCode == 404 { throw APIError.notFound }
        if !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
    }

    private func storeSessionStateIfPresent(in resp: URLResponse, data: Data) {
        if let token = sessionTokenFromCookies(in: resp) ?? sessionTokenFromJSON(data) {
            storeSessionToken(token)
        }
        if let activeContext = activeContextFromCookies(in: resp) ?? activeContextFromJSON(data) {
            SessionStorage.activeContext = activeContext
        }
    }

    private func sessionTokenFromCookies(in resp: URLResponse) -> String? {
        guard let http = resp as? HTTPURLResponse else { return nil }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key.lowercased()] = String(describing: pair.value)
        }
        guard let setCookie = headers["set-cookie"] else { return nil }
        let cookieNames = [
            "__Secure-authjs.session-token",
            "authjs.session-token",
            "__Secure-next-auth.session-token",
            "next-auth.session-token",
            "session-token",
            "token"
        ]
        for cookieName in cookieNames {
            if let token = cookieValue(named: cookieName, in: setCookie), !token.isEmpty {
                return token.removingPercentEncoding ?? token
            }
        }
        return nil
    }

    private func cookieValue(named name: String, in setCookie: String) -> String? {
        let parts = setCookie.components(separatedBy: CharacterSet(charactersIn: ";,"))
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(name)=") else { continue }
            return String(trimmed.dropFirst(name.count + 1))
        }
        return nil
    }

    private func sessionTokenFromJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["token", "sessionToken", "jwt", "sessionJWT"] {
            if let token = object[key] as? String, !token.isEmpty {
                return token
            }
        }
        if let session = object["session"] as? [String: Any] {
            for key in ["token", "sessionToken", "jwt"] {
                if let token = session[key] as? String, !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }

    private func activeContextFromCookies(in resp: URLResponse) -> ActiveContext? {
        guard let http = resp as? HTTPURLResponse else { return nil }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key.lowercased()] = String(describing: pair.value)
        }
        guard let setCookie = headers["set-cookie"],
              let rawValue = cookieValue(named: "mv_active_ctx", in: setCookie) else {
            return nil
        }
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        guard let data = decoded.data(using: .utf8),
              let context = try? JSONDecoder().decode(ActiveContext.self, from: data) else {
            return nil
        }
        SessionStorage.activeContextCookieJSON = decoded
        return context
    }

    private func activeContextFromJSON(_ data: Data) -> ActiveContext? {
        if let context = try? JSONDecoder().decode(ActiveContext.self, from: data) {
            return context
        }
        if let response = try? JSONDecoder().decode(SwitchContextResponse.self, from: data) {
            return response.context
        }
        if let response = try? JSONDecoder().decode(ContextsResponse.self, from: data) {
            return response.active
        }
        return nil
    }

    private func fetchTusOffset(uploadUrl: URL) async throws -> Int64 {
        var req = URLRequest(url: uploadUrl)
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 204 else {
            return 0
        }
        return Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? 0
    }
}

actor CurationEventTracker {
    static let shared = CurationEventTracker()

    private let sessionId = UUID().uuidString
    private var impressions = Set<String>()

    func impression(listingId: String) async {
        guard impressions.insert(listingId).inserted else { return }
        await APIClient.shared.trackCurationEvent(
            listingId: listingId,
            eventType: "impression",
            sessionId: sessionId
        )
    }

    func click(listingId: String, contentId: String) async {
        await APIClient.shared.trackCurationEvent(
            listingId: listingId,
            eventType: "click",
            contentId: contentId,
            sessionId: sessionId
        )
    }
}

enum APIError: LocalizedError {
    case badURL(String)
    case unauthorized
    case notFound
    case http(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let p):  return "Invalid URL: \(p)"
        case .unauthorized:   return "Not signed in"
        case .notFound:       return "Not found"
        case .http(let c):    return "HTTP \(c)"
        case .invalidResponse(let message): return message
        }
    }
}

private struct SocialAPIErrorPayload: Decodable {
    let error: String
}
