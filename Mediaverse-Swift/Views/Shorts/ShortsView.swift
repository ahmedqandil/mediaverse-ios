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

private struct InitialShortsPrewarm: Codable {
    let seed: String
    let response: ShortsResponse
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
        guard let cap else { return true }
        guard cap > 0 else { return false }
        return UserDefaults.standard.integer(forKey: storageKey(for: placement, userId: userId)) < cap
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
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var initialPrewarmTask: Task<Void, Never>?
    private var initialPrewarmPayload: (seed: String, response: ShortsResponse)?
    private var initialPrewarmScope: String?
    private var failedWarmIDs: [String: Date] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var endObservers: [String: NSObjectProtocol] = [:]
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
            if let cached: InitialShortsPrewarm = try? await DiskJSONCache.shared.value(forKey: cacheKey) {
                self?.storeInitialPrewarm(
                    seed: cached.seed,
                    response: cached.response,
                    isMuted: isMuted,
                    cacheKey: cacheKey,
                    userId: userId
                )
                return
            }

            let seed = UUID().uuidString
            do {
                let response = try await APIClient.shared.fetchShorts(
                    feed: ShortsFeed.forYou.rawValue,
                    limit: 10,
                    seed: seed
                )
                try? await DiskJSONCache.shared.store(
                    InitialShortsPrewarm(seed: seed, response: response),
                    forKey: cacheKey,
                    ttl: 300
                )
                self?.storeInitialPrewarm(
                    seed: seed,
                    response: response,
                    isMuted: isMuted,
                    cacheKey: cacheKey,
                    userId: userId
                )
            } catch {
                if let stale: InitialShortsPrewarm = try? await DiskJSONCache.shared.staleValue(forKey: cacheKey) {
                    self?.storeInitialPrewarm(
                        seed: stale.seed,
                        response: stale.response,
                        isMuted: isMuted,
                        cacheKey: cacheKey,
                        userId: userId
                    )
                } else {
                    self?.clearInitialPrewarmTask(cacheKey: cacheKey)
                }
            }
        }
    }

    func takePreparedInitialFeedIfAvailable(
        isMuted: Bool,
        userId: String?,
        context: String?
    ) async -> (seed: String, response: ShortsResponse)? {
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
    ) async -> (seed: String, response: ShortsResponse)? {
        let cacheKey = ShortsFeedCacheScope.initialFeedKey(userId: userId, context: context)
        prewarmInitialFeed(isMuted: isMuted, userId: userId, context: context)
        if let payload = takeReadyInitialFeed() {
            return payload
        }

        if let initialPrewarmTask {
            await initialPrewarmTask.value
            if let payload = takeReadyInitialFeed() {
                return payload
            }
        }

        guard let cached: InitialShortsPrewarm = try? await DiskJSONCache.shared.value(forKey: cacheKey) else {
            return nil
        }
        storeInitialPrewarm(
            seed: cached.seed,
            response: cached.response,
            isMuted: isMuted,
            cacheKey: cacheKey,
            userId: userId
        )
        return takeReadyInitialFeed()
    }

    private func takeReadyInitialFeed() -> (seed: String, response: ShortsResponse)? {
        let payload = initialPrewarmPayload
        initialPrewarmPayload = nil
        return payload
    }

    fileprivate func configure(feedItems: [ShortsFeedItem], currentID: String?, isMuted: Bool) {
        var shortsByID = [String: Short]()
        feedItems.forEach { item in
            if case .short(_, let short) = item {
                shortsByID[short.id] = short
            }
        }

        let preparedIDs = preparedShortIDs(feedItems: feedItems, currentID: currentID)
        preparedIDs.compactMap { shortsByID[$0] }.forEach { prepare($0, isMuted: isMuted) }

        Set(players.keys).subtracting(preparedIDs).forEach(releasePlayer)
        Set(assetCache.keys).subtracting(preparedIDs).forEach(releaseWarmState)
        players.values.forEach { $0.isMuted = isMuted }

        if let currentID, shortsByID[currentID] != nil {
            activate(currentID)
        } else {
            pauseActive()
        }
    }

    func prepare(_ short: Short, isMuted: Bool) {
        guard let url = C.mediaURL(short.videoUrl), !hasRecentWarmFailure(for: short.id) else { return }
        let asset = cachedAsset(for: short.id, url: url)
        warmAsset(asset, id: short.id)
        guard players[short.id] == nil else { return }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        player.volume = 1
        player.actionAtItemEnd = .none
        var updatedPlayers = players
        updatedPlayers[short.id] = player
        players = updatedPlayers
        CacheMetrics.shared.recordStore(metricsNamespace)

        endObservers[short.id] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player, weak self] _ in
            Task { @MainActor in
                guard let player, let self else { return }
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        if self.activeID == short.id {
                            player.playImmediately(atRate: 1)
                        }
                    }
                }
            }
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

    func cacheInitialFeedForNextSession(
        seed: String,
        response: ShortsResponse,
        userId: String?,
        context: String?
    ) async {
        let cacheKey = ShortsFeedCacheScope.initialFeedKey(userId: userId, context: context)
        try? await DiskJSONCache.shared.store(
            InitialShortsPrewarm(seed: seed, response: response),
            forKey: cacheKey,
            ttl: 300
        )
    }

    private func storeInitialPrewarm(
        seed: String,
        response: ShortsResponse,
        isMuted: Bool,
        cacheKey: String,
        userId: String?
    ) {
        guard initialPrewarmScope == cacheKey else { return }
        initialPrewarmPayload = (seed, response)
        initialPrewarmTask = nil
        let feedItems = response.shorts.enumerated().map { index, short in
            ShortsFeedItem.short(index: index, short: short)
        }
        let preparedIDs = preparedShortIDs(feedItems: feedItems, currentID: nil)
        preparedIDs.compactMap { id in response.shorts.first { $0.id == id } }
            .forEach { prepare($0, isMuted: isMuted) }
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
        if let asset = assetCache[id] {
            CacheMetrics.shared.recordHit(metricsNamespace)
            return asset
        }
        CacheMetrics.shared.recordMiss(metricsNamespace)
        let asset = AVURLAsset(url: url)
        assetCache[id] = asset
        CacheMetrics.shared.recordStore(metricsNamespace)
        return asset
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
        if let observer = endObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
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
    @State private var feedRevalidationTask: Task<Void, Never>?
    @State private var feedGeneration = UUID()
    @State private var skippedShortsAdItemIds = Set<String>()
    @State private var pendingShortsAdItemIds = Set<String>()
    @State private var filledShortsAdDecisions = [String: AdDecision]()
    @State private var filledShortsAdPolicies = [String: EffectiveAdPolicy]()
    @State private var shortsAdIdentityGeneration = UUID()
    @State private var shortsAdConfig: PlatformShortsAdsConfig = .default
    @State private var shortsFeedListings = [AssembledListing]()
    @StateObject private var playbackManager: ShortsPlaybackManager
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var shouldLoadInitialShorts: Bool {
        isRootActive || initialShortId != nil || contextShowId != nil || contextChannelId != nil || showsDismissControls
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
        .onChange(of: platformConfig.isLoaded) { _, _ in
            loadShortsAdConfig()
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
        HStack(spacing: 8) {
            ForEach(ShortsFeed.allCases, id: \.self) { tab in
                Button {
                    Task { await switchFeed(tab) }
                } label: {
                    Text(tab.label)
                        .font(.system(size: 14, weight: feed == tab ? .bold : .semibold))
                        .foregroundStyle(feed == tab ? .black : .white.opacity(0.78))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(feed == tab ? C.watch : Color.black.opacity(0.42), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(feed == tab ? C.watch.opacity(0.4) : Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .zIndex(40)
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
        playbackManager.configure(feedItems: feedItems, currentID: playbackID, isMuted: isMuted)
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
        guard let currentShortIndex = currentShortIndexForAdPrefetch() else { return }
        let candidates = ShortsFeedAssembler.adCandidates(
            shorts: shorts,
            shortsAdConfig: shortsAdConfig,
            afterShortIndex: currentShortIndex,
            lookahead: 3
        )

        for candidate in candidates {
            guard shouldRequestShortsAd(at: candidate.afterIndex, placement: candidate.placement, adConfig: candidate.adConfig),
                  !skippedShortsAdItemIds.contains(candidate.id),
                  filledShortsAdDecisions[candidate.id] == nil,
                  !pendingShortsAdItemIds.contains(candidate.id) else { continue }

            pendingShortsAdItemIds.insert(candidate.id)
            Task { await prefetchShortsAd(candidate) }
        }
    }

    @MainActor
    private func prefetchShortsAd(_ candidate: ShortsAdCandidate) async {
        let identityGeneration = shortsAdIdentityGeneration
        defer {
            if identityGeneration == shortsAdIdentityGeneration {
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

        guard identityGeneration == shortsAdIdentityGeneration,
              requestUserId == auth.currentUser?.id else { return }
        guard let decision, decision.filled, !decision.ads.isEmpty else {
            skippedShortsAdItemIds.insert(candidate.id)
            return
        }

        filledShortsAdDecisions[candidate.id] = decision
        filledShortsAdPolicies[candidate.id] = policy
    }

    private func advanceAfterAd(itemId: String) {
        guard adLockedItemId == nil || adLockedItemId == itemId,
              let index = feedItems.firstIndex(where: { $0.id == itemId }) else { return }

        adLockedItemId = nil
        postShortsAdPlaybackVisibility(false)

        if feedItems.indices.contains(index + 1) {
            currentID = feedItems[index + 1].id
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
        guard config.enabled else { return false }
        let placementConfig = config.placementConfig(for: placement)
        guard placementConfig.enabled else { return false }
        guard ShortsAdFrequencyStore.canShow(
            placement: placement,
            userId: auth.currentUser?.id,
            cap: placementConfig.frequencyPerUserPerDay
        ) else {
            return false
        }

        if placement == "shorts_first_view" {
            return index == 0
        }

        guard config.cadenceKind == "count", config.cadenceValue > 0 else { return false }
        let viewedCount = index + 1
        guard viewedCount > config.firstAfter else { return false }
        let firstAdPosition = config.firstAfter + 1
        return viewedCount == firstAdPosition || (viewedCount - firstAdPosition).isMultiple(of: config.cadenceValue)
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
        Button {
            dismiss()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.46))
                    .overlay {
                        Circle().stroke(.white.opacity(0.16), lineWidth: 1)
                    }

                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
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
        feedRevalidationTask?.cancel()
        feedRevalidationTask = nil
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
        shortsAdConfig = platformConfig.config.ads.shorts
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
        let restoredCachedSession = !replacingExisting && restoreRootFeedSessionIfNeeded()
        if restoredCachedSession || (!replacingExisting && !shorts.isEmpty) {
            ensureInitialShortSelection()
            configurePlayback(ensureAutoplay: true)
            recordShortViewIfNeeded(itemID: currentID)
            if restoredCachedSession {
                scheduleCachedFeedRevalidation()
            }
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
                    ids: requestedShortIds
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
            if prewarmedFeed != nil {
                scheduleCachedFeedRevalidation()
            }
        } catch {
            guard feedGeneration == generation, !Task.isCancelled else { return }
            if replacingExisting {
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

    private func scheduleCachedFeedRevalidation() {
        guard canPersistRootFeedSession, feedRevalidationTask == nil else { return }
        let generation = feedGeneration
        let requestedFeed = feed
        let requestedSeed = feedSessionSeed
        let requestedIDs = feedSessionIDs
        let requestedUserId = auth.currentUser?.id
        let requestedContext = SessionStorage.activeContextCookieValue
        feedRevalidationTask = Task {
            defer {
                if feedGeneration == generation {
                    feedRevalidationTask = nil
                }
            }
            do {
                let refreshed = try await APIClient.shared.fetchShorts(
                    feed: requestedFeed.rawValue,
                    limit: requestedIDs.map { min(30, max(10, $0.count + 10)) } ?? 10,
                    seed: requestedSeed,
                    ids: requestedIDs,
                    forceRefresh: true
                )
                guard !Task.isCancelled,
                      feedGeneration == generation,
                      feed == requestedFeed,
                      feedSessionSeed == requestedSeed else { return }
                let refreshedShorts = uniqueByID(refreshed.shorts)
                guard !refreshedShorts.isEmpty else { return }
                let reconciliation = ShortsFeedReconciliation.reconcile(
                    visible: shorts,
                    fresh: refreshedShorts,
                    currentCursor: nextCursor,
                    freshCursor: refreshed.nextCursor
                )
                guard reconciliation.shouldApply else {
                    await playbackManager.cacheInitialFeedForNextSession(
                        seed: requestedSeed,
                        response: refreshed,
                        userId: requestedUserId,
                        context: requestedContext
                    )
                    return
                }
                shorts = reconciliation.shorts
                nextCursor = reconciliation.nextCursor
                emptyReason = nil
                paginationError = nil
                saveRootFeedSessionIfNeeded()
                configurePlayback(ensureAutoplay: true)
            } catch {
                // Cached playback remains valid when silent revalidation fails.
            }
        }
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

    private var tabBarClearance: CGFloat { C.bottomMenuClearance }
    private var playerHorizontalInset: CGFloat { 24 }
    private var progressControlHeight: CGFloat { 16 }
    private var playerVerticalGap: CGFloat { 12 }
    private var metadataBottomClearance: CGFloat { tabBarClearance + progressControlHeight + playerVerticalGap }
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
        .sheet(isPresented: $showComments) {
            StandardCommentsSheet(target: .video(short.id), autoFocusComposer: true) {
                showComments = false
            }
            .id(short.id)
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
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { handleDoubleTap() }
                .onTapGesture(count: 1) { handleSingleTap() }

            // ── Heart bursts ───────────────────────────────────────────────
            ForEach(heartBursts) { _ in
                HeartBurstView()
                    .frame(width: 88, height: 88)
            }

            // ── Center pause icon ──────────────────────────────────────────
            if isPaused || showPauseIcon {
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
                .padding(.bottom, tabBarClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

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
        let likeRed = Color(red: 1, green: 0.28, blue: 0.34)
        return VStack(alignment: .center, spacing: 18) {
            // Like
            actionBtn(
                assetIcon:  isLiked ? "heart-filled" : "heart",
                fallbackIcon: isLiked ? "heart.fill" : "heart",
                color:      isLiked ? likeRed : .white,
                bgColor:    isLiked ? likeRed.opacity(0.35) : .black.opacity(0.35),
                label:      likeCount > 0 ? fmtCount(likeCount) : nil,
                labelColor: isLiked ? likeRed : .white.opacity(0.85)
            ) { Task { await handleLike() } }

            // Dislike — matches web IcThumbDown
            actionBtn(
                assetIcon: "thumbs-down",
                fallbackIcon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                color:   isDisliked ? Color(white: 0.67) : .white,
                bgColor: .black.opacity(0.35),
                label:   nil
            ) { Task { await handleDislike() } }

            // Comment
            actionBtn(assetIcon: "message-square", fallbackIcon: "bubble.left", color: .white, bgColor: .black.opacity(0.35), label: nil) {
                showComments = true
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
        playbackManager.prepare(short, isMuted: isMuted)
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
        Task { await handleLike(force: true) }
        // Heart burst animation
        let burst = HeartBurst()
        heartBursts.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            heartBursts.removeAll { $0.id == burst.id }
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

    private var adBottomClearance: CGFloat { 96 }
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
        ZStack {
            Color.black.ignoresSafeArea()

            if isActive {
                NativeAdPlayerView(
                    decision: decision,
                    contentId: contentId,
                    placement: placement,
                    userId: userId,
                    aspectRatio: 9 / 16,
                    bottomContentInset: adBottomClearance,
                    progressHorizontalInset: progressBarHorizontalInset,
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
                Button(action: onClose) {
                    MediaverseIcon(name: "chevron-left", fallbackSystemName: "chevron.left")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)

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
