import SwiftUI
import AVKit
import AVFoundation

// MARK: - Muted looping video layer (used by hero + feed card previews)

/// AVPlayerLayer-backed UIView that fills its bounds (resizeAspectFill).
/// Use with AVQueuePlayer + AVPlayerLooper for seamless looping.
/// @MainActor required: iOS 26 SDK marks UIViewRepresentable methods as @MainActor.
@MainActor
private struct LoopingVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // Safe cast — UIView guarantees `layerClass` is used during init,
        // but using `as?` prevents any force-cast crash if iOS ever defers that.
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer?.player = player
        v.playerLayer?.videoGravity = .resizeAspectFill
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        guard uiView.playerLayer?.player !== player else { return }
        uiView.playerLayer?.player = player
    }
}

// MARK: - Render item (video or interleaved carousel)

private enum HomeItem: Identifiable {
    case video(FeedVideo)
    case carousel(AssembledListing)

    var id: String {
        switch self {
        case .video(let v):    return "v-\(v.id)"
        case .carousel(let s): return "c-\(s.id)"
        }
    }
}

private extension FeedVideo {
    var homeFeedCardAspectRatio: CGFloat {
        C.mediaAspectRatio(forContentType: type ?? "video")
    }

    func homeFeedCardHeight(for width: CGFloat) -> CGFloat {
        width / homeFeedCardAspectRatio
    }
}

private enum HomeCarouselMetrics {
    static let landscapeWidth: CGFloat = CarouselCardMetrics.landscapeWidth
    static let posterWidth: CGFloat = CarouselCardMetrics.posterWidth

    static func height(width: CGFloat, contentType: String) -> CGFloat {
        CarouselCardMetrics.height(width: width, contentType: contentType)
    }
}

private struct StoryViewerPresentation: Identifiable {
    let id = UUID()
    let groupId: String
}

struct HomeVideoFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FeedPreviewAutoplayPolicy {
    let visibleTop: CGFloat = 96
    let visibleBottom: CGFloat = UIScreen.main.bounds.height - 132
    let minimumCandidateVisibility: CGFloat = 0.40

    var viewportCenter: CGFloat { (visibleTop + visibleBottom) / 2 }
    var viewportHeight: CGFloat { max(visibleBottom - visibleTop, 1) }

    func visibleRatio(for frame: CGRect) -> CGFloat {
        guard frame.maxY > visibleTop, frame.minY < visibleBottom else { return 0 }
        let visibleHeight = max(0, min(frame.maxY, visibleBottom) - max(frame.minY, visibleTop))
        return visibleHeight / max(frame.height, 1)
    }

    func isExitingTop(frame: CGRect) -> Bool {
        frame.minY < visibleTop
    }

    func isInitialTopCandidate(frame: CGRect) -> Bool {
        !isExitingTop(frame: frame) && visibleRatio(for: frame) >= minimumCandidateVisibility && frame.minY <= viewportCenter
    }

    func candidateScore(for frame: CGRect) -> CGFloat? {
        guard !isExitingTop(frame: frame) else { return nil }
        let ratio = visibleRatio(for: frame)
        guard ratio >= minimumCandidateVisibility else { return nil }
        let centerPenalty = abs(frame.midY - viewportCenter) / viewportHeight
        return ratio - centerPenalty * 0.35
    }
}

@MainActor
final class FeedPreviewPlayerManager: ObservableObject {
    @Published private(set) var activeVideoId: String?
    @Published private(set) var isReady = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffered: Double = 0

    private(set) var player = AVPlayer()

    private let backwardWarmCount = 2
    private let forwardWarmCount = 6
    private let initialWarmCount = 7
    private let bottomPrebufferLimit = 2
    private let metricsNamespace = "feed.preview"
    private var currentURL: URL?
    private var assetCache: [String: AVURLAsset] = [:]
    private var prebufferPlayers: [String: AVPlayer] = [:]
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var failedWarmIDs: [String: Date] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var readinessTask: Task<Void, Never>?

    init() {
        configurePreviewPlayer(player)
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
        readinessTask?.cancel()
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        warmTasks.values.forEach { $0.cancel() }
        prebufferPlayers.values.forEach { $0.pause() }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func handoffActivePlayer(for videoId: String, muted: Bool) -> AVPlayer? {
        guard activeVideoId == videoId, player.currentItem != nil else { return nil }
        readinessTask?.cancel()
        readinessTask = nil
        removeEndObserver()
        removeTimelineObserver()

        let handoffPlayer = player
        handoffPlayer.isMuted = muted
        handoffPlayer.volume = 1

        player = AVPlayer()
        configurePreviewPlayer(player)
        currentURL = nil
        activeVideoId = nil
        isReady = false
        resetTimelineState()
        objectWillChange.send()
        return handoffPlayer
    }

    private func configurePreviewPlayer(_ player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        player.volume = 0
    }

    func warm(videos: [FeedVideo], currentID: String?) {
        pruneFailedWarmIDs()
        let preparedIDs = preparedVideoIDs(videos: videos, currentID: currentID)
        var videosByID = [String: FeedVideo]()
        videos.forEach { videosByID[$0.id] = $0 }
        preparedIDs.compactMap { videosByID[$0] }.forEach(warm)
        Set(assetCache.keys).subtracting(preparedIDs).subtracting([activeVideoId].compactMap { $0 }).forEach(releaseWarmState)
    }

    private func warm(_ video: FeedVideo) {
        guard let url = C.mediaURL(video.videoUrl), !hasRecentWarmFailure(for: video.id) else { return }
        let asset = cachedAsset(for: video.id, url: url)
        warmAsset(asset, id: video.id)
    }

    func prebufferBottomCandidates(videos: [FeedVideo], frames: [String: CGRect]) {
        pruneFailedWarmIDs()
        var videosByID = [String: FeedVideo]()
        videos.forEach { videosByID[$0.id] = $0 }

        let policy = FeedPreviewAutoplayPolicy()
        let candidateIDs = frames.compactMap { id, frame -> (id: String, distance: CGFloat)? in
            guard id != activeVideoId,
                  frame.minY >= policy.visibleTop,
                  frame.minY < policy.visibleBottom + 180,
                  frame.maxY > policy.visibleTop,
                  videosByID[id].flatMap({ C.mediaURL($0.videoUrl) }) != nil else { return nil }
            return (id, abs(frame.minY - policy.visibleBottom))
        }
        .sorted { $0.distance < $1.distance }
        .prefix(bottomPrebufferLimit)
        .map(\.id)

        let protectedIDs = Set(candidateIDs).union([activeVideoId].compactMap { $0 })
        candidateIDs.compactMap { videosByID[$0] }.forEach(prebuffer)
        Set(prebufferPlayers.keys).subtracting(protectedIDs).forEach(releasePrebufferPlayer)
    }

    private func prebuffer(_ video: FeedVideo) {
        guard prebufferPlayers[video.id] == nil,
              let url = C.mediaURL(video.videoUrl),
              !hasRecentWarmFailure(for: video.id) else { return }
        let asset = cachedAsset(for: video.id, url: url)
        let item = makePreviewItem(asset: asset)
        warmAsset(asset, id: video.id)

        let prebufferPlayer = AVPlayer(playerItem: item)
        configurePreviewPlayer(prebufferPlayer)
        prebufferPlayer.actionAtItemEnd = .none
        prebufferPlayers[video.id] = prebufferPlayer
        CacheMetrics.shared.recordStore(metricsNamespace)
    }

    func play(videoId: String, url: URL) {
        if currentURL != url || prebufferPlayers[videoId] != nil {
            isReady = false
            readinessTask?.cancel()
            player.pause()
            removeEndObserver()
            removeTimelineObserver()
            player.replaceCurrentItem(with: nil)

            let item: AVPlayerItem
            if let prebufferedPlayer = prebufferPlayers.removeValue(forKey: videoId) {
                CacheMetrics.shared.recordHit(metricsNamespace)
                player = prebufferedPlayer
                configurePreviewPlayer(player)
                item = prebufferedPlayer.currentItem ?? makePreviewItem(asset: cachedAsset(for: videoId, url: url))
                objectWillChange.send()
            } else {
                CacheMetrics.shared.recordMiss(metricsNamespace)
                item = makePreviewItem(asset: cachedAsset(for: videoId, url: url))
                player.replaceCurrentItem(with: item)
            }
            observeReadiness(for: item, videoId: videoId)
            observeEnd(for: item)
            attachTimelineObserver()
            currentURL = url
        } else {
            attachTimelineObserver()
        }

        activeVideoId = videoId
        updateTimelineState()
        isReady = player.currentItem?.status == .readyToPlay
        player.playImmediately(atRate: 1)
    }

    func pauseIfActive(videoId: String) {
        guard activeVideoId == videoId else { return }
        player.pause()
        activeVideoId = nil
    }

    func seekActivePreview(to seconds: Double) {
        guard activeVideoId != nil, duration > 0 else { return }
        let clampedSeconds = min(max(seconds, 0), duration)
        currentTime = clampedSeconds
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, self.activeVideoId != nil else { return }
                self.player.playImmediately(atRate: 1)
                self.updateTimelineState()
            }
        }
    }

    func pausePreservingHandoff() {
        player.pause()
    }

    func pause() {
        player.pause()
        activeVideoId = nil
    }

    func reset() {
        player.pause()
        readinessTask?.cancel()
        readinessTask = nil
        removeEndObserver()
        removeTimelineObserver()
        player.replaceCurrentItem(with: nil)
        Array(prebufferPlayers.keys).forEach(releasePrebufferPlayer)
        currentURL = nil
        activeVideoId = nil
        isReady = false
        resetTimelineState()
    }

    private func observeReadiness(for item: AVPlayerItem, videoId: String) {
        readinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.player.currentItem === item else { return }

                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    if self.activeVideoId == videoId {
                        self.player.playImmediately(atRate: 1)
                    }
                    return
                case .failed:
                    self.isReady = false
                    return
                default:
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
    }

    private func observeEnd(for item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.activeVideoId != nil {
                    self.player.playImmediately(atRate: 1)
                }
            }
        }
    }

    private func cachedAsset(for id: String, url: URL) -> AVURLAsset {
        if let asset = assetCache[id], asset.url == url {
            CacheMetrics.shared.recordHit(metricsNamespace)
            return asset
        }
        CacheMetrics.shared.recordMiss(metricsNamespace)
        releaseWarmState(id)
        let asset = AVURLAsset(url: url)
        assetCache[id] = asset
        CacheMetrics.shared.recordStore(metricsNamespace)
        return asset
    }

    private func makePreviewItem(asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.35
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func warmAsset(_ asset: AVURLAsset, id: String) {
        guard warmTasks[id] == nil else { return }
        warmTasks[id] = Task(priority: .utility) { [weak self] in
            do {
                _ = try await asset.load(.isPlayable)
                _ = try await asset.load(.duration)
                _ = try await asset.load(.tracks)
            } catch {
                CacheMetrics.shared.recordError("feed.preview")
                self?.recordWarmFailure(for: id)
            }
        }
    }

    private func preparedVideoIDs(videos: [FeedVideo], currentID: String?) -> Set<String> {
        guard let currentID,
              let currentIndex = videos.firstIndex(where: { $0.id == currentID }) else {
            return Set(videos.prefix(initialWarmCount).map(\.id))
        }

        let lowerBound = max(0, currentIndex - backwardWarmCount)
        let upperBound = min(videos.count - 1, currentIndex + forwardWarmCount)
        return Set(videos[lowerBound...upperBound].map(\.id))
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

    private func releaseWarmState(_ id: String) {
        warmTasks[id]?.cancel()
        warmTasks[id] = nil
        releasePrebufferPlayer(id)
        if assetCache.removeValue(forKey: id) != nil {
            CacheMetrics.shared.recordEviction(metricsNamespace)
        }
    }

    private func releasePrebufferPlayer(_ id: String) {
        prebufferPlayers[id]?.pause()
        prebufferPlayers[id]?.replaceCurrentItem(with: nil)
        if prebufferPlayers.removeValue(forKey: id) != nil {
            CacheMetrics.shared.recordEviction(metricsNamespace)
        }
    }

    private func trimWarmStateForMemoryPressure() {
        let protectedIDs = Set([activeVideoId].compactMap { $0 })
        Set(assetCache.keys).subtracting(protectedIDs).forEach(releaseWarmState)
    }

    private func attachTimelineObserver() {
        guard timeObserverPlayer !== player else { return }
        removeTimelineObserver()
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimelineState()
            }
        }
        timeObserver = token
        timeObserverPlayer = player
        updateTimelineState()
    }

    private func updateTimelineState() {
        let item = player.currentItem
        currentTime = player.currentTime().seconds.validTime ?? currentTime
        duration = resolvedDuration(from: item)
        buffered = bufferedEnd(from: item)
    }

    private func resetTimelineState() {
        currentTime = 0
        duration = 0
        buffered = 0
    }

    private func resolvedDuration(from item: AVPlayerItem?) -> Double {
        guard let item else { return 0 }
        let directDuration = item.duration.seconds.validTime
        let seekableEnd = item.seekableTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .compactMap(\.validTime)
            .max()
        let loadedEnd = item.loadedTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .compactMap(\.validTime)
            .max()
        return [directDuration, seekableEnd, loadedEnd, duration]
            .compactMap { $0 }
            .filter { $0 > 0 }
            .max() ?? 0
    }

    private func bufferedEnd(from item: AVPlayerItem?) -> Double {
        item?.loadedTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .compactMap(\.validTime)
            .max() ?? 0
    }

    private func removeTimelineObserver() {
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

// MARK: - Press scale effect (matches web hover → tap scale)

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - HomeView

/// Mirrors the web homepage: hero → continue watching → feed with interleaved
/// carousels (Shows every 3 videos, then Shorts, then Microdramas).
struct HomeView: View {
    enum HeaderStyle {
        case home
        case videos
    }

    var headerStyle: HeaderStyle = .home

    // MARK: State

    @AppStorage("playerMuted") private var playerMuted = false
    @State private var feed:               [FeedVideo]          = []
    @State private var renderItems:        [HomeItem]           = []
    @State private var continueItems:      [ProgressItem]       = []
    @State private var cursor:             String?              = nil
    @State private var isLoading                                = false
    @State private var isLoadingMore                            = false
    @State private var isRefreshingHome                         = false
    @State private var searchPresented                          = false
    @State private var notificationsPresented                   = false
    @State private var unreadNotificationCount                  = 0
    @State private var isUploadEligible                         = false
    @State private var didStartInitialLoad                      = false
    @State private var isLoadTaskRunning                        = false
    @State private var initialLoadTask: Task<Void, Never>?       = nil
    @State private var activeHomeLoadID: UUID?                   = nil
    @State private var activePreviewVideoId: String?            = nil
    @State private var latestPreviewFrames: [String: CGRect]     = [:]
    @State private var suppressedPreviewVideoId: String?         = nil
    @State private var previewIdleTask: Task<Void, Never>?       = nil
    @State private var imagePrefetchTask: Task<Void, Never>?      = nil
    @State private var didStartPreviewScroll                    = false
    @State private var isPreservingPreviewHandoff               = false
    @StateObject private var previewPlayerManager               = FeedPreviewPlayerManager()
    @StateObject private var storiesRepository                  = StoriesRepository()
    @State private var storyViewerPresentation: StoryViewerPresentation? = nil
    @State private var activeContext: ActiveContext?             = nil
    @State private var isCreatingStory                          = false

    @State private var pageListings: [AssembledListing] = []
    @State private var heroListing: AssembledListing? = nil
    @State private var videoFeedListing: AssembledListing? = nil

    @State private var featuredShows:      [ShowBrowseCard]     = []

    // Hero trailer player always starts muted; users can opt into audio per trailer session.
    @State private var heroPlayer: AVQueuePlayer? = nil
    @State private var heroLooper: AVPlayerLooper? = nil
    @State private var heroTrailerMuted = true
    @State private var heroTrailerVisible = false
    @State private var heroTrailerStartTask: Task<Void, Never>?
    @State private var heroAdvanceTask: Task<Void, Never>?
    @State private var heroTrailerEndObserver: NSObjectProtocol?
    @State private var heroTrailerFailureObserver: NSObjectProtocol?
    @State private var heroTrailerStallObserver: NSObjectProtocol?
    @State private var heroSlideIndex = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    // MARK: - Computed: interleaved render list

    private func makeRenderItems(from videos: [FeedVideo], isEndOfFeed: Bool) -> [HomeItem] {
        var result  = [HomeItem]()
        var slotIdx = 0
        let everyN  = max(1, videoFeedListing?.feedConfig?.mobileEvery ?? 5)
        let slotCap = max(0, videoFeedListing?.feedConfig?.mobileCount ?? 3)
        let slots   = Array((videoFeedListing?.feedSlots ?? []).prefix(slotCap))

        for (i, video) in uniqueByID(videos).enumerated() {
            result.append(.video(video))
            if (i + 1) % everyN == 0, slotIdx < slots.count {
                let slot = slots[slotIdx]
                if hasCarouselData(for: slot) {
                    result.append(.carousel(slot))
                }
                slotIdx += 1
            }
        }

        if isEndOfFeed, slotIdx < slots.count {
            for slot in slots.dropFirst(slotIdx) where hasCarouselData(for: slot) {
                result.append(.carousel(slot))
            }
        }

        return result
    }

    private func hasCarouselData(for listing: AssembledListing) -> Bool {
        !listing.items.isEmpty
    }

    private func nextFeedCursor(for listing: AssembledListing?, response: FeedResponse?) -> String? {
        guard listing?.infiniteLoad == true else { return nil }
        let nextCursor = response?.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        return nextCursor?.isEmpty == false ? nextCursor : nil
    }

    private var feedVideoIdsInOrder: [String] {
        renderItems.compactMap { item in
            if case .video(let video) = item {
                return video.id
            }
            return nil
        }
    }

    private var activeChannelUploadContext: UploadContext? {
        guard auth.isAuthenticated else { return nil }
        guard let activeContext, activeContext.type == "channel" else { return nil }
        return UploadContext(
            type: "channel",
            id: activeContext.channelId ?? activeContext.id,
            name: activeContext.name,
            avatarUrl: activeContext.avatarUrl ?? activeContext.image,
            networkName: nil
        )
    }

    private func uniqueByID<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func route(for video: FeedVideo) -> AppRoute {
        AppRoute.media(id: video.id, type: video.type, showId: video.show?.id, channelId: video.channel?.id)
    }

    private func isShortContent(_ type: String?) -> Bool {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short"
    }

    private func continueWatchingShortIDs(_ items: [ProgressItem]) -> [String] {
        items.compactMap { item in
            guard let video = item.video, isShortContent(video.type) else { return nil }
            return video.id
        }
    }

    private func sourceRoute(for video: FeedVideo) -> AppRoute? {
        if let channel = video.channel {
            return .channel(channel.handle ?? channel.id)
        }
        if let show = video.show {
            return .show(show.id)
        }
        return nil
    }

    private func openExploreSection(_ section: String) {
        NotificationCenter.default.post(name: .exploreSectionRequested, object: section)
    }

    private func openShortsPlayer() {
        NotificationCenter.default.post(name: .shortsTabRequested, object: nil)
    }

    private var isHomeAutoplayBlocked: Bool {
        miniPlayer.item != nil || miniPlayer.isExpansionHandoffActive
    }

    private var homeHeroHeight: CGFloat {
        C.heroHeight
    }

    private var homeHeroHorizontalMargin: CGFloat {
        0
    }

    private var homeContentTopInset: CGFloat {
        headerStyle == .home ? 52 : 0
    }

    private func canReplaceMiniPlayer(with video: FeedVideo) -> Bool {
        guard C.mediaURL(video.videoUrl) != nil else { return false }
        if case .video = route(for: video) {
            return true
        }
        return false
    }

    private func replaceMiniPlayerAndExpand(with video: FeedVideo, sourceFrame: CGRect? = nil) {
        guard let url = C.mediaURL(video.videoUrl) else { return }
        let player = previewPlayerManager.handoffActivePlayer(for: video.id, muted: playerMuted) ?? AVPlayer(url: url)
        player.isMuted = playerMuted
        player.volume = 1
        miniPlayer.replaceAndExpand(player: player, title: video.title, route: route(for: video), sourceFrame: sourceFrame, entrySurface: .homeFeed)
    }

    private func presentStoryViewer(groupId: String) {
        storyViewerPresentation = nil
        Task { @MainActor in
            await Task.yield()
            storyViewerPresentation = StoryViewerPresentation(groupId: groupId)
        }
    }

    private func scheduleActivePreviewUpdate(from frames: [String: CGRect]) {
        latestPreviewFrames = frames
        previewIdleTask?.cancel()
        previewPlayerManager.warm(videos: feed, currentID: activePreviewVideoId)

        guard !isHomeAutoplayBlocked else {
            isPreservingPreviewHandoff = false
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        if activePreviewVideoId != nil {
            isPreservingPreviewHandoff = true
            activePreviewVideoId = nil
            previewPlayerManager.pausePreservingHandoff()
        }

        previewPlayerManager.prebufferBottomCandidates(videos: feed, frames: frames)
        previewIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            didStartPreviewScroll = true
            updateActivePreview(from: latestPreviewFrames)
            previewIdleTask = nil
        }
    }

    private func updateActivePreview(from frames: [String: CGRect]) {
        isPreservingPreviewHandoff = false

        guard !isHomeAutoplayBlocked else {
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        let autoplayPolicy = FeedPreviewAutoplayPolicy()

        var videosById = [String: FeedVideo]()
        feed.forEach { videosById[$0.id] = $0 }

        if !didStartPreviewScroll,
           let topCandidate = feedVideoIdsInOrder.compactMap({ id -> (id: String, url: URL)? in
               guard id != suppressedPreviewVideoId,
                     let frame = frames[id],
                     let url = C.mediaURL(videosById[id]?.videoUrl),
                     autoplayPolicy.isInitialTopCandidate(frame: frame) else { return nil }
               return (id, url)
           }).first {
            suppressedPreviewVideoId = nil
            activePreviewVideoId = topCandidate.id
            prefetchNearbyFeedImages(around: topCandidate.id)
            stopHeroTrailer()
            previewPlayerManager.warm(videos: feed, currentID: topCandidate.id)
            previewPlayerManager.play(videoId: topCandidate.id, url: topCandidate.url)
            return
        }

        let candidate = feedVideoIdsInOrder.compactMap { id -> (id: String, url: URL, score: CGFloat)? in
            guard id != suppressedPreviewVideoId,
                  let frame = frames[id],
                  let url = C.mediaURL(videosById[id]?.videoUrl),
                  let score = autoplayPolicy.candidateScore(for: frame) else { return nil }
            return (id, url, score)
        }
        .max { $0.score < $1.score }

        guard let candidate else {
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        suppressedPreviewVideoId = nil
        activePreviewVideoId = candidate.id
        prefetchNearbyFeedImages(around: candidate.id)
        stopHeroTrailer()
        previewPlayerManager.warm(videos: feed, currentID: candidate.id)
        previewPlayerManager.play(videoId: candidate.id, url: candidate.url)
    }

    private func playNextPreview(afterPaused pausedId: String) {
        guard activePreviewVideoId == nil || activePreviewVideoId == pausedId else { return }
        suppressedPreviewVideoId = pausedId
        updateActivePreview(from: latestPreviewFrames)
    }

    private func prefetchNearbyFeedImages(around videoID: String?) {
        imagePrefetchTask?.cancel()
        guard !feed.isEmpty else { return }
        let startIndex = videoID.flatMap { id in feed.firstIndex { $0.id == id } } ?? 0
        let endIndex = min(feed.count, startIndex + 5)
        guard startIndex < endIndex else { return }
        let urls = feed[startIndex..<endIndex].compactMap { C.mediaURL($0.thumbnailUrl) }
        guard !urls.isEmpty else { return }
        let scale = UIScreen.main.scale
        let width = max(320, UIScreen.main.bounds.width - C.pagePad * 2) * scale
        let targetSize = CGSize(width: width, height: width * 9 / 16)
        imagePrefetchTask = Task(priority: .utility) {
            await RemoteImageCache.shared.prefetch(
                urls: urls,
                targetPixelSize: targetSize,
                limit: 5,
                concurrency: 2
            )
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            C.bg.ignoresSafeArea()

            if isLoading && feed.isEmpty && featuredShows.isEmpty && continueItems.isEmpty {
                ProgressView()
                    .tint(C.watch)
                    .id("home-loading")
            } else {
                feedContent
                    .id("home-feed")
            }

            if headerStyle == .home {
                homeFloatingHeader
            }
        }
        .navigationTitle(headerStyle == .videos ? "Videos" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(headerStyle == .home ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if headerStyle == .videos {
                ToolbarItem(placement: .principal) {
                    Text("Videos")
                        .font(.system(size: 17, weight: .bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(C.text)
                }
            }
        }
        .sheet(isPresented: $searchPresented) { SearchView() }
        .sheet(isPresented: $notificationsPresented) {
            NotificationsView { unreadCount in
                unreadNotificationCount = unreadCount
            }
        }
        .fullScreenCover(isPresented: $isCreatingStory) {
            StoryCreatorCoordinator(preselectedPublisher: activeChannelUploadContext) {
                isCreatingStory = false
                Task { await storiesRepository.refresh(force: true) }
            }
        }
        .fullScreenCover(item: $storyViewerPresentation, onDismiss: {
            guard platformConfig.storiesFeedEnabled else { return }
            Task { await storiesRepository.refresh(force: true) }
        }) { presentation in
            StoryViewerView(repository: storiesRepository, initialGroupId: presentation.groupId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .storiesDidChange)) { _ in
            guard platformConfig.storiesFeedEnabled else { return }
            Task { await storiesRepository.refresh(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { _ in
            updateUploadEligibilityFromCache()
            Task { await reloadForContextChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uploadEligibilityChanged)) { notification in
            isUploadEligible = (notification.object as? Bool) == true
        }
        .onReceive(NotificationCenter.default.publisher(for: .storyPublishNotificationTapped)) { notification in
            guard platformConfig.storiesFeedEnabled else { return }
            let groupId = notification.userInfo?["groupId"] as? String
            Task {
                await storiesRepository.refresh(force: true)
                await MainActor.run {
                    if let groupId, storiesRepository.groups.contains(where: { $0.id == groupId }) {
                        presentStoryViewer(groupId: groupId)
                    } else if let first = storiesRepository.groups.first {
                        presentStoryViewer(groupId: first.id)
                    }
                }
            }
        }
        .onChange(of: notificationsPresented) { _, isPresented in
            if !isPresented {
                Task { await loadNotificationCount() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notificationCountsDidChange)) { notification in
            if let count = notification.object as? Int {
                unreadNotificationCount = count
            } else {
                Task { await loadNotificationCount() }
            }
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                isUploadEligible = false
            } else {
                updateUploadEligibilityFromCache()
            }
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await loadNotificationCount()
                if platformConfig.storiesFeedEnabled {
                    await storiesRepository.refresh(force: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await loadNotificationCount() }
        }
        .onAppear {
            startInitialLoadIfNeeded()
            updateUploadEligibilityFromCache()
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                await loadNotificationCount()
                if platformConfig.storiesFeedEnabled {
                    await storiesRepository.refresh(force: true)
                }
            }
        }
        .onDisappear {
            cancelActiveHomeLoad()
            previewIdleTask?.cancel()
            previewIdleTask = nil
            imagePrefetchTask?.cancel()
            imagePrefetchTask = nil
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            stopHeroTrailer()
        }
        .onChange(of: isHomeAutoplayBlocked) { _, isBlocked in
            if isBlocked {
                previewIdleTask?.cancel()
                previewIdleTask = nil
                activePreviewVideoId = nil
                previewPlayerManager.pause()
                stopHeroTrailer()
            } else {
                restartHeroPlaybackAndAdvance()
            }
        }
        .onChange(of: heroSlideIDs) { _, _ in
            resetHeroSlideIndexIfNeeded()
            restartHeroPlaybackAndAdvance()
        }
    }

    private var homeHeaderTitle: some View {
        HStack(spacing: 7) {
            HStack(spacing: 0) {
                Text("We")
                    .foregroundStyle(C.text)
                Text("Streem")
                    .foregroundStyle(C.watch)
            }
            .font(.system(size: 19, weight: .black))
            .fontDesign(.rounded)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(C.watch, lineWidth: 2)
                .frame(width: 18, height: 13)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(C.watch)
                        .frame(width: 9, height: 2)
                        .offset(y: 5)
                }
        }
    }

    @ViewBuilder
    private var homeUploadButton: some View {
        if auth.isAuthenticated && isUploadEligible {
            Button {
                NotificationCenter.default.post(name: .uploadRequested, object: nil)
            } label: {
                toolbarIcon("upload", fallback: "plus.circle")
            }
            .accessibilityLabel("Upload")
        }
    }

    private var homeHeaderActions: some View {
        HStack(spacing: 6) {
            Button { notificationsPresented = true } label: {
                notificationBell
            }
            .disabled(!auth.isAuthenticated)
            .opacity(auth.isAuthenticated ? 1 : 0.45)
            .accessibilityLabel("Notifications")

            Button { searchPresented = true } label: {
                toolbarIcon("search", fallback: "magnifyingglass")
            }
            .accessibilityLabel("Search")
        }
    }


    private var homeFloatingHeader: some View {
        ZStack {
            HStack(spacing: 12) {
                homeUploadButton
                Spacer()
                homeHeaderActions
            }

            homeHeaderTitle
                .allowsHitTesting(false)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [C.bg.opacity(0.92), C.bg.opacity(0.68), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private func toolbarIcon(_ iconName: String, fallback: String) -> some View {
        MediaverseIcon(name: iconName, fallbackSystemName: fallback)
            .frame(width: 20, height: 20)
            .foregroundStyle(C.text)
            .frame(width: 34, height: 34)
    }

    private var notificationBell: some View {
        toolbarIcon("notification", fallback: "bell")
            .overlay(alignment: .topTrailing) {
                if unreadNotificationCount > 0 {
                    Text(unreadNotificationCount > 9 ? "9+" : "\(unreadNotificationCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(C.bg, lineWidth: 1.5))
                        .offset(x: 4, y: 1)
                        .zIndex(2)
                }
            }
        .frame(width: 44, height: 38)
    }

    // MARK: - Main feed

    private var emptyState: some View {
        VStack(spacing: 20) {
            MediaverseIcon(name: "short", fallbackSystemName: "play.rectangle.on.rectangle")
                .frame(width: 48, height: 48)
                .foregroundStyle(Color.white.opacity(0.15))
            Text("Nothing here yet")
                .font(.system(size: 18, weight: .bold))
                .fontDesign(.rounded)
                .foregroundStyle(C.text)
            Text("Check back soon for new content.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(C.watch)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 520)
        .padding(.horizontal, C.pagePad)
    }

    private var feedContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("home-feed-top")
                    feedBodyContent
                }
            }
            .coordinateSpace(name: "homeFeedScroll")
            .refreshable {
                C.lightHaptic()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isRefreshingHome = true
                }
                defer {
                    withAnimation(.easeOut(duration: 0.22)) {
                        isRefreshingHome = false
                    }
                }
                await reloadForContextChange()
                await loadNotificationCount()
            }
            .tint(headerStyle == .videos ? C.watch : .clear)
            .overlay(alignment: .top) {
                if isRefreshingHome && headerStyle == .home {
                    HomeRefreshIndicator()
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                }
            }
            .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
                scheduleActivePreviewUpdate(from: frames)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
                guard (notification.object as? String) == "home" else { return }
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo("home-feed-top", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private var feedBodyContent: some View {
        if pageListings.isEmpty && feed.isEmpty && featuredShows.isEmpty && continueItems.isEmpty && storiesRepository.groups.isEmpty && activeChannelUploadContext == nil {
            emptyState
        } else if !pageListings.isEmpty {
            ForEach(pageListings) { listing in
                homeListingView(listing)
            }
        } else {
            heroSection
                .padding(.top, homeContentTopInset)

            storiesTraySection

            if !continueItems.isEmpty {
                continueWatchingSection
            }

            feedList

            if cursor != nil {
                paginationSentinel
            }

            if cursor == nil && !feed.isEmpty {
                endOfFeedText
            }
        }
    }

    @ViewBuilder
    private func homeListingView(_ listing: AssembledListing) -> some View {
        switch listing.normalizedTemplateType {
        case "hero":
            heroSection
                .padding(.top, homeContentTopInset)
        case "stories":
            storiesTraySection
        case "continue_watching":
            if !continueItems.isEmpty {
                continueWatchingSection
            }
        case "video_feed", "shorts_feed":
            homeFeedSectionTitle(for: listing)
            feedList
            if cursor != nil {
                paginationSentinel
            }
            if cursor == nil && !feed.isEmpty {
                endOfFeedText
            }
        case "carousel", "grid", "banner", "spotlight", "channels":
            NativeCurationListingView(listing: listing)
                .padding(.bottom, C.sectionSpacing)
        default:
            NativeCurationListingView(listing: listing)
                .padding(.bottom, C.sectionSpacing)
        }
    }

    @ViewBuilder
    private func homeFeedSectionTitle(for listing: AssembledListing) -> some View {
        if let title = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(listing.accentColor.map(Color.init(hex:)) ?? C.watch)
                    .frame(width: 3, height: 18)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, C.pagePad)
            .padding(.top, 8)
            .padding(.bottom, C.rowSpacing)
        }
    }

    @ViewBuilder
    private var storiesTraySection: some View {
        if platformConfig.storiesFeedEnabled && auth.isAuthenticated {
            StoryTrayView(
                repository: storiesRepository,
                activeChannel: activeChannelUploadContext,
                onAddStory: { isCreatingStory = true }
            ) { group in
                presentStoryViewer(groupId: group.id)
            }
            .padding(.top, 16)
            .padding(.bottom, C.sectionSpacing)
        }
    }

    private var paginationSentinel: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)
                .onAppear { Task { await loadMore() } }
            if isLoadingMore {
                ProgressView().tint(C.watch).padding(.vertical, 20)
            }
        }
    }

    private var endOfFeedText: some View {
        Text("You've seen it all")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.2))
            .padding(.vertical, 32)
    }

    private var feedList: some View {
        ForEach(renderItems, id: \.id) { item in
            feedItemView(item)
        }
    }

    @ViewBuilder
    private func feedItemView(_ item: HomeItem) -> some View {
        switch item {
        case .video(let v):
            HomeVideoCard(
                video: v,
                mediaRoute: route(for: v),
                sourceRoute: sourceRoute(for: v),
                activePreviewVideoId: $activePreviewVideoId,
                previewManager: previewPlayerManager,
                isAutoplayBlocked: isHomeAutoplayBlocked,
                isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                onPreviewPaused: { playNextPreview(afterPaused: v.id) },
                openMediaAction: { NotificationCenter.default.post(name: .mentionNavigationRequested, object: route(for: v)) },
                replaceMediaAction: canReplaceMiniPlayer(with: v) ? { sourceFrame in replaceMiniPlayerAndExpand(with: v, sourceFrame: sourceFrame) } : nil
            )
            .padding(.bottom, C.sectionSpacing)

        case .carousel(let listing):
            NativeCurationListingView(listing: listing)
                .padding(.bottom, C.sectionSpacing)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        if let item = currentHeroItem {
            if heroSlides.count > 1 {
                heroSlideshow(item)
            } else {
                curationHero(item)
            }
        } else if let v = feed.first {
            // Fallback: first feed video as hero
            NavigationLink(value: AppRoute.media(id: v.id, type: v.type, showId: v.show?.id, channelId: v.channel?.id)) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        GeometryReader { proxy in
                            CachedRemoteImage(
                                url: C.mediaURL(v.thumbnailUrl),
                                targetSize: proxy.size
                            ) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            } placeholder: {
                                LinearGradient(
                                    colors: [C.watch.opacity(0.18), C.bg],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(width: proxy.size.width, height: proxy.size.height)
                            }
                            .clipped()
                        }

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.28), .black.opacity(0.94)],
                            startPoint: .center,
                            endPoint: .bottom
                        )

                        LinearGradient(
                            colors: [.black.opacity(0.50), .clear, .black.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: homeHeroHeight)
                    .clipped()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("FEATURED")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.watch)
                            .tracking(4)
                        Text(v.title)
                            .font(.system(size: 22, weight: .bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(C.text)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            MediaverseIcon(name: "play", fallbackSystemName: "play")
                                .frame(width: 11, height: 11)
                            Text("Watch Now").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(C.watch)
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 12)
                    .padding(.bottom, C.pagePad)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.bg)
                .padding(.horizontal, homeHeroHorizontalMargin)
            }
            .buttonStyle(.plain)
        }
    }

    private var heroSlides: [ContentItem] {
        if let items = heroListing?.items, !items.isEmpty {
            return items
        }
        return fallbackHeroItem.map { [$0] } ?? []
    }

    private var heroSlideIDs: [String] {
        heroSlides.map { "\($0.entityType)-\($0.entityId)" }
    }

    private var currentHeroItem: ContentItem? {
        let slides = heroSlides
        guard !slides.isEmpty else { return nil }
        let index = min(max(heroSlideIndex, 0), slides.count - 1)
        return slides[index]
    }

    private var fallbackHeroItem: ContentItem? {
        featuredShows.first.map { show in
            ContentItem(
                entityType: "show",
                entityId: show.id,
                title: show.title,
                thumbnailUrl: show.coverUrl,
                coverUrl: show.bannerUrl ?? show.coverUrl,
                meta: [
                    "genre": show.genre.map(AnyJSON.string) ?? .null,
                    "language": show.language.map(AnyJSON.string) ?? .null,
                    "description": show.description.map(AnyJSON.string) ?? .null,
                    "trailerUrl": show.trailerUrl.map(AnyJSON.string) ?? .null
                ]
            )
        }
    }

    private func heroSlideshow(_ item: ContentItem) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                curationHero(item)
                    .id(heroSlideIndex)
                    .transition(.opacity)

                heroSlideControls
                    .frame(height: homeHeroHeight)
            }

            heroSlideIndicators
        }
        .onAppear {
            restartHeroPlaybackAndAdvance()
        }
        .onChange(of: heroSlideIndex) { _, _ in
            restartHeroPlaybackAndAdvance()
        }
        .onDisappear {
            heroAdvanceTask?.cancel()
            heroAdvanceTask = nil
        }
    }

    private var heroSlideControls: some View {
        HStack {
            heroSlideButton(systemName: "chevron.left", label: "Previous hero slide") {
                retreatHeroSlide()
            }

            Spacer(minLength: 0)

            heroSlideButton(systemName: "chevron.right", label: "Next hero slide") {
                advanceHeroSlide()
            }
        }
        .padding(.horizontal, C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroSlideIndicators: some View {
        HStack(spacing: 6) {
            ForEach(heroSlides.indices, id: \.self) { index in
                Button {
                    selectHeroSlide(index)
                } label: {
                    Capsule()
                        .fill(index == heroSlideIndex ? C.watch : Color.white.opacity(0.34))
                        .frame(width: index == heroSlideIndex ? 18 : 6, height: 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hero slide \(index + 1)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.32), in: Capsule())
    }

    private func heroSlideButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.36), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func curationHero(_ item: ContentItem) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: item.appRoute) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        GeometryReader { proxy in
                            CachedRemoteImage(
                                url: C.mediaURL(item.coverUrl ?? item.thumbnailUrl),
                                targetSize: CGSize(width: proxy.size.width, height: proxy.size.height)
                            ) { image in
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            } placeholder: {
                                LinearGradient(
                                    colors: [C.watch.opacity(0.25), C.bg],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(width: proxy.size.width, height: proxy.size.height)
                            }
                            .clipped()
                        }
                        .overlay {
                            Color.black.opacity(heroTrailerVisible ? 0 : 0.18)
                        }

                        if let player = heroPlayer {
                            LoopingVideoLayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(heroTrailerVisible ? 0.72 : 0)
                                .animation(.easeInOut(duration: 0.55), value: heroTrailerVisible)
                        }

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.28), .black.opacity(0.94)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .opacity(heroTrailerVisible ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: heroTrailerVisible)

                        LinearGradient(
                            colors: [.black.opacity(0.50), .clear, .black.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .opacity(heroTrailerVisible ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: heroTrailerVisible)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: homeHeroHeight)
                    .clipped()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(heroListing?.badge?.uppercased() ?? "FEATURED")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.watch)
                            .tracking(4)

                        Text(item.curationDisplayTitle)
                            .font(.system(size: 24, weight: .bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(C.text)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            if let genre = item.metaString("genre"), !genre.isEmpty {
                                Text(genre)
                            }
                            if let language = item.metaString("language"), !language.isEmpty {
                                if item.metaString("genre")?.isEmpty == false { Text("•") }
                                Text(language.uppercased())
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(C.textMuted)

                        if let description = item.metaString("description"), !description.isEmpty {
                            Text(description)
                                .font(.system(size: 14))
                                .foregroundStyle(C.textMuted)
                                .lineLimit(3)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        LazyHStack(spacing: 12) {
                            HStack(spacing: 6) {
                                MediaverseIcon(name: "play", fallbackSystemName: "play")
                                    .frame(width: 11, height: 11)
                                Text(item.metaString("trailerUrl") != nil ? "Watch Trailer" : "Watch Now")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(C.watch)
                            .clipShape(Capsule())

                            Text("More Info")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                .overlay { Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1) }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 12)
                    .padding(.bottom, C.pagePad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.bg)
                .padding(.horizontal, homeHeroHorizontalMargin)
            }
            .buttonStyle(.plain)

            if heroPlayer != nil, heroTrailerVisible, item.metaString("trailerUrl") != nil {
                heroTrailerMuteButton
                    .padding(.top, 16)
                    .padding(.trailing, homeHeroHorizontalMargin + 16)
            }
        }
    }

    // MARK: - Continue Watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.system(size: 17, weight: .bold))
                .fontDesign(.rounded)
                .foregroundStyle(C.text)
                .padding(.horizontal, C.pagePad)

            ScrollView(.horizontal, showsIndicators: false) {
                let renderedItems = uniqueByID(continueItems)
                HStack(spacing: 12) {
                    ForEach(renderedItems) { item in
                        if let vid = item.video {
                            let isShort = isShortContent(vid.type)
                            NavigationLink(value: isShort ? AppRoute.short(vid.id, showId: nil, channelId: nil) : AppRoute.media(id: vid.id, type: vid.type, channelId: vid.channel?.id)) {
                                ContinueCard(
                                    title: vid.title,
                                    thumbnailUrl: vid.thumbnailUrl,
                                    progress: item.progress
                                )
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                if isShort {
                                    ShortNavigationCache.shared.seedIDs(continueWatchingShortIDs(renderedItems))
                                }
                            })
                            .buttonStyle(CardPressStyle())
                        } else if let ep = item.episode {
                            NavigationLink(value: AppRoute.episode(ep.id)) {
                                ContinueCard(
                                    title: ep.title,
                                    thumbnailUrl: ep.thumbnailUrl,
                                    progress: item.progress
                                )
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 22)
    }

    // MARK: - Carousel rows

    @ViewBuilder
    private func carouselRow(for listing: AssembledListing) -> some View {
        let accent = listing.accentColor.map(Color.init(hex:)) ?? C.watch
        CarouselWrapper(title: listing.listingTitle ?? "", accentColor: accent, seeAllAction: seeAllAction(for: listing)) {
            ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                contentItemTarget(item)
            }
        }
    }

    @ViewBuilder
    private func curationGridRow(for listing: AssembledListing) -> some View {
        CurationGridListingView(
            listing: listing,
            accentColor: listing.accentColor.map(Color.init(hex:)) ?? C.watch,
            seeAllAction: seeAllAction(for: listing)
        ) { item in
            contentItemTarget(item)
        }
    }

    private func seeAllAction(for listing: AssembledListing) -> (() -> Void)? {
        if let seeAllUrl = listing.seeAllUrl {
            return {
                if let route = AppRoute.route(link: seeAllUrl) {
                    NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
                } else if let url = URL(string: seeAllUrl), InAppBrowserManager.canDisplayInApp(url) {
                    inAppBrowser.open(url)
                }
            }
        }

        switch listing.contentTypeHint ?? listing.items.first?.entityType {
        case "show":
            return { openExploreSection("shows") }
        case "channel":
            return { openExploreSection("channels") }
        case "short":
            return openShortsPlayer
        case "microdrama":
            return { openExploreSection("microdramas") }
        case "video":
            return { openExploreSection("videos") }
        default:
            return nil
        }
    }

    @ViewBuilder
    private func contentItemTarget(_ item: ContentItem) -> some View {
        let normalizedType = item.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedType == "video" {
            let video = item.asFeedVideo
            if canReplaceMiniPlayer(with: video) {
                Button {
                    replaceMiniPlayerAndExpand(with: video)
                } label: {
                    ContentItemCard(item: item, isAutoplayBlocked: isHomeAutoplayBlocked)
                }
                .buttonStyle(CardPressStyle())
            } else {
                NavigationLink(value: item.appRoute) {
                    ContentItemCard(item: item, isAutoplayBlocked: isHomeAutoplayBlocked)
                }
                .buttonStyle(CardPressStyle())
            }
        } else {
            NavigationLink(value: item.appRoute) {
                ContentItemCard(item: item, isAutoplayBlocked: isHomeAutoplayBlocked)
            }
            .simultaneousGesture(TapGesture().onEnded {
                if normalizedType == "short" {
                    let shorts = listingShortSeedItems(containing: item)
                    let shortIDs = shorts.map(\.entityId)
                    ShortNavigationCache.shared.seedIDs(shortIDs.isEmpty ? [item.entityId] : shortIDs)
                }
            })
            .buttonStyle(CardPressStyle())
        }
    }

    private func listingShortSeedItems(containing item: ContentItem) -> [ContentItem] {
        let topLevelShorts = pageListings
            .flatMap(\.items)
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" }
        let injectedShorts = (videoFeedListing?.feedSlots ?? [])
            .flatMap(\.items)
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" }
        return uniqueContentItems(topLevelShorts + injectedShorts + [item])
    }

    private func uniqueContentItems(_ items: [ContentItem]) -> [ContentItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.entityId).inserted }
    }

    // MARK: - Data loading

    private func startInitialLoadIfNeeded() {
        if feed.isEmpty && featuredShows.isEmpty && continueItems.isEmpty && !isLoadTaskRunning {
            didStartInitialLoad = false
            initialLoadTask = nil
        }

        guard !didStartInitialLoad, initialLoadTask == nil else {
            return
        }
        initialLoadTask = Task {
            await load()
        }
    }

    @MainActor
    private func reloadForContextChange() async {
        cancelActiveHomeLoad()
        activePreviewVideoId = nil
        didStartPreviewScroll = false
        storyViewerPresentation = nil
        stopHeroTrailer()
        didStartInitialLoad = false
        if platformConfig.storiesFeedEnabled {
            async let storiesLoad: Void = storiesRepository.refresh(force: true)
            async let homeLoad: Void = load()
            _ = await (storiesLoad, homeLoad)
        } else {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard !isLoadTaskRunning else {
            return
        }
        let loadID = UUID()
        activeHomeLoadID = loadID
        let hadContent = !feed.isEmpty || !renderItems.isEmpty || !featuredShows.isEmpty || !continueItems.isEmpty
        if !hadContent {
            didStartPreviewScroll = false
        }
        didStartInitialLoad = true
        isLoadTaskRunning = true
        isLoading = !hadContent
        defer {
            if activeHomeLoadID == loadID {
                activeHomeLoadID = nil
                isLoading = false
                isLoadTaskRunning = false
                initialLoadTask = nil
            }
        }

        do {
            async let pageTask = CurationManager.shared.fetchPage(key: "videos")
            async let feedTask = APIClient.shared.fetchFeed()

            let page = try await pageTask
            let feedResponse = try? await feedTask
            guard activeHomeLoadID == loadID, !Task.isCancelled else { return }
            let activeListings = page.activeListings
            let feedListing = activeListings.first { $0.normalizedTemplateType == "video_feed" }
            let hero = activeListings.first { $0.normalizedTemplateType == "hero" }
            let curationVideos = (feedListing?.items ?? []).map(\.asFeedVideo)
            let videos = uniqueByID(feedResponse?.videos ?? curationVideos)
            let refreshedShows = activeListings
                .flatMap(\.items)
                .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "show" }
                .map(\.asShowBrowseCard)
            let cachedActiveContext = SessionStorage.activeContext ?? activeContext

            guard !videos.isEmpty || !hadContent else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pageListings = activeListings
                    heroListing = hero
                    videoFeedListing = feedListing
                    activeContext = cachedActiveContext
                    featuredShows = refreshedShows.isEmpty ? featuredShows : refreshedShows
                }
                schedulePostInitialHomeWork(videos: feed)
                return
            }

            stopHeroTrailer()

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageListings = activeListings
                heroListing = hero
                videoFeedListing = feedListing
                activeContext = cachedActiveContext
                feed = videos
                let nextCursor = nextFeedCursor(for: feedListing, response: feedResponse)
                cursor = nextCursor
                featuredShows = refreshedShows
                renderItems = makeRenderItems(from: videos, isEndOfFeed: nextCursor == nil)
            }
            schedulePostInitialHomeWork(videos: videos)
        } catch {
            guard activeHomeLoadID == loadID, !Task.isCancelled else { return }
            print("Home feed failed:", error)
            didStartInitialLoad = hadContent
            if !hadContent {
                pageListings = []
                heroListing = nil
                videoFeedListing = nil
                feed = []
                cursor = nil
                renderItems = []
            }
        }
    }

    @MainActor
    private func cancelActiveHomeLoad() {
        initialLoadTask?.cancel()
        initialLoadTask = nil
        activeHomeLoadID = nil
        isLoadTaskRunning = false
        isLoading = false
        if feed.isEmpty && featuredShows.isEmpty && continueItems.isEmpty {
            didStartInitialLoad = false
        }
    }

    @MainActor
    private func schedulePostInitialHomeWork(videos: [FeedVideo]) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await loadDeferredHomeCompanionData()
            let videosToWarm = videos.isEmpty ? feed : videos
            if !videosToWarm.isEmpty {
                prefetchNearbyFeedImages(around: activePreviewVideoId ?? videosToWarm.first?.id)
                previewPlayerManager.warm(videos: videosToWarm, currentID: activePreviewVideoId)
            }
            restartHeroPlaybackAndAdvance()
        }
    }

    @MainActor
    private func loadDeferredHomeCompanionData() async {
        async let continueTask = APIClient.shared.fetchContinueWatching()
        async let contextsTask = APIClient.shared.fetchContexts()
        let refreshedContinueItems = ((try? await continueTask)?.items ?? continueItems)
        let contextsResponse = try? await contextsTask
        let refreshedActiveContext = SessionStorage.activeContext ?? contextsResponse?.active ?? activeContext

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            continueItems = refreshedContinueItems
            activeContext = refreshedActiveContext
        }
    }

    @MainActor
    private func updateUploadEligibilityFromCache() {
        guard auth.isAuthenticated, let contexts = UploadOptionsCache.contexts else {
            isUploadEligible = false
            return
        }
        isUploadEligible = !contexts.channels.isEmpty || !contexts.shows.isEmpty
    }

    @MainActor
    private func loadNotificationCount() async {
        guard auth.isAuthenticated else {
            unreadNotificationCount = 0
            return
        }

        if let counts = try? await APIClient.shared.fetchNotificationCounts(),
           let unread = notificationUnreadCount(from: counts) {
            unreadNotificationCount = unread
            return
        }

        if let notifications = try? await APIClient.shared.fetchNotifications() {
            unreadNotificationCount = notifications.filter { !$0.read }.count
        }
    }

    private func notificationUnreadCount(from counts: [String: Int]) -> Int? {
        for key in ["unread", "unreadCount", "unread_count", "totalUnread", "total_unread", "notificationsUnread", "notifications_unread"] {
            if let value = counts[key] { return value }
        }
        return nil
    }

    private var heroTrailerMuteButton: some View {
        Button { toggleHeroTrailerMute() } label: {
            Image(systemName: heroTrailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.44), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.18), lineWidth: 1) }
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(heroTrailerMuted ? "Unmute trailer" : "Mute trailer")
        .accessibilityHint("Toggles audio for the hero trailer")
    }

    @MainActor
    private func restartHeroPlaybackAndAdvance() {
        stopHeroTrailer()
        startHeroTrailerIfAvailable()
        scheduleHeroAdvance()
    }

    @MainActor
    private func startHeroTrailerIfAvailable() {
        guard !isHomeAutoplayBlocked,
              heroPlayer == nil,
              heroTrailerStartTask == nil,
              let url = currentHeroItem?.trailerURL else { return }

        heroTrailerVisible = false
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        heroTrailerMuted = true
        player.isMuted = true
        player.volume = 1

        if heroSlides.count > 1 {
            player.insert(item, after: nil)
            observeHeroTrailerAdvance(for: item)
        } else {
            heroLooper = AVPlayerLooper(player: player, templateItem: item)
        }

        heroPlayer = player

        heroTrailerStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !isHomeAutoplayBlocked, heroPlayer === player else {
                heroTrailerStartTask = nil
                return
            }
            player.play()
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, !isHomeAutoplayBlocked, heroPlayer === player else {
                heroTrailerStartTask = nil
                return
            }
            heroTrailerVisible = true
            heroTrailerStartTask = nil
        }
    }

    @MainActor
    private func scheduleHeroAdvance() {
        heroAdvanceTask?.cancel()
        heroAdvanceTask = nil
        guard heroSlides.count > 1, !isHomeAutoplayBlocked else { return }

        let delay: UInt64 = currentHeroItem?.trailerURL == nil ? 5_000_000_000 : 60_000_000_000
        heroAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  heroSlides.count > 1,
                  !isHomeAutoplayBlocked else { return }
            advanceHeroSlide()
        }
    }

    @MainActor
    private func observeHeroTrailerAdvance(for item: AVPlayerItem) {
        removeHeroTrailerObservers()
        heroTrailerEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                advanceHeroSlide()
            }
        }
        heroTrailerFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                advanceHeroSlide()
            }
        }
        heroTrailerStallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                advanceHeroSlide()
            }
        }
    }

    @MainActor
    private func removeHeroTrailerObservers() {
        if let heroTrailerEndObserver {
            NotificationCenter.default.removeObserver(heroTrailerEndObserver)
            self.heroTrailerEndObserver = nil
        }
        if let heroTrailerFailureObserver {
            NotificationCenter.default.removeObserver(heroTrailerFailureObserver)
            self.heroTrailerFailureObserver = nil
        }
        if let heroTrailerStallObserver {
            NotificationCenter.default.removeObserver(heroTrailerStallObserver)
            self.heroTrailerStallObserver = nil
        }
    }

    @MainActor
    private func advanceHeroSlide() {
        let slides = heroSlides
        guard slides.count > 1 else { return }
        let nextIndex = (min(max(heroSlideIndex, 0), slides.count - 1) + 1) % slides.count
        updateHeroSlideIndex(nextIndex)
    }

    @MainActor
    private func retreatHeroSlide() {
        let slides = heroSlides
        guard slides.count > 1 else { return }
        let currentIndex = min(max(heroSlideIndex, 0), slides.count - 1)
        updateHeroSlideIndex((currentIndex - 1 + slides.count) % slides.count)
    }

    @MainActor
    private func selectHeroSlide(_ index: Int) {
        guard heroSlides.indices.contains(index), index != heroSlideIndex else { return }
        updateHeroSlideIndex(index)
    }

    @MainActor
    private func updateHeroSlideIndex(_ index: Int) {
        if reduceMotion {
            heroSlideIndex = index
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                heroSlideIndex = index
            }
        }
    }

    @MainActor
    private func resetHeroSlideIndexIfNeeded() {
        let slides = heroSlides
        guard !slides.isEmpty else {
            heroSlideIndex = 0
            return
        }
        if heroSlideIndex >= slides.count {
            heroSlideIndex = 0
        }
    }

    @MainActor
    private func toggleHeroTrailerMute() {
        heroTrailerMuted.toggle()
        heroPlayer?.isMuted = heroTrailerMuted
    }

    @MainActor
    private func stopHeroTrailer() {
        heroTrailerStartTask?.cancel()
        heroTrailerStartTask = nil
        heroAdvanceTask?.cancel()
        heroAdvanceTask = nil
        heroTrailerVisible = false
        heroPlayer?.pause()
        heroLooper = nil
        heroPlayer = nil
        removeHeroTrailerObservers()
    }

    @MainActor
    private func loadMore() async {
        guard let cur = cursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cur.isEmpty,
              !isLoading,
              !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        if let r = try? await APIClient.shared.fetchFeed(cursor: cur) {
            let videos = uniqueByID(feed + r.videos)
            feed = videos
            cursor = r.nextCursor
            renderItems = makeRenderItems(from: videos, isEndOfFeed: r.nextCursor == nil)
            previewPlayerManager.warm(videos: videos, currentID: activePreviewVideoId)
        }
    }
}

private struct HomeRefreshIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(C.watch.opacity(0.20), lineWidth: 2)
                    .frame(width: 24, height: 24)

                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(C.watch, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))

                Circle()
                    .fill(C.watch)
                    .frame(width: 5, height: 5)
                    .scaleEffect(isAnimating ? 1.25 : 0.75)
                    .opacity(isAnimating ? 1 : 0.55)
            }

            Text("Refreshing")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(C.watch.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 6)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Channel carousel card
// Portrait card: avatar circle + name + handle.
// Matches web ChannelCard behaviour — tapping navigates to ChannelView.
// Data comes from ChannelStub (derived from feed videos), so no extra API call.

private struct ChannelCarouselCard: View {
    let channel: ChannelStub

    // Initials fallback for missing avatar
    private var initial: String {
        channel.name.first.map(String.init) ?? "?"
    }

    var body: some View {
        VStack(spacing: 8) {
            // ── Avatar ────────────────────────────────────────────────────────
            Group {
                if let url = C.mediaURL(channel.avatarUrl) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: CarouselCardMetrics.channelAvatarSize, height: CarouselCardMetrics.channelAvatarSize)
                    ) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        initialsCircle
                    }
                } else {
                    initialsCircle
                }
            }
            .frame(width: CarouselCardMetrics.channelAvatarSize, height: CarouselCardMetrics.channelAvatarSize)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1) }

            // ── Name + handle ─────────────────────────────────────────────────
            VStack(spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: CarouselCardMetrics.channelWidth, alignment: .center)
                if let handle = channel.handle {
                    Text("@\(handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                        .frame(width: CarouselCardMetrics.channelWidth, height: CarouselCardMetrics.metaHeight, alignment: .center)
                } else {
                    Color.clear.frame(width: CarouselCardMetrics.channelWidth, height: CarouselCardMetrics.metaHeight)
                }
            }
        }
        .frame(width: CarouselCardMetrics.channelWidth)
        .contentShape(Rectangle())
    }

    private var initialsCircle: some View {
        Circle()
            .fill(Color.white.opacity(0.1))
            .overlay {
                Text(initial.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
    }
}

// MARK: - Video carousel card
// Landscape 16:9 thumbnail + title + channel name.
// Used when a carouselSlot has type="videos" — shows regular feed videos
// in a horizontal strip (equivalent to web VideoCarouselCard).

private struct VideoCarouselCard: View {
    let video: FeedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Thumbnail ─────────────────────────────────────────────────────
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { proxy in
                    CachedRemoteImage(
                        url: C.mediaURL(video.thumbnailUrl),
                        targetSize: proxy.size
                    ) { img in
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } placeholder: {
                        Color.white.opacity(0.07)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .clipped()
                }

                // Duration badge
                if let dur = video.duration {
                    Text(fmtDur(dur))
                        .font(.system(size: 9, weight: .semibold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.80))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .frame(width: HomeCarouselMetrics.landscapeWidth, height: video.homeFeedCardHeight(for: HomeCarouselMetrics.landscapeWidth))
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))
            .clipped()

            // ── Text ──────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: HomeCarouselMetrics.landscapeWidth, alignment: .leading)

                if let ch = video.channel {
                    Text(ch.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                        .frame(width: HomeCarouselMetrics.landscapeWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
                } else {
                    Color.clear.frame(width: HomeCarouselMetrics.landscapeWidth, height: CarouselCardMetrics.metaHeight)
                }
            }
            .frame(width: HomeCarouselMetrics.landscapeWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: HomeCarouselMetrics.landscapeWidth)
        .contentShape(Rectangle())
    }

    private func fmtDur(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

// MARK: - Carousel wrapper (full-bleed row with header)

private struct CarouselWrapper<Content: View>: View {
    let title: String
    let accentColor: Color
    let seeAllAction: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty || seeAllAction != nil {
                HStack {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if let seeAllAction {
                        Button(action: seeAllAction) {
                            HStack(spacing: 3) {
                                Text("See all")
                                    .font(.system(size: 13, weight: .semibold))
                                MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                                    .frame(width: 11, height: 11)
                            }
                            .foregroundStyle(accentColor)
                            .padding(.vertical, 8)
                            .padding(.leading, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.bottom, 14)
            }

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CarouselCardMetrics.spacing) {
                    content
                }
                .padding(.horizontal, C.pagePad)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 20)
        .background(Color.white.opacity(0.025))
    }
}

// MARK: - Home video card (single-column, avatar + title + channel + views)

struct HomeVideoCard: View {
    let video: FeedVideo
    let mediaRoute: AppRoute
    let sourceRoute: AppRoute?
    @Binding var activePreviewVideoId: String?
    @ObservedObject var previewManager: FeedPreviewPlayerManager
    let isAutoplayBlocked: Bool
    let isPreservingPreviewHandoff: Bool
    let onPreviewPaused: () -> Void
    let openMediaAction: () -> Void
    let replaceMediaAction: ((CGRect?) -> Void)?
    @State private var thumbnailGlobalFrame: CGRect?
    @State private var previewScrubTime: Double?
    @State private var showPreviewVideo = false
    @State private var keepsPreviewVideoLayer = false
    @State private var previewRevealTask: Task<Void, Never>?

    private var isPreviewActive: Bool {
        !isAutoplayBlocked && activePreviewVideoId == video.id && previewManager.activeVideoId == video.id
    }

    private var isPreviewPlaying: Bool {
        isPreviewActive && previewManager.isReady
    }

    private var feedMetaText: String {
        ["\(fmtViews(video.views)) views", publishedTimeText].compactMap { $0 }.joined(separator: " • ")
    }

    private var publishedTimeText: String? {
        let publishedAt = video.publishedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = video.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = publishedAt?.isEmpty == false ? publishedAt : (createdAt.isEmpty ? nil : createdAt)
        guard let timestamp else { return nil }
        return relativePublishedTime(from: timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnailMediaTarget
            // ── Avatar + text row ─────────────────────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                sourceTarget {
                    avatarView
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    mediaTarget {
                        Text(video.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let ch = video.channel {
                        sourceTarget {
                            Text(ch.name)
                                .font(.system(size: 12))
                                .foregroundStyle(C.textMuted)
                                .lineLimit(1)
                        }
                    } else if let show = video.show {
                        sourceTarget {
                            Text(show.title)
                                .font(.system(size: 12))
                                .foregroundStyle(C.textMuted)
                                .lineLimit(1)
                        }
                    }

                    Text(feedMetaText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, C.pagePad)
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HomeVideoFramePreferenceKey.self,
                    value: [video.id: proxy.frame(in: .named("homeFeedScroll"))]
                )
            }
        }
    }

    // MARK: - Sub-views

    private var thumbnailMediaTarget: some View {
        ZStack {
            thumbnailPreviewArea
                .allowsHitTesting(false)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { thumbnailGlobalFrame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in
                                thumbnailGlobalFrame = frame
                            }
                    }
                }

            Button {
                launchMedia()
            } label: {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle())
            .accessibilityLabel(video.title)
            .accessibilityHint("Opens the video player")

            if isPreviewActive, previewManager.duration > 0 {
                feedPreviewSeekBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(2)
            }
        }
    }

    private var feedPreviewSeekBar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let duration = max(previewManager.duration, 0)
            let visibleTime = previewScrubTime ?? previewManager.currentTime
            let progress = duration > 0 ? min(max(visibleTime / duration, 0), 1) : 0
            let bufferedProgress = duration > 0 ? min(max(previewManager.buffered / duration, 0), 1) : 0

            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 3)
                Rectangle()
                    .fill(Color.white.opacity(0.36))
                    .frame(width: width * CGFloat(bufferedProgress), height: 3)
                Rectangle()
                    .fill(C.watch)
                    .frame(width: width * CGFloat(progress), height: 3)
            }
            .frame(width: width, height: 28, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let pct = min(max(value.location.x / width, 0), 1)
                        previewScrubTime = duration * pct
                    }
                    .onEnded { value in
                        guard duration > 0 else {
                            previewScrubTime = nil
                            return
                        }
                        let pct = min(max(value.location.x / width, 0), 1)
                        let target = duration * pct
                        previewScrubTime = target
                        previewManager.seekActivePreview(to: target)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            previewScrubTime = nil
                        }
                    }
            )
            .accessibilityLabel("Preview playback position")
            .accessibilityValue("\(fmtDur(visibleTime)) of \(fmtDur(duration))")
        }
        .frame(height: 28)
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func mediaTarget<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button {
            launchMedia()
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func launchMedia() {
        if let replaceMediaAction {
            replaceMediaAction(thumbnailGlobalFrame)
        } else {
            pausePreview()
            openMediaAction()
        }
    }

    private func pausePreview() {
        activePreviewVideoId = nil
        previewManager.pauseIfActive(videoId: video.id)
        onPreviewPaused()
    }

    @ViewBuilder
    private func sourceTarget<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let sourceRoute {
            NavigationLink(value: sourceRoute) {
                content()
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            content()
        }
    }

    private var thumbnailPreviewArea: some View {
        ZStack(alignment: .bottomTrailing) {
            // Static thumbnail fades once the preview is actually ready, avoiding a black flash.
            GeometryReader { proxy in
                CachedRemoteImage(
                    url: C.mediaURL(video.thumbnailUrl),
                    targetSize: proxy.size
                ) { img in
                    img.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } placeholder: {
                    Color.white.opacity(0.07)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .opacity(showPreviewVideo ? 0 : 1)
                .animation(.easeInOut(duration: 0.34), value: showPreviewVideo)
                .clipped()
            }

            if isPreviewActive || keepsPreviewVideoLayer {
                GeometryReader { proxy in
                    LoopingVideoLayer(player: previewManager.player)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(showPreviewVideo ? 1 : 0)
                        .animation(.easeInOut(duration: 0.34), value: showPreviewVideo)
                        .allowsHitTesting(false)
                }
            }

            if !isAutoplayBlocked && activePreviewVideoId == video.id {
                HStack(spacing: 6) {
                    MediaverseIcon(name: "play", fallbackSystemName: "play")
                        .frame(width: 10, height: 10)
                    Text("Tap to watch")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.68))
                .clipShape(Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
                .allowsHitTesting(false)
            }

            if let dur = video.duration {
                Text(fmtDur(dur))
                    .font(.system(size: 10, weight: .semibold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.80))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .frame(height: video.homeFeedCardHeight(for: UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity)
        .clipped()
        .onDisappear {
            let wasActive = activePreviewVideoId == video.id || previewManager.activeVideoId == video.id
            if activePreviewVideoId == video.id {
                activePreviewVideoId = nil
            }
            cancelPreviewReveal()
            previewManager.pauseIfActive(videoId: video.id)
            if wasActive {
                onPreviewPaused()
            }
        }
        .onChange(of: activePreviewVideoId) { _, activeId in
            if activeId == video.id, isPreviewPlaying {
                schedulePreviewReveal()
            } else if activeId != video.id {
                previewScrubTime = nil
                cancelPreviewReveal()
            }
            if activeId != video.id && !isPreservingPreviewHandoff {
                previewManager.pauseIfActive(videoId: video.id)
            }
        }
        .onChange(of: isPreviewPlaying) { _, playing in
            if playing {
                schedulePreviewReveal()
            } else {
                cancelPreviewReveal()
            }
        }
        .onChange(of: isAutoplayBlocked) { _, isBlocked in
            if isBlocked {
                cancelPreviewReveal()
                previewManager.pauseIfActive(videoId: video.id)
            }
        }
    }

    private func schedulePreviewReveal() {
        previewRevealTask?.cancel()
        keepsPreviewVideoLayer = true
        showPreviewVideo = false
        previewRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, isPreviewPlaying else { return }
            withAnimation(.easeInOut(duration: 0.34)) {
                showPreviewVideo = true
            }
        }
    }

    private func cancelPreviewReveal() {
        previewRevealTask?.cancel()
        previewRevealTask = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            showPreviewVideo = false
        }
        guard keepsPreviewVideoLayer else { return }
        previewRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, !isPreviewPlaying else { return }
            keepsPreviewVideoLayer = false
        }
    }

    // Computed outside @ViewBuilder to avoid iOS 26 instability with `let` bindings
    // inside ViewBuilder closures (local `let` inside @ViewBuilder can confuse the
    // compiler's result-builder rewrite in Swift 6 / Xcode 26).
    private var avatarInitial: String {
        (video.channel?.name.first ?? video.show?.title.first).map(String.init) ?? "?"
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = C.mediaURL(video.channel?.avatarUrl ?? video.show?.coverUrl) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: 34, height: 34)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                initialsCircle(avatarInitial)
            }
        } else {
            initialsCircle(avatarInitial)
        }
    }

    private func initialsCircle(_ initial: String) -> some View {
        Circle()
            .fill(Color.white.opacity(0.1))
            .overlay {
                Text(initial.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
    }

    private func fmtDur(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }

    private func fmtViews(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    private func relativePublishedTime(from isoString: String) -> String? {
        guard let date = Self.feedFractionalDateFormatter.date(from: isoString)
            ?? Self.feedDateFormatter.date(from: isoString) else { return nil }
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        if seconds < 604_800 { return "\(seconds / 86_400)d ago" }
        if seconds < 2_592_000 { return "\(seconds / 604_800)w ago" }
        if seconds < 31_536_000 { return "\(seconds / 2_592_000)mo ago" }
        return "\(seconds / 31_536_000)y ago"
    }

    private static let feedFractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let feedDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Continue watching card

private struct ContinueCard: View {
    private let cardWidth: CGFloat = 160
    private let cardHeight: CGFloat = 90

    let title: String
    let thumbnailUrl: String?
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                GeometryReader { proxy in
                    CachedRemoteImage(
                        url: C.mediaURL(thumbnailUrl),
                        targetSize: proxy.size
                    ) { img in
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } placeholder: {
                        Color.white.opacity(0.06)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .clipped()
                }

                GeometryReader { geo in
                    Rectangle()
                        .fill(C.watch)
                        .frame(width: geo.size.width * min(max(progress, 0), 1), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth)
    }
}

private struct CurationGridListingView<Cell: View>: View {
    let listing: AssembledListing
    let accentColor: Color
    let seeAllAction: (() -> Void)?
    @ViewBuilder let cell: (ContentItem) -> Cell

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filterQuery = ""

    private var title: String { listing.listingTitle ?? "" }
    private var shouldShowFilter: Bool { listing.items.count > 8 }

    private var filteredItems: [ContentItem] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listing.items }
        return listing.items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if shouldShowFilter {
                    CurationGridFilterBar(query: $filterQuery, title: title)
                }
            }
            .padding(.horizontal, C.pagePad)

            if filteredItems.isEmpty, shouldShowFilter {
                CurationGridEmptyState(query: filterQuery) {
                    filterQuery = ""
                }
                .padding(.horizontal, C.pagePad)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(Array(filteredItems.enumerated()), id: \.offset) { _, item in
                        cell(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
        .onChange(of: filteredItems.count) { _, count in
            guard shouldShowFilter, !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let label = count == 1 ? "1 result" : "\(count) results"
            UIAccessibility.post(notification: .announcement, argument: label)
        }
    }

    @ViewBuilder
    private var header: some View {
        if !title.isEmpty || seeAllAction != nil {
            HStack(spacing: 10) {
                if !title.isEmpty {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: 3, height: 18)
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let seeAllAction {
                    Button("See all", action: seeAllAction)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(C.textMuted)
                }
            }
        }
    }
}

private struct CurationGridFilterBar: View {
    @Binding var query: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.textTertiary)

            TextField("Search \(title.isEmpty ? "items" : title.lowercased())", text: $query)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(C.text)
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(C.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct CurationGridEmptyState: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("No results for \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(C.text)
                .multilineTextAlignment(.center)

            Button("Clear filter", action: clear)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(C.watch, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct ContentItemCard: View {
    let item: ContentItem
    let isAutoplayBlocked: Bool

    var body: some View {
        switch item.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "show":
            ShowCarouselCard(show: item.asShowBrowseCard)
        case "short":
            ShortCarouselCard(short: item.asShort, isAutoplayBlocked: isAutoplayBlocked)
        case "episode":
            EpisodeCarouselCard(item: item)
        case "channel":
            CurationChannelCarouselCard(item: item)
        default:
            VideoCarouselCard(video: item.asFeedVideo)
        }
    }
}

private struct EpisodeCarouselCard: View {
    let item: ContentItem
    private let cardWidth = HomeCarouselMetrics.landscapeWidth

    private var subtitle: String {
        var parts = [String]()
        if let season = item.metaInt("seasonNumber"), let episode = item.metaInt("episodeNumber") {
            parts.append("S\(season) E\(episode)")
        }
        if let showTitle = item.metaString("showTitle"), !showTitle.isEmpty {
            parts.append(showTitle)
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(item.thumbnailUrl ?? item.coverUrl),
                    targetSize: CGSize(width: cardWidth, height: cardWidth / C.mediaAspectRatio(forContentType: "video"))
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .frame(width: cardWidth, height: cardWidth / C.mediaAspectRatio(forContentType: "video"))
                .clipped()

                if let duration = item.metaDouble("duration") {
                    Text(fmtDur(duration))
                        .font(.system(size: 9, weight: .semibold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.80))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.curationDisplayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(width: cardWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
            }
            .frame(width: cardWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
    }

    private func fmtDur(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

private struct CurationChannelCarouselCard: View {
    let item: ContentItem

    private var initial: String {
        item.title.first.map(String.init) ?? "?"
    }

    private var handle: String? {
        item.metaString("handle") ?? item.metaString("channelHandle")
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let url = C.mediaURL(item.thumbnailUrl) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: CarouselCardMetrics.channelAvatarSize, height: CarouselCardMetrics.channelAvatarSize)
                    ) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        initialsCircle
                    }
                } else {
                    initialsCircle
                }
            }
            .frame(width: CarouselCardMetrics.channelAvatarSize, height: CarouselCardMetrics.channelAvatarSize)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1) }

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.curationDisplayTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if item.metaBool("verified") == true {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(C.watch)
                    }
                }
                .frame(width: CarouselCardMetrics.channelWidth, alignment: .center)

                Text(channelSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(width: CarouselCardMetrics.channelWidth, height: CarouselCardMetrics.metaHeight, alignment: .center)
            }
        }
        .frame(width: CarouselCardMetrics.channelWidth)
        .contentShape(Rectangle())
    }

    private var channelSubtitle: String {
        let handleText = handle.map { "@\($0)" }
        let followersText = item.metaInt("followers").map { "\(fmtCount($0)) followers" }
        return [handleText, followersText].compactMap { $0 }.joined(separator: " • ")
    }

    private var initialsCircle: some View {
        Circle()
            .fill(Color.white.opacity(0.1))
            .overlay {
                Text(initial.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
    }

    private func fmtCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

// MARK: - Show carousel card (portrait 2:3)

private struct ShowCarouselCard: View {
    let show: ShowBrowseCard
    private let cardWidth = HomeCarouselMetrics.posterWidth
    private var thumbnailHeight: CGFloat {
        HomeCarouselMetrics.height(width: cardWidth, contentType: "show")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedRemoteImage(
                url: C.mediaURL(show.coverUrl),
                targetSize: CGSize(width: cardWidth, height: thumbnailHeight)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.07)
            }
            .frame(width: cardWidth, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))
            .clipped()
            .overlay {
                RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                if let year = show.productionYear {
                    Text(year)
                        .font(.system(size: 10))
                        .foregroundStyle(C.textMuted)
                        .frame(width: cardWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
                } else if show.seasonCount > 0 {
                    Text("\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(C.textMuted)
                        .frame(width: cardWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
                } else {
                    Color.clear.frame(width: cardWidth, height: CarouselCardMetrics.metaHeight)
                }
            }
            .frame(width: cardWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

// MARK: - Short carousel card (portrait 9:16)

private struct ShortCarouselCard: View {
    let short: Short
    let isAutoplayBlocked: Bool


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                CachedRemoteImage(
                    url: C.mediaURL(short.thumbnailUrl),
                    targetSize: CGSize(width: HomeCarouselMetrics.posterWidth, height: HomeCarouselMetrics.height(width: HomeCarouselMetrics.posterWidth, contentType: "short"))
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .aspectRatio(C.mediaAspectRatio(forContentType: "short"), contentMode: .fill)
                .frame(width: HomeCarouselMetrics.posterWidth)
                .clipped()

                Text("Short")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(6)

                if let dur = short.duration {
                    Text(fmtDur(dur))
                        .font(.system(size: 9, weight: .semibold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
            }
            .frame(width: HomeCarouselMetrics.posterWidth)
            .aspectRatio(C.mediaAspectRatio(forContentType: "short"), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(short.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .frame(width: HomeCarouselMetrics.posterWidth, alignment: .leading)

                if let ch = short.channel {
                    Text(ch.name)
                        .font(.system(size: 10))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                        .frame(width: HomeCarouselMetrics.posterWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
                } else {
                    Color.clear.frame(width: HomeCarouselMetrics.posterWidth, height: CarouselCardMetrics.metaHeight)
                }
            }
            .frame(width: HomeCarouselMetrics.posterWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: HomeCarouselMetrics.posterWidth)
    }


    private func fmtDur(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

// MARK: - Microdrama carousel card (portrait 9:16 with gradient title overlay)

private struct MicrodramaCarouselCard: View {
    let show: MicrodramaListShow

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background image
            CachedRemoteImage(
                url: C.mediaURL(show.coverUrl),
                targetSize: CGSize(width: HomeCarouselMetrics.posterWidth, height: HomeCarouselMetrics.height(width: HomeCarouselMetrics.posterWidth, contentType: "microdrama"))
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [C.listen.opacity(0.25), C.bg],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .aspectRatio(C.mediaAspectRatio(forContentType: "microdrama"), contentMode: .fill)
            .frame(width: HomeCarouselMetrics.posterWidth)
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))
            .clipped()

            // Bottom gradient
            LinearGradient(
                colors: [.black.opacity(0.85), .clear],
                startPoint: .bottom, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))

            // "Microdrama" badge (top left)
            VStack {
                HStack {
                    Text("Microdrama")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(C.listen.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
                .padding(6)
                Spacer()
            }

            // Title (bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let genre = show.genre {
                    Text(genre)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            width: HomeCarouselMetrics.posterWidth,
            height: HomeCarouselMetrics.height(width: HomeCarouselMetrics.posterWidth, contentType: "microdrama")
        )
        .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))
    }
}
