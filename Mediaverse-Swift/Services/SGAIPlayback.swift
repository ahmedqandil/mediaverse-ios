import AVFoundation
import Foundation
import SwiftUI

private extension AVPlayer.TimeControlStatus {
    var debugName: String {
        switch self {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }
}

private extension AVPlayerItem.Status {
    var debugName: String {
        switch self {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unknown"
        }
    }
}

enum AdDeliveryMode: String, Equatable {
    case none
    case csai
    case sgai
    case ssai
}

#if DEBUG
struct AdDeliveryDebugBadge: View {
    let mode: AdDeliveryMode

    var body: some View {
        Text("ADS · \(mode.rawValue.uppercased())")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.25), lineWidth: 1) }
            .accessibilityLabel("Ad delivery mode \(mode.rawValue)")
    }
}
#endif

enum AdDeliveryResolver {
    static func resolve(policy: EffectiveAdPolicy, supportsHLSInterstitials: Bool = true) -> AdDeliveryMode {
        guard policy.adsEnabled else { return .none }

        let masterMode = policy.deliveryMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Match the web contract: per-device settings are consulted only while
        // the platform-wide master is explicitly set to server delivery.
        // Missing, legacy, or malformed master values fail safely to CSAI.
        guard masterMode == "server" else { return .csai }

        let deviceSetting = policy.deliveryByDevice?["nativeApp"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "auto"

        switch deviceSetting {
        case "csai":
            return .csai
        case "ssai":
            return .ssai
        case "sgai", "auto":
            // Native AVPlayer normally supports HLS interstitials. When it
            // cannot, retain server delivery through stitched SSAI, matching
            // the web player's native-playback fallback.
            return supportsHLSInterstitials ? .sgai : .ssai
        default:
            return .csai
        }
    }
}

struct WatchAdDeliveryPlan: Equatable {
    let mode: AdDeliveryMode
    let playbackURL: URL

    var usesClientSideAds: Bool { mode == .csai }
    var usesServerDelivery: Bool { mode == .sgai || mode == .ssai }

    static func resolve(
        policy: EffectiveAdPolicy,
        mediaURL: URL,
        context: SGAIPlaybackContext,
        supportsHLSInterstitials: Bool = true
    ) -> WatchAdDeliveryPlan {
        let resolved = AdDeliveryResolver.resolve(
            policy: policy,
            supportsHLSInterstitials: supportsHLSInterstitials
        )
        guard resolved == .sgai || resolved == .ssai else {
            return WatchAdDeliveryPlan(mode: resolved, playbackURL: mediaURL)
        }
        guard mediaURL.pathExtension.lowercased() == "m3u8" else {
            return WatchAdDeliveryPlan(mode: .csai, playbackURL: mediaURL)
        }
        return WatchAdDeliveryPlan(
            mode: resolved,
            playbackURL: SGAIPlaybackURLBuilder.makeURL(
                streamMaster: mediaURL,
                mode: resolved,
                context: context,
                skippable: policy.skippable,
                maxDurationSec: policy.maxAdDurationSec
                    ?? policy.maxDurationSec
                    ?? policy.pods?.maxAdDurationSec
            )
        )
    }
}

enum AdPlaybackDevice {
    static var stableId: String {
        let key = "westreem.adDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

struct ShortsAdDeliveryPlan: Equatable {
    let feed: AdDeliveryMode
    let inStream: AdDeliveryMode

    static func resolve(
        policy: EffectiveAdPolicy,
        mediaURL: URL?,
        supportsHLSInterstitials: Bool = true
    ) -> ShortsAdDeliveryPlan {
        guard policy.adsEnabled else {
            return ShortsAdDeliveryPlan(feed: .none, inStream: .none)
        }

        // Ads between independent Shorts remain app-controlled feed cards.
        // Server-guided delivery is only meaningful inside an HLS stream.
        let resolved = AdDeliveryResolver.resolve(
            policy: policy,
            supportsHLSInterstitials: supportsHLSInterstitials
        )
        let isHLS = mediaURL?.pathExtension.lowercased() == "m3u8"
        let inStream: AdDeliveryMode
        if isHLS, resolved == .sgai || resolved == .ssai {
            inStream = resolved
        } else {
            inStream = .none
        }
        return ShortsAdDeliveryPlan(feed: .csai, inStream: inStream)
    }
}

enum PlaybackEntrySurface: String, Codable {
    case direct
    case homeFeed = "home_feed"
    case atmosphere
    case videosFeed = "videos_feed"
    case shortsFeed = "shorts_feed"
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
    static let productionWorker = URL(string: "https://ads.westreem.com")!

    static func makeURL(
        streamMaster: URL,
        mode: AdDeliveryMode,
        context: SGAIPlaybackContext,
        skippable: Bool? = nil,
        maxDurationSec: Int? = nil,
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
        if skippable == true {
            items.append(URLQueryItem(name: "restrict", value: "JUMP"))
        }
        if let maxDurationSec {
            items.append(URLQueryItem(name: "maxDurationSec", value: String(max(1, maxDurationSec))))
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

    static func bootstrapURL(
        streamMaster: URL,
        context: SGAIPlaybackContext,
        policy: EffectiveAdPolicy,
        worker: URL = productionWorker
    ) -> URL? {
        let wrapped = makeURL(
            streamMaster: streamMaster,
            mode: .sgai,
            context: context,
            skippable: policy.skippable,
            maxDurationSec: policy.maxAdDurationSec
                ?? policy.maxDurationSec
                ?? policy.pods?.maxAdDurationSec,
            worker: worker
        )
        guard var components = URLComponents(url: wrapped, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/v1/bootstrap"
        components.queryItems = (components.queryItems ?? [])
            .filter { $0.name != "u" && $0.name != "mode" }
            + [
                URLQueryItem(name: "breakId", value: "preroll"),
                URLQueryItem(
                    name: "maxAds",
                    value: String(max(1, policy.pods?.prerollMaxAds ?? policy.adLoad ?? 1))
                )
            ]
        return components.url
    }

    static func scheduleURL(
        context: SGAIPlaybackContext,
        durationSec: Double?,
        policy: EffectiveAdPolicy,
        worker: URL = productionWorker
    ) -> URL? {
        var components = URLComponents(
            url: worker.appendingPathComponent("v1/schedule"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "contentId", value: context.contentId),
            URLQueryItem(name: "contentType", value: context.contentType),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "sessionId", value: context.sessionId),
            URLQueryItem(name: "orientation", value: context.orientation),
            URLQueryItem(name: "entrySurface", value: context.entry.surface.rawValue),
            URLQueryItem(name: "entryMode", value: context.entry.mode.rawValue),
            URLQueryItem(name: "contentStartSec", value: String(max(0, context.entry.contentStartSec))),
            URLQueryItem(name: "skippable", value: policy.skippable == true ? "1" : "0")
        ]
        if let durationSec, durationSec.isFinite, durationSec > 0 {
            items.append(URLQueryItem(name: "durationSec", value: String(durationSec)))
        }
        if let skipAfterSec = policy.skipAfterSec {
            items.append(URLQueryItem(name: "skipAfterSec", value: String(max(0, skipAfterSec))))
        }
        if let maxDurationSec = policy.maxAdDurationSec
            ?? policy.maxDurationSec
            ?? policy.pods?.maxAdDurationSec {
            items.append(URLQueryItem(name: "maxDurationSec", value: String(max(1, maxDurationSec))))
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
        components?.queryItems = items
        return components?.url
    }
}

private struct SSAISchedule: Decodable {
    let breaks: [SSAIScheduleBreak]
}

private struct SSAIScheduleBreak: Decodable, Equatable {
    struct Brand: Decodable, Equatable {
        let logo: String?
        let label: String?
        let title: String?
        let description: String?
        let cta: String?
    }

    let breakId: String
    let kind: String?
    let start: Double
    let end: Double
    let duration: Double
    let iid: String?
    let did: String?
    let li: String?
    let camp: String?
    let cr: String?
    let skippable: Bool
    let skipOffset: Double
    let click: String?
    let brand: Brand?
}

struct SGAIAssetList: Decodable {
    let assets: [SGAIAsset]

    enum CodingKeys: String, CodingKey {
        case assets = "ASSETS"
    }
}

struct SGAIBootstrapResponse: Decodable {
    let ready: Bool
    let breakId: String
    let assets: [SGAIAsset]

    enum CodingKeys: String, CodingKey {
        case ready
        case breakId
        case assets = "ASSETS"
    }
}

struct SGAIBootstrapLoad {
    let payload: SGAIBootstrapResponse
    let serverTiming: String?
    let cfRay: String?
    let networkTiming: String
}

private final class SGAIBootstrapMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collectedMetrics: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collectedMetrics = metrics
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let metrics = collectedMetrics
        lock.unlock()
        guard let metrics, let transaction = metrics.transactionMetrics.last else {
            return "networkMetrics=missing"
        }

        func milliseconds(_ start: Date?, _ end: Date?) -> Int {
            guard let start, let end else { return 0 }
            return max(0, Int(end.timeIntervalSince(start) * 1_000))
        }

        return [
            "dnsMs=\(milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate))",
            "connectMs=\(milliseconds(transaction.connectStartDate, transaction.connectEndDate))",
            "tlsMs=\(milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))",
            "requestMs=\(milliseconds(transaction.requestStartDate, transaction.requestEndDate))",
            "firstByteMs=\(milliseconds(transaction.requestEndDate, transaction.responseStartDate))",
            "responseMs=\(milliseconds(transaction.responseStartDate, transaction.responseEndDate))",
            "taskMs=\(max(0, Int(metrics.taskInterval.duration * 1_000)))",
            "protocol=\(transaction.networkProtocolName ?? "unknown")",
            "reused=\(transaction.isReusedConnection)",
            "proxy=\(transaction.isProxyConnection)"
        ].joined(separator: " ")
    }
}

enum SGAIBootstrapClient {
    static func load(
        streamMaster: URL,
        context: SGAIPlaybackContext,
        policy: EffectiveAdPolicy
    ) async -> SGAIBootstrapLoad? {
        guard let url = SGAIPlaybackURLBuilder.bootstrapURL(
            streamMaster: streamMaster,
            context: context,
            policy: policy
        ) else { return nil }
        do {
            // Give an almost-ready same-origin warm-up a brief chance to finish,
            // but never serialize the full health request ahead of bootstrap.
            // If the connection is still cold, both requests continue in
            // parallel and bootstrap remains on the critical path.
            let preconnectWaitMs = await SGAIConnectionWarmer.waitUntilReady(
                maxWait: .milliseconds(250)
            )
            let metricsDelegate = SGAIBootstrapMetricsDelegate()
            let (data, response) = try await URLSession.shared.data(
                for: URLRequest(url: url),
                delegate: metricsDelegate
            )
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return SGAIBootstrapLoad(
                payload: try JSONDecoder().decode(SGAIBootstrapResponse.self, from: data),
                serverTiming: http.value(forHTTPHeaderField: "Server-Timing"),
                cfRay: http.value(forHTTPHeaderField: "CF-Ray"),
                networkTiming: "preconnectWaitMs=\(preconnectWaitMs) " + metricsDelegate.summary()
            )
        } catch {
            return nil
        }
    }
}

@MainActor
enum SGAIConnectionWarmer {
    private static var task: Task<Void, Never>?
    private static var startedAt: Date?

    static func warm() {
        if let startedAt, Date().timeIntervalSince(startedAt) < 20 {
            return
        }
        startedAt = Date()
        task = Task {
            var request = URLRequest(
                url: SGAIPlaybackURLBuilder.productionWorker.appendingPathComponent("health")
            )
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 4
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    static func waitUntilReady(maxWait: Duration) async -> Int {
        guard let task else { return 0 }
        let startedAt = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(for: maxWait)
            }
            _ = await group.next()
            group.cancelAll()
        }
        let elapsed = startedAt.duration(to: .now).components
        return Int(elapsed.seconds) * 1_000
            + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

enum SGAICreativeWarmer {
    private static let warmed = NSCache<NSURL, NSNumber>()

    static func warm(_ assets: [SGAIAsset]) async -> [String] {
        await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for (index, asset) in assets.prefix(2).enumerated() {
                guard let url = URL(string: asset.uri),
                      warmed.object(forKey: url as NSURL) == nil else { continue }
                warmed.setObject(1, forKey: url as NSURL)
                group.addTask { await warmHLS(at: url, index: index) }
            }
            var results: [String] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results.sorted()
        }
    }

    private static func warmHLS(at masterURL: URL, index: Int) async -> String? {
        let totalStartedAt = Date()
        var masterMs = 0
        var renditionMs = 0
        var firstMediaMs = 0
        guard masterURL.path.lowercased().hasSuffix(".m3u8") else {
            return timing(index, masterURL, totalStartedAt, masterMs, renditionMs, firstMediaMs, "unsupported-non-hls")
        }
        do {
            var masterRequest = URLRequest(url: masterURL)
            masterRequest.cachePolicy = .returnCacheDataElseLoad
            masterRequest.timeoutInterval = 4
            let masterStartedAt = Date()
            let (masterData, masterResponse) = try await URLSession.shared.data(for: masterRequest)
            masterMs = Int(Date().timeIntervalSince(masterStartedAt) * 1_000)
            guard (masterResponse as? HTTPURLResponse)?.statusCode == 200,
                  let master = String(data: masterData, encoding: .utf8),
                  let renditionURL = firstPlaylistURL(in: master, relativeTo: masterURL) else {
                return timing(index, masterURL, totalStartedAt, masterMs, renditionMs, firstMediaMs, "master-invalid")
            }

            var renditionRequest = URLRequest(url: renditionURL)
            renditionRequest.cachePolicy = .returnCacheDataElseLoad
            renditionRequest.timeoutInterval = 4
            let renditionStartedAt = Date()
            let (renditionData, renditionResponse) = try await URLSession.shared.data(for: renditionRequest)
            renditionMs = Int(Date().timeIntervalSince(renditionStartedAt) * 1_000)
            guard (renditionResponse as? HTTPURLResponse)?.statusCode == 200,
                  let rendition = String(data: renditionData, encoding: .utf8),
                  let firstMediaURL = firstMediaURL(in: rendition, relativeTo: renditionURL) else {
                return timing(index, masterURL, totalStartedAt, masterMs, renditionMs, firstMediaMs, "rendition-invalid")
            }

            // Establish the CDN path without downloading a segment twice. AVPlayer
            // remains the owner of media bytes and playback.
            var request = URLRequest(url: firstMediaURL)
            request.httpMethod = "HEAD"
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 3
            let firstMediaStartedAt = Date()
            _ = try? await URLSession.shared.data(for: request)
            firstMediaMs = Int(Date().timeIntervalSince(firstMediaStartedAt) * 1_000)
            return timing(index, masterURL, totalStartedAt, masterMs, renditionMs, firstMediaMs, "ready")
        } catch {
            // Warming is opportunistic and must never affect playback.
            return timing(index, masterURL, totalStartedAt, masterMs, renditionMs, firstMediaMs, "failed")
        }
    }

    private static func timing(
        _ index: Int,
        _ masterURL: URL,
        _ startedAt: Date,
        _ masterMs: Int,
        _ renditionMs: Int,
        _ firstMediaMs: Int,
        _ status: String
    ) -> String {
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        return "creative_warm index=\(index) host=\(masterURL.host ?? "unknown") "
            + "masterMs=\(masterMs) renditionMs=\(renditionMs) firstMediaMs=\(firstMediaMs) "
            + "totalMs=\(totalMs) status=\(status)"
    }

    private static func firstPlaylistURL(in playlist: String, relativeTo base: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#"), value.contains(".m3u8") else { continue }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func firstMediaURL(in playlist: String, relativeTo base: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#EXT-X-MAP"),
               let range = value.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let matched = String(value[range])
                    .replacingOccurrences(of: "URI=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                return URL(string: matched, relativeTo: base)?.absoluteURL
            }
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        return nil
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

struct ShortsServerAdPresentation: Equatable {
    let breakId: String
    let asset: SGAIAsset?
    let remainingSec: Double
    let progress: Double
    let canSkip: Bool
    var isSkippable: Bool = false
    var skipCountdown: Int = 0

    var clickThroughURL: URL? {
        guard let rawValue = asset?.clickThroughURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        let raw = rawValue.lowercased().hasPrefix("www.") ? "https://\(rawValue)" : rawValue
        guard let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
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

@MainActor
final class ServerAdPlaybackCoordinator: ObservableObject {
    @Published private(set) var presentation: ShortsServerAdPresentation?
    @Published private(set) var isPaused = false
    @Published private(set) var isMuted = false

    private weak var primaryPlayer: AVPlayer?
    private var monitor: AVPlayerInterstitialEventMonitor?
    private weak var timeObserverPlayer: AVPlayer?
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    fileprivate var context: SGAIPlaybackContext?
    fileprivate var policy: EffectiveAdPolicy?
    private var assets: [SGAIAsset] = []
    private var bootstrapAssetsByBreak: [String: [SGAIAsset]] = [:]
    private var ssaiSchedule: [SSAIScheduleBreak] = []
    private var activeSSAIWindow: SSAIScheduleBreak?
    private var lastSSAIPlaybackTime: Double?
    private var isCorrectingSSAISeek = false
    private var scheduleTask: Task<Void, Never>?
    private var interstitialStartTask: Task<Void, Never>?
    private var hasLoggedInterstitialProgress = false
    private var firedEvents = Set<String>()

    var interstitialPlayer: AVPlayer? {
        monitor?.interstitialPlayer ?? (ssaiSchedule.isEmpty ? nil : primaryPlayer)
    }

    var activeCreative: AdCreative? {
        presentation?.asset.map(Self.creative)
    }

    func activeFullscreenPresentation() -> ActiveAdPresentation? {
        guard let decision = activeDecision, let context, let presentation else { return nil }
        return ActiveAdPresentation(
            decision: decision,
            contentId: context.contentId,
            placement: placement(for: presentation.breakId),
            breakId: presentation.breakId,
            userId: context.userId,
            currentAdIndex: 0,
            hasTrackedImpression: true,
            hasTrackedStart: true,
            adPolicy: policy,
            adRemoval: policy?.adRemoval,
            overrideSkippable: policy?.skippable,
            overrideSkipAfterSec: policy?.skipAfterSec,
            onSkip: { [weak self] in self?.skip() },
            onFinish: nil,
            suppressTracking: true,
            observeExternalCompletion: false
        )
    }

    fileprivate var activeDecision: AdDecision? {
        guard let presentation else { return nil }
        let asset = presentation.asset ?? SGAIAsset(
            uri: (interstitialPlayer?.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "about:blank",
            duration: interstitialPlayer?.currentItem?.duration.seconds.validTime,
            impressionId: presentation.breakId,
            decisionId: nil,
            lineItemId: nil,
            campaignId: nil,
            creativeId: nil,
            skippable: policy?.skippable == true ? 1 : 0,
            skipOffsetSec: policy?.skipAfterSec.map(Double.init),
            clickThroughURL: nil,
            brandLogoURL: nil,
            brandLabel: nil,
            brandTitle: nil,
            brandDescription: nil,
            ctaText: nil
        )
        return AdDecision(
            decisionId: asset.decisionId,
            filled: true,
            ads: [Self.creative(asset)],
            noFillReason: nil,
            adRemoval: policy?.adRemoval,
            policy: AdDecisionPolicy(
                skippable: policy?.skippable ?? (asset.skippable == 1),
                skipAfterSec: policy?.skipAfterSec.map(Double.init) ?? asset.skipOffsetSec
            ),
            adPolicy: nil
        )
    }

    private static func creative(_ asset: SGAIAsset) -> AdCreative {
        AdCreative(
            impressionId: asset.impressionId ?? asset.uri,
            lineItemId: asset.lineItemId,
            campaignId: asset.campaignId,
            creativeId: asset.creativeId,
            advertiserId: nil,
            demandOwner: nil,
            name: asset.brandTitle,
            durationSec: asset.duration,
            mediaUrl: asset.uri,
            mediaType: "application/vnd.apple.mpegurl",
            width: nil,
            height: nil,
            skippable: asset.skippable == 1,
            skipOffsetSec: asset.skipOffsetSec,
            clickThroughUrl: asset.clickThroughURL,
            brandLogoUrl: asset.brandLogoURL,
            brandLabel: asset.brandLabel,
            brandTitle: asset.brandTitle,
            brandDescription: asset.brandDescription,
            ctaText: asset.ctaText
        )
    }

    func configure(
        player: AVPlayer,
        monitor: AVPlayerInterstitialEventMonitor,
        context: SGAIPlaybackContext,
        policy: EffectiveAdPolicy,
        bootstrap: SGAIBootstrapResponse? = nil
    ) {
        reset()
        primaryPlayer = player
        isMuted = player.isMuted
        self.monitor = monitor
        self.context = context
        self.policy = policy
        if let bootstrap, !bootstrap.assets.isEmpty {
            bootstrapAssetsByBreak[bootstrap.breakId] = bootstrap.assets
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVPlayerInterstitialEventMonitor.currentEventDidChangeNotification,
                object: monitor,
                queue: .main
            ) { [weak self, weak monitor] _ in
                Task { @MainActor in self?.handleEventChange(monitor: monitor) }
            }
        ]
        timeObserver = monitor.interstitialPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak monitor] time in
            Task { @MainActor in
                self?.updateProgress(monitor: monitor, elapsed: time.seconds)
            }
        }
        timeObserverPlayer = monitor.interstitialPlayer
        monitor.interstitialPlayer.automaticallyWaitsToMinimizeStalling = false
        monitor.interstitialPlayer.currentItem?.preferredForwardBufferDuration = 2
        debugPlayback(
            "monitor_configured primaryStatus=\(player.timeControlStatus.debugName) "
            + "interstitialStatus=\(monitor.interstitialPlayer.timeControlStatus.debugName)"
        )
    }

    func acceptBootstrap(_ bootstrap: SGAIBootstrapResponse, context: SGAIPlaybackContext) {
        guard self.context == context, !bootstrap.assets.isEmpty else { return }
        bootstrapAssetsByBreak[bootstrap.breakId] = bootstrap.assets
    }

    func configureSSAI(
        player: AVPlayer,
        context: SGAIPlaybackContext,
        policy: EffectiveAdPolicy,
        durationSec: Double?
    ) {
        reset()
        primaryPlayer = player
        isMuted = player.isMuted
        self.context = context
        self.policy = policy
        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.updateSSAIProgress(elapsed: time.seconds)
            }
        }

        guard let url = SGAIPlaybackURLBuilder.scheduleURL(
            context: context,
            durationSec: durationSec,
            policy: policy
        ) else { return }
        // Companion metadata must never delay player attachment or playback.
        // AVPlayer independently prepares the stitched HLS source.
        scheduleTask = Task { [weak self, weak player] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      let self,
                      let player,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      self.context == context,
                      self.monitor == nil else { return }
                let schedule = try JSONDecoder().decode(SSAISchedule.self, from: data)
                self.ssaiSchedule = schedule.breaks.sorted { $0.start < $1.start }
                self.lastSSAIPlaybackTime = player.currentTime().seconds.validTime
                self.updateSSAIProgress(elapsed: player.currentTime().seconds)
            } catch {
                // Stitched playback remains valid if optional metadata fails.
            }
        }
    }

    func contentTime(forStitchedTime stitchedTime: Double) -> Double {
        guard stitchedTime.isFinite else { return 0 }
        var insertedDuration = 0.0
        for window in ssaiSchedule {
            if stitchedTime >= window.end {
                insertedDuration += max(0, window.end - window.start)
            } else if stitchedTime >= window.start {
                return max(0, window.start - insertedDuration)
            } else {
                break
            }
        }
        return max(0, stitchedTime - insertedDuration)
    }

    func stitchedTime(forContentTime contentTime: Double) -> Double {
        guard contentTime.isFinite else { return 0 }
        var insertedDuration = 0.0
        for window in ssaiSchedule {
            let contentBreakTime = window.start - insertedDuration
            if contentTime > contentBreakTime {
                insertedDuration += max(0, window.end - window.start)
            } else {
                break
            }
        }
        return max(0, contentTime + insertedDuration)
    }

    func skip() {
        guard presentation?.canSkip == true else { return }
        if let activeSSAIWindow, let primaryPlayer {
            track("skip")
            primaryPlayer.seek(
                to: CMTime(seconds: activeSSAIWindow.end, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        } else if let monitor {
            track("skip")
            monitor.interstitialPlayer.advanceToNextItem()
            // AVFoundation does not consistently restart the primary timeline
            // after an interstitial is skipped. Resume it explicitly so the ad
            // overlay cannot leave the watch screen on a frozen final frame.
            primaryPlayer?.playImmediately(atRate: 1)
        }
    }

    func openAdvertiser() {
        guard let url = presentation?.clickThroughURL else { return }
        track("click")
        UIApplication.shared.open(url, options: [:])
    }

    func togglePause() {
        guard let player = interstitialPlayer else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
        isPaused.toggle()
    }

    func toggleMute() {
        isMuted.toggle()
        primaryPlayer?.isMuted = isMuted
        monitor?.interstitialPlayer.isMuted = isMuted
    }

    func reset() {
        scheduleTask?.cancel()
        scheduleTask = nil
        interstitialStartTask?.cancel()
        interstitialStartTask = nil
        if let timeObserverPlayer, let timeObserver {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timeObserver = nil
        timeObserverPlayer = nil
        monitor = nil
        primaryPlayer = nil
        context = nil
        policy = nil
        assets = []
        bootstrapAssetsByBreak = [:]
        ssaiSchedule = []
        activeSSAIWindow = nil
        lastSSAIPlaybackTime = nil
        isCorrectingSSAISeek = false
        firedEvents = []
        hasLoggedInterstitialProgress = false
        presentation = nil
        isPaused = false
    }

    private func updateSSAIProgress(elapsed: Double) {
        guard elapsed.isFinite else { return }
        if let previous = lastSSAIPlaybackTime,
           !isCorrectingSSAISeek,
           elapsed - previous > 1.25,
           let blocked = ssaiSchedule.first(where: {
               let isSkippable = policy?.skippable ?? $0.skippable
               return !isSkippable
                   && previous < $0.end
                   && elapsed >= $0.end
           }),
           let primaryPlayer {
            isCorrectingSSAISeek = true
            primaryPlayer.seek(
                to: CMTime(seconds: blocked.start, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.lastSSAIPlaybackTime = blocked.start
                    self?.isCorrectingSSAISeek = false
                }
            }
            return
        }
        lastSSAIPlaybackTime = elapsed
        guard let window = ssaiSchedule.first(where: { elapsed >= $0.start && elapsed < $0.end }) else {
            activeSSAIWindow = nil
            presentation = nil
            return
        }
        activeSSAIWindow = window
        let duration = max(0, window.end - window.start)
        let adElapsed = max(0, elapsed - window.start)
        let skipOffset = policy?.skipAfterSec.map(Double.init) ?? window.skipOffset
        let isSkippable = policy?.skippable ?? window.skippable
        let asset = SGAIAsset(
            uri: (primaryPlayer?.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "",
            duration: duration,
            impressionId: window.iid,
            decisionId: window.did,
            lineItemId: window.li,
            campaignId: window.camp,
            creativeId: window.cr,
            skippable: isSkippable ? 1 : 0,
            skipOffsetSec: skipOffset,
            clickThroughURL: window.click,
            brandLogoURL: window.brand?.logo,
            brandLabel: window.brand?.label,
            brandTitle: window.brand?.title,
            brandDescription: window.brand?.description,
            ctaText: window.brand?.cta
        )
        presentation = ShortsServerAdPresentation(
            breakId: window.breakId,
            asset: asset,
            remainingSec: max(0, window.end - elapsed),
            progress: duration > 0 ? min(1, adElapsed / duration) : 0,
            canSkip: isSkippable && adElapsed >= min(max(0, skipOffset), duration),
            isSkippable: isSkippable,
            skipCountdown: Int(ceil(max(0, skipOffset - adElapsed)))
        )
        // True SSAI tracking is segment-driven at the Worker. The first ad
        // segment fires impression/start and later segment redirects fire
        // quartiles/complete. The client only owns interactive click/skip.
    }

    private func handleEventChange(monitor: AVPlayerInterstitialEventMonitor?) {
        guard let monitor else { return }
        guard let event = monitor.currentEvent else {
            debugPlayback("event_inactive")
            interstitialStartTask?.cancel()
            interstitialStartTask = nil
            if presentation != nil { track("complete") }
            presentation = nil
            assets = []
            firedEvents = []
            isPaused = false
            primaryPlayer?.playImmediately(atRate: 1)
            debugPlayback(
                "content_resume_requested primary=\(primaryPlayer?.timeControlStatus.debugName ?? "missing")"
            )
            return
        }
        monitor.interstitialPlayer.automaticallyWaitsToMinimizeStalling = false
        monitor.interstitialPlayer.currentItem?.preferredForwardBufferDuration = 2
        debugPlayback(
            "event_active id=\(event.identifier) "
            + "itemStatus=\(monitor.interstitialPlayer.currentItem?.status.debugName ?? "missing") "
            + "timeControl=\(monitor.interstitialPlayer.timeControlStatus.debugName)"
        )
        resumeActiveInterstitial()

        let breakId = SGAIBreakIdentifier.breakId(from: event.identifier)
        if let bootstrapAssets = bootstrapAssetsByBreak.removeValue(forKey: breakId),
           let first = bootstrapAssets.first {
            assets = bootstrapAssets
            presentation = ShortsServerAdPresentation(
                breakId: breakId,
                asset: first,
                remainingSec: max(0, first.duration ?? 0),
                progress: 0,
                canSkip: false,
                isSkippable: policy?.skippable ?? (first.skippable == 1),
                skipCountdown: Int(ceil(policy?.skipAfterSec.map(Double.init) ?? first.skipOffsetSec ?? 0))
            )
            track("start")
            return
        }
        presentation = ShortsServerAdPresentation(
            breakId: breakId,
            asset: nil,
            remainingSec: 0,
            progress: 0,
            canSkip: false
        )
        assets = []
        firedEvents = []
        guard let context,
              let url = SGAIPlaybackURLBuilder.assetListURL(breakId: breakId, context: context) else {
            return
        }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let list = try JSONDecoder().decode(SGAIAssetList.self, from: data)
                guard let first = list.assets.first else { return }
                await MainActor.run {
                    guard self.monitor?.currentEvent?.identifier == event.identifier else { return }
                    self.assets = list.assets
                    self.presentation = ShortsServerAdPresentation(
                        breakId: breakId,
                        asset: first,
                        remainingSec: max(0, first.duration ?? 0),
                        progress: 0,
                        canSkip: false
                    )
                    self.track("start")
                }
            } catch {
                // The interstitial can continue without optional companion metadata.
            }
        }
    }

    private func updateProgress(
        monitor: AVPlayerInterstitialEventMonitor?,
        elapsed: Double
    ) {
        guard monitor?.currentEvent != nil, let current = presentation else { return }
        if elapsed.isFinite, elapsed > 0.05 {
            if !hasLoggedInterstitialProgress {
                hasLoggedInterstitialProgress = true
                debugPlayback(
                    "playback_started elapsedMs=\(Int(elapsed * 1_000)) "
                    + "timeControl=\(monitor?.interstitialPlayer.timeControlStatus.debugName ?? "missing")"
                )
            }
            interstitialStartTask?.cancel()
            interstitialStartTask = nil
            isPaused = false
        }
        let itemURL = (monitor?.interstitialPlayer.currentItem?.asset as? AVURLAsset)?.url
        let matched = assets.first {
            guard let assetURL = URL(string: $0.uri), let itemURL else { return false }
            return assetURL.absoluteString == itemURL.absoluteString
        }
        let activeAsset = matched ?? current.asset
        if activeAsset?.impressionId != current.asset?.impressionId {
            track("complete")
            presentation = ShortsServerAdPresentation(
                breakId: current.breakId,
                asset: activeAsset,
                remainingSec: max(0, activeAsset?.duration ?? 0),
                progress: 0,
                canSkip: false
            )
            track("start")
        }
        guard let refreshed = presentation else { return }

        let itemDuration = monitor?.interstitialPlayer.currentItem?.duration.seconds
        let duration = (itemDuration?.isFinite == true ? itemDuration : nil)
            ?? refreshed.asset?.duration
            ?? 0
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let progress = duration > 0 ? min(1, safeElapsed / duration) : 0
        let skipOffset = policy?.skipAfterSec.map(Double.init)
            ?? refreshed.asset?.skipOffsetSec
            ?? 0
        let isSkippable = policy?.skippable ?? (refreshed.asset?.skippable == 1)
        let remainingToSkip = max(0, skipOffset - safeElapsed)
        presentation = ShortsServerAdPresentation(
            breakId: refreshed.breakId,
            asset: refreshed.asset,
            remainingSec: duration > 0 ? max(0, duration - safeElapsed) : 0,
            progress: progress,
            canSkip: refreshed.asset != nil
                && isSkippable
                && safeElapsed >= max(0, duration > 0 ? min(skipOffset, duration) : skipOffset),
            isSkippable: isSkippable,
            skipCountdown: Int(ceil(remainingToSkip))
        )
        if progress >= 0.25 { track("firstQuartile") }
        if progress >= 0.50 { track("midpoint") }
        if progress >= 0.75 { track("thirdQuartile") }
    }

    private func resumeActiveInterstitial() {
        interstitialStartTask?.cancel()
        isPaused = false

        // The primary player's play state drives AVFoundation's interstitial
        // timeline. Starting only the dedicated interstitial player can leave a
        // ready preroll paused until another UI transition calls play().
        primaryPlayer?.play()
        monitor?.interstitialPlayer.playImmediately(atRate: 1)
        debugPlayback(
            "play_requested primary=\(primaryPlayer?.timeControlStatus.debugName ?? "missing") "
            + "interstitial=\(monitor?.interstitialPlayer.timeControlStatus.debugName ?? "missing") "
            + "itemStatus=\(monitor?.interstitialPlayer.currentItem?.status.debugName ?? "missing")"
        )

        // The event notification can arrive before AVFoundation has attached
        // the interstitial item. Retry briefly until playback advances; this is
        // bounded and stops as soon as the event starts or ends.
        interstitialStartTask = Task { [weak self] in
            for _ in 0..<20 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      let monitor = self.monitor,
                      monitor.currentEvent != nil else { return }
                let elapsed = monitor.interstitialPlayer.currentTime().seconds
                if elapsed.isFinite, elapsed > 0.05 {
                    self.interstitialStartTask = nil
                    return
                }
                self.primaryPlayer?.play()
                monitor.interstitialPlayer.playImmediately(atRate: 1)
            }
            if let self {
                let item = self.monitor?.interstitialPlayer.currentItem
                let errorEvent = item?.errorLog()?.events.last
                self.debugPlayback(
                    "play_retry_exhausted primary=\(self.primaryPlayer?.timeControlStatus.debugName ?? "missing") "
                    + "interstitial=\(self.monitor?.interstitialPlayer.timeControlStatus.debugName ?? "missing") "
                    + "waiting=\(self.monitor?.interstitialPlayer.reasonForWaitingToPlay?.rawValue ?? "none") "
                    + "itemStatus=\(item?.status.debugName ?? "missing") "
                    + "likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) "
                    + "bufferEmpty=\(item?.isPlaybackBufferEmpty ?? true) "
                    + "loadedRanges=\(item?.loadedTimeRanges.count ?? 0) "
                    + "itemError=\(item?.error?.localizedDescription ?? "none") "
                    + "errorLogStatus=\(errorEvent?.errorStatusCode ?? 0) "
                    + "errorLog=\(errorEvent?.errorComment ?? "none") "
                    + "errorURI=\(errorEvent?.uri ?? "none")"
                )
            }
            self?.interstitialStartTask = nil
        }
    }

    private func debugPlayback(_ message: String) {
#if DEBUG
        print("[Ads][Video][SGAI] \(message)")
#endif
    }

    fileprivate func track(_ event: String) {
        guard let presentation,
              let asset = presentation.asset,
              let impressionId = asset.impressionId,
              !impressionId.isEmpty,
              let context else { return }
        guard firedEvents.insert("\(impressionId):\(event)").inserted else { return }
        let creative = AdCreative(
            impressionId: impressionId,
            lineItemId: asset.lineItemId,
            campaignId: asset.campaignId,
            creativeId: asset.creativeId,
            advertiserId: nil,
            demandOwner: nil,
            name: asset.brandTitle,
            durationSec: asset.duration,
            mediaUrl: asset.uri,
            mediaType: "application/vnd.apple.mpegurl",
            width: nil,
            height: nil,
            skippable: asset.skippable == 1,
            skipOffsetSec: asset.skipOffsetSec,
            clickThroughUrl: asset.clickThroughURL,
            brandLogoUrl: asset.brandLogoURL,
            brandLabel: asset.brandLabel,
            brandTitle: asset.brandTitle,
            brandDescription: asset.brandDescription,
            ctaText: asset.ctaText
        )
        Task {
            await AdServerClient.shared.track(
                event: event,
                ad: creative,
                decisionId: asset.decisionId,
                contentId: context.contentId,
                placement: placement(for: presentation.breakId),
                breakId: presentation.breakId,
                userId: context.userId
            )
        }
    }

    fileprivate func placement(for breakId: String) -> String {
        let value = breakId.lowercased()
        if value.contains("post") { return "postroll" }
        if value.contains("mid") { return "midroll" }
        return "preroll"
    }
}

struct ServerGuidedAdPlayerView: View {
    @ObservedObject var coordinator: ServerAdPlaybackCoordinator
    var vertical = false
    var brandCardPlacement: NativeAdBrandCardPlacement = .hidden
    var onFullscreen: (() -> Void)?

    var body: some View {
        if let player = coordinator.interstitialPlayer,
           let presentation = coordinator.presentation {
            ZStack {
                Color.black
                WatchPlayerSurface(player: player)
                ServerAdOverlay(
                    presentation: presentation,
                    vertical: vertical,
                    isPaused: coordinator.isPaused,
                    isMuted: coordinator.isMuted,
                    showBrandCard: brandCardPlacement != .hidden,
                    onTogglePause: { coordinator.togglePause() },
                    onToggleMute: { coordinator.toggleMute() },
                    onFullscreen: onFullscreen,
                    onSkip: { coordinator.skip() },
                    onOpen: { coordinator.openAdvertiser() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil)
            .aspectRatio(vertical ? nil : 16 / 9, contentMode: .fit)
            .clipped()
        }
    }
}

struct ServerAdOverlay: View {
    let presentation: ShortsServerAdPresentation
    var vertical = false
    var isPaused = false
    var isMuted = false
    var showBrandCard = true
    var bottomContentInset: CGFloat = 0
    var progressBottomInset: CGFloat? = nil
    var onTogglePause: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onFullscreen: (() -> Void)?
    let onSkip: () -> Void
    let onOpen: () -> Void

    private var title: String {
        presentation.asset?.brandTitle
            ?? presentation.asset?.brandLabel
            ?? "Sponsored"
    }

    var body: some View {
        ZStack {
            if presentation.clickThroughURL != nil {
                Button(action: onOpen) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Visit advertiser")
            }

            LinearGradient(
                colors: [.black.opacity(0.50), .clear, .black.opacity(0.70)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("AD")
                        .font(.system(size: 11, weight: vertical ? .black : .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                    Text(presentation.remainingSec > 0
                         ? "Ad · \(Int(ceil(presentation.remainingSec)))s"
                         : "Ad")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let onTogglePause, !vertical {
                        controlButton(
                            systemName: isPaused ? "play.fill" : "pause.fill",
                            action: onTogglePause
                        )
                    }
                    if let onToggleMute {
                        controlButton(
                            systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            action: onToggleMute
                        )
                    }
                    if let onFullscreen, !vertical {
                        controlButton(
                            systemName: "arrow.up.left.and.arrow.down.right",
                            action: onFullscreen
                        )
                    }
                }
                .padding(.horizontal, vertical ? 12 : 8)
                .frame(height: 44)

                Spacer()

                HStack {
                    Spacer()
                    if presentation.canSkip {
                        Button("Skip ad ▸", action: onSkip)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(vertical ? .white : .black)
                            .padding(.horizontal, vertical ? 14 : 12)
                            .padding(.vertical, 6)
                            .background(vertical ? .black.opacity(0.70) : .white.opacity(0.90), in: RoundedRectangle(cornerRadius: vertical ? 6 : 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: vertical ? 6 : 4)
                                    .stroke(.white.opacity(vertical ? 0.20 : 1), lineWidth: 1)
                            }
                    } else if presentation.isSkippable {
                        Text("Skip in \(presentation.skipCountdown)s")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(vertical ? 0.70 : 0.60))
                            .monospacedDigit()
                            .padding(.horizontal, vertical ? 14 : 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(vertical ? 0.50 : 0.40), in: RoundedRectangle(cornerRadius: vertical ? 6 : 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: vertical ? 6 : 4)
                                    .stroke(.white.opacity(0.20), lineWidth: 1)
                            }
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 10)

                if showBrandCard {
                    HStack(spacing: 12) {
                        if let rawLogo = presentation.asset?.brandLogoURL,
                           let logoURL = URL(string: rawLogo) {
                            AsyncImage(url: logoURL) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Color.white.opacity(0.08)
                            }
                            .frame(width: vertical ? 40 : 48, height: vertical ? 40 : 48)
                            .clipShape(RoundedRectangle(cornerRadius: vertical ? 10 : 8))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = presentation.asset?.brandLabel, !label.isEmpty {
                                Text(vertical ? label : label.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(vertical ? 0.60 : 0.50))
                                    .lineLimit(1)
                            }
                            Text(title)
                                .font(.system(size: vertical ? 14 : 15, weight: vertical ? .bold : .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let description = presentation.asset?.brandDescription,
                               !description.isEmpty {
                                Text(description)
                                    .font(.system(size: vertical ? 12 : 13))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if presentation.clickThroughURL != nil {
                            Button(presentation.asset?.ctaText ?? "Learn more", action: onOpen)
                                .font(.system(size: 13, weight: vertical ? .bold : .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, vertical ? 14 : 16)
                                .padding(.vertical, 8)
                                .background(vertical ? Color.yellow : C.watch, in: Capsule())
                        }
                    }
                    .padding(vertical ? 12 : 0)
                    .padding(.horizontal, vertical ? 0 : 16)
                    .padding(.vertical, vertical ? 0 : 12)
                    .background(vertical ? Color.black.opacity(0.55) : Color(red: 0.071, green: 0.071, blue: 0.102), in: RoundedRectangle(cornerRadius: vertical ? 14 : 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: vertical ? 14 : 12)
                            .stroke(.white.opacity(vertical ? 0.15 : 0.08), lineWidth: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }

            }
            .padding(.bottom, vertical ? bottomContentInset : 0)

            GeometryReader { geo in
                Color.yellow
                    .frame(width: geo.size.width * min(max(presentation.progress, 0), 1))
            }
            .frame(height: 3)
            .padding(
                .bottom,
                vertical ? (progressBottomInset ?? bottomContentInset) : 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .zIndex(2)
        }
        .background(Color.black.opacity(0.05))
    }

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: vertical ? 34 : 32, height: vertical ? 34 : 32)
                .background(.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
