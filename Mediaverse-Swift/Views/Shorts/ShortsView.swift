import SwiftUI
import AVKit

// MARK: - Feed enum

enum ShortsFeed: String, CaseIterable {
    case forYou    = "recommended"
    case following = "following"
    var label: String { self == .forYou ? "For You" : "Following" }
}

private enum ShortsFeedItem: Identifiable {
    case short(index: Int, short: Short)
    case ad(id: String, afterIndex: Int, contentId: String, placement: String, adConfig: PlatformShortsAdsConfig, policy: EffectiveAdPolicy, decision: AdDecision)
    case curationSlot(index: Int, listing: AssembledListing)

    var id: String {
        switch self {
        case .short(_, let short): return short.id
        case .ad(let id, _, _, _, _, _, _): return id
        case .curationSlot(let index, let listing): return "curation-\(index)-\(listing.id)"
        }
    }
}

private struct ShortsAdCandidate {
    let id: String
    let afterIndex: Int
    let contentId: String
    let placement: String
    let adConfig: PlatformShortsAdsConfig
    let adPolicy: EffectiveAdPolicy
}

private struct ShortsAdRequestGuard {
    let identityGeneration: UUID
    let feedGeneration: UUID
    let configGeneration: UUID
    let feedSeed: String
    let shortsIDs: [String]
}

private enum ShortsFeedAssembler {
    static func makeItems(
        shorts: [Short],
        nextCursor: String?,
        curationListings: [AssembledListing],
        shortsAdConfig: PlatformShortsAdsConfig,
        skippedAdItemIDs: Set<String>,
        filledAdDecisions: [String: AdDecision],
        filledAdPolicies: [String: EffectiveAdPolicy],
        shouldRequestAd: (Int, String, PlatformShortsAdsConfig) -> Bool
    ) -> [ShortsFeedItem] {
        var renderedItems = [ShortsFeedItem]()
        var injectedEventIndex = 0
        let events = curationSlotEvents(from: curationListings)

        func appendNextCurationSlot() {
            guard injectedEventIndex < events.count else { return }
            let event = events[injectedEventIndex]
            injectedEventIndex += 1
            renderedItems.append(.curationSlot(index: event.index, listing: event.listing))
        }

        func appendDueCurationSlots(afterShortCount shortCount: Int) {
            while injectedEventIndex < events.count,
                  events[injectedEventIndex].afterShortCount <= shortCount {
                appendNextCurationSlot()
            }
        }

        for (index, short) in shorts.enumerated() {
            let shortItem = ShortsFeedItem.short(index: index, short: short)
            let candidate = adCandidate(at: index, short: short, shortsAdConfig: shortsAdConfig)

            renderedItems.append(shortItem)
            if shouldRequestAd(index, candidate.placement, candidate.adConfig),
               !skippedAdItemIDs.contains(candidate.id),
               let decision = filledAdDecisions[candidate.id],
               let policy = filledAdPolicies[candidate.id] {
                renderedItems.append(
                    .ad(
                        id: candidate.id,
                        afterIndex: index,
                        contentId: short.id,
                        placement: candidate.placement,
                        adConfig: candidate.adConfig,
                        policy: policy,
                        decision: decision
                    )
                )
            }

            appendDueCurationSlots(afterShortCount: index + 1)
        }

        if nextCursor == nil {
            while injectedEventIndex < events.count {
                appendNextCurationSlot()
            }
        }

        return renderedItems
    }

    static func adCandidates(
        shorts: [Short],
        shortsAdConfig: PlatformShortsAdsConfig,
        afterShortIndex currentShortIndex: Int,
        lookahead: Int
    ) -> [ShortsAdCandidate] {
        let lowerBound = max(0, currentShortIndex)
        let upperBound = min(shorts.count - 1, currentShortIndex + lookahead)
        guard lowerBound <= upperBound else { return [] }

        return (lowerBound...upperBound).map { index in
            adCandidate(at: index, short: shorts[index], shortsAdConfig: shortsAdConfig)
        }
    }

    private struct CurationSlotEvent {
        let index: Int
        let afterShortCount: Int
        let listingOrder: Int
        let slotOrder: Int
        let listing: AssembledListing
    }

    private static func curationSlotEvents(from listings: [AssembledListing]) -> [CurationSlotEvent] {
        var events = [CurationSlotEvent]()

        for (listingOrder, listing) in listings.enumerated() {
            let everyN = max(1, listing.feedConfig?.mobileEvery ?? 5)
            let slotCap = max(0, listing.feedConfig?.mobileCount ?? 3)
            let slots = (listing.feedSlots ?? [])
                .prefix(slotCap)
                .filter { !$0.items.isEmpty }

            for (slotOrder, slot) in slots.enumerated() {
                events.append(
                    CurationSlotEvent(
                        index: events.count,
                        afterShortCount: everyN * (slotOrder + 1),
                        listingOrder: listingOrder,
                        slotOrder: slotOrder,
                        listing: slot
                    )
                )
            }
        }

        return events.sorted {
            if $0.afterShortCount != $1.afterShortCount {
                return $0.afterShortCount < $1.afterShortCount
            }
            if $0.listingOrder != $1.listingOrder {
                return $0.listingOrder < $1.listingOrder
            }
            return $0.slotOrder < $1.slotOrder
        }
    }

    private static func adCandidate(
        at index: Int,
        short: Short,
        shortsAdConfig: PlatformShortsAdsConfig
    ) -> ShortsAdCandidate {
        let placement = shortsAdPlacement(at: index)
        // Ad eligibility is entitlement-sensitive and must come from the backend.
        // If the policy is absent, fail closed instead of potentially showing ads
        // to a user whose subscription removes them.
        let policy = short.adPolicy ?? .disabled(reason: "policy_unavailable")
        let adConfig = policy.applying(to: shortsAdConfig)
        return ShortsAdCandidate(
            id: shortsAdItemID(placement: placement, shortID: short.id),
            afterIndex: index,
            contentId: short.id,
            placement: placement,
            adConfig: adConfig,
            adPolicy: policy
        )
    }

    private static func shortsAdItemID(placement: String, shortID: String) -> String {
        "shorts-ad-\(placement)-after-\(shortID)"
    }

    private static func shortsAdPlacement(at index: Int) -> String {
        index == 0 ? "shorts_first_view" : "shorts_feed"
    }
}

@MainActor
final class ShortNavigationCache {
    static let shared = ShortNavigationCache()

    private var seededShort: Short?
    private var seededShortIds: [String]?

    private init() {}

    func seed(_ short: Short, ids: [String]? = nil) {
        seededShort = short
        seededShortIds = ids
    }

    func seedIDs(_ ids: [String]) {
        seededShort = nil
        seededShortIds = ids
    }

    func take(id: String?) -> Short? {
        guard let id, seededShort?.id == id else { return nil }
        let short = seededShort
        seededShort = nil
        seededShortIds = nil
        return short
    }

    func takeIDs(containing id: String?) -> [String]? {
        guard let id, let ids = seededShortIds, ids.contains(id) else { return nil }
        seededShort = nil
        seededShortIds = nil
        return ids
    }
}

struct PreparedInitialShortsFeed {
    let seed: String
    let response: ShortsResponse
}

enum ShortsAdSchedule {
    static func isEligible(
        afterShortAt index: Int,
        placement: String,
        config: PlatformShortsAdsConfig
    ) -> Bool {
        guard index >= 0, config.enabled, config.placementConfig(for: placement).enabled else {
            return false
        }
        if placement == "shorts_first_view" {
            return index == 0
        }
        guard placement == "shorts_feed",
              config.cadenceKind.lowercased() == "count",
              config.cadenceValue > 0 else {
            return false
        }
        let viewedCount = index + 1
        let firstBreak = max(1, config.firstAfter)
        guard viewedCount >= firstBreak else { return false }
        return (viewedCount - firstBreak).isMultiple(of: config.cadenceValue)
    }
}

enum ShortsServerAdSchedule {
    static func isEligible(shortIndex index: Int, policy: EffectiveAdPolicy) -> Bool {
        guard policy.adsEnabled,
              policy.cadenceKind?.lowercased() == "count",
              let cadence = policy.cadenceValue,
              cadence > 0 else {
            return false
        }
        // A preroll on item N occupies the feed boundary after N prior items.
        let firstBreak = max(1, policy.firstAfter ?? cadence)
        guard index >= firstBreak else { return false }
        return (index - firstBreak).isMultiple(of: cadence)
    }
}

enum ShortsAdLayoutClearance {
    static func top(safeAreaTop: CGFloat) -> CGFloat {
        max(8, safeAreaTop + 8)
    }

    static func bottom(safeAreaBottom: CGFloat, controlClearance: CGFloat) -> CGFloat {
        max(12, safeAreaBottom + controlClearance)
    }
}

enum ShortsFeedCacheScope {
    static func identityScope(userId: String?) -> String {
        guard let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty else {
            return "anonymous"
        }
        return "user-\(stableDigest(userId))"
    }

    static func initialFeedKey(userId: String?, context: String?) -> String {
        let contextValue = context?.nilIfEmpty ?? "default"
        return "shorts.initial.recommended.v2.\(identityScope(userId: userId)).context-\(stableDigest(contextValue))"
    }

    private static func stableDigest(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte))
                .multipliedReportingOverflow(by: 1_099_511_628_211)
                .partialValue
        }
        return String(hash, radix: 16)
    }
}

struct ShortsFeedReconciliation {
    let shorts: [Short]
    let nextCursor: String?
    let shouldApply: Bool

    static func reconcile(
        visible: [Short],
        fresh: [Short],
        currentCursor: String?,
        freshCursor: String?
    ) -> ShortsFeedReconciliation {
        let freshByID = fresh.reduce(into: [String: Short]()) { result, short in
            result[short.id] = short
        }
        let visibleIDs = Set(visible.map(\.id))
        let overlapCount = fresh.reduce(into: 0) { count, short in
            if visibleIDs.contains(short.id) { count += 1 }
        }
        let meaningfulOverlap = overlapCount >= min(2, min(visible.count, fresh.count))
        guard meaningfulOverlap else {
            return ShortsFeedReconciliation(
                shorts: visible,
                nextCursor: currentCursor,
                shouldApply: false
            )
        }

        var reconciled = visible.map { freshByID[$0.id] ?? $0 }
        var seen = visibleIDs
        reconciled.append(contentsOf: fresh.filter { seen.insert($0.id).inserted })
        return ShortsFeedReconciliation(
            shorts: reconciled,
            nextCursor: freshCursor,
            shouldApply: true
        )
    }
}

private extension AssembledPage {
    var shortsFeedListings: [AssembledListing] {
        activeListings.filter { $0.normalizedTemplateType == "shorts_feed" }
    }
}

private extension AssembledListing {
    var shortIDs: [String] {
        items
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" }
            .map(\.entityId)
    }
}

private enum ShortsAdFrequencyStore {
    static func canShow(placement: String, userId: String?, cap: Int?) -> Bool {
        // Frequency/session caps are enforced by the server. A second persistent
        // client cap can become stale and suppress otherwise eligible inventory.
        true
    }

    static func record(placement: String, userId: String?, cap: Int?) {
        guard let cap, cap > 0 else { return }
        let key = storageKey(for: placement, userId: userId)
        let nextCount = min(cap, UserDefaults.standard.integer(forKey: key) + 1)
        UserDefaults.standard.set(nextCount, forKey: key)
    }

    private static func storageKey(for placement: String, userId: String?) -> String {
        let date = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = "\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)"
        let identityScope = ShortsFeedCacheScope.identityScope(userId: userId)
        return "westreem.shortsAdFrequency.\(day).\(identityScope).\(placement)"
    }
}

@MainActor
final class ShortsPlaybackManager: ObservableObject {
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var serverAdPresentations: [String: ShortsServerAdPresentation] = [:]

    struct RootFeedSnapshot {
        let cacheScope: String
        let feed: ShortsFeed
        let shorts: [Short]
        let currentID: String?
        let nextCursor: String?
        let feedSessionSeed: String
        let feedSessionIDs: [String]?
        let shortsFeedListings: [AssembledListing]
        let skippedShortsAdItemIds: Set<String>
    }

    private let backwardWarmCount = 2
    private let forwardWarmCount = 6
    private let initialWarmCount = 7
    private let metricsNamespace = "shorts.preview"
    private var assetCache: [String: AVURLAsset] = [:]
    private var assetSourceURLs: [String: URL] = [:]
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var initialPrewarmTask: Task<Void, Never>?
    private var initialPrewarmPayload: PreparedInitialShortsFeed?
    private var initialPrewarmScope: String?
    private var failedWarmIDs: [String: Date] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var endObservers: [String: NSObjectProtocol] = [:]
    private var failureObservers: [String: NSObjectProtocol] = [:]
    private var statusObservers: [String: NSKeyValueObservation] = [:]
    private var fallbackSourceURLs: [String: URL] = [:]
    // One stable session for the whole Shorts feed. A per-Short session resets
    // server pacing/caps and can produce a preroll on every swipe.
    private var playbackSessionID = UUID().uuidString
    private var serverAdEligibleShortIDs = Set<String>()
    private var serverAdContexts: [String: SGAIPlaybackContext] = [:]
    private var serverAdPolicies: [String: EffectiveAdPolicy] = [:]
    private var serverAdAssets: [String: [SGAIAsset]] = [:]
    private var interstitialMonitors: [String: AVPlayerInterstitialEventMonitor] = [:]
    private var interstitialObservers: [String: [NSObjectProtocol]] = [:]
    private var interstitialTimeObservers: [String: Any] = [:]
    private var firedServerAdEvents: [String: Set<String>] = [:]
    private var shortsAdsEnabled = false
    private var activeID: String?
    private var rootFeedSnapshot: RootFeedSnapshot?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trimWarmStateForMemoryPressure()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        initialPrewarmTask?.cancel()
        warmTasks.values.forEach { $0.cancel() }
    }

    func player(for id: String) -> AVPlayer? {
        players[id]
    }

    func setShortsAdsEnabled(_ enabled: Bool) {
        shortsAdsEnabled = enabled
    }

    func prewarmInitialFeed(isMuted: Bool, userId: String?, context: String?) {
        guard activeID == nil else { return }
        players.values.forEach { $0.isMuted = isMuted }
        pruneFailedWarmIDs()
        let cacheKey = ShortsFeedCacheScope.initialFeedKey(userId: userId, context: context)
        if initialPrewarmScope != cacheKey {
            initialPrewarmTask?.cancel()
            initialPrewarmTask = nil
            initialPrewarmPayload = nil
            initialPrewarmScope = cacheKey
        }
        guard initialPrewarmPayload == nil, initialPrewarmTask == nil else { return }

        initialPrewarmTask = Task { [weak self] in
            let seed = UUID().uuidString
            do {
                let response = try await APIClient.shared.fetchShorts(
                    feed: ShortsFeed.forYou.rawValue,
                    limit: 10,
                    seed: seed,
                    forceRefresh: true
                )
                self?.storeInitialPrewarm(
                    seed: seed,
                    response: response,
                    isMuted: isMuted,
                    cacheKey: cacheKey,
                    userId: userId
                )
            } catch {
                self?.clearInitialPrewarmTask(cacheKey: cacheKey)
            }
        }
    }

    func takePreparedInitialFeedIfAvailable(
        isMuted: Bool,
        userId: String?,
        context: String?
    ) async -> PreparedInitialShortsFeed? {
        await preparedInitialFeedPayload(isMuted: isMuted, userId: userId, context: context)
    }

    func prepareRootInitialFeedSnapshot(isMuted: Bool, userId: String?, context: String?) async {
        guard activeID == nil, rootFeedSnapshot == nil else { return }
        guard let payload = await preparedInitialFeedPayload(
            isMuted: isMuted,
            userId: userId,
            context: context
        ),
              !payload.response.shorts.isEmpty else { return }
        let currentID = payload.response.shorts.first { C.mediaURL($0.videoUrl) != nil }?.id ?? payload.response.shorts.first?.id
        rootFeedSnapshot = RootFeedSnapshot(
            cacheScope: ShortsFeedCacheScope.initialFeedKey(userId: userId, context: context),
            feed: .forYou,
            shorts: payload.response.shorts,
            currentID: currentID,
            nextCursor: payload.response.nextCursor,
            feedSessionSeed: payload.seed,
            feedSessionIDs: nil,
            shortsFeedListings: [],
            skippedShortsAdItemIds: []
        )
    }

    private func preparedInitialFeedPayload(
        isMuted: Bool,
        userId: String?,
        context: String?
    ) async -> PreparedInitialShortsFeed? {
        prewarmInitialFeed(isMuted: isMuted, userId: userId, context: context)
        if let payload = takeReadyInitialFeed() {
            return payload
        }

        if let initialPrewarmTask {
            await initialPrewarmTask.value
        }
        return takeReadyInitialFeed()
    }

    private func takeReadyInitialFeed() -> PreparedInitialShortsFeed? {
        let payload = initialPrewarmPayload
        initialPrewarmPayload = nil
        return payload
    }

    fileprivate func configure(feedItems: [ShortsFeedItem], currentID: String?, isMuted: Bool, userId: String?) {
        var shortsByID = [String: Short]()
        feedItems.forEach { item in
            if case .short(let index, let short) = item {
                shortsByID[short.id] = short
                if let policy = short.adPolicy,
                   ShortsServerAdSchedule.isEligible(shortIndex: index, policy: policy) {
                    serverAdEligibleShortIDs.insert(short.id)
                } else {
                    serverAdEligibleShortIDs.remove(short.id)
                }
            }
        }

        let preparedIDs = preparedShortIDs(feedItems: feedItems, currentID: currentID)
        preparedIDs.compactMap { shortsByID[$0] }.forEach {
            prepare($0, isMuted: isMuted, userId: userId)
        }

        Set(players.keys).subtracting(preparedIDs).forEach(releasePlayer)
        Set(assetCache.keys).subtracting(preparedIDs).forEach(releaseWarmState)
        players.values.forEach { $0.isMuted = isMuted }

        if let currentID, shortsByID[currentID] != nil {
            activate(currentID)
        } else {
            pauseActive()
        }
    }

    func prepare(_ short: Short, isMuted: Bool, userId: String? = nil) {
        guard let sourceURL = C.mediaURL(short.videoUrl), !hasRecentWarmFailure(for: short.id) else { return }
        let url = playbackURL(for: short, sourceURL: sourceURL, userId: userId)
        if url != sourceURL {
            fallbackSourceURLs[short.id] = sourceURL
        } else {
            fallbackSourceURLs[short.id] = nil
        }
        let asset = cachedAsset(for: short.id, url: url)
        warmAsset(asset, id: short.id)
        guard players[short.id] == nil else { return }
        installPlayer(asset: asset, id: short.id, isMuted: isMuted)
    }

    private func installPlayer(asset: AVURLAsset, id: String, isMuted: Bool) {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        player.volume = 1
        player.actionAtItemEnd = .none
        var updatedPlayers = players
        updatedPlayers[id] = player
        players = updatedPlayers
        CacheMetrics.shared.recordStore(metricsNamespace)
        installInterstitialLifecycleIfNeeded(player: player, id: id)

        endObservers[id] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player, weak self] _ in
            Task { @MainActor in
                guard let player, let self else { return }
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        if self.activeID == id {
                            player.playImmediately(atRate: 1)
                        }
                    }
                }
            }
        }

        failureObservers[id] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fallbackToDirectPlaybackIfAvailable(id: id, isMuted: isMuted)
            }
        }
        statusObservers[id] = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                self?.fallbackToDirectPlaybackIfAvailable(id: id, isMuted: isMuted)
            }
        }
    }

    private func fallbackToDirectPlaybackIfAvailable(id: String, isMuted: Bool) {
        guard let sourceURL = fallbackSourceURLs.removeValue(forKey: id) else { return }
        let shouldResume = activeID == id
        releasePlayer(id)
        releaseWarmState(id)
        serverAdContexts[id] = nil
        serverAdPolicies[id] = nil

        let asset = AVURLAsset(url: sourceURL)
        assetCache[id] = asset
        assetSourceURLs[id] = sourceURL
        warmAsset(asset, id: id)
        installPlayer(asset: asset, id: id, isMuted: isMuted)
        if shouldResume {
            activeID = id
            players[id]?.playImmediately(atRate: 1)
        }
    }

    func activate(_ id: String) {
        activeID = id
        for (playerID, player) in players where playerID != id {
            player.pause()
        }

        guard let player = players[id] else { return }
        CacheMetrics.shared.recordHit(metricsNamespace)
        if isAtEnd(player) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.playImmediately(atRate: 1)
    }

    func pauseActive() {
        activeID = nil
        players.values.forEach { $0.pause() }
    }

    func pausePlayback() {
        players.values.forEach { $0.pause() }
    }

    func setMuted(_ isMuted: Bool) {
        players.values.forEach { $0.isMuted = isMuted }
    }

    func release(_ id: String) {
        if activeID == id {
            activeID = nil
        }
        releasePlayer(id)
        releaseWarmState(id)
    }

    func reset() {
        activeID = nil
        Array(players.keys).forEach(releasePlayer)
        Array(assetCache.keys).forEach(releaseWarmState)
        playbackSessionID = UUID().uuidString
        serverAdEligibleShortIDs.removeAll()
        serverAdContexts.removeAll()
        serverAdPolicies.removeAll()
        serverAdAssets.removeAll()
        firedServerAdEvents.removeAll()
    }

    func resetForIdentityChange() {
        initialPrewarmTask?.cancel()
        initialPrewarmTask = nil
        initialPrewarmPayload = nil
        initialPrewarmScope = nil
        rootFeedSnapshot = nil
        reset()
    }

    func saveRootFeedSnapshot(_ snapshot: RootFeedSnapshot) {
        rootFeedSnapshot = snapshot
    }

    func restoreRootFeedSnapshot(userId: String?, context: String?) -> RootFeedSnapshot? {
        let expectedScope = ShortsFeedCacheScope.initialFeedKey(userId: userId, context: context)
        guard rootFeedSnapshot?.cacheScope == expectedScope else {
            rootFeedSnapshot = nil
            return nil
        }
        return rootFeedSnapshot
    }

    fileprivate func clearRootFeedSnapshot() {
        rootFeedSnapshot = nil
    }

    private func storeInitialPrewarm(
        seed: String,
        response: ShortsResponse,
        isMuted: Bool,
        cacheKey: String,
        userId: String?
    ) {
        guard initialPrewarmScope == cacheKey else { return }
        initialPrewarmPayload = PreparedInitialShortsFeed(
            seed: seed,
            response: response
        )
        initialPrewarmTask = nil
        let feedItems = response.shorts.enumerated().map { index, short in
            ShortsFeedItem.short(index: index, short: short)
        }
        let preparedIDs = preparedShortIDs(feedItems: feedItems, currentID: nil)
        preparedIDs.compactMap { id in response.shorts.first { $0.id == id } }
            .forEach { prepare($0, isMuted: isMuted, userId: userId) }
        players.values.forEach {
            $0.isMuted = isMuted
            $0.pause()
        }
    }

    private func clearInitialPrewarmTask(cacheKey: String) {
        guard initialPrewarmScope == cacheKey else { return }
        initialPrewarmTask = nil
    }

    private func cachedAsset(for id: String, url: URL) -> AVURLAsset {
        if let asset = assetCache[id], assetSourceURLs[id] == url {
            CacheMetrics.shared.recordHit(metricsNamespace)
            return asset
        }
        if assetCache[id] != nil {
            releasePlayer(id)
            releaseWarmState(id)
        }
        CacheMetrics.shared.recordMiss(metricsNamespace)
        let asset = AVURLAsset(url: url)
        assetCache[id] = asset
        assetSourceURLs[id] = url
        CacheMetrics.shared.recordStore(metricsNamespace)
        return asset
    }

    private func playbackURL(for short: Short, sourceURL: URL, userId: String?) -> URL {
        guard let policy = short.adPolicy else {
            serverAdContexts[short.id] = nil
            serverAdPolicies[short.id] = nil
            return sourceURL
        }
        let plan = ShortsAdDeliveryPlan.resolve(policy: policy, mediaURL: sourceURL)
        guard plan.inStream == .sgai || plan.inStream == .ssai else {
            serverAdContexts[short.id] = nil
            serverAdPolicies[short.id] = nil
            return sourceURL
        }
        guard serverAdEligibleShortIDs.contains(short.id) else {
            serverAdContexts[short.id] = nil
            serverAdPolicies[short.id] = nil
            return sourceURL
        }

        let context = SGAIPlaybackContext(
            contentId: short.id,
            contentType: "short",
            sessionId: playbackSessionID,
            userId: userId,
            deviceId: shortsAdDeviceId,
            country: nil,
            orientation: "VERTICAL",
            entry: PlaybackEntryContext(
                surface: .shortsFeed,
                mode: .userPlay,
                contentStartSec: 0,
                previewSessionId: nil
            )
        )
        serverAdContexts[short.id] = context
        serverAdPolicies[short.id] = policy
        return SGAIPlaybackURLBuilder.makeURL(
            streamMaster: sourceURL,
            mode: plan.inStream,
            context: context,
            skippable: policy.skippable,
            maxDurationSec: policy.maxAdDurationSec
                ?? policy.maxDurationSec
                ?? policy.pods?.maxAdDurationSec
        )
    }

    private var shortsAdDeviceId: String {
        AdPlaybackDevice.stableId
    }

    func skipServerAd(for id: String) {
        guard serverAdPresentations[id]?.canSkip == true,
              let monitor = interstitialMonitors[id] else { return }
        trackServerAdEvent("skip", id: id)
        monitor.interstitialPlayer.advanceToNextItem()
    }

    func openServerAd(for id: String) {
        guard let url = serverAdPresentations[id]?.clickThroughURL else { return }
        trackServerAdEvent("click", id: id)
        UIApplication.shared.open(url, options: [:])
    }

    func toggleServerAdPause(for id: String) {
        guard let player = interstitialMonitors[id]?.interstitialPlayer else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func serverAdIsPaused(for id: String) -> Bool {
        interstitialMonitors[id]?.interstitialPlayer.timeControlStatus == .paused
    }

    func setServerAdMuted(_ muted: Bool, for id: String) {
        interstitialMonitors[id]?.interstitialPlayer.isMuted = muted
        players[id]?.isMuted = muted
    }

    private func installInterstitialLifecycleIfNeeded(player: AVPlayer, id: String) {
        guard let context = serverAdContexts[id] else { return }
        removeInterstitialLifecycle(for: id)

        let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: player)
        interstitialMonitors[id] = monitor
        let center = NotificationCenter.default
        interstitialObservers[id] = [
            center.addObserver(
                forName: AVPlayerInterstitialEventMonitor.currentEventDidChangeNotification,
                object: monitor,
                queue: .main
            ) { [weak self, weak monitor] _ in
                Task { @MainActor in
                    self?.handleInterstitialChange(id: id, monitor: monitor, context: context)
                }
            },
            center.addObserver(
                forName: AVPlayerInterstitialEventMonitor.assetListResponseStatusDidChangeNotification,
                object: monitor,
                queue: .main
            ) { [weak self] notification in
                guard notification.userInfo?[AVPlayerInterstitialEventMonitor.assetListResponseStatusDidChangeErrorKey] != nil else {
                    return
                }
                Task { @MainActor in
                    self?.fallbackToDirectPlaybackIfAvailable(id: id, isMuted: player.isMuted)
                }
            }
        ]
        interstitialTimeObservers[id] = monitor.interstitialPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak monitor] time in
            Task { @MainActor in
                self?.updateInterstitialProgress(id: id, monitor: monitor, elapsed: time.seconds)
            }
        }
    }

    private func handleInterstitialChange(
        id: String,
        monitor: AVPlayerInterstitialEventMonitor?,
        context: SGAIPlaybackContext
    ) {
        guard let monitor else { return }
        guard let event = monitor.currentEvent else {
            if serverAdPresentations[id] != nil {
                trackServerAdEvent("complete", id: id)
            }
            serverAdPresentations[id] = nil
            firedServerAdEvents[id] = nil
            return
        }

        let breakId = SGAIBreakIdentifier.breakId(from: event.identifier)
        serverAdPresentations[id] = ShortsServerAdPresentation(
            breakId: breakId,
            asset: nil,
            remainingSec: 0,
            progress: 0,
            canSkip: false
        )
        serverAdAssets[id] = []
        firedServerAdEvents[id] = []

        guard let url = SGAIPlaybackURLBuilder.assetListURL(breakId: breakId, context: context) else { return }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let list = try JSONDecoder().decode(SGAIAssetList.self, from: data)
                guard let asset = list.assets.first else { return }
                await MainActor.run {
                    guard self.interstitialMonitors[id]?.currentEvent?.identifier == event.identifier else { return }
                    self.serverAdAssets[id] = list.assets
                    let duration = max(0, asset.duration ?? 0)
                    self.serverAdPresentations[id] = ShortsServerAdPresentation(
                        breakId: breakId,
                        asset: asset,
                        remainingSec: duration,
                        progress: 0,
                        canSkip: false
                    )
                    // The SGAI Worker owns impression when AVPlayer fetches the
                    // ASSET-LIST. The client begins with start to avoid double
                    // counting the billable impression.
                    self.trackServerAdEvent("start", id: id)
                }
            } catch {
                // AVFoundation can still finish the server-guided break when optional
                // companion metadata is unavailable, so keep playback running.
            }
        }
    }

    private func updateInterstitialProgress(
        id: String,
        monitor: AVPlayerInterstitialEventMonitor?,
        elapsed: Double
    ) {
        guard monitor?.currentEvent != nil,
              let current = serverAdPresentations[id] else { return }
        let currentItemURL = (monitor?.interstitialPlayer.currentItem?.asset as? AVURLAsset)?.url
        let matchedAsset = serverAdAssets[id]?.first(where: {
            guard let assetURL = URL(string: $0.uri), let currentItemURL else { return false }
            return assetURL.absoluteString == currentItemURL.absoluteString
        })
        let activeAsset = matchedAsset ?? current.asset
        if activeAsset?.impressionId != current.asset?.impressionId {
            trackServerAdEvent("complete", id: id)
            serverAdPresentations[id] = ShortsServerAdPresentation(
                breakId: current.breakId,
                asset: activeAsset,
                remainingSec: max(0, activeAsset?.duration ?? 0),
                progress: 0,
                canSkip: false
            )
            trackServerAdEvent("start", id: id)
        }
        guard let refreshed = serverAdPresentations[id] else { return }
        let itemDuration = monitor?.interstitialPlayer.currentItem?.duration.seconds
        let duration = (itemDuration?.isFinite == true ? itemDuration : nil) ?? refreshed.asset?.duration ?? 0
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let progress = duration > 0 ? min(1, safeElapsed / duration) : 0
        let remaining = duration > 0 ? max(0, duration - safeElapsed) : 0
        let policy = serverAdPolicies[id]
        let isSkippable = policy?.skippable ?? (refreshed.asset?.skippable == 1)
        let rawSkipOffset = policy?.skipAfterSec.map(Double.init)
            ?? refreshed.asset?.skipOffsetSec
            ?? 0
        let skipOffset = min(max(0, rawSkipOffset), duration > 0 ? duration : .greatestFiniteMagnitude)
        serverAdPresentations[id] = ShortsServerAdPresentation(
            breakId: refreshed.breakId,
            asset: refreshed.asset,
            remainingSec: remaining,
            progress: progress,
            canSkip: isSkippable && safeElapsed >= skipOffset,
            isSkippable: isSkippable,
            skipCountdown: Int(ceil(max(0, skipOffset - safeElapsed)))
        )
        if progress >= 0.25 { trackServerAdEvent("firstQuartile", id: id) }
        if progress >= 0.50 { trackServerAdEvent("midpoint", id: id) }
        if progress >= 0.75 { trackServerAdEvent("thirdQuartile", id: id) }
    }

    private func trackServerAdEvent(_ event: String, id: String) {
        guard let presentation = serverAdPresentations[id],
              let asset = presentation.asset,
              let impressionId = asset.impressionId,
              !impressionId.isEmpty,
              let context = serverAdContexts[id] else { return }
        var fired = firedServerAdEvents[id] ?? []
        guard fired.insert("\(impressionId):\(event)").inserted else { return }
        firedServerAdEvents[id] = fired
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
                placement: "preroll",
                breakId: presentation.breakId,
                userId: context.userId
            )
        }
    }

    private func removeInterstitialLifecycle(for id: String) {
        if let monitor = interstitialMonitors[id],
           let token = interstitialTimeObservers.removeValue(forKey: id) {
            monitor.interstitialPlayer.removeTimeObserver(token)
        }
        interstitialObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        interstitialMonitors[id] = nil
        serverAdPresentations[id] = nil
        serverAdAssets[id] = nil
        firedServerAdEvents[id] = nil
    }

    private func warmAsset(_ asset: AVURLAsset, id: String) {
        guard warmTasks[id] == nil else { return }
        warmTasks[id] = Task(priority: .utility) { [weak self] in
            do {
                _ = try await asset.load(.isPlayable)
                _ = try await asset.load(.duration)
                _ = try await asset.load(.tracks)
            } catch {
                CacheMetrics.shared.recordError("shorts.preview")
                self?.recordWarmFailure(for: id)
            }
        }
    }

    private func recordWarmFailure(for id: String) {
        failedWarmIDs[id] = Date()
    }

    private func hasRecentWarmFailure(for id: String) -> Bool {
        guard let failedAt = failedWarmIDs[id] else { return false }
        return Date().timeIntervalSince(failedAt) < 300
    }

    private func pruneFailedWarmIDs() {
        failedWarmIDs = failedWarmIDs.filter { Date().timeIntervalSince($0.value) < 300 }
    }

    private func trimWarmStateForMemoryPressure() {
        let protectedIDs = Set([activeID].compactMap { $0 })
        Set(players.keys).subtracting(protectedIDs).forEach(releasePlayer)
        Set(assetCache.keys).subtracting(protectedIDs).forEach(releaseWarmState)
    }

    private func releasePlayer(_ id: String) {
        if activeID == id {
            activeID = nil
        }
        removeInterstitialLifecycle(for: id)
        if let observer = endObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = failureObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObservers.removeValue(forKey: id)?.invalidate()
        players[id]?.pause()
        var updatedPlayers = players
        if updatedPlayers.removeValue(forKey: id) != nil {
            CacheMetrics.shared.recordEviction(metricsNamespace)
        }
        players = updatedPlayers
    }

    private func releaseWarmState(_ id: String) {
        warmTasks[id]?.cancel()
        warmTasks[id] = nil
        if assetCache.removeValue(forKey: id) != nil {
            CacheMetrics.shared.recordEviction(metricsNamespace)
        }
        assetSourceURLs[id] = nil
    }

    private func preparedShortIDs(feedItems: [ShortsFeedItem], currentID: String?) -> Set<String> {
        guard let currentID,
              let currentIndex = feedItems.firstIndex(where: { $0.id == currentID }) else {
            return Set(feedItems.prefix(initialWarmCount).compactMap { item in
                if case .short(_, let short) = item { return short.id }
                return nil
            })
        }

        let lowerBound = max(0, currentIndex - backwardWarmCount)
        let upperBound = min(feedItems.count - 1, currentIndex + forwardWarmCount)
        return Set(feedItems[lowerBound...upperBound].compactMap { item in
            if case .short(_, let short) = item { return short.id }
            return nil
        })
    }

    private func isAtEnd(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        guard current.isFinite, duration.isFinite, duration > 0 else { return false }
        return current >= max(0, duration - 0.2)
    }
}

// MARK: - ShortsView (root)

struct ShortsView: View {

    let initialShortId: String?
    let contextShowId: String?
    let contextChannelId: String?
    let showsDismissControls: Bool
    let isRootActive: Bool

    @AppStorage("playerMuted") private var isMuted: Bool = false
    @State private var shorts:       [Short]     = []
    @State private var currentID:    String?     = nil   // scrollPosition id
    @State private var nextCursor:   String?     = nil
    @State private var isLoading:    Bool        = false
    @State private var feed:         ShortsFeed  = .forYou
    @State private var emptyReason:  String?     = nil
    @State private var loadError:    String?     = nil
    @State private var paginationError: String?  = nil
    @State private var feedMovesForward = true
    @State private var adLockedItemId: String?
    @State private var feedSessionSeed = UUID().uuidString
    @State private var feedSessionIDs: [String]?
    @State private var recordedShortViewIds = Set<String>()
    @State private var pendingShortViewTask: Task<Void, Never>?
    @State private var imagePrefetchTask: Task<Void, Never>?
    @State private var activationRetryTask: Task<Void, Never>?
    @State private var feedGeneration = UUID()
    @State private var skippedShortsAdItemIds = Set<String>()
    @State private var pendingShortsAdItemIds = Set<String>()
    @State private var filledShortsAdDecisions = [String: AdDecision]()
    @State private var filledShortsAdPolicies = [String: EffectiveAdPolicy]()
    @State private var shortsAdIdentityGeneration = UUID()
    @State private var shortsAdConfigGeneration = UUID()
    @State private var shortsAdConfig: PlatformShortsAdsConfig = .disabled
    @State private var shortsFeedListings = [AssembledListing]()
    @StateObject private var playbackManager: ShortsPlaybackManager
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var shouldLoadInitialShorts: Bool {
        isRootActive || initialShortId != nil || contextShowId != nil || contextChannelId != nil || showsDismissControls
    }

    private var shortsAdConfigVersion: String {
        let config = platformConfig.config.ads.shorts
        let placements = config.placements.keys.sorted().map { key in
            let placement = config.placementConfig(for: key)
            return [
                key,
                String(placement.enabled),
                String(describing: placement.skippable),
                String(describing: placement.skipAfterSec),
                String(describing: placement.maxDurationSec),
                String(describing: placement.frequencyPerUserPerDay)
            ].joined(separator: ":")
        }.joined(separator: "|")
        return [
            String(platformConfig.isLoaded),
            String(config.enabled),
            config.cadenceKind,
            String(config.cadenceValue),
            String(config.firstAfter),
            placements
        ].joined(separator: ";")
    }

    @MainActor
    init(
        initialShortId: String? = nil,
        contextShowId: String? = nil,
        contextChannelId: String? = nil,
        showsDismissControls: Bool = false,
        isRootActive: Bool = true,
        playbackManager: ShortsPlaybackManager? = nil
    ) {
        self.initialShortId = initialShortId
        self.contextShowId = contextShowId
        self.contextChannelId = contextChannelId
        self.showsDismissControls = showsDismissControls
        self.isRootActive = isRootActive
        self._playbackManager = StateObject(wrappedValue: playbackManager ?? ShortsPlaybackManager())
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            feedContent
                .id(feed)
                .transition(feedTransition)
        }
        .overlay(alignment: .topLeading) {
            if showsDismissControls && !isShowingShortsAd {
                shortsBackButton
            }
        }
        .overlay(alignment: .top) {
            if shouldShowFeedTabs {
                feedTabs
            }
        }
        .simultaneousGesture(showsDismissControls ? edgeDismissGesture : nil)
        .simultaneousGesture(feedSwipeGesture)
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(showsDismissControls)
        .disablesInteractiveSwipeBack()
        .task {
            guard shouldLoadInitialShorts else { return }
            loadShortsAdConfig()
            await loadInitial()
        }
        .onAppear {
            if showsDismissControls {
                postRoutedShortsVisibility(true)
            }
            guard isRootActive else { return }
            ensureInitialShortSelection()
            configurePlayback(ensureAutoplay: true)
        }
        .onChange(of: isRootActive) { _, isActive in
            guard isActive else { return }
            loadShortsAdConfig()
            Task { await loadInitial() }
        }
        .onDisappear {
            if showsDismissControls {
                postRoutedShortsVisibility(false)
            }
        }
        .onChange(of: shortsAdConfigVersion) { _, _ in
            handleShortsAdConfigChange()
        }
        .onChange(of: auth.currentUser?.id) { _, _ in
            handleIdentityChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { _ in
            handleIdentityChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
            guard (notification.object as? String) == "shorts" else { return }
            adLockedItemId = nil
            currentID = firstPlayableShortID
        }
    }

    // MARK: - Feed tabs

    private var sourceContext: (source: String, sourceId: String)? {
        if let showId = contextShowId, !showId.isEmpty {
            return ("show", showId)
        }
        if let channelId = contextChannelId, !channelId.isEmpty {
            return ("channel", channelId)
        }
        return nil
    }

    private var canPersistRootFeedSession: Bool {
        initialShortId == nil && sourceContext == nil
    }

    private var feedTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: feedMovesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: feedMovesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var shouldShowFeedTabs: Bool {
        sourceContext == nil && !isShowingShortsAd && !isShowingCurationSlot
    }

    private var isShowingCurationSlot: Bool {
        guard let currentID,
              let item = feedItems.first(where: { $0.id == currentID }) else { return false }
        if case .curationSlot = item { return true }
        return false
    }

    private var feedTabs: some View {
        MediaverseUnderlineTabStrip(
            items: ShortsFeed.allCases.map {
                MediaverseTabItem(id: $0.rawValue, label: $0.label)
            },
            selectedID: feed.rawValue,
            fillsWidth: true,
            horizontalPadding: 0,
            verticalPadding: 10,
            background: .clear
        ) { id in
            guard let tab = ShortsFeed(rawValue: id) else { return }
            Task { await switchFeed(tab) }
        }
        .frame(maxWidth: 300)
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .zIndex(40)
    }

    private var feedSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                guard shouldShowFeedTabs, !showsDismissControls else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.5, abs(horizontal) > 72 else { return }
                let feeds = ShortsFeed.allCases
                guard let index = feeds.firstIndex(of: feed) else { return }
                let nextIndex = horizontal < 0 ? index + 1 : index - 1
                guard feeds.indices.contains(nextIndex) else { return }
                C.lightHaptic()
                Task { await switchFeed(feeds[nextIndex]) }
            }
    }

    @ViewBuilder
    private var feedContent: some View {
        if isLoading && shorts.isEmpty {
            ProgressView().tint(C.watch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            // Decode/network error — show it so we can diagnose
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(.white.opacity(0.4))
                Text(err).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button {
                    loadError = nil
                    Task { await loadInitial() }
                } label: {
                    Text("Retry").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(.white.opacity(0.15)).clipShape(Capsule())
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shorts.isEmpty {
            emptyState
        } else {
            let assembledFeedItems = feedItems
            ShortsPagerView(
                items: assembledFeedItems,
                currentID: $currentID,
                isScrollLocked: adLockedItemId != nil,
                onApproachingEnd: {
                    Task { await loadMore() }
                },
                onRefresh: {
                    await refreshShorts()
                }
            ) { item in
                switch item {
                case .short(let idx, let short):
                    ShortCardView(
                        short: short,
                        isActive: item.id == currentID,
                        shouldPrepare: shouldPrepareShort(at: idx, in: assembledFeedItems),
                        isMuted: $isMuted,
                        playbackManager: playbackManager,
                        onPlaylistShortSelected: jumpToPlaylistShort
                    )
                case .ad(_, let afterIndex, let contentId, let placement, let adConfig, let policy, let decision):
                    ShortsAdCardView(
                        decision: decision,
                        policy: policy,
                        contentId: contentId,
                        placement: placement,
                        adIndex: afterIndex,
                        adConfig: adConfig,
                        userId: auth.currentUser?.id,
                        isActive: item.id == currentID,
                        onAdPlaybackChanged: { isPlayingAd in
                            if isPlayingAd {
                                adLockedItemId = item.id
                                postShortsAdPlaybackVisibility(true)
                            } else {
                                if adLockedItemId == item.id {
                                    adLockedItemId = nil
                                }
                                postShortsAdPlaybackVisibility(false)
                            }
                        },
                        onSwipeUnlocked: {
                            if adLockedItemId == item.id {
                                adLockedItemId = nil
                            }
                        },
                        onAdvance: {
                            advanceAfterAd(itemId: item.id)
                        }
                    )
                case .curationSlot(_, let listing):
                    ShortsCurationSlotView(listing: listing) { item in
                        handleCurationSlotSelection(item)
                    }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                ensureInitialShortSelection()
                configurePlayback(ensureAutoplay: true)
                prefetchUpcomingShortsAds()
                prefetchNearbyShortImages(around: currentID, in: assembledFeedItems)
                recordShortViewIfNeeded(itemID: currentID)
            }
            .onChange(of: shorts.count) { _, _ in
                ensureInitialShortSelection()
                configurePlayback(ensureAutoplay: true)
                prefetchUpcomingShortsAds()
            }
            .onChange(of: currentID) { _, id in
                configurePlayback()
                guard let id else { return }
                prefetchUpcomingShortsAds()
                prefetchNearbyShortImages(around: id, in: assembledFeedItems)
                recordShortViewIfNeeded(itemID: id)
                saveRootFeedSessionIfNeeded()
                if let itemIndex = assembledFeedItems.firstIndex(where: { $0.id == id }),
                   itemIndex >= assembledFeedItems.count - 2 {
                    Task { await loadMore() }
                }
            }
            .onChange(of: feedItems.map(\.id)) { _, _ in
                configurePlayback()
                prefetchUpcomingShortsAds()
                prefetchNearbyShortImages(around: currentID, in: assembledFeedItems)
                saveRootFeedSessionIfNeeded()
            }
            .onChange(of: isMuted) { _, _ in
                configurePlayback()
            }
            .overlay(alignment: .bottom) {
                if let paginationError {
                    paginationErrorBanner(paginationError)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    ensureInitialShortSelection()
                    configurePlayback(ensureAutoplay: true)
                } else {
                    playbackManager.pausePlayback()
                }
            }
            .onChange(of: isRootActive) { _, isActive in
                if isActive {
                    ensureInitialShortSelection()
                    configurePlayback(ensureAutoplay: true)
                    Task { @MainActor in
                        await Task.yield()
                        ensureInitialShortSelection()
                        configurePlayback(ensureAutoplay: true)
                    }
                } else {
                    cancelSessionTasks()
                    saveRootFeedSessionIfNeeded()
                    adLockedItemId = nil
                    postShortsAdPlaybackVisibility(false)
                    playbackManager.pausePlayback()
                }
            }
            .onDisappear {
                pendingShortViewTask?.cancel()
                pendingShortViewTask = nil
                imagePrefetchTask?.cancel()
                imagePrefetchTask = nil
                activationRetryTask?.cancel()
                activationRetryTask = nil
                saveRootFeedSessionIfNeeded()
                adLockedItemId = nil
                postShortsAdPlaybackVisibility(false)
                playbackManager.pausePlayback()
            }
        }
    }

    private var firstPlayableShortID: String? {
        feedItems.compactMap { item -> String? in
            guard case .short(_, let short) = item,
                  C.mediaURL(short.videoUrl) != nil else { return nil }
            return short.id
        }.first
    }

    private var canPlayShorts: Bool {
        isRootActive && UIApplication.shared.applicationState == .active
    }

    private func ensureInitialShortSelection() {
        guard currentID == nil else { return }
        currentID = firstPlayableShortID
    }

    private func configurePlayback(ensureAutoplay: Bool = false) {
        guard canPlayShorts else {
            playbackManager.pausePlayback()
            return
        }
        let playbackID = currentID ?? firstPlayableShortID
        if currentID == nil {
            currentID = playbackID
        }
        playbackManager.configure(
            feedItems: feedItems,
            currentID: playbackID,
            isMuted: isMuted,
            userId: auth.currentUser?.id
        )
        guard ensureAutoplay, let playbackID else { return }
        activateSelectedShortWhenReady(playbackID)
    }

    private func activateSelectedShortWhenReady(_ playbackID: String) {
        activationRetryTask?.cancel()
        let retryDelays: [UInt64] = [0, 120_000_000, 360_000_000, 800_000_000, 1_500_000_000]
        activationRetryTask = Task { @MainActor in
            for delay in retryDelays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      canPlayShorts,
                      currentID == playbackID else { return }
                guard feedItems.contains(where: { item in
                    if case .short = item, item.id == playbackID { return true }
                    return false
                }) else { return }
                playbackManager.activate(playbackID)
            }
            activationRetryTask = nil
        }
    }

    private func paginationErrorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                paginationError = nil
                Task { await loadMore() }
            } label: {
                Text("Retry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(C.watch, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 28)
    }

    private func recordShortViewIfNeeded(itemID: String?) {
        pendingShortViewTask?.cancel()
        guard let itemID,
              let item = feedItems.first(where: { $0.id == itemID }),
              case .short(_, let short) = item,
              !recordedShortViewIds.contains(short.id) else { return }

        pendingShortViewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  isRootActive,
                  canPlayShorts,
                  currentID == itemID,
                  recordedShortViewIds.insert(short.id).inserted else { return }
            try? await APIClient.shared.recordShortView(videoId: short.id)
        }
    }

    private func handleCurationSlotSelection(_ item: ContentItem) {
        let type = item.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type == "short" else {
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: item.appRoute)
            return
        }

        Task {
            do {
                let response = try await APIClient.shared.fetchShorts(
                    feed: feed.rawValue,
                    limit: 10,
                    seed: feedSessionSeed,
                    source: sourceContext?.source,
                    sourceId: sourceContext?.sourceId,
                    ids: [item.entityId]
                )
                guard let selectedShort = response.shorts.first(where: { $0.id == item.entityId }) else { return }
                let mergedShorts = uniqueByID(shorts + [selectedShort])
                shorts = prioritizeShort(id: selectedShort.id, in: mergedShorts)
                currentID = selectedShort.id
                configurePlayback()
                recordShortViewIfNeeded(itemID: selectedShort.id)
            } catch {
                paginationError = error.localizedDescription
            }
        }
    }

    private var isShowingShortsAd: Bool {
        if adLockedItemId != nil { return true }
        guard let currentID,
              let item = feedItems.first(where: { $0.id == currentID }) else { return false }
        if case .ad = item { return true }
        return false
    }

    private var feedItems: [ShortsFeedItem] {
        ShortsFeedAssembler.makeItems(
            shorts: shorts,
            nextCursor: nextCursor,
            curationListings: shortsFeedListings,
            shortsAdConfig: shortsAdConfig,
            skippedAdItemIDs: skippedShortsAdItemIds,
            filledAdDecisions: filledShortsAdDecisions,
            filledAdPolicies: filledShortsAdPolicies,
            shouldRequestAd: { index, placement, adConfig in
                shouldRequestShortsAd(at: index, placement: placement, adConfig: adConfig)
            }
        )
    }

    private func shouldPrepareShort(at index: Int, in assembledFeedItems: [ShortsFeedItem]) -> Bool {
        guard let currentID,
              let itemIndex = assembledFeedItems.firstIndex(where: { $0.id == currentID }) else {
            return index <= 6
        }

        let lowerBound = max(0, itemIndex - 2)
        let upperBound = min(assembledFeedItems.count - 1, itemIndex + 6)
        return assembledFeedItems[lowerBound...upperBound].contains { item in
            if case .short(let shortIndex, _) = item {
                return shortIndex == index
            }
            return false
        }
    }

    private func currentShortIndexForAdPrefetch() -> Int? {
        guard let currentID,
              let item = feedItems.first(where: { $0.id == currentID }) else {
            return shorts.isEmpty ? nil : 0
        }

        switch item {
        case .short(let index, _):
            return index
        case .ad(_, let afterIndex, _, _, _, _, _):
            return afterIndex + 1
        case .curationSlot:
            return 0
        }
    }

    private func prefetchNearbyShortImages(around itemID: String?, in assembledFeedItems: [ShortsFeedItem]) {
        imagePrefetchTask?.cancel()
        guard !assembledFeedItems.isEmpty else { return }
        let activeIndex = itemID.flatMap { id in assembledFeedItems.firstIndex { $0.id == id } } ?? 0
        let endIndex = min(assembledFeedItems.count, activeIndex + 5)
        guard activeIndex < endIndex else { return }
        let urls = assembledFeedItems[activeIndex..<endIndex].compactMap { item -> URL? in
            guard case .short(_, let short) = item else { return nil }
            return C.mediaURL(short.thumbnailUrl)
        }
        guard !urls.isEmpty else { return }
        let scale = UIScreen.main.scale
        let width = max(320, UIScreen.main.bounds.width) * scale
        let height = max(560, UIScreen.main.bounds.height) * scale
        imagePrefetchTask = Task(priority: .utility) {
            await RemoteImageCache.shared.prefetch(
                urls: urls,
                targetPixelSize: CGSize(width: width, height: height),
                limit: 5,
                concurrency: 2
            )
        }
    }

    private func prefetchUpcomingShortsAds() {
        guard shortsAdConfig.enabled else { return }
        guard let currentShortIndex = currentShortIndexForAdPrefetch() else { return }
        let candidates = ShortsFeedAssembler.adCandidates(
            shorts: shorts,
            shortsAdConfig: shortsAdConfig,
            afterShortIndex: currentShortIndex,
            lookahead: 6
        )

        for candidate in candidates {
            guard shouldRequestShortsAd(at: candidate.afterIndex, placement: candidate.placement, adConfig: candidate.adConfig),
                  !skippedShortsAdItemIds.contains(candidate.id),
                  filledShortsAdDecisions[candidate.id] == nil,
                  !pendingShortsAdItemIds.contains(candidate.id) else { continue }

            pendingShortsAdItemIds.insert(candidate.id)
            let request = ShortsAdRequestGuard(
                identityGeneration: shortsAdIdentityGeneration,
                feedGeneration: feedGeneration,
                configGeneration: shortsAdConfigGeneration,
                feedSeed: feedSessionSeed,
                shortsIDs: shorts.map(\.id)
            )
            Task { await prefetchShortsAd(candidate, request: request) }
        }
    }

    @MainActor
    private func prefetchShortsAd(_ candidate: ShortsAdCandidate, request: ShortsAdRequestGuard) async {
        defer {
            if request.identityGeneration == shortsAdIdentityGeneration {
                pendingShortsAdItemIds.remove(candidate.id)
            }
        }
        let requestUserId = auth.currentUser?.id
        guard candidate.adConfig.enabled,
              candidate.adConfig.placementConfig(for: candidate.placement).enabled else {
            skippedShortsAdItemIds.insert(candidate.id)
            return
        }

        let policy = candidate.adPolicy
        guard policy.adsEnabled else {
            skippedShortsAdItemIds.insert(candidate.id)
            return
        }

        let policyConfig = policy.applying(to: candidate.adConfig)
        let placementConfig = policyConfig.placementConfig(for: candidate.placement)
        let effectiveSkippable = placementConfig.skippable ?? policyConfig.skippable
        let effectiveSkipAfterSec = placementConfig.skipAfterSec ?? policyConfig.skipAfterSec
        let effectiveMaxDurationSec = placementConfig.maxDurationSec ?? policyConfig.maxDurationSec ?? policy.pods?.maxAdDurationSec

        let decision: AdDecision?
        do {
            decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: candidate.contentId,
                    contentType: "short",
                    placement: candidate.placement,
                    maxAds: policy.pods?.prerollMaxAds ?? policy.adLoad ?? policyConfig.maxAds ?? 1,
                    maxDurationSec: effectiveMaxDurationSec,
                    skippable: effectiveSkippable,
                    skipAfterSec: effectiveSkipAfterSec,
                    orientation: "VERTICAL",
                    userId: requestUserId
                )
            )
        } catch {
            decision = nil
        }

        guard request.identityGeneration == shortsAdIdentityGeneration,
              request.feedGeneration == feedGeneration,
              request.configGeneration == shortsAdConfigGeneration,
              request.feedSeed == feedSessionSeed,
              request.shortsIDs == shorts.map(\.id),
              requestUserId == auth.currentUser?.id,
              shouldRequestShortsAd(
                  at: candidate.afterIndex,
                  placement: candidate.placement,
                  adConfig: candidate.adConfig
              ),
              shorts.indices.contains(candidate.afterIndex),
              shorts[candidate.afterIndex].id == candidate.contentId else { return }
        if let currentShortIndex = currentShortIndexForAdPrefetch(),
           currentShortIndex > candidate.afterIndex {
            skippedShortsAdItemIds.insert(candidate.id)
            return
        }
        guard let decision else {
            // Do not permanently consume this slot after a transient timeout.
            return
        }
        guard decision.filled, !decision.ads.isEmpty else {
            skippedShortsAdItemIds.insert(candidate.id)
            return
        }

        filledShortsAdDecisions[candidate.id] = decision
        filledShortsAdPolicies[candidate.id] = policy
    }

    private func advanceAfterAd(itemId: String) {
        guard adLockedItemId == nil || adLockedItemId == itemId,
              let index = feedItems.firstIndex(where: { $0.id == itemId }) else { return }

        let nextItemID = feedItems.indices.contains(index + 1) ? feedItems[index + 1].id : nil
        adLockedItemId = nil
        postShortsAdPlaybackVisibility(false)

        // A completed feed ad is a consumed feed item. Removing its decision
        // prevents a back swipe or view reconstruction from replaying it and
        // recording another impression against the same decision.
        skippedShortsAdItemIds.insert(itemId)
        pendingShortsAdItemIds.remove(itemId)
        filledShortsAdDecisions[itemId] = nil
        filledShortsAdPolicies[itemId] = nil

        if let nextItemID {
            currentID = nextItemID
        } else {
            Task { await loadMore() }
        }
    }

    private func skipUnavailableAd(itemId: String, moveIfActive: Bool) {
        let previousItems = feedItems
        let previousIndex = previousItems.firstIndex { $0.id == itemId }
        skippedShortsAdItemIds.insert(itemId)
        pendingShortsAdItemIds.remove(itemId)
        filledShortsAdDecisions[itemId] = nil
        filledShortsAdPolicies[itemId] = nil

        guard moveIfActive || currentID == itemId else {
            if adLockedItemId == itemId {
                adLockedItemId = nil
                postShortsAdPlaybackVisibility(false)
            }
            return
        }

        let refreshedItems = feedItems
        let replacementID = previousIndex.flatMap { index -> String? in
            if refreshedItems.indices.contains(index) {
                return refreshedItems[index].id
            }
            if refreshedItems.indices.contains(index - 1) {
                return refreshedItems[index - 1].id
            }
            return refreshedItems.first?.id
        } ?? refreshedItems.first?.id

        if adLockedItemId == itemId {
            adLockedItemId = nil
            postShortsAdPlaybackVisibility(false)
        }

        if let replacementID {
            currentID = replacementID
        } else {
            Task { await loadMore() }
        }
    }

    private func jumpToPlaylistShort(_ selectedShort: Short) {
        adLockedItemId = nil
        postShortsAdPlaybackVisibility(false)
        if !shorts.contains(where: { $0.id == selectedShort.id }) {
            shorts = uniqueByID(shorts + [selectedShort])
        }
        currentID = selectedShort.id
        configurePlayback()
    }

    private func shouldRequestShortsAd(at index: Int, placement: String, adConfig: PlatformShortsAdsConfig) -> Bool {
        let config = adConfig
        guard ShortsAdSchedule.isEligible(afterShortAt: index, placement: placement, config: config)
        else { return false }
        let placementConfig = config.placementConfig(for: placement)
        guard ShortsAdFrequencyStore.canShow(
            placement: placement,
            userId: auth.currentUser?.id,
            cap: placementConfig.frequencyPerUserPerDay
        ) else {
            return false
        }

        return true
    }

    private var edgeDismissGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onEnded { value in
                guard adLockedItemId == nil else { return }
                guard value.startLocation.x <= 80 else { return }
                guard value.translation.width > 72 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                dismiss()
            }
    }

    private var shortsBackButton: some View {
        PlatformBackButton { dismiss() }
        .padding(.leading, 14)
        .padding(.top, 12)
        .zIndex(30)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName:
                    emptyReason == "not_logged_in" ? "lock.fill" :
                    emptyReason == "no_follows"    ? "person.2.fill" :
                    "bolt.fill"
            )
            .font(.system(size: 52))
            .foregroundStyle(.white.opacity(0.25))

            Text(
                emptyReason == "not_logged_in" ? "Sign in to see Following" :
                emptyReason == "no_follows"    ? "Follow channels & shows" :
                "No Shorts yet"
            )
            .font(.title3.bold())

            Text(
                emptyReason == "not_logged_in"
                ? "Sign in to see shorts from channels and shows you follow."
                : emptyReason == "no_follows"
                ? "Follow channels or shows — their new shorts appear here."
                : "Vertical videos will appear here."
            )
            .font(.subheadline)
            .foregroundStyle(C.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 260)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func cancelSessionTasks() {
        pendingShortViewTask?.cancel()
        pendingShortViewTask = nil
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil
        activationRetryTask?.cancel()
        activationRetryTask = nil
    }

    private func handleIdentityChange() {
        cancelSessionTasks()
        feedGeneration = UUID()
        feedSessionSeed = UUID().uuidString
        feedSessionIDs = nil
        shortsFeedListings.removeAll()
        shorts.removeAll()
        nextCursor = nil
        currentID = nil
        emptyReason = nil
        loadError = nil
        paginationError = nil
        isLoading = false
        recordedShortViewIds.removeAll()
        skippedShortsAdItemIds.removeAll()
        pendingShortsAdItemIds.removeAll()
        filledShortsAdDecisions.removeAll()
        filledShortsAdPolicies.removeAll()
        adLockedItemId = nil
        postShortsAdPlaybackVisibility(false)
        shortsAdIdentityGeneration = UUID()
        playbackManager.resetForIdentityChange()
        guard shouldLoadInitialShorts else { return }
        Task { await loadInitial(replacingExisting: true) }
    }

    private func loadShortsAdConfig() {
        // Start with safe platform defaults so config loading cannot block the
        // first ad prefetch. Once loaded, the real config invalidates in-flight
        // requests through shortsAdConfigGeneration and replaces these values.
        shortsAdConfig = platformConfig.isLoaded ? platformConfig.config.ads.shorts : .default
        playbackManager.setShortsAdsEnabled(shortsAdConfig.enabled)
    }

    private func handleShortsAdConfigChange() {
        loadShortsAdConfig()
        shortsAdConfigGeneration = UUID()
        pendingShortsAdItemIds.removeAll()
        filledShortsAdDecisions.removeAll()
        filledShortsAdPolicies.removeAll()
        if shortsAdConfig.enabled {
            configurePlayback()
            prefetchUpcomingShortsAds()
        } else {
            skippedShortsAdItemIds.removeAll()
            configurePlayback()
        }
    }

    private func restoreRootFeedSessionIfNeeded() -> Bool {
        guard canPersistRootFeedSession,
              shorts.isEmpty,
              let snapshot = playbackManager.restoreRootFeedSnapshot(
                userId: auth.currentUser?.id,
                context: SessionStorage.activeContextCookieValue
              ),
              !snapshot.shorts.isEmpty
        else { return false }

        feed = snapshot.feed
        shorts = snapshot.shorts
        currentID = snapshot.currentID.flatMap { id in
            feedItems.contains(where: { $0.id == id }) ? id : nil
        } ?? snapshot.shorts.first?.id
        nextCursor = snapshot.nextCursor
        feedSessionSeed = snapshot.feedSessionSeed
        feedSessionIDs = snapshot.feedSessionIDs
        shortsFeedListings = snapshot.shortsFeedListings
        skippedShortsAdItemIds = snapshot.skippedShortsAdItemIds
        pendingShortsAdItemIds.removeAll()
        filledShortsAdDecisions.removeAll()
        filledShortsAdPolicies.removeAll()
        emptyReason = nil
        loadError = nil
        paginationError = nil
        return true
    }

    private func saveRootFeedSessionIfNeeded() {
        guard canPersistRootFeedSession, !shorts.isEmpty else { return }
        playbackManager.saveRootFeedSnapshot(
            ShortsPlaybackManager.RootFeedSnapshot(
                cacheScope: ShortsFeedCacheScope.initialFeedKey(
                    userId: auth.currentUser?.id,
                    context: SessionStorage.activeContextCookieValue
                ),
                feed: feed,
                shorts: shorts,
                currentID: currentID,
                nextCursor: nextCursor,
                feedSessionSeed: feedSessionSeed,
                feedSessionIDs: feedSessionIDs,
                shortsFeedListings: shortsFeedListings,
                skippedShortsAdItemIds: skippedShortsAdItemIds
            )
        )
    }

    private func loadInitial(replacingExisting: Bool = false) async {
        guard !isLoading else { return }
        let generation = feedGeneration
        if !replacingExisting && !shorts.isEmpty {
            ensureInitialShortSelection()
            configurePlayback(ensureAutoplay: true)
            recordShortViewIfNeeded(itemID: currentID)
            return
        }

        isLoading = replacingExisting || shorts.isEmpty
        defer {
            if feedGeneration == generation {
                isLoading = false
            }
        }
        loadError = nil
        paginationError = nil

        let resolvedSourceContext = sourceContext
        let queuedShortIds = resolvedSourceContext == nil ? ShortNavigationCache.shared.takeIDs(containing: initialShortId) : nil
        let canUseCuration = resolvedSourceContext == nil && initialShortId == nil && feed == .forYou
        let curationPage = canUseCuration ? CurationManager.shared.cachedPage(key: "shorts") : nil
        if canUseCuration, curationPage == nil {
            Task { _ = try? await CurationManager.shared.fetchPage(key: "shorts") }
        }
        let curationShortsFeeds = curationPage?.shortsFeedListings ?? []
        let curationShortIds = uniqueStrings(curationShortsFeeds.flatMap(\.shortIDs))
        shortsFeedListings = curationShortsFeeds

        let requestedShortIds: [String]?
        if let queuedShortIds {
            requestedShortIds = queuedShortIds
        } else if !curationShortIds.isEmpty {
            requestedShortIds = curationShortIds
        } else {
            requestedShortIds = nil
        }

        let canUsePrewarmedFeed = resolvedSourceContext == nil && requestedShortIds == nil && initialShortId == nil && feed == .forYou
        let prewarmedFeed = canUsePrewarmedFeed
            ? await playbackManager.takePreparedInitialFeedIfAvailable(
                isMuted: isMuted,
                userId: auth.currentUser?.id,
                context: SessionStorage.activeContextCookieValue
            )
            : nil
        guard feedGeneration == generation, !Task.isCancelled else { return }
        if let prewarmedFeed {
            feedSessionSeed = prewarmedFeed.seed
        }
        feedSessionIDs = requestedShortIds
        let seededShort = resolvedSourceContext == nil && requestedShortIds == nil ? ShortNavigationCache.shared.take(id: initialShortId) : nil
        if let seededShort {
            shorts = [seededShort]
            currentID = seededShort.id
            emptyReason = nil
        }
        do {
            let initialLimit = requestedShortIds.map { min(30, max(10, $0.count + 10)) } ?? 10
            let resp: ShortsResponse
            if let prewarmedFeed {
                resp = prewarmedFeed.response
            } else {
                resp = try await APIClient.shared.fetchShorts(
                    feed: feed.rawValue,
                    limit: initialLimit,
                    seed: feedSessionSeed,
                    source: resolvedSourceContext?.source,
                    sourceId: resolvedSourceContext?.sourceId,
                    ids: requestedShortIds,
                    forceRefresh: true
                )
            }
            let resolved = try await resolveInitialShorts(
                firstPage: resp,
                seededShort: seededShort
            )
            guard feedGeneration == generation, !Task.isCancelled else { return }
            let shouldPromoteInitialShort = resolvedSourceContext == nil && requestedShortIds == nil
            let uniqueShorts = shouldPromoteInitialShort
                ? prioritizeInitialShort(in: uniqueByID(resolved.shorts))
                : uniqueByID(resolved.shorts)
            if replacingExisting {
                playbackManager.reset()
                shortsFeedListings = curationShortsFeeds
                recordedShortViewIds.removeAll()
                skippedShortsAdItemIds.removeAll()
                pendingShortsAdItemIds.removeAll()
                filledShortsAdDecisions.removeAll()
                filledShortsAdPolicies.removeAll()
            }
            shorts = uniqueShorts
            nextCursor = resolved.nextCursor
            emptyReason = uniqueShorts.isEmpty ? (resp.reason ?? "empty") : nil
            currentID = initialShortId.flatMap { id in
                uniqueShorts.contains(where: { $0.id == id }) ? id : nil
            } ?? uniqueShorts.first?.id
            saveRootFeedSessionIfNeeded()
            configurePlayback(ensureAutoplay: true)
            recordShortViewIfNeeded(itemID: currentID)
        } catch {
            guard feedGeneration == generation, !Task.isCancelled else { return }
            if !replacingExisting && restoreRootFeedSessionIfNeeded() {
                ensureInitialShortSelection()
                configurePlayback(ensureAutoplay: true)
                recordShortViewIfNeeded(itemID: currentID)
            } else if replacingExisting {
                paginationError = error.localizedDescription
            } else {
                loadError = error.localizedDescription
            }
        }
    }

    private func refreshShorts() async {
        guard !isLoading else { return }
        feedGeneration = UUID()
        playbackManager.clearRootFeedSnapshot()
        feedSessionSeed = UUID().uuidString
        feedSessionIDs = nil
        emptyReason = nil
        loadError = nil
        paginationError = nil
        await loadInitial(replacingExisting: true)
    }

    private func resolveInitialShorts(
        firstPage: ShortsResponse,
        seededShort: Short?
    ) async throws -> (shorts: [Short], nextCursor: String?) {
        var allShorts = [Short]()
        if let seededShort {
            allShorts.append(seededShort)
        }
        allShorts.append(contentsOf: firstPage.shorts)

        guard let initialShortId,
              !allShorts.contains(where: { $0.id == initialShortId })
        else {
            return (allShorts, firstPage.nextCursor)
        }

        var nextCursor = firstPage.nextCursor
        for _ in 0..<4 {
            guard let cursor = nextCursor else { break }
            let resp = try await APIClient.shared.fetchShorts(
                feed: feed.rawValue,
                cursor: cursor,
                limit: 10,
                seed: feedSessionSeed,
                source: sourceContext?.source,
                sourceId: sourceContext?.sourceId,
                ids: feedSessionIDs
            )
            allShorts.append(contentsOf: resp.shorts)
            nextCursor = resp.nextCursor
            if allShorts.contains(where: { $0.id == initialShortId }) {
                break
            }
        }

        if !allShorts.contains(where: { $0.id == initialShortId }) {
            let directResp = try await APIClient.shared.fetchShorts(
                feed: feed.rawValue,
                limit: 1,
                seed: feedSessionSeed,
                source: sourceContext?.source,
                sourceId: sourceContext?.sourceId,
                ids: [initialShortId]
            )
            if let directShort = directResp.shorts.first(where: { $0.id == initialShortId }) {
                allShorts.insert(directShort, at: 0)
            }
        }

        return (allShorts, nextCursor)
    }

    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let generation = feedGeneration
        isLoading = true
        defer {
            if feedGeneration == generation {
                isLoading = false
            }
        }
        do {
            let resp = try await APIClient.shared.fetchShorts(
                feed: feed.rawValue,
                cursor: cursor,
                limit: 10,
                seed: feedSessionSeed,
                source: sourceContext?.source,
                sourceId: sourceContext?.sourceId,
                ids: feedSessionIDs
            )
            guard feedGeneration == generation, !Task.isCancelled else { return }
            shorts = uniqueByID(shorts + resp.shorts)
            nextCursor = resp.nextCursor
            paginationError = nil
            saveRootFeedSessionIfNeeded()
        } catch {
            guard feedGeneration == generation, !Task.isCancelled else { return }
            paginationError = error.localizedDescription
        }
    }

    private func switchFeed(_ newFeed: ShortsFeed) async {
        guard newFeed != feed else { return }
        feedGeneration = UUID()
        let generation = feedGeneration
        feedSessionSeed = UUID().uuidString
        feedSessionIDs = nil
        shortsFeedListings = []
        recordedShortViewIds.removeAll()
        skippedShortsAdItemIds.removeAll()
        pendingShortsAdItemIds.removeAll()
        filledShortsAdDecisions.removeAll()
        filledShortsAdPolicies.removeAll()
        feedMovesForward = newFeed == .following
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            feed = newFeed
            shorts = []
            nextCursor = nil
            currentID = nil
            emptyReason = nil
            paginationError = nil
            isLoading = true
        }
        defer {
            if feedGeneration == generation {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isLoading = false
                }
            }
        }
        do {
            let canUseCuration = sourceContext == nil && newFeed == .forYou
            let curationPage = canUseCuration ? try? await CurationManager.shared.fetchPage(key: "shorts") : nil
            guard feedGeneration == generation, !Task.isCancelled else { return }
            let curationShortsFeeds = curationPage?.shortsFeedListings ?? []
            let curationShortIds = uniqueStrings(curationShortsFeeds.flatMap(\.shortIDs))
            let requestedShortIds = curationShortIds.isEmpty ? nil : curationShortIds
            let initialLimit = requestedShortIds.map { min(30, max(10, $0.count + 10)) } ?? 10

            shortsFeedListings = curationShortsFeeds
            feedSessionIDs = requestedShortIds

            let resp = try await APIClient.shared.fetchShorts(
                feed: newFeed.rawValue,
                limit: initialLimit,
                seed: feedSessionSeed,
                source: sourceContext?.source,
                sourceId: sourceContext?.sourceId,
                ids: requestedShortIds
            )
            guard feedGeneration == generation, !Task.isCancelled else { return }
            let uniqueShorts = uniqueByID(resp.shorts)
            shorts = uniqueShorts
            nextCursor = resp.nextCursor
            currentID = uniqueShorts.first?.id
            emptyReason = uniqueShorts.isEmpty ? (resp.reason ?? "empty") : nil
            saveRootFeedSessionIfNeeded()
        } catch {
            guard feedGeneration == generation, !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func prioritizeInitialShort(in items: [Short]) -> [Short] {
        guard let initialShortId,
              let index = items.firstIndex(where: { $0.id == initialShortId })
        else { return items }

        return moveShort(at: index, toFrontOf: items)
    }

    private func prioritizeShort(id: String, in items: [Short]) -> [Short] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        return moveShort(at: index, toFrontOf: items)
    }

    private func moveShort(at index: Int, toFrontOf items: [Short]) -> [Short] {
        var reordered = items
        let selected = reordered.remove(at: index)
        reordered.insert(selected, at: 0)
        return reordered
    }

    private func uniqueByID<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Controlled pager

private struct ShortsPagerView<Content: View>: View {
    let items: [ShortsFeedItem]
    @Binding var currentID: String?
    let isScrollLocked: Bool
    let onApproachingEnd: () -> Void
    let onRefresh: () async -> Void
    let content: (ShortsFeedItem) -> Content

    init(
        items: [ShortsFeedItem],
        currentID: Binding<String?>,
        isScrollLocked: Bool,
        onApproachingEnd: @escaping () -> Void,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder content: @escaping (ShortsFeedItem) -> Content
    ) {
        self.items = items
        self._currentID = currentID
        self.isScrollLocked = isScrollLocked
        self.onApproachingEnd = onApproachingEnd
        self.onRefresh = onRefresh
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            UIKitShortsPager(
                items: items,
                currentID: $currentID,
                isScrollLocked: isScrollLocked,
                pageSize: geo.size,
                onApproachingEnd: onApproachingEnd,
                onRefresh: onRefresh,
                content: content
            )
            .background(Color.black.ignoresSafeArea())
            .onAppear(perform: ensureValidCurrentID)
            .onChange(of: items.map(\.id)) { _, _ in
                ensureValidCurrentID()
            }
        }
    }

    private func ensureValidCurrentID() {
        guard !items.isEmpty else {
            currentID = nil
            return
        }
        if let currentID, items.contains(where: { $0.id == currentID }) {
            notifyIfApproachingEnd(itemID: currentID)
            return
        }
        currentID = items[0].id
        notifyIfApproachingEnd(itemID: items[0].id)
    }

    private func notifyIfApproachingEnd(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if index >= items.count - 2 {
            onApproachingEnd()
        }
    }
}

private struct UIKitShortsPager<Content: View>: UIViewControllerRepresentable {
    let items: [ShortsFeedItem]
    @Binding var currentID: String?
    let isScrollLocked: Bool
    let pageSize: CGSize
    let onApproachingEnd: () -> Void
    let onRefresh: () async -> Void
    let content: (ShortsFeedItem) -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PagerViewController<AnyView> {
        let controller = PagerViewController(rootView: AnyView(pageStack))
        controller.scrollView.delegate = context.coordinator
        controller.scrollView.isPagingEnabled = true
        controller.scrollView.showsVerticalScrollIndicator = false
        controller.scrollView.showsHorizontalScrollIndicator = false
        controller.scrollView.bounces = true
        controller.scrollView.alwaysBounceVertical = true
        controller.scrollView.contentInsetAdjustmentBehavior = .never
        controller.scrollView.decelerationRate = .fast
        controller.scrollView.backgroundColor = .black
        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = .white
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        controller.scrollView.refreshControl = refreshControl
        controller.updateContentHeight(pageSize.height * CGFloat(items.count))
        return controller
    }

    func updateUIViewController(_ controller: PagerViewController<AnyView>, context: Context) {
        context.coordinator.parent = self
        controller.hostingController.rootView = AnyView(pageStack)
        controller.updateContentHeight(pageSize.height * CGFloat(items.count))

        let isSettled = !controller.scrollView.isTracking
            && !controller.scrollView.isDragging
            && !controller.scrollView.isDecelerating
        controller.scrollView.isScrollEnabled = !isScrollLocked || !isSettled

        if isSettled {
            scrollToCurrent(in: controller, animated: false)
        }
    }

    private var pageStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if shouldMaterializePage(at: index) {
                    content(item)
                        .frame(width: pageSize.width, height: pageSize.height)
                } else {
                    Color.black
                        .frame(width: pageSize.width, height: pageSize.height)
                }
            }
        }
        .frame(width: pageSize.width, alignment: .top)
    }

    private func shouldMaterializePage(at index: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let activeIndex = currentID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        return abs(index - activeIndex) <= 2
    }

    private func scrollToCurrent(in controller: PagerViewController<AnyView>, animated: Bool) {
        guard pageSize.height > 0,
              let currentID,
              let index = items.firstIndex(where: { $0.id == currentID }) else { return }
        let targetY = CGFloat(index) * pageSize.height
        if abs(controller.scrollView.contentOffset.y - targetY) > 0.5 {
            controller.scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        }
        notifyIfApproachingEnd(index: index)
    }

    private func notifyIfApproachingEnd(index: Int) {
        if index >= items.count - 2 {
            onApproachingEnd()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: UIKitShortsPager
        private var refreshTask: Task<Void, Never>?

        init(_ parent: UIKitShortsPager) {
            self.parent = parent
        }

        deinit {
            refreshTask?.cancel()
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            guard refreshTask == nil else { return }
            refreshTask = Task { [weak self, weak sender] in
                guard let self else { return }
                await parent.onRefresh()
                await MainActor.run {
                    sender?.endRefreshing()
                    self.refreshTask = nil
                }
            }
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard parent.pageSize.height > 0, !parent.items.isEmpty else { return }
            guard targetContentOffset.pointee.y >= 0 else { return }
            let rawIndex = targetContentOffset.pointee.y / parent.pageSize.height
            let index = min(max(Int(round(rawIndex)), 0), parent.items.count - 1)
            targetContentOffset.pointee.y = CGFloat(index) * parent.pageSize.height
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                updateCurrentID(from: scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateCurrentID(from: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            updateCurrentID(from: scrollView)
        }

        private func updateCurrentID(from scrollView: UIScrollView) {
            guard parent.pageSize.height > 0, !parent.items.isEmpty else { return }
            let rawIndex = max(0, scrollView.contentOffset.y) / parent.pageSize.height
            let index = min(max(Int(round(rawIndex)), 0), parent.items.count - 1)
            updateCurrentID(index: index)
        }

        private func updateCurrentID(index: Int) {
            guard parent.items.indices.contains(index) else { return }
            let id = parent.items[index].id
            if parent.currentID != id {
                parent.currentID = id
            }
            parent.notifyIfApproachingEnd(index: index)
        }
    }
}

private final class PagerViewController<Content: View>: UIViewController {
    let scrollView = UIScrollView()
    let hostingController: UIHostingController<Content>
    private var contentHeightConstraint: NSLayoutConstraint?

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .black

        view.addSubview(scrollView)
        addChild(hostingController)
        scrollView.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        let contentHeightConstraint = hostingController.view.heightAnchor.constraint(equalToConstant: 0)
        self.contentHeightConstraint = contentHeightConstraint

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentHeightConstraint
        ])
    }

    func updateContentHeight(_ height: CGFloat) {
        let resolvedHeight = max(0, height)
        guard let contentHeightConstraint,
              abs(contentHeightConstraint.constant - resolvedHeight) > 0.5 else { return }
        contentHeightConstraint.constant = resolvedHeight
    }
}

// MARK: - ShortCardView

private struct ShortCardView: View {

    let short:    Short
    let isActive: Bool
    let shouldPrepare: Bool
    @Binding var isMuted: Bool
    @ObservedObject var playbackManager: ShortsPlaybackManager
    let onPlaylistShortSelected: (Short) -> Void

    @State private var isFollowing:     Bool     = false
    @State private var isLiked:         Bool     = false
    @State private var isDisliked:      Bool     = false
    @State private var isBookmarked:    Bool     = false
    @State private var likeCount:       Int
    @State private var showEnergy:      Bool     = false
    @State private var energyAggregate: ContentEnergyAggregate?
    @State private var isPaused:        Bool     = false
    @State private var showPauseIcon:   Bool     = false
    @State private var heartBursts:     [HeartBurst] = []
    @State private var descExpanded:    Bool     = false
    @State private var showComments:    Bool     = false
    @State private var progress:        Double   = 0
    @State private var isPlayerReady:   Bool     = false
    @State private var lastTap:         Date     = .distantPast
    @State private var progressTimer:   Timer?
    @State private var showSaveSheet:   Bool     = false
    @State private var showEchoSheet:   Bool     = false
    @State private var playlist: VideoPlaylist?
    @State private var isLoadingPlaylist = false
    @State private var showPlaylistPage = false

    @EnvironmentObject private var auth: AuthManager

    init(
        short: Short,
        isActive: Bool,
        shouldPrepare: Bool,
        isMuted: Binding<Bool>,
        playbackManager: ShortsPlaybackManager,
        onPlaylistShortSelected: @escaping (Short) -> Void
    ) {
        self.short    = short
        self.isActive = isActive
        self.shouldPrepare = shouldPrepare
        self._isMuted = isMuted
        self.playbackManager = playbackManager
        self.onPlaylistShortSelected = onPlaylistShortSelected
        self._likeCount = State(initialValue: short.likes)
    }

    private struct HeartBurst: Identifiable {
        let id   = UUID()
        var show = true
    }

    // Owner info
    private var ownerName:   String { short.channel?.name ?? short.channel?.handle ?? "unknown" }
    private var ownerHandle: String { short.channel?.handle ?? short.channel?.name ?? "unknown" }
    private var ownerAvatar: String? { short.channel?.avatarUrl }
    private var channelNav:  AppRoute? {
        if let h = short.channel?.handle { return .channel(h) }
        return nil
    }

    private var player: AVPlayer? {
        playbackManager.player(for: short.id)
    }

    private var isVideoPrewarmed: Bool {
        player != nil
    }

    private var serverAdPresentation: ShortsServerAdPresentation? {
        playbackManager.serverAdPresentations[short.id]
    }

    private var tabBarClearance: CGFloat { C.bottomMenuClearance }
    // The floating menu extends above its general content-clearance baseline.
    // Reserve the menu's top lip as well so the complete scrubber stays visible.
    private var progressBottomClearance: CGFloat { tabBarClearance + 24 }
    private var playerHorizontalInset: CGFloat { 24 }
    private var progressControlHeight: CGFloat { 16 }
    private var playerVerticalGap: CGFloat { 12 }
    private var metadataBottomClearance: CGFloat {
        progressBottomClearance + progressControlHeight + playerVerticalGap
    }
    private var actionRailWidth: CGFloat { 58 }
    private var actionRailGap: CGFloat { 12 }
    private var metadataTrailingInset: CGFloat { actionRailWidth + actionRailGap }
    private var progressBarHorizontalInset: CGFloat { playerHorizontalInset }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                cardContent(size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .task {
            if shouldPrepare {
                setupPlayer(autoplay: isActive)
            }
            guard isActive else { return }
            await loadFollowStatus()
            await loadPlaylistIfNeeded()
            energyAggregate = try? await APIClient.shared
                .fetchContentEnergy(contentPath: "videos", id: short.id)
                .aggregate
        }
        .onDisappear {
            teardownPlayer()
            postCommentsOverlayVisibility(false)
        }
        .onChange(of: showComments) { _, isShown in
            postCommentsOverlayVisibility(isShown)
        }
        .onChange(of: isActive) { _, active in
            if active {
                setupPlayer(autoplay: true)
                Task {
                    await loadFollowStatus()
                    await loadPlaylistIfNeeded()
                }
                resumePlay()
            } else {
                player?.pause()
                progressTimer?.invalidate()
                progressTimer = nil
                showPlaylistPage = false
                isPlayerReady = false
                if !shouldPrepare {
                    teardownPlayer()
                }
            }
        }
        .onChange(of: shouldPrepare) { _, prepare in
            if prepare {
                setupPlayer(autoplay: isActive)
            } else if !isActive {
                teardownPlayer()
            }
        }
        .onChange(of: isVideoPrewarmed) { _, isPrepared in
            guard isPrepared, isActive else { return }
            resumePlay()
        }
        .onChange(of: isMuted) { _, muted in playbackManager.setMuted(muted) }
        .sheet(isPresented: $showSaveSheet) {
            SaveToCollectionSheet(videoId: short.id, targetKind: .short)
        }
        .sheet(isPresented: $showEchoSheet) {
            EchoVibeSheet(
                content: .video(
                    id: short.id,
                    title: short.title,
                    thumbnailURL: short.thumbnailUrl,
                    isShort: true
                )
            )
        }
        .sheet(isPresented: $showComments) {
            StandardCommentsSheet(target: .video(short.id), autoFocusComposer: true) {
                showComments = false
            }
            .id(short.id)
        }
        .sheet(isPresented: $showEnergy) {
            ContentEnergySheet(kind: .video, contentID: short.id) {
                energyAggregate = $0
            }
            .presentationDetents([.height(610), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    private func cardContent(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            Color.black

            // ── Poster + AVPlayer ──────────────────────────────────────────
            if !isVideoPrewarmed, let url = C.mediaURL(short.thumbnailUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: size
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.black }
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            if let p = player {
                ShortPlayerView(player: p)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .opacity(isPlayerReady || isVideoPrewarmed ? 1 : 0)
            }

            // ── Tap gesture layer ──────────────────────────────────────────
            if serverAdPresentation == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { handleDoubleTap() }
                    .onTapGesture(count: 1) { handleSingleTap() }
            }

            // ── Heart bursts ───────────────────────────────────────────────
            ForEach(heartBursts) { _ in
                HeartBurstView()
                    .frame(width: 88, height: 88)
            }

            // ── Center pause icon ──────────────────────────────────────────
            if serverAdPresentation == nil && (isPaused || showPauseIcon) {
                shortsIcon(
                    name: isPaused ? "play" : "pause",
                    fallback: isPaused ? "play.fill" : "pause.fill"
                )
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.52))
                    .clipShape(Circle())
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Button {
                isMuted.toggle()
            } label: {
                shortsIcon(
                    name: isMuted ? "volume-x" : "volume",
                    fallback: isMuted ? "speaker.slash" : "speaker.wave.2"
                )
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.46))
                    .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
                    .clipShape(Circle())
            }
            .padding(.trailing, 14)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if serverAdPresentation == nil {
                actionColumn
                    .padding(.trailing, playerHorizontalInset)
                    .padding(.bottom, metadataBottomClearance + 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                bottomInfo
                    .padding(.leading, playerHorizontalInset)
                    .padding(.bottom, metadataBottomClearance)
                    .padding(.trailing, playerHorizontalInset + metadataTrailingInset)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)

                shortsProgressBar
                    .padding(.horizontal, progressBarHorizontalInset)
                    .padding(.bottom, progressBottomClearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if let presentation = serverAdPresentation {
                ServerAdOverlay(
                    presentation: presentation,
                    vertical: true,
                    isPaused: playbackManager.serverAdIsPaused(for: short.id),
                    isMuted: isMuted,
                    bottomContentInset: tabBarClearance,
                    progressBottomInset: progressBottomClearance,
                    onTogglePause: { playbackManager.toggleServerAdPause(for: short.id) },
                    onToggleMute: {
                        isMuted.toggle()
                        playbackManager.setServerAdMuted(isMuted, for: short.id)
                    },
                    onSkip: { playbackManager.skipServerAd(for: short.id) },
                    onOpen: { playbackManager.openServerAd(for: short.id) }
                )
                .zIndex(35)
            }

            if showPlaylistPage, let playlist {
                ShortsPlaylistPage(
                    playlist: playlist,
                    currentShort: short,
                    onClose: { showPlaylistPage = false },
                    onSelectPlayableShort: { selectedShort in
                        showPlaylistPage = false
                        onPlaylistShortSelected(selectedShort)
                    }
                )
                .padding(.bottom, tabBarClearance)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(29)
            }
        }
    }

    private func pillarSize(in size: CGSize) -> CGSize {
        let targetRatio: CGFloat = 9.0 / 16.0
        let maxWidth = size.width
        let maxHeight = size.height
        let widthFromHeight = maxHeight * targetRatio

        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        }

        return CGSize(width: maxWidth, height: maxWidth / targetRatio)
    }

    private var shortsProgressBar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                Capsule().fill(C.watch)
                    .frame(width: width * CGFloat(progress.clampedProgress), height: 4)
                Circle()
                    .fill(C.watch)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(x: max(0, width * CGFloat(progress.clampedProgress) - 6))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seekShort(to: Double(value.location.x / width), commit: false)
                    }
                    .onEnded { value in
                        seekShort(to: Double(value.location.x / width), commit: true)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int(progress.clampedProgress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    seekShort(to: progress + 0.05, commit: true)
                case .decrement:
                    seekShort(to: progress - 0.05, commit: true)
                default:
                    break
                }
            }
        }
        .frame(height: progressControlHeight)
    }

    private func seekShort(to rawProgress: Double, commit: Bool) {
        let targetProgress = rawProgress.clampedProgress
        progress = targetProgress
        guard commit, let p = player, let item = p.currentItem else { return }
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let target = CMTime(seconds: total * targetProgress, preferredTimescale: 600)
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if isActive, !isPaused {
            p.play()
        }
    }

    // MARK: - Action column

    private var actionColumn: some View {
        return VStack(alignment: .center, spacing: 18) {
            // Energy is the single universal content reaction.
            actionBtn(
                assetIcon: "energy",
                fallbackIcon: "bolt.fill",
                color: C.watch,
                bgColor: C.watch.opacity(0.28),
                label: {
                    if let count = energyAggregate?.count, count > 0 {
                        return fmtCount(count)
                    }
                    return "Add Energy"
                }(),
                labelColor: .white.opacity(0.9)
            ) {
                if auth.isAuthenticated {
                    showEnergy = true
                } else {
                    NotificationCenter.default.post(name: .profileTabRequested, object: nil)
                }
            }

            // Comment
            actionBtn(assetIcon: "message-square", fallbackIcon: "bubble.left", color: .white, bgColor: .black.opacity(0.35), label: nil) {
                showComments = true
            }

            actionBtn(
                assetIcon: "echo",
                fallbackIcon: "dot.radiowaves.left.and.right",
                color: .white,
                bgColor: .black.opacity(0.35),
                label: "Echo"
            ) {
                if auth.isAuthenticated {
                    showEchoSheet = true
                } else {
                    NotificationCenter.default.post(name: .profileTabRequested, object: nil)
                }
            }

            // Share
            actionBtn(assetIcon: "share", fallbackIcon: "square.and.arrow.up", color: .white, bgColor: .black.opacity(0.35), label: "Share") {
                shareShort()
            }

            // Bookmark / Save — matches web IcBookmark
            actionBtn(
                assetIcon: "bookmark",
                fallbackIcon: isBookmarked ? "bookmark.fill" : "bookmark",
                color:   isBookmarked ? C.watch : .white,
                bgColor: isBookmarked ? C.watch.opacity(0.30) : .black.opacity(0.35),
                label:   "Save",
                labelColor: isBookmarked ? C.watch : .white.opacity(0.85)
            ) {
                showSaveSheet = true
                isBookmarked = true
            }
        }
    }

    private func actionBtn(
        assetIcon: String,
        fallbackIcon: String,
        color: Color,
        bgColor: Color,
        label: String?,
        labelColor: Color = .white.opacity(0.85),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                shortsIcon(name: assetIcon, fallback: fallbackIcon)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(color)
                    .frame(width: 50, height: 50)
                    .background(bgColor)
                    .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
                    .clipShape(Circle())
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(labelColor)
                }
            }
        }
    }

    private func shortsIcon(name: String, fallback: String) -> some View {
        MediaverseIcon(name: name, fallbackSystemName: fallback)
    }

    // MARK: - Bottom info

    private var bottomInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 9) {
                Group {
                    if let nav = channelNav {
                        NavigationLink(value: nav) { avatarView }
                    } else {
                        avatarView
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(ownerName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                    Text("@\(ownerHandle)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                if short.channel != nil, !isFollowing {
                    Button {
                        Task { await toggleFollow() }
                    } label: {
                        Text("Follow")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(C.watch)
                            .padding(.horizontal, 11)
                            .frame(height: 27)
                            .overlay { Capsule().stroke(C.watch, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            Text(short.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .lineSpacing(2)
                .shadow(color: .black.opacity(0.9), radius: 3)

            if let desc = short.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(descExpanded ? nil : 2)
                    if desc.count > 80 {
                        Button {
                            withAnimation { descExpanded.toggle() }
                        } label: {
                            Text(descExpanded ? "less" : "more")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                    }
                }
            }

            if let aggregate = energyAggregate, aggregate.count > 0 {
                Button {
                    if auth.isAuthenticated {
                        showEnergy = true
                    } else {
                        NotificationCenter.default.post(name: .profileTabRequested, object: nil)
                    }
                } label: {
                    SocialEnergyMeter(
                        total: Int(((aggregate.avg ?? 0) * Double(aggregate.count)).rounded()),
                        count: aggregate.count,
                        tags: aggregate.topTags
                    )
                    .frame(maxWidth: 270, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View Short Energy")
            }

            if let playlist {
                playlistBar(playlist)
            }

            if let clip = short.linkedClip {
                linkedBanner(
                    label: "Watch full clip",
                    title: clip.title,
                    thumbnail: clip.thumbnailUrl,
                    destination: clip.id,
                    isEpisode: false
                )
            }

            if let ep = short.linkedEpisode {
                linkedBanner(
                    label: "Watch episode",
                    title: ep.title,
                    thumbnail: ep.thumbnailUrl,
                    destination: ep.id,
                    isEpisode: true,
                    subtitle: ep.season.map { "S\($0.seasonNumber)" }
                )
            }

        }
        .frame(maxWidth: 392 - (playerHorizontalInset * 2) - metadataTrailingInset, alignment: .leading)
    }

    private func playlistBar(_ playlist: VideoPlaylist) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showPlaylistPage = true
            }
        } label: {
            HStack(spacing: 8) {
                MediaverseIcon(name: "playlist", fallbackSystemName: "list.bullet")
                    .frame(width: 15, height: 15)
                    .foregroundStyle(C.watch)
                Text("Playlist")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                Text("·")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(playlist.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(playlistPositionText(playlist))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                MediaverseIcon(name: "chevron-up", fallbackSystemName: "chevron.up")
                    .frame(width: 10, height: 10)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func playlistPositionText(_ playlist: VideoPlaylist) -> String {
        guard let index = playlist.items.firstIndex(where: { $0.id == short.id }) else {
            return "\(playlist.items.count)"
        }
        return "\(index + 1) / \(playlist.items.count)"
    }

    private var avatarView: some View {
        Group {
            if let url = C.mediaURL(ownerAvatar) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 34, height: 34)
                ) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.12) }
            } else {
                Text(String((ownerName.first ?? "?").uppercased()))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.watch)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.55), lineWidth: 2) }
    }

    private func linkedBanner(label: String, title: String, thumbnail: String?, destination: String, isEpisode: Bool, subtitle: String? = nil) -> some View {
        NavigationLink(value: isEpisode ? AppRoute.episode(destination) : AppRoute.video(destination)) {
            HStack(spacing: 8) {
                // Thumbnail
                Group {
                    if let url = C.mediaURL(thumbnail) {
                        CachedRemoteImage(
                            url: url,
                            targetSize: CGSize(width: 48, height: 27)
                        ) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(C.watch)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer()
                MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                    .frame(width: 10, height: 10)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10).padding(.vertical, 6).padding(.leading, 6)
            .background(.black.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Player lifecycle

    @MainActor
    private func setupPlayer(autoplay: Bool) {
        guard shouldPrepare || isActive else { return }
        playbackManager.prepare(short, isMuted: isMuted, userId: auth.currentUser?.id)
        if autoplay && isActive {
            resumePlay()
        }
    }

    @MainActor
    private func teardownPlayer() {
        progressTimer?.invalidate()
        progressTimer = nil
        if !shouldPrepare && !isActive {
            playbackManager.release(short.id)
        }
        progress = 0
    }

    @MainActor
    private func resumePlay() {
        playbackManager.activate(short.id)
        isPaused = false
        startProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard isActive, let p = player, let item = p.currentItem else { return }
            if item.status == .readyToPlay || p.timeControlStatus == .playing {
                isPlayerReady = true
            }
            let current = p.currentTime().seconds
            let total = item.duration.seconds
            if current.isFinite, total.isFinite, total > 0 {
                progress = (current / total).clampedProgress
            }
        }
    }

    // MARK: - Gestures

    private func handleSingleTap() {
        guard let p = player else { return }
        if p.rate > 0 {
            p.pause()
            isPaused = true
        } else {
            p.play()
            isPaused = false
        }
    }

    private func handleDoubleTap() {
        if auth.isAuthenticated {
            showEnergy = true
        } else {
            NotificationCenter.default.post(name: .profileTabRequested, object: nil)
        }
    }

    // MARK: - Actions

    private func handleLike(force: Bool = false) async {
        let wasLiked    = isLiked
        let wasDisliked = isDisliked
        // Optimistic
        let nextLiked = force ? true : !wasLiked
        isLiked    = nextLiked
        if nextLiked && wasDisliked { isDisliked = false }
        let likeDelta = nextLiked == wasLiked ? 0 : (nextLiked ? 1 : -1)
        likeCount = max(0, likeCount + likeDelta)
        let type = nextLiked ? "like" : "remove"
        do {
            let result = try await APIClient.shared.likeVideo(videoId: short.id, type: type)
            likeCount = result.likes
            isLiked   = result.userLike == "like"
        } catch {
            // Revert
            isLiked    = wasLiked
            isDisliked = wasDisliked
            likeCount = max(0, likeCount - likeDelta)
        }
    }

    private func handleDislike() async {
        let wasLiked    = isLiked
        let wasDisliked = isDisliked
        let nextDisliked = !wasDisliked
        // Optimistic
        isDisliked = nextDisliked
        if nextDisliked && wasLiked { isLiked = false; likeCount -= 1 }
        let type = nextDisliked ? "dislike" : "remove"
        do {
            let result = try await APIClient.shared.likeVideo(videoId: short.id, type: type)
            likeCount  = result.likes
            isLiked    = result.userLike == "like"
            isDisliked = result.userLike == "dislike"
        } catch {
            isLiked    = wasLiked
            isDisliked = wasDisliked
            if nextDisliked && wasLiked { likeCount += 1 }
        }
    }

    private func loadFollowStatus() async {
        guard auth.isAuthenticated, let handle = short.channel?.handle, !handle.isEmpty else { return }
        if let status = try? await APIClient.shared.fetchChannelFollowStatus(handle: handle) {
            isFollowing = status.subscribed
        }
    }

    private func toggleFollow() async {
        guard auth.isAuthenticated, let handle = short.channel?.handle, !handle.isEmpty else { return }
        let wasFollowing = isFollowing
        isFollowing.toggle()
        do {
            let result = try await APIClient.shared.toggleChannelFollow(handle: handle)
            isFollowing = result.subscribed
            NotificationCenter.default.post(name: .userFollowChanged, object: nil)
        } catch {
            isFollowing = wasFollowing
        }
    }

    private func shareShort() {
        guard let url = URL(string: "\(C.baseURL)/watch/\(short.id)") else { return }
        let av  = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.presentFromRoot()
    }

    @MainActor
    private func loadPlaylistIfNeeded() async {
        guard isActive, !isLoadingPlaylist, playlist == nil else { return }
        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let response = try await APIClient.shared.fetchVideoPlaylist(videoId: short.id)
            guard isActive,
                  let fetchedPlaylist = response.playlist,
                  !fetchedPlaylist.items.isEmpty else { return }
            playlist = fetchedPlaylist
        } catch {
            playlist = nil
        }
    }

    private func debugAd(_ message: String) {
        #if DEBUG
        print("[Ads][Shorts] \(message)")
        #endif
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct ShortsCurationSlotView: View {
    let listing: AssembledListing
    let onSelect: (ContentItem) -> Void

    private var displayTitle: String {
        let title = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : "Recommended for You"
    }
    private var laneItems: (top: [ContentItem], bottom: [ContentItem]) {
        listing.items.enumerated().reduce(into: (top: [ContentItem](), bottom: [ContentItem]())) { result, pair in
            if pair.offset.isMultiple(of: 2) {
                result.top.append(pair.element)
            } else {
                result.bottom.append(pair.element)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [.black, C.surface.opacity(0.88), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 0)

                    header

                    twoLaneRail(maxWidth: geo.size.width)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, max(42, geo.safeAreaInsets.top + 28))
                .padding(.bottom, max(110, geo.safeAreaInsets.bottom + 96))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                if let badge = listing.badge, !badge.isEmpty {
                    Text(badge.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                        .tracking(1.4)
                }

                Text(displayTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)

                if let sponsoredBy = listing.sponsoredBy, !sponsoredBy.isEmpty {
                    Text("Sponsored by \(sponsoredBy)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.textMuted)
                } else {
                    Text("Picked from what is trending now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.textMuted)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func twoLaneRail(maxWidth: CGFloat) -> some View {
        let lanes = laneItems
        if !listing.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    lane(lanes.top)
                    lane(lanes.bottom)
                }
                .frame(minWidth: max(0, maxWidth - 36), alignment: .center)
                .padding(.horizontal, 18)
            }
            .padding(.horizontal, -18)
        }
    }

    private func lane(_ items: [ContentItem]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    onSelect(item)
                } label: {
                    slotCard(item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slotCard(_ item: ContentItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(item.thumbnailUrl ?? item.coverUrl),
                    targetSize: CGSize(width: 142, height: 252)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 142, height: 252)
                .clipped()

                if let duration = item.metaDouble("duration") {
                    Text(formatDuration(duration))
                        .font(.system(size: 10, weight: .bold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: 142, alignment: .leading)

            if let subtitle = subtitle(for: item) {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                    .frame(width: 142, alignment: .leading)
            }
        }
        .frame(width: 142, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var accent: Color {
        listing.accentColor.map(Color.init(hex:)) ?? C.watch
    }

    private func subtitle(for item: ContentItem) -> String? {
        let type = item.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch type {
        case "short", "video":
            let channel = item.metaString("channelName")
            let views = item.metaInt("views").map { "\(formatCount($0)) views" }
            return [channel, views].compactMap { $0 }.joined(separator: " • ").nilIfEmpty
        case "show":
            let year = item.metaString("productionYear")
            let seasons = item.metaInt("seasons").map { "\($0) season\($0 == 1 ? "" : "s")" }
            return [year, seasons].compactMap { $0 }.joined(separator: " • ").nilIfEmpty
        case "episode":
            var parts = [String]()
            if let season = item.metaInt("seasonNumber"), let episode = item.metaInt("episodeNumber") {
                parts.append("S\(season) E\(episode)")
            }
            if let showTitle = item.metaString("showTitle") {
                parts.append(showTitle)
            }
            return parts.joined(separator: " • ").nilIfEmpty
        case "channel":
            let handle = item.metaString("handle").map { "@\($0)" }
            let followers = item.metaInt("followers").map { "\(formatCount($0)) followers" }
            return [handle, followers].compactMap { $0 }.joined(separator: " • ").nilIfEmpty
        default:
            return nil
        }
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        let minutes = roundedSeconds / 60
        let remainder = roundedSeconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }
}

private struct ShortsAdCardView: View {
    let decision: AdDecision
    let policy: EffectiveAdPolicy
    let contentId: String
    let placement: String
    let adIndex: Int
    let adConfig: PlatformShortsAdsConfig
    let userId: String?
    let isActive: Bool
    let onAdPlaybackChanged: (Bool) -> Void
    let onSwipeUnlocked: () -> Void
    let onAdvance: () -> Void

    @State private var didRecordImpression = false

    private var progressBarHorizontalInset: CGFloat { 12 }
    private var policyAdConfig: PlatformShortsAdsConfig {
        policy.applying(to: adConfig)
    }
    private var placementConfig: PlatformAdPlacementConfig {
        policyAdConfig.placementConfig(for: placement)
    }
    private var effectiveSkippable: Bool? {
        placementConfig.skippable ?? policyAdConfig.skippable
    }
    private var effectiveSkipAfterSec: Int? {
        placementConfig.skipAfterSec ?? policyAdConfig.skipAfterSec
    }
    private var effectiveMaxDurationSec: Int? {
        placementConfig.maxDurationSec ?? policyAdConfig.maxDurationSec ?? policy.pods?.maxAdDurationSec
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = ShortsAdLayoutClearance.top(safeAreaTop: proxy.safeAreaInsets.top)
            let bottomInset = ShortsAdLayoutClearance.bottom(
                safeAreaBottom: proxy.safeAreaInsets.bottom,
                controlClearance: C.bottomMenuClearance
            )

            ZStack {
                Color.black.ignoresSafeArea()

                if isActive {
                    NativeAdPlayerView(
                        decision: decision,
                        contentId: contentId,
                        placement: placement,
                        userId: userId,
                        aspectRatio: 9 / 16,
                        topContentInset: topInset,
                        bottomContentInset: bottomInset,
                        progressHorizontalInset: progressBarHorizontalInset,
                        progressBottomInset: 0,
                        fillVerticalContainer: true,
                        adPolicy: policy,
                        adRemoval: policy.adRemoval,
                        overrideSkippable: effectiveSkippable,
                        overrideSkipAfterSec: effectiveSkipAfterSec,
                        onImpression: {
                            recordImpressionIfNeeded()
                        },
                        onCanSkipChanged: { canSkip in
                            if canSkip {
                                onSwipeUnlocked()
                            }
                        }
                    ) {
                        finishAd()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                onAdPlaybackChanged(true)
            } else {
                onAdPlaybackChanged(false)
            }
        }
        .onAppear {
            if isActive {
                onAdPlaybackChanged(true)
            }
        }
        .onDisappear {
            onAdPlaybackChanged(false)
        }
    }

    @MainActor
    private func finishAd() {
        onAdPlaybackChanged(false)
        onAdvance()
    }

    private func recordImpressionIfNeeded() {
        guard !didRecordImpression else { return }
        didRecordImpression = true
        ShortsAdFrequencyStore.record(
            placement: placement,
            userId: userId,
            cap: placementConfig.frequencyPerUserPerDay
        )
    }
}

private extension Double {
    var clampedProgress: Double {
        guard isFinite else { return 0 }
        return min(max(self, 0), 1)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - HeartBurst animation

private struct HeartBurstView: View {
    @State private var scale:   CGFloat = 0
    @State private var opacity: Double  = 1
    @State private var offsetY: CGFloat = 0

    var body: some View {
        MediaverseIcon(name: "heart-filled", fallbackSystemName: "heart.fill")
            .frame(width: 88, height: 88)
            .foregroundStyle(Color(red: 1, green: 0.28, blue: 0.34))
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(y: offsetY)
            .onAppear {
                withAnimation(.spring(duration: 0.45)) { scale = 1.9; offsetY = -30 }
                withAnimation(.easeOut(duration: 0.45).delay(0.45)) { opacity = 0; scale = 1.1; offsetY = -85 }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - ShortPlayerView (AVKit bridge)

@MainActor
private struct ShortPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        var player: AVPlayer? {
            get { playerLayer?.player }
            set {
                playerLayer?.player = newValue
                playerLayer?.videoGravity = .resizeAspectFill
            }
        }
    }
}

// MARK: - Shorts playlist page

private struct ShortsPlaylistPage: View {
    let playlist: VideoPlaylist
    let currentShort: Short
    let onClose: () -> Void
    let onSelectPlayableShort: (Short) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                        playlistRow(item, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
        .overlay(alignment: .top) {
            LinearGradient(colors: [C.watch.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PlatformBackButton(action: onClose)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlist")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(C.watch)
                    Text(playlist.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(playlist.items.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.white.opacity(0.09), in: Capsule())
            }

            Text("Choose a short to continue in the Shorts player.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(C.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func playlistRow(_ item: VideoPlaylistItem, index: Int) -> some View {
        if let playableShort = item.playableShort(fallback: currentShort) {
            Button {
                onSelectPlayableShort(playableShort)
            } label: {
                rowContent(item, index: index)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.short(item.id, showId: currentShort.showId, channelId: currentShort.channelId)) {
                rowContent(item, index: index)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { onClose() })
        }
    }

    private func rowContent(_ item: VideoPlaylistItem, index: Int) -> some View {
        let isCurrent = item.id == currentShort.id
        return HStack(spacing: 11) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isCurrent ? C.watch : C.textMuted)
                .frame(width: 24)

            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let url = C.mediaURL(item.thumbnailUrl) {
                        CachedRemoteImage(
                            url: url,
                            targetSize: CGSize(width: 96, height: 54)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                if let duration = item.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(isCurrent ? "Now playing" : "Play in Shorts")
                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? C.watch : C.textMuted)
            }

            Spacer(minLength: 8)

            MediaverseIcon(
                name: isCurrent ? "check" : "play",
                fallbackSystemName: isCurrent ? "checkmark" : "play.fill"
            )
            .frame(width: isCurrent ? 14 : 13, height: isCurrent ? 14 : 13)
            .foregroundStyle(isCurrent ? C.watch : .white.opacity(0.55))
        }
        .padding(11)
        .background(isCurrent ? C.watch.opacity(0.12) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isCurrent ? C.watch.opacity(0.42) : .white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: Double) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        let minutes = roundedSeconds / 60
        let remainder = roundedSeconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }
}

private extension VideoPlaylistItem {
    func playableShort(fallback: Short) -> Short? {
        guard let videoUrl, !videoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Short(
            id: id,
            title: title,
            description: description ?? fallback.description,
            videoUrl: videoUrl,
            thumbnailUrl: thumbnailUrl ?? fallback.thumbnailUrl,
            views: views ?? 0,
            likes: likes ?? 0,
            duration: duration,
            channelId: channelId ?? fallback.channelId,
            showId: showId ?? fallback.showId,
            channel: channel ?? fallback.channel,
            linkedClipId: linkedClipId,
            linkedEpisodeId: linkedEpisodeId,
            linkedClip: linkedClip,
            linkedEpisode: linkedEpisode
        )
    }
}

private func postCommentsOverlayVisibility(_ isVisible: Bool) {
    NotificationCenter.default.post(name: .commentsOverlayVisibilityChanged, object: isVisible)
}

private func postShortsAdPlaybackVisibility(_ isVisible: Bool) {
    NotificationCenter.default.post(name: .shortsAdPlaybackVisibilityChanged, object: isVisible)
}

private func postRoutedShortsVisibility(_ isVisible: Bool) {
    NotificationCenter.default.post(name: .routedShortsVisibilityChanged, object: isVisible)
}
