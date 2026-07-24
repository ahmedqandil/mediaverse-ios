import AVFoundation
import Foundation

enum AdDeliveryMode: String, Equatable {
    case none
    case csai
    case sgai
    case ssai
}

enum AdDeliveryResolver {
    static func resolve(policy: EffectiveAdPolicy, supportsHLSInterstitials: Bool = true) -> AdDeliveryMode {
        guard policy.adsEnabled else { return .none }

        let deviceOverride = policy.deliveryByDevice?["nativeApp"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let masterMode = policy.deliveryMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch deviceOverride {
        case "csai": return .csai
        case "ssai": return .ssai
        case "sgai": return supportsHLSInterstitials ? .sgai : .csai
        default: break
        }

        if masterMode == "csai" { return .csai }
        if masterMode == "server" || masterMode == "sgai" || masterMode == "ssai" || masterMode == nil || masterMode == "auto" {
            return supportsHLSInterstitials ? .sgai : .csai
        }
        return .csai
    }
}

enum PlaybackEntrySurface: String, Codable {
    case direct
    case homeFeed = "home_feed"
    case videosFeed = "videos_feed"
    case upNext = "up_next"
    case history
}

enum PlaybackEntryMode: String, Codable {
    case userPlay = "user_play"
    case autoplayPreview = "autoplay_preview"
    case resume
    case autoplayNext = "autoplay_next"
}

struct PlaybackEntryContext: Codable, Equatable {
    let surface: PlaybackEntrySurface
    let mode: PlaybackEntryMode
    let contentStartSec: Double
    let previewSessionId: String?

    static let direct = PlaybackEntryContext(
        surface: .direct,
        mode: .userPlay,
        contentStartSec: 0,
        previewSessionId: nil
    )
}

struct SGAIPlaybackContext: Equatable {
    let contentId: String
    let contentType: String
    let sessionId: String
    let userId: String?
    let deviceId: String?
    let country: String?
    let orientation: String
    let entry: PlaybackEntryContext
}

enum SGAIPlaybackURLBuilder {
    static let productionWorker = URL(string: "https://westreem-sgai.ssdai.workers.dev")!

    static func makeURL(
        streamMaster: URL,
        mode: AdDeliveryMode,
        context: SGAIPlaybackContext,
        worker: URL = productionWorker
    ) -> URL {
        guard mode == .sgai || mode == .ssai else { return streamMaster }

        var components = URLComponents(
            url: worker.appendingPathComponent("v1/hls/master.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "u", value: streamMaster.absoluteString),
            URLQueryItem(name: "contentId", value: context.contentId),
            URLQueryItem(name: "contentType", value: context.contentType),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "sessionId", value: context.sessionId),
            URLQueryItem(name: "orientation", value: context.orientation),
            URLQueryItem(name: "entrySurface", value: context.entry.surface.rawValue),
            URLQueryItem(name: "entryMode", value: context.entry.mode.rawValue),
            URLQueryItem(name: "contentStartSec", value: String(max(0, context.entry.contentStartSec)))
        ]
        if mode == .ssai {
            items.append(URLQueryItem(name: "mode", value: "ssai"))
        }
        if let userId = context.userId, !userId.isEmpty {
            items.append(URLQueryItem(name: "userId", value: userId))
        }
        if let deviceId = context.deviceId, !deviceId.isEmpty {
            items.append(URLQueryItem(name: "deviceId", value: deviceId))
        }
        if let country = context.country, !country.isEmpty {
            items.append(URLQueryItem(name: "country", value: country))
        }
        if let previewSessionId = context.entry.previewSessionId, !previewSessionId.isEmpty {
            items.append(URLQueryItem(name: "previewSessionId", value: previewSessionId))
        }
        components.queryItems = items
        return components.url ?? streamMaster
    }

    static func assetListURL(
        breakId: String,
        context: SGAIPlaybackContext,
        worker: URL = productionWorker
    ) -> URL? {
        var components = URLComponents(
            url: worker.appendingPathComponent("v1/assetlist"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "breakId", value: breakId),
            URLQueryItem(name: "contentId", value: context.contentId),
            URLQueryItem(name: "contentType", value: context.contentType),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "sessionId", value: context.sessionId)
        ]
        return components?.url
    }
}

struct SGAIAssetList: Decodable {
    let assets: [SGAIAsset]

    enum CodingKeys: String, CodingKey {
        case assets = "ASSETS"
    }
}

struct SGAIAsset: Decodable, Equatable {
    let uri: String
    let duration: Double?
    let impressionId: String?
    let decisionId: String?
    let lineItemId: String?
    let campaignId: String?
    let creativeId: String?
    let skippable: Int?
    let skipOffsetSec: Double?
    let clickThroughURL: String?
    let brandLogoURL: String?
    let brandLabel: String?
    let brandTitle: String?
    let brandDescription: String?
    let ctaText: String?

    enum CodingKeys: String, CodingKey {
        case uri = "URI"
        case duration = "DURATION"
        case impressionId = "X-WESTREEM-IID"
        case decisionId = "X-WESTREEM-DID"
        case lineItemId = "X-WESTREEM-LI"
        case campaignId = "X-WESTREEM-CAMP"
        case creativeId = "X-WESTREEM-CR"
        case skippable = "X-WESTREEM-SKIPPABLE"
        case skipOffsetSec = "X-WESTREEM-SKIP-OFFSET"
        case clickThroughURL = "X-WESTREEM-CLICK"
        case brandLogoURL = "X-WESTREEM-BRAND-LOGO"
        case brandLabel = "X-WESTREEM-BRAND-LABEL"
        case brandTitle = "X-WESTREEM-BRAND-TITLE"
        case brandDescription = "X-WESTREEM-BRAND-DESC"
        case ctaText = "X-WESTREEM-CTA"
    }
}

enum SGAIBreakIdentifier {
    static func breakId(from eventIdentifier: String) -> String {
        var identifier = eventIdentifier
        if identifier.hasPrefix("ad-") {
            identifier.removeFirst(3)
        }
        if let range = identifier.range(of: "-[0-9]+$", options: .regularExpression) {
            identifier.removeSubrange(range)
        }
        return identifier
    }
}

struct SGAITrackingState {
    private(set) var firedKeys = Set<String>()

    mutating func shouldFire(event: String, impressionId: String?) -> Bool {
        guard event != "impression", let impressionId, !impressionId.isEmpty else { return false }
        return firedKeys.insert("\(impressionId):\(event)").inserted
    }
}
