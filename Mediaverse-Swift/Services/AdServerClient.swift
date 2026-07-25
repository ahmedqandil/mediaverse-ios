import AVKit
import Foundation
import SwiftUI
import UIKit

struct AdDecision: Decodable {
    let decisionId: String?
    let filled: Bool
    let ads: [AdCreative]
    let noFillReason: String?
    let adRemoval: AdRemovalOffer?
    let policy: AdDecisionPolicy?
    let adPolicy: AdDecisionPolicy?
}

struct AdDecisionPolicy: Decodable {
    let skippable: Bool?
    let skipAfterSec: Double?
}

private struct PendingAdTrackingEvent: Codable {
    let id: String
    let url: String
    let createdAt: Date
    var failedAttempts: Int
}

struct AdRemovalOffer: Codable {
    let scope: String?
    let entityId: String?
    let entityName: String?
    let productIds: [String]?
    let salesUrl: String?
    let networkName: String?
}

struct AdCreative: Decodable, Identifiable {
    var id: String { impressionId }

    let impressionId: String
    let lineItemId: String?
    let campaignId: String?
    let creativeId: String?
    let advertiserId: String?
    let demandOwner: String?
    let name: String?
    let durationSec: Double?
    let mediaUrl: String?
    let mediaType: String?
    let width: Int?
    let height: Int?
    let skippable: Bool?
    let skipOffsetSec: Double?
    let clickThroughUrl: String?
    let brandLogoUrl: String?
    let brandLabel: String?
    let brandTitle: String?
    let brandDescription: String?
    let ctaText: String?
}

struct AdRequestContext {
    let contentId: String
    let contentType: String
    let placement: String?
    let durationSec: Double?
    let maxAds: Int?
    let maxDurationSec: Int?
    let skippable: Bool?
    let skipAfterSec: Int?
    let orientation: String
    let breakId: String?
    let userId: String?

    init(
        contentId: String,
        contentType: String,
        placement: String? = nil,
        durationSec: Double? = nil,
        maxAds: Int? = nil,
        maxDurationSec: Int? = nil,
        skippable: Bool? = nil,
        skipAfterSec: Int? = nil,
        orientation: String,
        breakId: String? = nil,
        userId: String? = nil
    ) {
        self.contentId = contentId
        self.contentType = contentType
        self.placement = placement
        self.durationSec = durationSec
        self.maxAds = maxAds
        self.maxDurationSec = maxDurationSec
        self.skippable = skippable
        self.skipAfterSec = skipAfterSec
        self.orientation = orientation
        self.breakId = breakId
        self.userId = userId
    }
}

struct NativeAdCompanionCard: View {
    let ad: AdCreative

    @Environment(\.openURL) private var openURL

    private var clickThroughURL: URL? {
        guard let rawValue = ad.clickThroughUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let value = rawValue.lowercased().hasPrefix("www.") ? "https://\(rawValue)" : rawValue
        guard let url = URL(string: value),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            brandLogo

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("AD")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.98, green: 0.80, blue: 0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if let label = ad.brandLabel, !label.isEmpty {
                        Text(label.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }

                if let title = ad.brandTitle ?? ad.name, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if let description = ad.brandDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let url = clickThroughURL, let cta = ctaLabel {
                Button {
                    openURL(url)
                } label: {
                    Text(cta)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(C.watch, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.071, green: 0.071, blue: 0.102), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var brandLogo: some View {
        Group {
            if let url = C.mediaURL(ad.brandLogoUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 48, height: 48)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    brandLogoFallback
                }
            } else {
                brandLogoFallback
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var brandLogoFallback: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.14))
            .overlay {
                Text("Ad")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
    }

    private var ctaLabel: String? {
        let raw = ad.ctaText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return "Learn more →" }
        return raw.hasSuffix("→") ? raw : "\(raw) →"
    }
}

struct AdBreak: Identifiable, Equatable {
    let id: String
    let breakId: String
    let timeOffsetSec: Double
    let placement: String
}

enum AdBreakScheduler {
    static func nextDue(
        in breaks: [AdBreak],
        watchedIds: Set<String>,
        pendingIds: Set<String>,
        from previousSeconds: Double,
        to currentSeconds: Double
    ) -> AdBreak? {
        guard currentSeconds >= previousSeconds else { return nil }
        return breaks
            .filter { !watchedIds.contains($0.id) && !pendingIds.contains($0.id) }
            .filter {
                $0.timeOffsetSec > previousSeconds + 0.05
                    && $0.timeOffsetSec <= currentSeconds + 0.25
            }
            .sorted { $0.timeOffsetSec < $1.timeOffsetSec }
            .first
    }
}

struct ActiveAdPresentation {
    let decision: AdDecision
    let contentId: String
    let placement: String?
    let breakId: String?
    let userId: String?
    let currentAdIndex: Int
    let hasTrackedImpression: Bool
    let hasTrackedStart: Bool
    let adPolicy: EffectiveAdPolicy?
    let adRemoval: AdRemovalOffer?
    let overrideSkippable: Bool?
    let overrideSkipAfterSec: Int?
    let onSkip: (() -> Void)?
    let onFinish: (() -> Void)?
    var suppressTracking = false
    var observeExternalCompletion = true
}

enum NativeAdBrandCardPlacement {
    case hidden
    case belowPlayer
    case playerOverlay
}

enum ActiveAdFullscreenHandoff {
    private static var protectedPlayers = Set<ObjectIdentifier>()

    static func protect(_ player: AVPlayer) {
        protectedPlayers.insert(ObjectIdentifier(player))
    }

    static func release(_ player: AVPlayer) {
        protectedPlayers.remove(ObjectIdentifier(player))
    }

    static func isProtected(_ player: AVPlayer?) -> Bool {
        guard let player else { return false }
        return protectedPlayers.contains(ObjectIdentifier(player))
    }
}

actor AdServerClient {
    static let shared = AdServerClient()

    private let session = URLSession(configuration: .ephemeral)
    private let trackingSession = URLSession(configuration: .default)
    private let decoder = JSONDecoder()
    private let trackingQueueCacheKey = "ads.pending-tracking.v1"
    private var isFlushingTrackingQueue = false

    private var sessionId: String {
        let idKey = "westreem.adSessionId"
        let lastSeenKey = "westreem.adSessionLastSeenAt"
        let ttl: TimeInterval = 30 * 60
        let now = Date().timeIntervalSince1970

        if let existing = UserDefaults.standard.string(forKey: idKey) {
            let lastSeen = UserDefaults.standard.double(forKey: lastSeenKey)
            if lastSeen > 0, now - lastSeen < ttl {
                UserDefaults.standard.set(now, forKey: lastSeenKey)
                return existing
            }
        }

        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: idKey)
        UserDefaults.standard.set(now, forKey: lastSeenKey)
        return created
    }

    private var deviceId: String {
        let key = "westreem.adDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    func requestAd(_ context: AdRequestContext) async throws -> AdDecision {
        let requestStartedAt = Date()
        scheduleTrackingQueueFlush()
        let deviceKind = await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        }
        var components = URLComponents(string: C.adServerURL + "/ad.json")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "contentId", value: context.contentId),
            URLQueryItem(name: "contentType", value: context.contentType),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "device", value: deviceKind),
            URLQueryItem(name: "os", value: "iOS"),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "orientation", value: context.orientation),
        ]

        if let placement = context.placement {
            items.append(URLQueryItem(name: "placement", value: placement))
        }
        if let durationSec = context.durationSec {
            items.append(URLQueryItem(name: "durationSec", value: String(Int(durationSec))))
        }
        if let maxAds = context.maxAds {
            items.append(URLQueryItem(name: "maxAds", value: String(maxAds)))
        }
        if let maxDurationSec = context.maxDurationSec {
            items.append(URLQueryItem(name: "maxDurationSec", value: String(maxDurationSec)))
        }
        if let skippable = context.skippable {
            items.append(URLQueryItem(name: "skippable", value: skippable ? "1" : "0"))
        }
        if let skipAfterSec = context.skipAfterSec {
            items.append(URLQueryItem(name: "skipAfterSec", value: String(skipAfterSec)))
        }
        if let breakId = context.breakId {
            items.append(URLQueryItem(name: "breakId", value: breakId))
        }
        if let userId = context.userId {
            items.append(URLQueryItem(name: "userId", value: userId))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw APIError.badURL(C.adServerURL + "/ad.json")
        }
        guard C.isTrustedAdURL(url) else {
            throw APIError.badURL(url.absoluteString)
        }

        Self.debugLog("request_started \(url.absoluteString)")
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let decision = try decoder.decode(AdDecision.self, from: data)
        Self.debugLog(
            "decision_received elapsedMs=\(Int(Date().timeIntervalSince(requestStartedAt) * 1_000)) "
            + "contentId=\(context.contentId) placement=\(context.placement ?? "linear") "
            + "filled=\(decision.filled) ads=\(decision.ads.count) noFill=\(decision.noFillReason ?? "none")"
        )
        return decision
    }

    func requestVMAP(_ context: AdRequestContext) async throws -> [AdBreak] {
        scheduleTrackingQueueFlush()
        let deviceKind = await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        }
        var components = URLComponents(string: C.adServerURL + "/vmap")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "contentId", value: context.contentId),
            URLQueryItem(name: "contentType", value: context.contentType),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "device", value: deviceKind),
            URLQueryItem(name: "os", value: "iOS"),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "orientation", value: context.orientation),
        ]

        if let placement = context.placement {
            items.append(URLQueryItem(name: "placement", value: placement))
        }
        if let durationSec = context.durationSec {
            items.append(URLQueryItem(name: "durationSec", value: String(Int(durationSec))))
        }
        if let maxAds = context.maxAds {
            items.append(URLQueryItem(name: "maxAds", value: String(maxAds)))
        }
        if let maxDurationSec = context.maxDurationSec {
            items.append(URLQueryItem(name: "maxDurationSec", value: String(maxDurationSec)))
        }
        if let skippable = context.skippable {
            items.append(URLQueryItem(name: "skippable", value: skippable ? "1" : "0"))
        }
        if let skipAfterSec = context.skipAfterSec {
            items.append(URLQueryItem(name: "skipAfterSec", value: String(skipAfterSec)))
        }
        if let breakId = context.breakId {
            items.append(URLQueryItem(name: "breakId", value: breakId))
        }
        if let userId = context.userId {
            items.append(URLQueryItem(name: "userId", value: userId))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw APIError.badURL(C.adServerURL + "/vmap")
        }
        guard C.isTrustedAdURL(url) else {
            throw APIError.badURL(url.absoluteString)
        }

        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try VMAPBreakParser.parse(data, durationSec: context.durationSec)
    }

    func track(event: String, ad: AdCreative, decisionId: String?, contentId: String, placement: String?, breakId: String? = nil, userId: String? = nil) async {
        let eventId = UUID().uuidString
        var components = URLComponents(string: C.adServerURL + "/track")
        components?.queryItems = [
            URLQueryItem(name: "eid", value: eventId),
            URLQueryItem(name: "e", value: event),
            URLQueryItem(name: "iid", value: ad.impressionId),
            URLQueryItem(name: "did", value: decisionId),
            URLQueryItem(name: "pl", value: placement),
            URLQueryItem(name: "li", value: ad.lineItemId),
            URLQueryItem(name: "camp", value: ad.campaignId),
            URLQueryItem(name: "cr", value: ad.creativeId),
            URLQueryItem(name: "c", value: contentId),
            URLQueryItem(name: "b", value: breakId),
            URLQueryItem(name: "s", value: sessionId),
            URLQueryItem(name: "p", value: "ios"),
            URLQueryItem(name: "u", value: userId),
            URLQueryItem(name: "dev", value: deviceId),
            URLQueryItem(name: "do", value: ad.demandOwner),
            URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ].compactMap { item in
            guard item.value != nil else { return nil }
            return item
        }

        guard let url = components?.url, C.isTrustedAdURL(url) else { return }
        let attempts = event == "impression" ? 3 : 2
        for attempt in 1...attempts {
            do {
                let (_, response) = try await trackingSession.data(from: url)
                try validate(response)
                return
            } catch {
                guard attempt < attempts else {
                    Self.debugLog("track failed event=\(event) impression=\(ad.impressionId): \(error.localizedDescription)")
                    await enqueueTrackingEvent(id: eventId, url: url)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }

    private func scheduleTrackingQueueFlush() {
        Task {
            await AdServerClient.shared.flushTrackingQueue()
        }
    }

    private func enqueueTrackingEvent(id: String, url: URL) async {
        var queued = (try? await DiskJSONCache.shared.value(
            forKey: trackingQueueCacheKey,
            as: [PendingAdTrackingEvent].self
        )) ?? []
        guard !queued.contains(where: { $0.id == id }) else { return }
        queued.append(
            PendingAdTrackingEvent(
                id: id,
                url: url.absoluteString,
                createdAt: Date(),
                failedAttempts: 0
            )
        )
        if queued.count > 200 {
            queued.removeFirst(queued.count - 200)
        }
        try? await DiskJSONCache.shared.store(
            queued,
            forKey: trackingQueueCacheKey,
            ttl: 24 * 60 * 60
        )
    }

    private func flushTrackingQueue() async {
        guard !isFlushingTrackingQueue else { return }
        isFlushingTrackingQueue = true
        defer { isFlushingTrackingQueue = false }

        guard let queued = try? await DiskJSONCache.shared.value(
            forKey: trackingQueueCacheKey,
            as: [PendingAdTrackingEvent].self
        ), !queued.isEmpty else { return }

        let now = Date()
        var remaining = [PendingAdTrackingEvent]()
        for var item in queued.prefix(20) {
            guard now.timeIntervalSince(item.createdAt) < 24 * 60 * 60,
                  let url = URL(string: item.url),
                  C.isTrustedAdURL(url) else { continue }
            do {
                let (_, response) = try await trackingSession.data(from: url)
                try validate(response)
            } catch {
                item.failedAttempts += 1
                if item.failedAttempts < 8 {
                    remaining.append(item)
                }
            }
        }
        if queued.count > 20 {
            remaining.append(contentsOf: queued.dropFirst(20))
        }

        if remaining.isEmpty {
            try? await DiskJSONCache.shared.removeValue(forKey: trackingQueueCacheKey)
        } else {
            try? await DiskJSONCache.shared.store(
                remaining,
                forKey: trackingQueueCacheKey,
                ttl: 24 * 60 * 60
            )
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            Self.debugLog("http \(http.statusCode)")
            throw APIError.http(http.statusCode)
        }
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Ads] \(message)")
        #endif
    }
}

final class VMAPBreakParser: NSObject, XMLParserDelegate {
    private var breaks = [AdBreak]()
    private let durationSec: Double?

    private init(durationSec: Double?) {
        self.durationSec = durationSec
    }

    static func parse(_ data: Data, durationSec: Double?) throws -> [AdBreak] {
        let parser = XMLParser(data: data)
        let delegate = VMAPBreakParser(durationSec: durationSec)
        parser.delegate = delegate
        guard parser.parse() else {
            throw APIError.invalidResponse(
                parser.parserError?.localizedDescription ?? "Invalid VMAP response"
            )
        }
        return delegate.breaks
            .filter { $0.timeOffsetSec > 0 }
            .sorted { $0.timeOffsetSec < $1.timeOffsetSec }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let normalized = elementName.lowercased()
        guard normalized == "adbreak" || normalized.hasSuffix(":adbreak") else { return }

        guard let offset = attributeDict["timeOffset"].flatMap(parseOffset) else { return }
        let breakId = attributeDict["breakId"]
            ?? attributeDict["breakID"]
            ?? attributeDict["id"]
            ?? attributeDict["breakType"]
            ?? "break-\(Int(offset))"
        let placement = Self.placementKey(breakId: breakId, offset: offset)
        breaks.append(
            AdBreak(
                id: "\(breakId)-\(Int(offset))",
                breakId: breakId,
                timeOffsetSec: offset,
                placement: placement
            )
        )
    }

    private static func placementKey(breakId: String, offset: Double) -> String {
        let normalizedBreakId = breakId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedBreakId.contains("preroll") || normalizedBreakId.contains("pre-roll") {
            return "preroll"
        }
        if normalizedBreakId.contains("midroll") || normalizedBreakId.contains("mid-roll") {
            return "midroll"
        }
        if normalizedBreakId.contains("postroll") || normalizedBreakId.contains("post-roll") {
            return "postroll"
        }
        return offset <= 0 ? "preroll" : "midroll"
    }

    private func parseOffset(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "start" { return 0 }
        if trimmed == "end" { return durationSec }
        if trimmed.hasSuffix("%"),
           let durationSec,
           durationSec.isFinite,
           durationSec > 0,
           let percent = Double(trimmed.dropLast()) {
            return durationSec * min(max(percent, 0), 100) / 100
        }
        if let seconds = Double(trimmed) { return seconds }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}

@MainActor
private final class NativeAdMediaCache {
    static let shared = NativeAdMediaCache()

    private struct Entry {
        let asset: AVURLAsset
        var lastAccess: UInt64
        var preparationTask: Task<Void, Never>?
    }

    private let capacity = 8
    private var accessCounter: UInt64 = 0
    private var entries: [URL: Entry] = [:]

    func asset(for url: URL) -> AVURLAsset {
        accessCounter &+= 1
        if var entry = entries[url] {
            entry.lastAccess = accessCounter
            entries[url] = entry
            return entry.asset
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let preparationTask = Task {
            _ = try? await asset.load(.isPlayable)
        }
        entries[url] = Entry(
            asset: asset,
            lastAccess: accessCounter,
            preparationTask: preparationTask
        )
        evictIfNeeded()
        return asset
    }

    func prefetch(_ urls: [URL]) {
        for url in urls.prefix(capacity) {
            _ = asset(for: url)
        }
    }

    private func evictIfNeeded() {
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries[oldest]?.preparationTask?.cancel()
            entries.removeValue(forKey: oldest)
        }
    }
}

struct NativeAdPlayerView: View {
    let decision: AdDecision
    let contentId: String
    let placement: String?
    var userId: String? = nil
    var breakId: String?
    var aspectRatio: CGFloat = 16 / 9
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var progressHorizontalInset: CGFloat = 0
    var fillVerticalContainer: Bool = false
    var onFullscreen: (() -> Void)? = nil
    var preservePlaybackOnDisappear = false
    var externalPlayer: AVPlayer? = nil
    var initialAdIndex = 0
    var isPresentationOnly = false
    var brandCardPlacement: NativeAdBrandCardPlacement? = nil
    var initialImpressionTracked = false
    var initialStartTracked = false
    var presentationElapsed: Double? = nil
    var adPolicy: EffectiveAdPolicy? = nil
    var adRemoval: AdRemovalOffer? = nil
    var overrideSkippable: Bool? = nil
    var overrideSkipAfterSec: Int? = nil
    var onImpression: (() -> Void)? = nil
    var onCanSkipChanged: ((Bool) -> Void)? = nil
    var onActivePlayerChanged: ((AVPlayer?) -> Void)? = nil
    var onActiveAdPresentationChanged: ((ActiveAdPresentation?) -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var onClick: (() -> Void)? = nil
    var onComplete: (() -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    var suppressTracking = false
    var observeExternalCompletion = true
    let onFinished: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage("playerMuted") private var isMuted = false
    @State private var player: AVPlayer?
    @State private var currentAdIndex = 0
    @State private var elapsed: Double = 0
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var failureObserver: NSObjectProtocol?
    @State private var itemStatusObservation: NSKeyValueObservation?
    @State private var playbackStartTask: Task<Void, Never>?
    @State private var playbackWatchdogTask: Task<Void, Never>?
    @State private var adStartupStartedAt: Date?
    @State private var firedEvents: Set<String> = []
    @State private var isPaused = false

    private var currentAd: AdCreative? {
        decision.ads.indices.contains(currentAdIndex) ? decision.ads[currentAdIndex] : nil
    }

    private var adDuration: Double {
        guard let duration = currentAd?.durationSec, duration > 0 else { return 0 }
        return duration
    }

    private var displayElapsed: Double {
        max(0, presentationElapsed ?? elapsed)
    }

    private var adProgress: Double {
        guard adDuration > 0 else { return 0 }
        return min(max(displayElapsed / adDuration, 0), 1)
    }

    private var remainingSeconds: Int? {
        guard adDuration > 0 else { return nil }
        return max(0, Int(ceil(adDuration - displayElapsed)))
    }

    private var resolvedDecisionPolicy: AdDecisionPolicy? {
        decision.policy ?? decision.adPolicy
    }

    private var isCurrentAdSkippable: Bool {
        overrideSkippable ?? currentAd?.skippable ?? adPolicy?.skippable ?? resolvedDecisionPolicy?.skippable ?? false
    }

    private var skipOffset: Double {
        let raw = overrideSkipAfterSec.map(Double.init)
            ?? currentAd?.skipOffsetSec
            ?? adPolicy?.skipAfterSec.map(Double.init)
            ?? resolvedDecisionPolicy?.skipAfterSec
            ?? 0
        if aspectRatio < 1, raw <= 0 {
            return 5
        }
        return max(0, raw)
    }

    private var skipCountdown: Int {
        max(0, Int(ceil(skipOffset - displayElapsed)))
    }

    private var canSkip: Bool {
        guard currentAd != nil, isCurrentAdSkippable else { return false }
        return displayElapsed >= skipOffset
    }

    private var hasSponsorCard: Bool {
        guard let ad = currentAd else { return false }
        if aspectRatio < 1 {
            return !(ad.brandLabel ?? "").isEmpty
                || !(ad.brandTitle ?? "").isEmpty
                || !(ad.ctaText ?? "").isEmpty
        }
        return clickThroughURL != nil
            || !(ad.brandLogoUrl ?? "").isEmpty
            || !(ad.brandLabel ?? "").isEmpty
            || !(ad.brandTitle ?? "").isEmpty
            || !(ad.brandDescription ?? "").isEmpty
            || !(ad.ctaText ?? "").isEmpty
    }

    private var resolvedBrandCardPlacement: NativeAdBrandCardPlacement {
        if let brandCardPlacement {
            return brandCardPlacement
        }
        return aspectRatio < 1 ? .playerOverlay : .belowPlayer
    }

    private var adRemovalURL: URL? {
        guard let salesUrl = (adRemoval ?? adPolicy?.adRemoval ?? decision.adRemoval)?.salesUrl else { return nil }
        return URL(string: salesUrl)
    }

    var body: some View {
        Group {
            if aspectRatio < 1 {
                verticalAdPlayer
            } else {
                horizontalAdPlayer
            }
        }
        .clipped()
        .task(id: currentAdIndex) {
            if isPresentationOnly {
                attachExternalPlayerIfNeeded()
            } else {
                setupCurrentAd()
            }
        }
        .onAppear {
            if isPresentationOnly {
                currentAdIndex = min(max(initialAdIndex, 0), max(decision.ads.count - 1, 0))
                attachExternalPlayerIfNeeded()
            }
        }
        .onChange(of: isMuted) { _, muted in
            player?.isMuted = muted
        }
        .onChange(of: canSkip) { _, canSkip in
            onCanSkipChanged?(canSkip)
        }
        .onDisappear {
            if preservePlaybackOnDisappear || ActiveAdFullscreenHandoff.isProtected(player) {
                if let player,
                   player.currentTime().seconds > 0.05 {
                    recordPlaybackStartIfNeeded()
                }
                publishActiveAdState(player)
                detachPlaybackObservers()
            } else if isPresentationOnly {
                cleanup()
            } else {
                cleanup()
            }
        }
    }

    private var horizontalAdPlayer: some View {
        VStack(spacing: 0) {
            adMediaSurface(showSponsorOverlay: hasSponsorCard && resolvedBrandCardPlacement == .playerOverlay)
                .frame(maxWidth: .infinity)
                .aspectRatio(aspectRatio, contentMode: .fit)

            if hasSponsorCard && resolvedBrandCardPlacement == .belowPlayer {
                bottomPanel
                    .padding(.horizontal, 12)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var verticalAdPlayer: some View {
        Group {
            if fillVerticalContainer {
                adMediaSurface(showSponsorOverlay: hasSponsorCard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                adMediaSurface(showSponsorOverlay: hasSponsorCard)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
    }

    private func adMediaSurface(showSponsorOverlay: Bool) -> some View {
        ZStack(alignment: .top) {
            Color.black

            if let player {
                WatchPlayerSurface(player: player)
            }

            clickThroughLayer

            LinearGradient(
                colors: [.black.opacity(0.50), .clear, .black.opacity(showSponsorOverlay ? 0.70 : 0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if isPaused {
                Button {
                    togglePause()
                } label: {
                    MediaverseIcon(name: "play", fallbackSystemName: "play.fill")
                        .frame(width: aspectRatio < 1 ? 26 : 30, height: aspectRatio < 1 ? 26 : 30)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.50), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.25), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .allowsHitTesting(aspectRatio >= 1)
            }

            VStack(spacing: 0) {
                topBar
                resumeCountdownChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.top, -8)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    skipControl
                }
                .padding(.trailing, 12)
                .padding(.bottom, showSponsorOverlay ? 10 : 14)

                if showSponsorOverlay {
                    bottomPanel
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }

                progressBar
                    .frame(height: 3)
                    .padding(.horizontal, progressHorizontalInset)
            }
            .padding(.top, aspectRatio < 1 ? topContentInset : 0)
            .padding(.bottom, aspectRatio < 1 ? bottomContentInset : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if aspectRatio < 1 {
                togglePause()
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var clickThroughLayer: some View {
        if aspectRatio >= 1, let url = clickThroughURL {
            Button {
                openAdURL(url)
            } label: {
                Color.white.opacity(0.001)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var resumeCountdownChip: some View {
        if let remainingSeconds,
           remainingSeconds <= 10,
           currentAdIndex == max(decision.ads.count - 1, 0) {
            Text("Video resumes in \(remainingSeconds) \(remainingSeconds == 1 ? "second" : "seconds")")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.70), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 1) }
        }
    }

    private var topBar: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 520
            topBarContent(compact: compact)
                .frame(width: proxy.size.width, height: 44)
        }
        .frame(height: 44)
    }

    private func topBarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 12) {
            HStack(spacing: 8) {
                Text("AD")
                    .font(.system(size: 11, weight: aspectRatio < 1 ? .black : .bold))
                    .tracking(aspectRatio < 1 ? 0.44 : 0)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.98, green: 0.80, blue: 0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(compact ? compactAdStatusText : adStatusText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()
            }
            .layoutPriority(1)

            Spacer(minLength: compact ? 4 : 8)

            if aspectRatio >= 1, let url = adRemovalURL {
                Button {
                    openURL(url)
                } label: {
                    Text("Remove ads →")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: 240)
                        .background(C.watch, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)
            }

            HStack(spacing: compact ? 6 : 8) {
                if aspectRatio >= 1 {
                    mediaControlButton(iconName: isPaused ? "play" : "pause", fallbackSystemName: isPaused ? "play.fill" : "pause.fill", size: 32, iconSize: 16) {
                        togglePause()
                    }
                }

                mediaControlButton(iconName: isMuted ? "mute" : "volume", fallbackSystemName: isMuted ? "speaker.slash" : "speaker.wave.2", size: aspectRatio < 1 ? 34 : 32, iconSize: 16) {
                    toggleMute()
                }

                if aspectRatio >= 1 {
                    mediaControlButton(
                        iconName: isPresentationOnly ? "fullscreen-exit" : "fullscreen",
                        fallbackSystemName: isPresentationOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        size: 32,
                        iconSize: 16
                    ) {
                        if let onFullscreen {
                            onFullscreen()
                        } else {
                            presentAdFullscreen()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, aspectRatio < 1 ? 12 : 8)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.20))
                Rectangle()
                    .fill(Color(red: 1, green: 0.83, blue: 0.12))
                    .frame(width: proxy.size.width * adProgress)
            }
        }
    }

    @ViewBuilder
    private var skipControl: some View {
        if canSkip {
            Button {
                trackEvent("skip")
                onSkip?()
                playNextOrFinish()
            } label: {
                Text("Skip ad ▸")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(aspectRatio < 1 ? .white : .black)
                    .padding(.horizontal, aspectRatio < 1 ? 14 : 12)
                    .padding(.vertical, 6)
                    .background(aspectRatio < 1 ? .black.opacity(0.70) : .white.opacity(0.90), in: RoundedRectangle(cornerRadius: aspectRatio < 1 ? 6 : 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: aspectRatio < 1 ? 6 : 4, style: .continuous)
                            .stroke(.white.opacity(aspectRatio < 1 ? 0.20 : 1), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        } else if isCurrentAdSkippable {
            Text("Skip in \(skipCountdown)s")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(aspectRatio < 1 ? 0.70 : 0.60))
                .monospacedDigit()
                .padding(.horizontal, aspectRatio < 1 ? 14 : 12)
                .padding(.vertical, 6)
                .background(.black.opacity(aspectRatio < 1 ? 0.50 : 0.40), in: RoundedRectangle(cornerRadius: aspectRatio < 1 ? 6 : 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: aspectRatio < 1 ? 6 : 4, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        if let ad = currentAd {
            let isShorts = aspectRatio < 1
            let cornerRadius: CGFloat = isShorts ? 14 : 12

            HStack(alignment: .center, spacing: 12) {
                if isShorts || !(ad.brandLogoUrl ?? "").isEmpty {
                    brandLogo(for: ad)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if !isShorts {
                            Text("AD")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.98, green: 0.80, blue: 0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        if let label = ad.brandLabel, !label.isEmpty {
                            Text(isShorts ? label : label.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(isShorts ? 0.60 : 0.50))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }

                    if let title = ad.brandTitle ?? ad.name, !title.isEmpty {
                        Text(title)
                            .font(.system(size: isShorts ? 14 : 15, weight: isShorts ? .bold : .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    if let description = ad.brandDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: isShorts ? 12 : 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if let url = clickThroughURL, let cta = ctaLabel(for: ad, isShorts: isShorts) {
                    Button {
                        openAdURL(url)
                    } label: {
                        Text(cta)
                            .font(.system(size: 13, weight: isShorts ? .bold : .semibold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .padding(.horizontal, isShorts ? 14 : 16)
                            .padding(.vertical, 8)
                            .background(isShorts ? Color(red: 0.98, green: 0.80, blue: 0.08) : C.watch, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(isShorts ? 12 : 0)
            .padding(.horizontal, isShorts ? 0 : 16)
            .padding(.vertical, isShorts ? 0 : 12)
            .background(isShorts ? Color.black.opacity(0.55) : Color(red: 0.071, green: 0.071, blue: 0.102), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(isShorts ? 0.15 : 0.08), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func brandLogo(for ad: AdCreative) -> some View {
        let isShorts = aspectRatio < 1
        let size: CGFloat = isShorts ? 40 : 48
        let radius: CGFloat = isShorts ? 10 : 8

        if let url = C.mediaURL(ad.brandLogoUrl) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: size, height: size)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                brandLogoFallback(cornerRadius: radius)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
        } else {
            brandLogoFallback(cornerRadius: radius)
                .frame(width: size, height: size)
        }
    }

    private func brandLogoFallback(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.14))
            .overlay {
                Text("Ad")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
    }

    private var clickThroughURL: URL? {
        guard let click = currentAd?.clickThroughUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: click),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private var adStatusText: String {
        let totalAds = max(decision.ads.count, 1)
        let countText = totalAds == 1 ? "Ad" : "Ad \(currentAdIndex + 1) of \(totalAds)"
        guard let remainingSeconds else { return countText }
        if aspectRatio < 1, placement == "shorts_first_view" {
            return "Featured · \(formatTime(Double(remainingSeconds)))"
        }
        return "\(countText) · \(formatTime(Double(remainingSeconds)))"
    }

    private var compactAdStatusText: String {
        adStatusText
    }

    private func ctaLabel(for ad: AdCreative, isShorts: Bool) -> String? {
        let text = ad.ctaText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isShorts {
            return text?.isEmpty == false ? text : nil
        }
        guard let text, !text.isEmpty else { return "Learn more →" }
        return "\(text) →"
    }

    private func mediaControlButton(iconName: String, fallbackSystemName: String, size: CGFloat = 58, iconSize: CGFloat = 24, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.42), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.24), lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
    }

    private func setupCurrentAd() {
        cleanup()
        guard let ad = currentAd, let url = C.mediaURL(ad.mediaUrl) else {
            if currentAd != nil {
                trackEvent("error")
            }
            playNextOrFinish()
            return
        }

        firedEvents = []
        elapsed = 0
        isPaused = false
        adStartupStartedAt = Date()
        // Keep the active creative on AVPlayer's direct URL path. Starting a
        // separate `AVURLAsset.load(.isPlayable)` task and immediately attaching
        // that same cached HLS asset to AVPlayer caused first-ad preparation to
        // remain in `.unknown` on device. The cache is still useful for later
        // creatives in the pod, which are prefetched below.
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.automaticallyWaitsToMinimizeStalling = false
        nextPlayer.isMuted = isMuted
        player = nextPlayer
        debugPlayback(
            "creative_item_created index=\(currentAdIndex) "
            + "host=\(url.host ?? "unknown") ext=\(url.pathExtension.lowercased())"
        )
        publishActiveAdState(nextPlayer)
        NativeAdMediaCache.shared.prefetch(
            decision.ads.dropFirst(currentAdIndex + 1).compactMap { C.mediaURL($0.mediaUrl) }
        )

        observer = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            elapsed = max(0, time.seconds)
            fireQuartileEventsIfNeeded()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            guard !ActiveAdFullscreenHandoff.isProtected(nextPlayer) else { return }
            trackEvent("complete")
            if currentAdIndex + 1 >= decision.ads.count {
                onComplete?()
            }
            playNextOrFinish()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            guard !ActiveAdFullscreenHandoff.isProtected(nextPlayer) else { return }
            trackEvent("error")
            playNextOrFinish()
        }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            Task { @MainActor in
                guard player === nextPlayer else { return }
                switch observedItem.status {
                case .readyToPlay:
                    debugPlayback("creative_ready_to_play index=\(currentAdIndex)")
                case .failed:
                    debugPlayback(
                        "creative_failed index=\(currentAdIndex) "
                        + "error=\(observedItem.error?.localizedDescription ?? "unknown")"
                    )
                case .unknown:
                    debugPlayback("creative_status_unknown index=\(currentAdIndex)")
                @unknown default:
                    debugPlayback("creative_status_unrecognized index=\(currentAdIndex)")
                }
            }
        }

        nextPlayer.play()
        schedulePlaybackStartTracking(for: nextPlayer)
        schedulePlaybackWatchdog(for: nextPlayer)
        onCanSkipChanged?(canSkip)
    }

    private func detachPlaybackObservers() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        if let observer {
            player?.removeTimeObserver(observer)
            self.observer = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    private func cleanup() {
        detachPlaybackObservers()
        player?.pause()
        player = nil
        adStartupStartedAt = nil
        onActivePlayerChanged?(nil)
        onActiveAdPresentationChanged?(nil)
    }

    private func detachPresentationObserver() {
        if let observer {
            player?.removeTimeObserver(observer)
            self.observer = nil
        }
        player = nil
    }

    private func publishActiveAdState(_ activePlayer: AVPlayer?) {
        onActivePlayerChanged?(activePlayer)
        guard activePlayer != nil else {
            onActiveAdPresentationChanged?(nil)
            return
        }
        onActiveAdPresentationChanged?(
            ActiveAdPresentation(
                decision: decision,
                contentId: contentId,
                placement: placement,
                breakId: breakId,
                userId: userId,
                currentAdIndex: currentAdIndex,
                hasTrackedImpression: firedEvents.contains("impression"),
                hasTrackedStart: firedEvents.contains("start"),
                adPolicy: adPolicy,
                adRemoval: adRemoval,
                overrideSkippable: overrideSkippable,
                overrideSkipAfterSec: overrideSkipAfterSec,
                onSkip: {
                    trackEvent("skip")
                    playNextOrFinish()
                },
                onFinish: {
                    playNextOrFinish()
                }
            )
        )
    }

    private func attachExternalPlayerIfNeeded() {
        guard let externalPlayer else { return }
        if initialImpressionTracked {
            firedEvents.insert("impression")
        }
        if initialStartTracked {
            firedEvents.insert("start")
        }
        if player !== externalPlayer {
            detachPresentationObserver()
            player = externalPlayer
            externalPlayer.isMuted = isMuted
            observer = externalPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { time in
                elapsed = max(0, time.seconds)
            }
            if observeExternalCompletion, let item = externalPlayer.currentItem {
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    trackEvent("complete")
                    cleanup()
                    onFinished()
                }
                failureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    trackEvent("error")
                    cleanup()
                    onFinished()
                }
            }
        }
        isPaused = externalPlayer.timeControlStatus == .paused
        externalPlayer.play()
        if !suppressTracking {
            schedulePlaybackStartTracking(for: externalPlayer)
            schedulePlaybackWatchdog(for: externalPlayer)
        }
    }

    private func schedulePlaybackStartTracking(for player: AVPlayer) {
        playbackStartTask?.cancel()
        playbackStartTask = Task { @MainActor in
            while !Task.isCancelled {
                if player.currentTime().seconds > 0.05 {
                    recordPlaybackStartIfNeeded()
                    playbackStartTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func recordPlaybackStartIfNeeded() {
        let shouldNotifyImpression = !firedEvents.contains("impression")
        if shouldNotifyImpression {
            let elapsedMs = adStartupStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
            debugPlayback("creative_first_progress index=\(currentAdIndex) elapsedMs=\(elapsedMs)")
        }
        trackEvent("impression")
        trackEvent("start")
        if shouldNotifyImpression {
            onImpression?()
        }
    }

    private func schedulePlaybackWatchdog(for watchedPlayer: AVPlayer) {
        playbackWatchdogTask?.cancel()
        let watchedAdIndex = currentAdIndex
        playbackWatchdogTask = Task { @MainActor in
            var lastProgress = max(0, watchedPlayer.currentTime().seconds)
            var lastProgressAt = Date()
            var activeStartupElapsed: TimeInterval = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled,
                      player === watchedPlayer,
                      currentAdIndex == watchedAdIndex else { return }

                if UIApplication.shared.applicationState != .active || isPaused {
                    lastProgress = max(0, watchedPlayer.currentTime().seconds)
                    lastProgressAt = Date()
                    continue
                }

                let currentProgress = max(0, watchedPlayer.currentTime().seconds)
                let hasStarted = firedEvents.contains("start") || currentProgress > 0.05
                if !hasStarted {
                    activeStartupElapsed += 0.5
                    if activeStartupElapsed >= 7 {
                        let item = watchedPlayer.currentItem
                        debugPlayback(
                            "creative_start_timeout index=\(watchedAdIndex) "
                            + "status=\(itemStatusName(item?.status)) "
                            + "waiting=\(waitingReasonName(watchedPlayer.reasonForWaitingToPlay)) "
                            + "error=\(item?.error?.localizedDescription ?? watchedPlayer.error?.localizedDescription ?? "none")"
                        )
                        trackEvent("error")
                        playbackWatchdogTask = nil
                        playNextOrFinish()
                        return
                    }
                }
                if currentProgress > lastProgress + 0.1 {
                    lastProgress = currentProgress
                    lastProgressAt = Date()
                    continue
                }

                let timeout: TimeInterval = 20
                guard Date().timeIntervalSince(lastProgressAt) >= timeout else { continue }

                debugPlayback(
                    "creative_stall_timeout index=\(watchedAdIndex) "
                    + "status=\(itemStatusName(watchedPlayer.currentItem?.status)) "
                    + "waiting=\(waitingReasonName(watchedPlayer.reasonForWaitingToPlay))"
                )
                trackEvent("error")
                playbackWatchdogTask = nil
                playNextOrFinish()
                return
            }
        }
    }

    private func itemStatusName(_ status: AVPlayerItem.Status?) -> String {
        switch status {
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        case .unknown: return "unknown"
        case nil: return "missing"
        @unknown default: return "unrecognized"
        }
    }

    private func waitingReasonName(_ reason: AVPlayer.WaitingReason?) -> String {
        reason?.rawValue ?? "none"
    }

    private func debugPlayback(_ message: String) {
        #if DEBUG
        print("[Ads][Playback] \(message)")
        #endif
    }

    private func playNextOrFinish() {
        if isPresentationOnly {
            cleanup()
            onFinished()
            return
        }

        cleanup()
        if currentAdIndex + 1 < decision.ads.count {
            currentAdIndex += 1
        } else {
            onFinished()
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        if isMuted {
            trackEvent("mute")
        }
    }

    private func togglePause() {
        guard let player else { return }
        if isPaused {
            player.play()
            trackEvent("resume")
        } else {
            player.pause()
            trackEvent("pause")
        }
        isPaused.toggle()
    }

    private func openAdURL(_ url: URL) {
        trackEvent("click")
        trackEvent("ctaClick")
        onClick?()
        openURL(url)
    }

    private func presentAdFullscreen() {
        player?.play()
    }

    private func fireQuartileEventsIfNeeded() {
        guard adDuration > 0 else { return }
        let ratio = elapsed / adDuration
        let events: [(String, Double)] = [
            ("firstQuartile", 0.25),
            ("midpoint", 0.5),
            ("thirdQuartile", 0.75),
        ]

        for (event, threshold) in events where ratio >= threshold && !firedEvents.contains(event) {
            trackEvent(event)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private func trackEvent(_ event: String) {
        guard let ad = currentAd else { return }
        let dedupedEvents: Set<String> = [
            "impression",
            "start",
            "firstQuartile",
            "midpoint",
            "thirdQuartile",
            "complete"
        ]
        if dedupedEvents.contains(event) {
            guard !firedEvents.contains(event) else { return }
            firedEvents.insert(event)
        }
        guard !suppressTracking else { return }
        let decisionId = decision.decisionId
        let contentId = contentId
        let placement = placement
        let breakId = breakId
        let userId = userId

        Task {
            await AdServerClient.shared.track(
                event: event,
                ad: ad,
                decisionId: decisionId,
                contentId: contentId,
                placement: placement,
                breakId: breakId,
                userId: userId
            )
        }
    }
}
