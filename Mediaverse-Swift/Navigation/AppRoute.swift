import Foundation

/// Typed navigation destinations used with .navigationDestination(for:).
/// All NavigationLink(value:) calls target one of these cases.
public enum AppRoute: Hashable, Identifiable {
    public var id: String {
        switch self {
        case .video(let s):            return "video_\(s)"
        case .short(let s, let showId, let channelId):
            return "short_\(s)_\(showId ?? "show-global")_\(channelId ?? "channel-global")"
        case .episode(let s):          return "episode_\(s)"
        case .channel(let s):          return "channel_\(s)"
        case .show(let s):             return "show_\(s)"
        case .showSeason(let showId, let seasonId): return "showSeason_\(showId)_\(seasonId)"
        case .showAccess(let showId, let productId, let intent, let handoffId):
            return "showAccess_\(showId)_\(productId ?? "any")_\(intent ?? "access")_\(handoffId ?? "direct")"
        case .handoff(let s):          return "handoff_\(s)"
        case .microdramaShow(let s):   return "mdShow_\(s)"
        case .microdramaWatch(let s):  return "mdWatch_\(s)"
        case .microdramaWatchEp(let s, let ep): return "mdWatchEp_\(s)_\(ep)"
        case .playlist(let s):         return "playlist_\(s)"
        case .collection(let s):       return "collection_\(s)"
        case .vibe(let s):             return "vibe_\(s)"
        case .vibeManagement(let slug, let tab): return "vibeManagement_\(slug)_\(tab)"
        case .vibeInvite(let s):       return "vibeInvite_\(s)"
        case .ripple(let s):           return "ripple_\(s)"
        case .atmo(let s):             return "atmo_\(s)"
        case .search(let s):           return "search_\(s)"
        }
    }
    case video(String)              // video id
    case short(String, showId: String?, channelId: String?) // short id + optional context
    case episode(String)            // episode id
    case channel(String)            // handle or id
    case show(String)               // show id
    case showSeason(showId: String, seasonId: String) // show id + selected season
    case showAccess(showId: String, productId: String?, intent: String?, handoffId: String?)
    case handoff(String)            // opaque public handoff id
    case microdramaShow(String)     // show id
    case microdramaWatch(String)    // show id (opens watch page at ep 1)
    case microdramaWatchEp(String, Int)  // show id + episode number
    case playlist(String)           // playlist id
    case collection(String)         // collection id
    case vibe(String)               // Vibe slug
    case vibeManagement(slug: String, tab: String) // Vibe management destination
    case vibeInvite(String)         // opaque Vibe invitation token
    case ripple(String)             // Ripple id
    case atmo(String)               // user handle
    case search(String)             // prefilled native search query
}

extension AppRoute {
    public static func media(id: String, type: String?, showId: String? = nil, channelId: String? = nil) -> AppRoute {
        if type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" {
            return .short(id, showId: showId, channelId: channelId)
        }
        return .video(id)
    }

    public static func notificationRoute(userInfo: [AnyHashable: Any]) -> AppRoute? {
        let type = stringValue(for: ["type", "contentType", "content_type", "mediaType", "media_type", "kind"], in: userInfo)
        let showId = stringValue(for: ["showId", "show_id", "targetShowId", "target_show_id"], in: userInfo)
        let channelId = stringValue(for: ["channelId", "channel_id", "targetChannelId", "target_channel_id"], in: userInfo)

        if let id = stringValue(for: ["shortId", "short_id", "targetShortId", "target_short_id"], in: userInfo) {
            return .short(id, showId: showId, channelId: channelId)
        }
        if let id = stringValue(for: ["videoId", "video_id", "targetVideoId", "target_video_id"], in: userInfo) {
            return media(id: id, type: type, showId: showId, channelId: channelId)
        }
        if let id = stringValue(for: ["episodeId", "episode_id", "targetEpisodeId", "target_episode_id"], in: userInfo) {
            return .episode(id)
        }
        if let id = stringValue(for: ["microdramaId", "microdrama_id", "targetMicrodramaId", "target_microdrama_id"], in: userInfo) {
            if let episodeNumber = intValue(for: ["episodeNumber", "episode_number", "targetEpisodeNumber", "target_episode_number"], in: userInfo) {
                return .microdramaWatchEp(id, episodeNumber)
            }
            return .microdramaShow(id)
        }
        if let id = showId {
            let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedType?.contains("micro") == true ? .microdramaShow(id) : .show(id)
        }
        if let id = stringValue(for: ["channelHandle", "channel_handle", "targetChannelHandle", "target_channel_handle", "channelId", "channel_id", "targetChannelId", "target_channel_id"], in: userInfo) {
            return .channel(id)
        }
        if let id = stringValue(for: ["playlistId", "playlist_id", "targetPlaylistId", "target_playlist_id"], in: userInfo) {
            return .playlist(id)
        }
        if let id = stringValue(for: ["collectionId", "collection_id", "targetCollectionId", "target_collection_id"], in: userInfo) {
            return .collection(id)
        }
        if let link = stringValue(for: ["linkUrl", "link_url", "url", "deeplink", "deepLink"], in: userInfo) {
            return route(link: link, notificationType: type)
        }
        return nil
    }

    public static func route(link: String, notificationType: String? = nil) -> AppRoute? {
        let path: String
        let queryItems: [URLQueryItem]
        if let url = URL(string: link), let host = url.host, !host.isEmpty {
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                path = url.path
            } else {
                path = "/" + ([host] + url.path.split(separator: "/").map(String.init)).joined(separator: "/")
            }
            queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        } else {
            let components = URLComponents(string: link)
            path = components?.path ?? link
            queryItems = components?.queryItems ?? []
        }

        let parts = path.split(separator: "/").map(String.init)
        let queryType = queryValue(["type", "contentType", "content_type", "mediaType", "media_type"], in: queryItems)
        let queryShowId = queryValue(["showId", "show_id"], in: queryItems)
        let queryChannelId = queryValue(["channelId", "channel_id"], in: queryItems)
        let queryEpisodeNumber = queryValue(["episodeNumber", "episode_number", "ep"], in: queryItems).flatMap(Int.init)
        let looksLikeShort = notificationType?.lowercased().contains("short") == true || queryType?.lowercased() == "short"

        if let id = queryValue(["shortId", "short_id"], in: queryItems) {
            return .short(id, showId: queryShowId, channelId: queryChannelId)
        }
        if let id = queryValue(["videoId", "video_id"], in: queryItems) {
            return media(id: id, type: queryType ?? notificationType, showId: queryShowId, channelId: queryChannelId)
        }
        if let id = queryValue(["episodeId", "episode_id"], in: queryItems) {
            return .episode(id)
        }
        if let id = queryValue(["microdramaId", "microdrama_id"], in: queryItems) {
            return queryEpisodeNumber.map { .microdramaWatchEp(id, $0) } ?? .microdramaShow(id)
        }

        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" { return .episode(parts[2]) }
        if parts.count >= 2, parts[0] == "watch" {
            return looksLikeShort
                ? .short(parts[1], showId: queryShowId, channelId: queryChannelId)
                : .video(parts[1])
        }
        if parts.count >= 2, parts[0] == "videos" { return .video(parts[1]) }
        if parts.count >= 2, parts[0] == "video" { return .video(parts[1]) }
        if parts.count >= 2, parts[0] == "shorts" { return .short(parts[1], showId: queryShowId, channelId: queryChannelId) }
        if parts.count >= 2, parts[0] == "short" { return .short(parts[1], showId: queryShowId, channelId: queryChannelId) }
        if parts.count >= 2, parts[0] == "handoff" { return .handoff(parts[1]) }
        if parts.count >= 2, parts[0] == "shows" { return .show(parts[1]) }
        if parts.count >= 2, parts[0] == "show" { return .show(parts[1]) }
        if parts.count >= 2, parts[0] == "channel" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "channels" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "playlist" { return .playlist(parts[1]) }
        if parts.count >= 2, parts[0] == "playlists" { return .playlist(parts[1]) }
        if parts.count >= 2, parts[0] == "collections" { return .collection(parts[1]) }
        if parts.count >= 2, parts[0] == "collection" { return .collection(parts[1]) }
        if parts.count >= 3, parts[0] == "vibes", parts[1] == "invite" { return .vibeInvite(parts[2]) }
        if parts.count >= 4, parts[0] == "vibes", parts[2] == "posts" { return .ripple(parts[3]) }
        if parts.count >= 3, parts[0] == "vibes", parts[2] == "manage" {
            let tab = queryValue(["tab"], in: queryItems) ?? "settings"
            return .vibeManagement(slug: parts[1], tab: tab)
        }
        if parts.count >= 2, parts[0] == "vibes" { return .vibe(parts[1]) }
        if parts.count >= 2, parts[0] == "atmo" { return .atmo(parts[1]) }
        if parts.count >= 2, parts[0] == "ripples" { return .ripple(parts[1]) }
        if parts.first == "discover",
           let topic = queryValue(["topic", "q", "query"], in: queryItems) {
            return .search(topic)
        }
        if parts.count >= 4, parts[0] == "microdramas", ["watch", "episode", "episodes"].contains(parts[2]), let episodeNumber = Int(parts[3]) {
            return .microdramaWatchEp(parts[1], episodeNumber)
        }
        if parts.count >= 4, parts[0] == "microdrama", ["watch", "episode", "episodes"].contains(parts[2]), let episodeNumber = Int(parts[3]) {
            return .microdramaWatchEp(parts[1], episodeNumber)
        }
        if parts.count >= 2, parts[0] == "microdramas" { return .microdramaShow(parts[1]) }
        if parts.count >= 2, parts[0] == "microdrama" { return .microdramaShow(parts[1]) }

        if let id = queryValue(["showId", "show_id"], in: queryItems) {
            let type = (queryType ?? notificationType)?.lowercased()
            return type?.contains("micro") == true ? .microdramaShow(id) : .show(id)
        }
        if let id = queryValue(["channelHandle", "channel_handle", "channelId", "channel_id"], in: queryItems) {
            return .channel(id)
        }
        if let id = queryValue(["playlistId", "playlist_id"], in: queryItems) {
            return .playlist(id)
        }
        if let id = queryValue(["collectionId", "collection_id"], in: queryItems) {
            return .collection(id)
        }

        return nil
    }

    private static func intValue(for keys: [String], in userInfo: [AnyHashable: Any]) -> Int? {
        stringValue(for: keys, in: userInfo).flatMap(Int.init)
    }

    private static func queryValue(_ names: [String], in queryItems: [URLQueryItem]) -> String? {
        for name in names {
            if let value = queryItems.first(where: { $0.name == name })?.value,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(for keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        for key in keys {
            if let value = userInfo[key] as? String, !value.isEmpty { return value }
            if let value = userInfo[AnyHashable(key)] as? String, !value.isEmpty { return value }
            if let value = userInfo[key] as? CustomStringConvertible {
                let string = value.description
                if !string.isEmpty { return string }
            }
            if let value = userInfo[AnyHashable(key)] as? CustomStringConvertible {
                let string = value.description
                if !string.isEmpty { return string }
            }
        }
        return nil
    }
}
