import Foundation

/// Typed navigation destinations used with .navigationDestination(for:).
/// All NavigationLink(value:) calls target one of these cases.
enum AppRoute: Hashable, Identifiable {
    var id: String {
        switch self {
        case .video(let s):            return "video_\(s)"
        case .short(let s, let showId, let channelId):
            return "short_\(s)_\(showId ?? "show-global")_\(channelId ?? "channel-global")"
        case .episode(let s):          return "episode_\(s)"
        case .channel(let s):          return "channel_\(s)"
        case .show(let s):             return "show_\(s)"
        case .microdramaShow(let s):   return "mdShow_\(s)"
        case .microdramaWatch(let s):  return "mdWatch_\(s)"
        case .microdramaWatchEp(let s, let ep): return "mdWatchEp_\(s)_\(ep)"
        case .playlist(let s):         return "playlist_\(s)"
        case .collection(let s):       return "collection_\(s)"
        }
    }
    case video(String)              // video id
    case short(String, showId: String?, channelId: String?) // short id + optional context
    case episode(String)            // episode id
    case channel(String)            // handle or id
    case show(String)               // show id
    case microdramaShow(String)     // show id
    case microdramaWatch(String)    // show id (opens watch page at ep 1)
    case microdramaWatchEp(String, Int)  // show id + episode number
    case playlist(String)           // playlist id
    case collection(String)         // collection id
}

extension AppRoute {
    static func media(id: String, type: String?, showId: String? = nil, channelId: String? = nil) -> AppRoute {
        if type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" {
            return .short(id, showId: showId, channelId: channelId)
        }
        return .video(id)
    }
}
