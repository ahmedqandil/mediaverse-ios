import Foundation

/// Thin URLSession wrapper that authenticates via a manually-injected Cookie header.
/// The JWT is stored in SessionStorage (UserDefaults) and attached to every request,
/// which is more reliable than relying on iOS HTTPCookieStorage for __Secure- cookies.
actor APIClient {
    static let shared = APIClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpCookieStorage = nil           // We manage cookies ourselves
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: - Auth header

    /// Builds the Cookie header value from the stored JWT.
    private var cookieHeader: String? {
        guard let token = SessionStorage.token else { return nil }
        return "next-auth.session-token=\(token); __Secure-next-auth.session-token=\(token)"
    }

    /// Attaches the session cookie to a request.
    private func attachAuth(_ req: inout URLRequest) {
        if let cookie = cookieHeader {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    // MARK: - Convenience

    func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: C.baseURL + path) else {
            throw APIError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuth(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        return try decoder.decode(T.self, from: data)
    }

    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
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
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Auth helpers

    /// Store a JWT — called after magic-link verify or Google OAuth.
    func storeSessionToken(_ jwt: String) {
        SessionStorage.token = jwt
    }

    /// Clear the stored JWT — called on sign-out.
    func clearSessionToken() {
        SessionStorage.token = nil
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
            SessionStorage.token = jwt
            return true
        }
        return false
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

    // MARK: - Feed config

    /// GET /api/feed-config — returns mobileCarouselEvery, mobileCarouselCount,
    /// and ordered carouselSlots so the iOS home feed matches the web admin config.
    func fetchFeedConfig() async throws -> HomeFeedConfig {
        return try await get("/api/feed-config")
    }

    // MARK: - Feed

    func fetchFeed(cursor: String? = nil) async throws -> FeedResponse {
        var path = "/api/feed"
        if let c = cursor { path += "?cursor=\(c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c)" }
        return try await get(path)
    }

    // MARK: - Shorts

    func fetchShorts(
        feed: String = "recommended",
        cursor: String? = nil,
        limit: Int = 10,
        channelId: String? = nil,
        showId: String? = nil
    ) async throws -> ShortsResponse {
        let encodedFeed = feed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? feed
        var path = "/api/shorts?feed=\(encodedFeed)&limit=\(limit)"
        if let c = cursor {
            path += "&cursor=\(c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c)"
        }
        if let channelId {
            path += "&channelId=\(channelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelId)"
        }
        if let showId {
            path += "&showId=\(showId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? showId)"
        }
        return try await get(path)
    }

    // MARK: - Video detail

    func fetchVideo(id: String) async throws -> VideoDetail {
        return try await get("/api/videos/\(id)")
    }

    // MARK: - Episode detail

    func fetchEpisode(id: String) async throws -> EpisodeDetail {
        return try await get("/api/episodes/\(id)")
    }

    // MARK: - Channel

    func fetchChannels() async throws -> [ChannelBrowseCard] {
        return try await get("/api/channels")
    }

    func fetchChannel(handle: String) async throws -> ChannelDetail {
        return try await get("/api/channels/\(handle)")
    }

    func fetchChannelShorts(handle: String) async throws -> [ChannelDetail.VideoItem] {
        return try await get("/api/channels/\(handle)/shorts")
    }

    func fetchChannelPlaylists(handle: String) async throws -> [ChannelPlaylist] {
        return try await get("/api/channels/\(handle)/playlists")
    }

    func fetchChannelFollowStatus(handle: String) async throws -> FollowStatus {
        return try await get("/api/channels/\(handle)/subscribe")
    }

    func toggleChannelFollow(handle: String) async throws -> FollowStatus {
        struct Empty: Encodable {}
        return try await post("/api/channels/\(handle)/subscribe", body: Empty())
    }

    func setChannelNotify(handle: String, on: Bool) async throws {
        struct Body: Encodable { let notifyOnPublish: Bool }
        struct Resp: Decodable { let notifyOnPublish: Bool }
        let _: Resp = try await patch("/api/channels/\(handle)/subscribe", body: Body(notifyOnPublish: on))
    }

    // MARK: - Show

    func fetchShow(id: String) async throws -> ShowPageResponse {
        return try await get("/api/shows/\(id)")
    }

    func fetchShowClips(id: String) async throws -> [ShowClip] {
        return try await get("/api/shows/\(id)/videos")
    }

    func fetchShowPlaylists(id: String) async throws -> [ChannelPlaylist] {
        return try await get("/api/shows/\(id)/playlists")
    }

    func fetchShowFollowStatus(id: String) async throws -> FollowStatus {
        return try await get("/api/shows/\(id)/subscribe")
    }

    func toggleShowFollow(id: String) async throws -> FollowStatus {
        struct Empty: Encodable {}
        return try await post("/api/shows/\(id)/subscribe", body: Empty())
    }

    func setShowNotify(id: String, on: Bool) async throws {
        struct Body: Encodable { let notifyOnPublish: Bool }
        struct Resp: Decodable { let notifyOnPublish: Bool }
        let _: Resp = try await patch("/api/shows/\(id)/subscribe", body: Body(notifyOnPublish: on))
    }

    // MARK: - Contexts

    func fetchContexts() async throws -> ContextsResponse {
        return try await get("/api/me/contexts")
    }

    // MARK: - Profile

    func fetchProfile() async throws -> ProfileResponse {
        return try await get("/api/me/profile")
    }

    func updateProfile(name: String?, bio: String?) async throws -> ProfileResponse {
        struct Body: Encodable { let name: String?; let bio: String? }
        return try await patch("/api/me/profile", body: Body(name: name, bio: bio))
    }

    // MARK: - Upload

    func fetchUploadContexts() async throws -> UploadContextsResponse {
        return try await get("/api/me/upload-contexts")
    }

    func fetchUploadPlaylists(destination: UploadContext, contentType: String) async throws -> [UploadPlaylistOption] {
        let type = contentType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contentType
        if destination.type == "show" {
            return try await get("/api/playlists?showId=\(destination.id)&type=\(type)")
        }
        return try await get("/api/playlists?channelId=\(destination.id)&type=\(type)")
    }

    func createCfStreamUpload(fileSize: Int64, channelId: String?) async throws -> CfStreamUploadResponse {
        var path = "/api/video/cf-stream-upload?fileSize=\(fileSize)"
        if let channelId {
            let enc = channelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelId
            path += "&channelId=\(enc)"
        }
        return try await get(path)
    }

    func uploadToTus(uploadUrl: URL, fileURL: URL, fileSize: Int64, progress: @escaping @Sendable (Double) async -> Void) async throws {
        var offset = try await fetchTusOffset(uploadUrl: uploadUrl)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(offset))
        let chunkSize = 8 * 1024 * 1024

        while offset < fileSize {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }

            var req = URLRequest(url: uploadUrl)
            req.httpMethod = "PATCH"
            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")

            let (_, resp) = try await session.upload(for: req, from: data)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 204 || http.statusCode == 200 else {
                throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let nextOffset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? (offset + Int64(data.count))
            offset = nextOffset
            await progress(min(Double(offset) / Double(max(fileSize, 1)), 1))
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
        return try await get("/api/video/\(videoId)/stream-status")
    }

    func fetchUploadLinkVideos(destination: UploadContext) async throws -> [UploadLinkItem] {
        let path = destination.type == "show"
            ? "/api/backstage/show/\(destination.id)/videos?type=video"
            : "/api/backstage/channel/\(destination.id)/videos?type=video"
        return try await get(path)
    }

    func fetchUploadLinkEpisodes(showId: String) async throws -> [UploadLinkItem] {
        struct Response: Decodable { let episodes: [UploadLinkItem] }
        let response: Response = try await get("/api/backstage/show/\(showId)/episodes")
        return response.episodes
    }

    // MARK: - Studio

    func fetchStudioProductions() async throws -> StudioProductionsResponse {
        return try await get("/api/backstage/studio/productions")
    }

    func createStudioProduction(
        title: String,
        arTitle: String,
        synopsis: String,
        genre: String,
        country: String,
        dialect: String
    ) async throws -> StudioProduction {
        struct Body: Encodable {
            let title: String
            let arTitle: String
            let synopsis: String
            let genre: String
            let language: String
            let country: String
            let dialect: String
        }
        let response: StudioProductionCreateResponse = try await post(
            "/api/backstage/studio/productions",
            body: Body(
                title: title,
                arTitle: arTitle,
                synopsis: synopsis,
                genre: genre,
                language: "ar",
                country: country,
                dialect: dialect
            )
        )
        return response.production
    }

    func fetchStudioProduction(id: String) async throws -> StudioProduction {
        let response: StudioProductionDetailResponse = try await get("/api/backstage/studio/productions/\(id)")
        return response.production
    }

    func runStudioBreakdown(
        productionId: String,
        concept: String,
        genre: String,
        dialect: String,
        episodeSec: Int = 60,
        culturalConstraints: Bool = true
    ) async throws {
        struct Body: Encodable {
            let concept: String
            let genre: String
            let culturalConstraints: Bool
            let dialect: String
            let episodeSec: Int
        }
        let _: StudioBreakdownResponse = try await post(
            "/api/backstage/studio/productions/\(productionId)/breakdown",
            body: Body(
                concept: concept,
                genre: genre,
                culturalConstraints: culturalConstraints,
                dialect: dialect,
                episodeSec: episodeSec
            )
        )
    }

    func fetchStudioScene(id: String) async throws -> StudioSceneDetail {
        let response: StudioSceneDetailResponse = try await get("/api/backstage/studio/scenes/\(id)")
        return response.scene
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
        return try await get("/api/entitlement/check?episodeId=\(episodeId)")
    }

    func checkEntitlementBySeason(seasonId: String) async throws -> EntitlementCheckResponse {
        return try await get("/api/entitlement/check?seasonId=\(seasonId)")
    }

    // MARK: - Checkout

    func checkoutPPV(productId: String, networkId: String, seasonId: String?, episodeId: String?) async throws -> CheckoutResponse {
        struct Body: Encodable {
            let productId: String; let networkId: String
            let seasonId: String?; let episodeId: String?
        }
        return try await post("/api/checkout/ppv", body: Body(productId: productId, networkId: networkId, seasonId: seasonId, episodeId: episodeId))
    }

    func checkoutSVOD(productId: String, networkId: String) async throws -> CheckoutResponse {
        struct Body: Encodable { let productId: String; let networkId: String }
        return try await post("/api/checkout/svod", body: Body(productId: productId, networkId: networkId))
    }

    // MARK: - Watch progress

    func deleteProgress(videoId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/progress?videoId=\(videoId)")
    }

    func deleteProgress(episodeId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/progress?episodeId=\(episodeId)")
    }

    func fetchContinueWatching() async throws -> ContinueWatchingResponse {
        return try await get("/api/progress")
    }

    func fetchProgress(videoId: String) async throws -> ProgressItem? {
        return try await get("/api/progress?videoId=\(videoId)")
    }

    func fetchProgress(episodeId: String) async throws -> ProgressItem? {
        return try await get("/api/progress?episodeId=\(episodeId)")
    }

    func recordProgress(videoId: String, seconds: Int, percent: Double) async throws {
        struct Body: Encodable { let videoId: String; let seconds: Int; let percent: Double }
        let _: ProgressItem = try await post(
            "/api/progress",
            body: Body(videoId: videoId, seconds: seconds, percent: min(max(percent, 0), 1))
        )
    }

    func recordProgress(episodeId: String, seconds: Int, percent: Double) async throws {
        struct Body: Encodable { let episodeId: String; let seconds: Int; let percent: Double }
        let _: ProgressItem = try await post(
            "/api/progress",
            body: Body(episodeId: episodeId, seconds: seconds, percent: min(max(percent, 0), 1))
        )
    }

    func fetchPlayerMarkers(videoId: String) async throws -> [PlayerMarker] {
        return try await get("/api/videos/\(videoId)/markers")
    }

    func fetchPlayerMarkers(episodeId: String) async throws -> [PlayerMarker] {
        return try await get("/api/episodes/\(episodeId)/markers")
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
        return try await patch("/api/comments/\(commentId)", body: Body(like: liked))
    }

    func flagComment(commentId: String) async throws -> Comment {
        struct Body: Encodable { let flag: Bool }
        return try await patch("/api/comments/\(commentId)", body: Body(flag: true))
    }

    // MARK: - Context switch

    func switchContext(_ ctx: ActiveContext) async throws -> SwitchContextResponse {
        let body = SwitchContextBody(id: ctx.id, type: ctx.type, name: ctx.name, channelId: ctx.channelId)
        return try await post("/api/me/active-context", body: body)
    }

    // MARK: - Search

    func searchSuggest(q: String) async throws -> [SuggestItem] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try await get("/api/search/suggest?q=\(enc)")
    }

    func search(q: String, type: String = "all") async throws -> SearchResults {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try await get("/api/search?q=\(enc)&type=\(type)")
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

    /// Fetch shows for the home hero carousel — uses /api/shows?withClips=1
    /// so each ShowBrowseCard has trailerUrl populated from clips[0].videoUrl.
    func fetchShowsHome() async throws -> [ShowBrowseCard] {
        struct ShowsResp: Decodable { let shows: [ShowBrowseCard] }
        let resp: ShowsResp = try await get("/api/shows?withClips=1")
        return resp.shows
    }

    // MARK: - Posts (clip reactions)

    func fetchPosts(videoId: String) async throws -> [UserPost] {
        return try await get("/api/videos/\(videoId)/posts")
    }

    func fetchPosts(episodeId: String) async throws -> [UserPost] {
        return try await get("/api/episodes/\(episodeId)/posts")
    }

    func createPost(videoId: String, markIn: Int, markOut: Int, caption: String?) async throws -> UserPost {
        struct Body: Encodable {
            let markIn: Int
            let markOut: Int
            let caption: String?
        }
        return try await post(
            "/api/videos/\(videoId)/posts",
            body: Body(markIn: markIn, markOut: markOut, caption: caption)
        )
    }

    func createPost(episodeId: String, markIn: Int, markOut: Int, caption: String?, isSpoiler: Bool) async throws -> UserPost {
        struct Body: Encodable {
            let markIn: Int
            let markOut: Int
            let caption: String?
            let isSpoiler: Bool
        }
        return try await post(
            "/api/episodes/\(episodeId)/posts",
            body: Body(markIn: markIn, markOut: markOut, caption: caption, isSpoiler: isSpoiler)
        )
    }

    func togglePostLike(postId: String) async throws -> PostLikeResponse {
        return try await post("/api/posts/\(postId)/like", body: [:] as [String: String])
    }

    func deletePost(postId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/posts/\(postId)")
    }

    func fetchPostComments(postId: String) async throws -> [PostComment] {
        return try await get("/api/posts/\(postId)/comments")
    }

    func createPostComment(postId: String, content: String, parentId: String? = nil) async throws -> PostComment {
        var body: [String: String] = ["content": content]
        if let parentId = parentId { body["parentId"] = parentId }
        return try await post("/api/posts/\(postId)/comments", body: body)
    }

    func likePostComment(postId: String, commentId: String, liked: Bool) async throws -> PostCommentLikeResponse {
        struct Body: Encodable { let liked: Bool }
        return try await post("/api/posts/\(postId)/comments/\(commentId)/like", body: Body(liked: liked))
    }

    // MARK: - Moment likes (heatmap)

    func fetchMomentLikes(videoId: String) async throws -> MomentLikesResponse {
        return try await get("/api/videos/\(videoId)/moment-likes")
    }

    func fetchMomentLikes(episodeId: String) async throws -> MomentLikesResponse {
        return try await get("/api/episodes/\(episodeId)/moment-likes")
    }

    func toggleMomentLike(videoId: String, timestampSec: Int) async throws -> MomentLikeToggleResponse {
        struct Body: Encodable { let timestampSec: Int }
        return try await post("/api/videos/\(videoId)/moment-likes", body: Body(timestampSec: timestampSec))
    }

    func toggleMomentLike(episodeId: String, timestampSec: Int) async throws -> MomentLikeToggleResponse {
        struct Body: Encodable { let timestampSec: Int }
        return try await post("/api/episodes/\(episodeId)/moment-likes", body: Body(timestampSec: timestampSec))
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
        return try await get("/api/microdramas?section=\(section)&limit=\(limit)")
    }

    func fetchMicrodramaEpisodes(showId: String) async throws -> MicrodramaEpisodesResponse {
        return try await get("/api/microdrama/\(showId)/episodes")
    }

    func adUnlock(episodeId: String) async throws -> AdUnlockResponse {
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
        return try await get("/api/collections/\(id)")
    }

    func createCollection(title: String, description: String?, type: String, visibility: String) async throws -> Collection {
        let body = CreateCollectionBody(title: title, description: description, type: type, visibility: visibility)
        return try await post("/api/collections", body: body)
    }

    func updateCollection(id: String, title: String, description: String?, visibility: String) async throws -> Collection {
        struct Body: Encodable { let title: String; let description: String?; let visibility: String }
        return try await patch("/api/collections/\(id)", body: Body(title: title, description: description, visibility: visibility))
    }

    func deleteCollection(id: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/collections/\(id)")
    }

    func toggleCollectionFollow(id: String) async throws -> CollectionFollowResponse {
        struct Empty: Encodable {}
        return try await post("/api/collections/\(id)/follow", body: Empty())
    }

    func addShowToCollection(collectionId: String, showId: String) async throws -> CollectionItemCreateResponse {
        struct Body: Encodable { let showId: String }
        return try await post("/api/collections/\(collectionId)/items", body: Body(showId: showId))
    }

    func addCollectionVideo(collectionId: String, videoId: String) async throws -> CollectionItemCreateResponse {
        struct Body: Encodable { let videoId: String }
        return try await post("/api/collections/\(collectionId)/items", body: Body(videoId: videoId))
    }

    func removeCollectionItem(collectionId: String, item: CollectionDetailItem) async throws {
        if let showId = item.show?.id {
            let enc = showId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? showId
            struct Resp: Decodable { let ok: Bool? }
            let _: Resp = try await delete("/api/collections/\(collectionId)/items?showId=\(enc)")
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
        let _: Resp = try await delete("/api/collections/\(collectionId)/items?videoId=\(enc)")
    }

    // MARK: - Playlists

    func fetchPlaylists() async throws -> [Playlist] {
        return try await get("/api/playlists")
    }

    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        return try await get("/api/playlists/\(id)")
    }

    func updatePlaylist(id: String, title: String, description: String?, visibility: String) async throws -> PlaylistDetail {
        struct Body: Encodable { let title: String; let description: String?; let visibility: String }
        return try await patch("/api/playlists/\(id)", body: Body(title: title, description: description, visibility: visibility))
    }

    func deletePlaylist(id: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/playlists/\(id)")
    }

    func removePlaylistItem(playlistId: String, itemId: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await delete("/api/playlists/\(playlistId)/items/\(itemId)")
    }

    func reorderPlaylist(playlistId: String, order: [String]) async throws {
        struct Body: Encodable { let order: [String] }
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await post("/api/playlists/\(playlistId)/reorder", body: Body(order: order))
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

    func fetchNotificationCounts() async throws -> [String: Int] {
        return try await get("/api/notifications/counts")
    }

    // MARK: - Like / Subscribe

    /// Send a like/dislike/remove reaction.
    /// - type: "like" | "dislike" | "remove"
    /// Returns updated like count, dislike count, and the user's current reaction.
    @discardableResult
    func likeVideo(videoId: String, type: String) async throws -> LikeVideoResponse {
        struct Body: Encodable { let type: String }
        return try await post("/api/videos/\(videoId)/like", body: Body(type: type))
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
        return try await post("/api/episodes/\(episodeId)/like", body: Body(type: type))
    }

    func toggleSubscribe(channelId: String) async throws {
        struct Body: Encodable {}
        struct Resp: Decodable { let ok: Bool? }
        let _: Resp = try await post("/api/channels/\(channelId)/follow", body: Body())
    }

    // MARK: - Private

    private func validate(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        if !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
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

enum APIError: LocalizedError {
    case badURL(String)
    case unauthorized
    case notFound
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL(let p):  return "Invalid URL: \(p)"
        case .unauthorized:   return "Not signed in"
        case .notFound:       return "Not found"
        case .http(let c):    return "HTTP \(c)"
        }
    }
}
