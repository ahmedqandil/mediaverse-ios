import SwiftUI
import AVKit
import UIKit

private enum MicrodramaPlaybackState: Equatable {
    case idle, loading, buffering, playing, paused, failed(String)
}

@MainActor
private final class MicrodramaPlaybackManager: ObservableObject {
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var progressByEpisode: [String: Double] = [:]
    @Published private(set) var stateByEpisode: [String: MicrodramaPlaybackState] = [:]

    private let backwardWarmCount = 2
    private let forwardWarmCount = 4
    private var assets: [String: AVURLAsset] = [:]
    private var knownDurations: [String: Double] = [:]
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var activeID: String?
    private var activeTimeObserver: Any?
    private weak var activeObserverPlayer: AVPlayer?
    private var waitingSince: Date?
    private var recoveryAttempts = 0
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trimForMemoryPressure() }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        warmTasks.values.forEach { $0.cancel() }
    }

    func player(for episodeID: String) -> AVPlayer? { players[episodeID] }
    func state(for episodeID: String) -> MicrodramaPlaybackState { stateByEpisode[episodeID] ?? .idle }

    func configure(episodes: [MicrodramaEpisode], currentID: String?, muted: Bool) {
        guard !episodes.isEmpty else { reset(); return }
        let currentIndex = currentID.flatMap { id in episodes.firstIndex { $0.id == id } } ?? 0
        let lower = max(0, currentIndex - backwardWarmCount)
        let upper = min(episodes.count - 1, currentIndex + forwardWarmCount)
        let preparedIDs = Set(episodes[lower...upper].filter { $0.videoUrl != nil }.map(\.id))

        for episode in episodes[lower...upper] {
            prepare(episode, muted: muted)
        }
        Set(players.keys).subtracting(preparedIDs).forEach(release)
        Set(assets.keys).subtracting(preparedIDs).forEach(releaseAsset)
        players.values.forEach { $0.isMuted = muted }

        if let currentID, players[currentID] != nil {
            activate(currentID)
        } else {
            pause()
        }
    }

    func prepare(_ episode: MicrodramaEpisode, muted: Bool) {
        guard let url = C.mediaURL(episode.videoUrl) else { return }
        if let duration = episode.duration, duration.isFinite, duration > 0 {
            knownDurations[episode.id] = duration
        }
        let asset = assets[episode.id] ?? AVURLAsset(url: url)
        assets[episode.id] = asset
        if warmTasks[episode.id] == nil {
            warmTasks[episode.id] = Task(priority: .utility) {
                _ = try? await asset.load(.isPlayable)
                _ = try? await asset.load(.duration)
                _ = try? await asset.load(.tracks)
            }
        }
        guard players[episode.id] == nil else { return }
        stateByEpisode[episode.id] = .loading
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        var updated = players
        updated[episode.id] = player
        players = updated
    }

    func activate(_ id: String) {
        activeID = id
        players.forEach { episodeID, player in
            episodeID == id ? player.playImmediately(atRate: 1) : player.pause()
        }
        guard let player = players[id] else { return }
        recoveryAttempts = 0
        waitingSince = nil
        installProgressObserver(for: player, episodeID: id)
    }

    func togglePlayback(_ id: String) {
        guard let player = players[id] else { return }
        if player.rate > 0 {
            player.pause()
            stateByEpisode[id] = .paused
        } else {
            activeID = id
            player.playImmediately(atRate: 1)
            installProgressObserver(for: player, episodeID: id)
        }
    }

    func retry(_ episode: MicrodramaEpisode, muted: Bool) {
        let wasActive = activeID == episode.id
        release(episode.id)
        releaseAsset(episode.id)
        prepare(episode, muted: muted)
        if wasActive || activeID == nil { activate(episode.id) }
    }

    func resume(_ episodeID: String, at seconds: Double) {
        guard seconds.isFinite, seconds > 0, let player = players[episodeID] else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() {
        activeID = nil
        players.values.forEach { $0.pause() }
        removeProgressObserver()
    }

    func reset() {
        pause()
        Array(players.keys).forEach(release)
        Array(assets.keys).forEach(releaseAsset)
    }

    private func release(_ id: String) {
        if activeID == id { removeProgressObserver() }
        players[id]?.pause()
        var updated = players
        updated.removeValue(forKey: id)
        players = updated
        stateByEpisode[id] = .idle
    }

    private func releaseAsset(_ id: String) {
        warmTasks[id]?.cancel()
        warmTasks[id] = nil
        assets[id] = nil
        knownDurations[id] = nil
    }

    private func installProgressObserver(for player: AVPlayer, episodeID: String) {
        if activeObserverPlayer === player, activeTimeObserver != nil { return }
        removeProgressObserver()
        activeObserverPlayer = player
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        activeTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player, self.activeID == episodeID, let item = player.currentItem else { return }
                let duration = item.duration.seconds
                let seekableEnd = item.seekableTimeRanges.last
                    .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) } ?? 0
                let knownDuration = self.knownDurations[episodeID] ?? 0
                let total = duration.isFinite && duration > 0
                    ? duration
                    : (seekableEnd.isFinite && seekableEnd > 0 ? seekableEnd : knownDuration)
                let current = time.seconds
                self.updatePlaybackHealth(player: player, item: item, episodeID: episodeID)
                guard current.isFinite, total.isFinite, total > 0 else { return }
                var updated = self.progressByEpisode
                updated[episodeID] = min(max(current / total, 0), 1)
                self.progressByEpisode = updated
            }
        }
    }

    private func updatePlaybackHealth(player: AVPlayer, item: AVPlayerItem, episodeID: String) {
        if item.status == .failed {
            stateByEpisode[episodeID] = .failed(item.error?.localizedDescription ?? "Video could not be played.")
            return
        }
        switch player.timeControlStatus {
        case .playing:
            waitingSince = nil
            recoveryAttempts = 0
            stateByEpisode[episodeID] = .playing
        case .paused:
            stateByEpisode[episodeID] = player.rate == 0 ? .paused : .loading
        case .waitingToPlayAtSpecifiedRate:
            stateByEpisode[episodeID] = .buffering
            let began = waitingSince ?? Date()
            waitingSince = began
            if Date().timeIntervalSince(began) > 6, recoveryAttempts < 2 {
                recoveryAttempts += 1
                waitingSince = Date()
                let current = player.currentTime()
                player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    player.playImmediately(atRate: 1)
                }
            }
        @unknown default:
            stateByEpisode[episodeID] = .loading
        }
    }

    private func trimForMemoryPressure() {
        let keep = Set([activeID].compactMap { $0 })
        Set(players.keys).subtracting(keep).forEach(release)
        Set(assets.keys).subtracting(keep).forEach(releaseAsset)
    }

    private func removeProgressObserver() {
        if let activeTimeObserver, let activeObserverPlayer {
            activeObserverPlayer.removeTimeObserver(activeTimeObserver)
        }
        activeTimeObserver = nil
        activeObserverPlayer = nil
    }
}

/// Full-screen vertical microdrama player.
/// Episodes are swiped vertically (like TikTok/Reels).
/// Mirrors /src/app/microdramas/watch/[showId]/page.tsx + MicrodramaPlayer component.
struct MicrodramaWatchView: View {

    let showId: String
    var startEpisodeNumber: Int = 1

    @State private var episodes   = [MicrodramaEpisode]()
    @State private var show: MicrodramaShowDetail?
    @State private var config: MicrodramaConfig?
    @State private var offers: MicrodramaOffers?
    @State private var remainingAdUnlocks: Int?
    @State private var adUnlockPlacement: String?
    @State private var adUnlockPolicy: MicrodramaAdUnlockPolicy?
    @State private var currentIdx = 0
    @State private var isLoading  = true
    @State private var errorMsg: String?
    @State private var showEpisodeDrawer = false
    @State private var currentEpisodeID: String?
    @State private var rewardedAdDecision: AdDecision?
    @State private var rewardedEpisodeID: String?
    @State private var rewardedAdCompleted = false
    @State private var unlockMessage: String?
    @State private var isRequestingUnlockAd = false
    @State private var followStatus: FollowStatus?
    @State private var isUpdatingFollow = false
    @State private var resumedEpisodeIDs = Set<String>()
    @State private var lastProgressReportAt = [String: Date]()
    @StateObject private var playbackManager = MicrodramaPlaybackManager()
    @AppStorage("playerMuted") private var playerMuted = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    private var currentEp: MicrodramaEpisode? { episodes.indices.contains(currentIdx) ? episodes[currentIdx] : nil }

    private var activeWindowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                loadingView
            } else if let err = errorMsg {
                errorView(err)
            } else if episodes.isEmpty {
                emptyView
            } else {
                playerStack
            }

            if let decision = rewardedAdDecision, let episodeID = rewardedEpisodeID {
                rewardedAdOverlay(decision: decision, episodeID: episodeID)
                    .zIndex(100)
            }
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .enablesInteractiveSwipeBack()
        .task { await load() }
        .alert("Unlock unavailable", isPresented: Binding(
            get: { unlockMessage != nil },
            set: { if !$0 { unlockMessage = nil } }
        )) {
            Button("OK", role: .cancel) { unlockMessage = nil }
        } message: {
            Text(unlockMessage ?? "Please try again.")
        }
        .sheet(isPresented: $showEpisodeDrawer) {
            MicrodramaEpisodesDrawer(
                episodes: episodes,
                currentEpisodeId: currentEp?.id,
                onSelect: { ep in
                    if let idx = episodes.firstIndex(where: { $0.id == ep.id }) {
                        currentIdx = idx
                        currentEpisodeID = ep.id
                    }
                    showEpisodeDrawer = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black.opacity(0.92))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                playbackManager.configure(episodes: episodes, currentID: currentEpisodeID, muted: playerMuted)
                Task { await resumeCurrentEpisodeIfNeeded() }
            } else {
                Task { await reportCurrentProgress(force: true) }
                playbackManager.pause()
            }
        }
        .onChange(of: playbackManager.progressByEpisode[currentEpisodeID ?? ""] ?? 0) { _, _ in
            Task { await reportCurrentProgress(force: false) }
        }
    }

    // MARK: - Player stack (vertical swipe)

    private var playerStack: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { idx, ep in
                            EpisodePlayerSlide(
                                episode: ep,
                                show: show,
                                totalEpisodes: episodes.count,
                                isActive: ep.id == currentEpisodeID,
                                shouldPrepare: abs(idx - currentIdx) <= 1,
                                bottomChromeHeight: 78 + geo.safeAreaInsets.bottom,
                                onBack: { dismiss() },
                                onPrev: idx > 0 ? { selectEpisode(at: idx - 1) } : nil,
                                onNext: idx < episodes.count - 1 ? { selectEpisode(at: idx + 1) } : nil,
                                offers: offers,
                                isAuthenticated: auth.isAuthenticated,
                                remainingAdUnlocks: remainingAdUnlocks,
                                isRequestingUnlockAd: isRequestingUnlockAd && rewardedEpisodeID == ep.id,
                                onWatchAd: { Task { await requestRewardedUnlockAd(for: ep) } },
                                playbackManager: playbackManager,
                                isFollowing: followStatus?.subscribed == true,
                                isUpdatingFollow: isUpdatingFollow,
                                onToggleFollow: { Task { await toggleFollow() } }
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ep.id)
                        }
                    }
                    .frame(width: geo.size.width, alignment: .top)
                    .scrollTargetLayout()
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentEpisodeID)
                .ignoresSafeArea()
                .onAppear {
                    if currentEpisodeID == nil {
                        currentEpisodeID = currentEp?.id ?? episodes.first?.id
                    }
                }
                .onChange(of: currentEpisodeID) { _, id in
                    guard let id,
                          let idx = episodes.firstIndex(where: { $0.id == id }) else { return }
                    currentIdx = idx
                    playbackManager.configure(episodes: episodes, currentID: id, muted: playerMuted)
                    Task { await resumeCurrentEpisodeIfNeeded() }
                }
                .onChange(of: currentIdx) { _, idx in
                    guard episodes.indices.contains(idx), currentEpisodeID != episodes[idx].id else { return }
                    currentEpisodeID = episodes[idx].id
                }

                if let currentEp, currentEp.videoUrl != nil {
                    episodesBottomBar(currentEp)
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom + 12, 24))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            // Jump to start episode
            if currentEpisodeID == nil, let idx = episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
                selectEpisode(at: idx)
            } else if currentEpisodeID == nil {
                selectEpisode(at: 0)
            }
            playbackManager.configure(episodes: episodes, currentID: currentEpisodeID, muted: playerMuted)
        }
        .onDisappear {
            Task { await reportCurrentProgress(force: true) }
            playbackManager.pause()
        }
        .onChange(of: playerMuted) { _, muted in
            playbackManager.configure(episodes: episodes, currentID: currentEpisodeID, muted: muted)
        }
    }

    // MARK: - Loading / error / empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading series…")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(msg).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Go back") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text("No episodes available yet").foregroundStyle(.white.opacity(0.6))
            Button("Go back") { dismiss() }.foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        let cacheKey = "microdrama.watch.v2.\(showId)"

        if let cached: MicrodramaEpisodesResponse = try? await DiskJSONCache.shared.value(forKey: cacheKey) {
            apply(cached, preserveSelection: true)
            isLoading = false
        } else if let stale: MicrodramaEpisodesResponse = try? await DiskJSONCache.shared.staleValue(forKey: cacheKey) {
            apply(stale, preserveSelection: true)
            isLoading = false
        }

        do {
            let resp = try await APIClient.shared.fetchMicrodramaEpisodes(showId: showId)
            apply(resp, preserveSelection: true)
            try? await DiskJSONCache.shared.store(resp, forKey: cacheKey, ttl: 300)
            if auth.isAuthenticated {
                followStatus = try? await APIClient.shared.fetchShowFollowStatus(id: showId)
            }
        } catch {
            if episodes.isEmpty { errorMsg = error.localizedDescription }
        }
        isLoading = false
    }

    @MainActor
    private func apply(_ response: MicrodramaEpisodesResponse, preserveSelection: Bool) {
        let previousID = preserveSelection ? currentEpisodeID : nil
        show = response.show
        config = response.config
        episodes = response.episodes
        offers = response.offers
        remainingAdUnlocks = response.remainingAdUnlocks
        adUnlockPlacement = response.adUnlockPlacement
        adUnlockPolicy = response.adUnlockPolicy

        if let previousID, let idx = response.episodes.firstIndex(where: { $0.id == previousID }) {
            currentIdx = idx
            currentEpisodeID = previousID
        } else if let idx = response.episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
            currentIdx = idx
            currentEpisodeID = response.episodes[idx].id
        } else if let first = response.episodes.first {
            currentIdx = 0
            currentEpisodeID = first.id
        }
        playbackManager.configure(episodes: response.episodes, currentID: currentEpisodeID, muted: playerMuted)
    }

    private func episodesBottomBar(_ episode: MicrodramaEpisode) -> some View {
        Button {
            showEpisodeDrawer = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                Text("Episodes")
                    .font(.subheadline.weight(.semibold))
                Text("Ep \(episode.episodeNumber)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(currentIdx + 1) / \(episodes.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: 392)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func selectEpisode(at index: Int) {
        guard episodes.indices.contains(index) else { return }
        currentIdx = index
        currentEpisodeID = episodes[index].id
    }

    @MainActor
    private func resumeCurrentEpisodeIfNeeded() async {
        guard auth.isAuthenticated,
              let episodeID = currentEpisodeID,
              !resumedEpisodeIDs.contains(episodeID) else { return }
        resumedEpisodeIDs.insert(episodeID)
        guard let saved = try? await APIClient.shared.fetchProgress(episodeId: episodeID),
              let seconds = saved.seconds,
              saved.percent < 0.95 else { return }
        playbackManager.resume(episodeID, at: Double(seconds))
    }

    @MainActor
    private func reportCurrentProgress(force: Bool) async {
        guard auth.isAuthenticated,
              let episodeID = currentEpisodeID,
              let player = playbackManager.player(for: episodeID) else { return }
        let now = Date()
        if !force, let last = lastProgressReportAt[episodeID], now.timeIntervalSince(last) < 10 { return }
        let seconds = player.currentTime().seconds
        let percent = playbackManager.progressByEpisode[episodeID] ?? 0
        guard seconds.isFinite, seconds >= 1, percent > 0 else { return }
        lastProgressReportAt[episodeID] = now
        try? await APIClient.shared.recordProgress(episodeId: episodeID, seconds: Int(seconds), percent: percent)
    }

    @MainActor
    private func toggleFollow() async {
        guard auth.isAuthenticated, !isUpdatingFollow else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }
        followStatus = try? await APIClient.shared.toggleShowFollow(id: showId)
    }

    @MainActor
    private func requestRewardedUnlockAd(for episode: MicrodramaEpisode) async {
        guard auth.isAuthenticated,
              episode.accessState == "ad_unlock",
              episode.videoUrl == nil,
              episode.adUnlockAvailable == true,
              !isRequestingUnlockAd else { return }

        isRequestingUnlockAd = true
        unlockMessage = nil
        rewardedEpisodeID = episode.id
        rewardedAdCompleted = false
        defer { isRequestingUnlockAd = false }

        let placement = adUnlockPolicy?.placement ?? adUnlockPlacement ?? "microdrama_unlock"
        do {
            let decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: episode.id,
                    contentType: "short",
                    placement: placement,
                    maxAds: 1,
                    maxDurationSec: adUnlockPolicy?.maxAdDurationSec,
                    skippable: adUnlockPolicy?.skippable,
                    skipAfterSec: adUnlockPolicy?.skipAfterSec,
                    orientation: "VERTICAL",
                    userId: auth.currentUser?.id
                )
            )
            guard decision.filled, !decision.ads.isEmpty else {
                rewardedEpisodeID = nil
                return
            }
            rewardedAdDecision = decision
        } catch {
            rewardedEpisodeID = nil
            unlockMessage = error.localizedDescription
        }
    }

    private func rewardedAdOverlay(decision: AdDecision, episodeID: String) -> some View {
        GeometryReader { geo in
            // A full-screen ignored-safe-area container can report zero here.
            // Fall back to the active window so Dynamic Island/status-bar and
            // home-indicator devices always receive real chrome clearance.
            let topSafeArea = max(geo.safeAreaInsets.top, activeWindowSafeAreaInsets.top)
            let bottomSafeArea = max(geo.safeAreaInsets.bottom, activeWindowSafeAreaInsets.bottom)
            let topInset = max(20, topSafeArea + 12)
            let bottomInset = max(20, bottomSafeArea + 16)

            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                NativeAdPlayerView(
                    decision: decision,
                    contentId: episodeID,
                    placement: adUnlockPolicy?.placement ?? adUnlockPlacement ?? "microdrama_unlock",
                    userId: auth.currentUser?.id,
                    aspectRatio: 9 / 16,
                    topContentInset: topInset,
                    bottomContentInset: bottomInset,
                    topTrailingContentInset: 52,
                    progressBottomInset: 0,
                    fillVerticalContainer: true,
                    overrideSkippable: adUnlockPolicy?.skippable,
                    overrideSkipAfterSec: adUnlockPolicy?.skipAfterSec,
                    onSkip: {
                        rewardedAdCompleted = false
                    },
                    onComplete: {
                        rewardedAdCompleted = true
                    }
                ) {
                    Task { await finishRewardedAd(for: episodeID) }
                }
                .ignoresSafeArea()

                Button {
                    rewardedAdCompleted = false
                    rewardedAdDecision = nil
                    rewardedEpisodeID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.20), lineWidth: 1) }
                }
                .padding(.top, topInset)
                .padding(.trailing, 14)
                .accessibilityLabel("Close ad")
            }
        }
        .ignoresSafeArea()
    }

    @MainActor
    private func finishRewardedAd(for episodeID: String) async {
        let completed = rewardedAdCompleted
        rewardedAdDecision = nil
        rewardedEpisodeID = nil
        guard completed else { return }
        do {
            let grant = try await APIClient.shared.grantMicrodramaAdUnlock(episodeId: episodeID)
            guard grant.granted else { return }
            remainingAdUnlocks = grant.remainingToday ?? remainingAdUnlocks
            await load()
        } catch {
            unlockMessage = error.localizedDescription
        }
    }

}

// MARK: - Single episode slide

private struct EpisodePlayerSlide: View {

    let episode: MicrodramaEpisode
    let show: MicrodramaShowDetail?
    let totalEpisodes: Int
    let isActive: Bool
    let shouldPrepare: Bool
    let bottomChromeHeight: CGFloat
    let onBack: () -> Void
    let onPrev: (() -> Void)?
    let onNext: (() -> Void)?
    let offers: MicrodramaOffers?
    let isAuthenticated: Bool
    let remainingAdUnlocks: Int?
    let isRequestingUnlockAd: Bool
    let onWatchAd: () -> Void
    @ObservedObject var playbackManager: MicrodramaPlaybackManager
    let isFollowing: Bool
    let isUpdatingFollow: Bool
    let onToggleFollow: () -> Void

    @State private var scrubProgress: Double = 0
    @State private var isSeeking = false
    @State private var showComments = false
    @State private var showSaveSheet = false
    @State private var showEnergy = false
    @State private var energyAggregate: ContentEnergyAggregate?
    @State private var commentCount = 0
    @AppStorage("playerMuted") private var playerMuted = false
    @Environment(\.openURL) private var openURL

    private var player: AVPlayer? {
        playbackManager.player(for: episode.id)
    }

    private var canPlay: Bool {
        episode.videoUrl != nil
    }

    private var playbackState: MicrodramaPlaybackState {
        playbackManager.state(for: episode.id)
    }

    private var displayedProgress: Double {
        isSeeking ? scrubProgress.clampedProgress : (playbackManager.progressByEpisode[episode.id] ?? 0).clampedProgress
    }

    private var paywallMessage: String {
        if episode.accessState == "ad_unlock" {
            if !isAuthenticated {
                return "Sign in to unlock this episode. Unlocks are saved to your account and follow you across devices."
            }
            if episode.adUnlockAvailable == true {
                return "This episode can be unlocked by watching a short ad, or with a subscription or rental."
            }
            return "You’ve hit today’s free-unlock limit. Subscribe or rent to keep watching."
        }
        if offers?.canSubscribe == true || offers?.canRent == true {
            return "Subscribe or rent this episode to continue watching."
        }
        return "This episode is not available to purchase yet."
    }

    private var showSubscribeButton: Bool {
        offers?.canSubscribe == true
    }

    private var showRentButton: Bool {
        offers?.canRent == true
    }

    private var channelTitle: String? {
        let name = show?.network?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private var showArtworkUrl: String? {
        show?.coverUrl ?? show?.bannerUrl ?? episode.thumbnailUrl
    }

    private var showTitleText: String {
        let value = show?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return "Microdrama"
    }

    private var episodeDescription: String? {
        let value = episode.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : show?.description
    }

    private var showEpisodeTitle: String {
        let showTitle = show?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeTitle = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let showTitle, !showTitle.isEmpty {
            return "\(showTitle) · E\(episode.episodeNumber) · \(episodeTitle)"
        }
        return "E\(episode.episodeNumber) · \(episodeTitle)"
    }

    var body: some View {
        ZStack {
            Color.black

            if canPlay, let player {
                // AVPlayer video (fills screen, no controls — swipe to navigate)
                AVPlayerViewRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                // Poster / locked state
                GeometryReader { artworkGeo in
                    ZStack {
                        CachedRemoteImage(
                            url: C.mediaURL(episode.thumbnailUrl),
                            targetSize: artworkGeo.size
                        ) { img in
                            img.resizable().scaledToFill().blur(radius: 24)
                        } placeholder: {
                            LinearGradient(
                                colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        }
                        .frame(width: artworkGeo.size.width, height: artworkGeo.size.height)
                        .clipped()

                        CachedRemoteImage(
                            url: C.mediaURL(episode.thumbnailUrl),
                            targetSize: artworkGeo.size
                        ) { img in
                            img.resizable().scaledToFit()
                        } placeholder: { Color.clear }
                        .frame(width: artworkGeo.size.width, height: artworkGeo.size.height)
                    }
                    .frame(width: artworkGeo.size.width, height: artworkGeo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()

                if !canPlay {
                    lockedOverlay
                }
            }

            if canPlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { handleDoubleTapEnergy() }
                    .onTapGesture(count: 1) { playbackManager.togglePlayback(episode.id) }

                playbackStatusOverlay
            }

            GeometryReader { geo in
                let safeTop = max(geo.safeAreaInsets.top, 44)
                let progressControlHeight: CGFloat = 16
                let playerVerticalGap: CGFloat = 12
                let reservedBottom = bottomChromeHeight + progressControlHeight + playerVerticalGap
                let horizontalInset: CGFloat = 24
                let rightRailInset: CGFloat = 94

                if canPlay {
                    VStack {
                        topBar(topInset: safeTop)
                        Spacer()
                        bottomInfo(
                            bottomInset: reservedBottom,
                            horizontalInset: horizontalInset,
                            trailingInset: rightRailInset
                        )
                    }

                    rightRail
                        .padding(.trailing, horizontalInset)
                        .padding(.bottom, reservedBottom + 36)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                    microdramaProgressBar(width: geo.size.width)
                        .padding(.horizontal, horizontalInset)
                        .padding(.bottom, bottomChromeHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(20)
                } else {
                    topBar(topInset: safeTop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .sheet(isPresented: $showComments) {
            StandardCommentsSheet(
                target: .episode(episode.id),
                title: "Comments"
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSaveSheet) {
            if let showID = show?.id {
                SaveToCollectionSheet(showId: showID)
            }
        }
        .sheet(isPresented: $showEnergy) {
            ContentEnergySheet(kind: .episode, contentID: episode.id) {
                energyAggregate = $0
            }
            .presentationDetents([.height(610), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .task(id: episode.id + "_\(shouldPrepare)") {
            if shouldPrepare {
                playbackManager.prepare(episode, muted: playerMuted)
                if isActive {
                    playbackManager.activate(episode.id)
                    await loadEngagement()
                }
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                if let player {
                    player.isMuted = playerMuted
                    playbackManager.activate(episode.id)
                } else {
                    playbackManager.prepare(episode, muted: playerMuted)
                    playbackManager.activate(episode.id)
                }
            }
        }
        .onChange(of: shouldPrepare) { _, prepare in
            if prepare {
                playbackManager.prepare(episode, muted: playerMuted)
                if isActive {
                    playbackManager.activate(episode.id)
                }
            }
        }
        .onChange(of: player != nil) { _, isAvailable in
            guard isAvailable, isActive, let player else { return }
            player.isMuted = playerMuted
            playbackManager.activate(episode.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard isActive,
                  let player,
                  notification.object as? AVPlayerItem === player.currentItem else { return }
            onNext?()
        }
    }

    @ViewBuilder
    private var playbackStatusOverlay: some View {
        switch playbackState {
        case .idle, .loading, .buffering:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .padding(18)
                .background(.black.opacity(0.42), in: Circle())
                .allowsHitTesting(false)
        case .paused:
            Image(systemName: "play.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.52), in: Circle())
                .allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Try Again") {
                    playbackManager.retry(episode, muted: playerMuted)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: 260)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        case .playing:
            EmptyView()
        }
    }

    private func playableDuration(for item: AVPlayerItem) -> Double {
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { return duration }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            if end.isFinite, end > 0 { return end }
        }
        return episode.duration ?? 0
    }

    private func microdramaProgressBar(width: CGFloat) -> some View {
        let safeWidth = max(1, width - 48)
        return ZStack {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                Capsule()
                    .fill(C.watch)
                    .frame(width: safeWidth * CGFloat(displayedProgress), height: 4)
                Circle()
                    .fill(C.watch)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(x: max(0, safeWidth * CGFloat(displayedProgress) - 6))
            }
            .allowsHitTesting(false)

            Slider(
                value: Binding(
                    get: { displayedProgress },
                    set: { value in
                        scrubProgress = value.clampedProgress
                        seekMicrodrama(to: value, resumePlayback: false)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { scrubProgress = displayedProgress }
                    isSeeking = editing
                    if !editing {
                        seekMicrodrama(to: scrubProgress, resumePlayback: true)
                    }
                }
            )
            .opacity(0.02)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(displayedProgress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                seekMicrodrama(to: displayedProgress + 0.05, resumePlayback: true)
            case .decrement:
                seekMicrodrama(to: displayedProgress - 0.05, resumePlayback: true)
            default:
                break
            }
        }
    }

    private func seekMicrodrama(to rawProgress: Double, resumePlayback: Bool) {
        let targetProgress = rawProgress.clampedProgress
        scrubProgress = targetProgress
        guard let player, let item = player.currentItem else { return }
        let total = playableDuration(for: item)
        guard total.isFinite, total > 0 else { return }
        let target = CMTime(seconds: total * targetProgress, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard resumePlayback, isActive else { return }
            player.playImmediately(atRate: 1)
        }
    }

    // MARK: - Top bar

    private func topBar(topInset: CGFloat) -> some View {
        HStack {
            PlatformBackButton(action: onBack)

            Spacer()

            Text("Ep \(episode.episodeNumber) of \(totalEpisodes)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.black.opacity(0.42), in: Capsule())

            Spacer()

            Button {
                playerMuted.toggle()
                player?.isMuted = playerMuted
            } label: {
                Image(systemName: playerMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 8)
    }

    // MARK: - Bottom info

    private func bottomInfo(bottomInset: CGFloat, horizontalInset: CGFloat, trailingInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                microdramaAvatar

                VStack(alignment: .leading, spacing: 1) {
                    Text(showTitleText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let channelTitle {
                        Text(channelTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Button(action: onToggleFollow) {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isFollowing ? .white : C.watch)
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .background(isFollowing ? .white.opacity(0.16) : .clear, in: Capsule())
                        .overlay { Capsule().stroke(isFollowing ? .white.opacity(0.30) : C.watch, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingFollow)

                Spacer(minLength: 0)
            }

            Text("E\(episode.episodeNumber) · \(episode.title)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if let description = episodeDescription {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            if let dur = episode.duration {
                Text(formatDur(dur))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            if let aggregate = energyAggregate, aggregate.count > 0 {
                Button {
                    presentEnergy()
                } label: {
                    SocialEnergyMeter(
                        total: Int(((aggregate.avg ?? 0) * Double(aggregate.count)).rounded()),
                        count: aggregate.count,
                        tags: aggregate.topTags
                    )
                    .frame(maxWidth: 270, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View Microdrama Energy")
                .padding(.bottom, 18)
            }
        }
        .padding(.leading, horizontalInset)
        .padding(.trailing, horizontalInset + trailingInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.76)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var microdramaAvatar: some View {
        Group {
            if let url = C.mediaURL(showArtworkUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 34, height: 34)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.12)
                }
            } else {
                Text(String((showTitleText.first ?? "?").uppercased()))
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

    private var rightRail: some View {
        VStack(alignment: .center, spacing: 18) {
            railButton(
                icon: "energy",
                fallback: "bolt.fill",
                color: C.watch,
                background: C.watch.opacity(0.22),
                label: {
                    if let count = energyAggregate?.count, count > 0 {
                        return "\(formatCount(count)) Energy"
                    }
                    return "Add Energy"
                }(),
                labelColor: .white
            ) {
                presentEnergy()
            }

            railButton(icon: "message-square", fallback: "bubble.left", label: commentCount > 0 ? formatCount(commentCount) : "Comment") {
                showComments = true
            }

            railButton(icon: "share", fallback: "square.and.arrow.up", label: "Share") {
                shareEpisode()
            }

            railButton(
                icon: "bookmark",
                fallback: "bookmark",
                color: .white,
                background: .black.opacity(0.35),
                label: "Save",
                labelColor: .white.opacity(0.85)
            ) { showSaveSheet = true }
        }
    }

    private func railButton(
        icon: String,
        fallback: String,
        color: Color = .white,
        background: Color = .black.opacity(0.35),
        label: String?,
        labelColor: Color = .white.opacity(0.85),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                MediaverseIcon(name: icon, fallbackSystemName: fallback)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(color)
                    .frame(width: 50, height: 50)
                    .background(background)
                    .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
                    .clipShape(Circle())
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func shareEpisode() {
        guard let url = URL(string: "\(C.baseURL)/microdramas/watch/\(show?.id ?? episode.id)?episode=\(episode.episodeNumber)") else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.presentFromRoot()
    }

    private func handleDoubleTapEnergy() {
        presentEnergy()
    }

    private func presentEnergy() {
        if isAuthenticated {
            showEnergy = true
        } else {
            NotificationCenter.default.post(name: .profileTabRequested, object: nil)
        }
    }

    @MainActor
    private func loadEngagement() async {
        guard isActive else { return }
        async let detailRequest = try? APIClient.shared.fetchEpisode(id: episode.id)
        async let energyRequest = try? APIClient.shared.fetchContentEnergy(
            contentPath: "episodes",
            id: episode.id
        )
        let (detail, energy) = await (detailRequest, energyRequest)
        commentCount = detail?.comments.count ?? 0
        energyAggregate = energy?.aggregate
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    // MARK: - Locked overlay

    private var lockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.78)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.6))
                if episode.accessState == "ad_unlock" {
                    Text("WATCH TO UNLOCK")
                        .font(.system(size: 11, weight: .black))
                        .tracking(0.8)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color(hex: "#FACC15"), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(episode.accessState == "ad_unlock" ? "Episode \(episode.episodeNumber)" : "Episode \(episode.episodeNumber) is locked")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(paywallMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                if episode.accessState == "ad_unlock",
                   isAuthenticated,
                   episode.adUnlockAvailable == true,
                   let remainingAdUnlocks,
                   remainingAdUnlocks > 0 {
                    Text("\(remainingAdUnlocks) free \(remainingAdUnlocks == 1 ? "unlock" : "unlocks") left today")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: "#FACC15"))
                }

                if episode.accessState == "ad_unlock",
                   isAuthenticated,
                   episode.adUnlockAvailable == true {
                    Button(action: onWatchAd) {
                        HStack(spacing: 8) {
                            if isRequestingUnlockAd {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "play.rectangle.fill")
                            }
                            Text(isRequestingUnlockAd ? "Finding an ad…" : "Watch a short ad to unlock")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "#FACC15"), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequestingUnlockAd)
                    .frame(maxWidth: 330)
                }

                VStack(spacing: 10) {
                    if showSubscribeButton || showRentButton {
                        HStack(spacing: 10) {
                            if showSubscribeButton {
                                Button {
                                    if let url = URL(string: C.baseURL + "/subscribe") { openURL(url) }
                                } label: {
                                    Text("Subscribe")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.black)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 52)
                                        .background(.white, in: Capsule())
                                }
                            }

                            if showRentButton {
                                Button {
                                    if let showID = show?.id,
                                       let url = URL(string: C.baseURL + "/microdramas/\(showID)") { openURL(url) }
                                } label: {
                                    Text("Rent episode")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 52)
                                        .background(.white.opacity(0.14), in: Capsule())
                                        .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 330)
            }
            .padding()
        }
    }

    private func formatDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

// MARK: - AVPlayer SwiftUI bridge

@MainActor
private struct AVPlayerViewRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = AVPlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerView = uiView as? AVPlayerUIView {
            if playerView.player !== player {
                playerView.player = player
            }
        }
    }
}

private class AVPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set {
            (layer as? AVPlayerLayer)?.player = newValue
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        }
    }
}

private extension Double {
    var clampedProgress: Double {
        guard isFinite else { return 0 }
        return min(max(self, 0), 1)
    }
}

// MARK: - Episodes drawer

private struct MicrodramaEpisodesDrawer: View {
    let episodes: [MicrodramaEpisode]
    let currentEpisodeId: String?
    let onSelect: (MicrodramaEpisode) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        Button {
                            onSelect(episode)
                        } label: {
                            MicrodramaEpisodeDrawerRow(
                                episode: episode,
                                isCurrent: episode.id == currentEpisodeId
                            )
                        }
                        Divider()
                            .background(.white.opacity(0.08))
                            .padding(.leading, 82)
                    }
                }
                .padding(.top, 10)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

private struct MicrodramaEpisodeDrawerRow: View {
    let episode: MicrodramaEpisode
    let isCurrent: Bool

    private var isLocked: Bool {
        episode.videoUrl == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(episode.thumbnailUrl),
                    targetSize: CGSize(width: 50, height: 89)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 50, height: 89)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Image(systemName: isLocked ? "lock.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.68), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ep \(episode.episodeNumber)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isCurrent ? C.watch : .white.opacity(0.62))

                Text(episode.title)
                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let duration = episode.duration {
                    Text(formatDur(duration))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.46))
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.watch)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? C.watch.opacity(0.12) : .clear)
    }

    private func formatDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}
