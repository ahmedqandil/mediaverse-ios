import SwiftUI
import AVKit

struct EpisodeWatchView: View {

    let episodeId: String

    @State private var currentEpisodeId: String
    @State private var episode: EpisodeDetail?
    @State private var entitlement: EntitlementCheckResponse?
    @State private var isLoading   = true
    @State private var loadError:  String?
    @State private var player: AVPlayer?
    @State private var progressTimer: Timer?
    @State private var prerollAdDecision: AdDecision?
    @State private var midrollAdDecision: AdDecision?
    @State private var activeAdBreak: AdBreak?
    @State private var adBreaks: [AdBreak] = []
    @State private var watchedAdBreakIds: Set<String> = []
    @State private var pendingAdBreakIds: Set<String> = []
    @State private var pendingContentSeekAfterAd: Double?
    @State private var activeAdPlayer: AVPlayer?
    @State private var activeAdPresentation: ActiveAdPresentation?
    @State private var restoredAdPlayer: AVPlayer?
    @State private var restoredAdPresentation: ActiveAdPresentation?
    @State private var isCollapsingAdToMiniPlayer = false
    @State private var episodeAdConfig: PlatformShortsAdsConfig = .episodeDefault
    @State private var episodeAdPolicy: EffectiveAdPolicy = .disabled(reason: "not_resolved")
    @State private var isFollowing   = false
    @State private var followerCount = 0
    @State private var savedProgress: Double = 0

    // ── Like / dislike (optimistic)
    @State private var userLike:  String?  // "like" | "dislike" | nil
    @State private var likeCount: Int = 0

    // ── Comments
    @State private var localComments:    [Comment] = []
    @State private var showCommentsSheet           = false

    // ── Autoplay
    @State private var autoplayCountdown: Int  = 0
    @State private var autoplayTask:     Task<Void, Never>?
    @State private var autoplayDest:      AppRoute?
    @State private var showReplayPrompt         = false

    // ── Moment likes (heatmap)
    @State private var heatmapBuckets:   [Int]  = []
    @State private var likedSeconds:     [Int]  = []
    @State private var currentPlayerSec: Int    = 0
    @State private var momentObserver:   Any?   = nil
    @State private var momentObserverPlayer: AVPlayer? = nil

    // ── Timed player markers
    @State private var playerMarkers: [PlayerMarker] = []
    @State private var dismissedMarkerIds: Set<String> = []
    @State private var markerRoute: AppRoute?
    @State private var isCheckingOut = false
    @State private var checkoutMessage: String?
    @State private var pendingCheckoutRefresh = false
    @State private var recordedPPVPlaybackEpisodeIds: Set<String> = []
    @State private var clipReactionReloadToken = 0
    @State private var insertedClipPostToken = 0
    @State private var insertedClipPost: UserPost?
    @State private var activeClipRange: ClipPlaybackRange?
    @State private var underPlayerPanel: WatchUnderPlayerPanel?
    @State private var playerDragOffset: CGFloat = 0
    @State private var isCollapsingToMiniPlayer = false
    @State private var hideControlsForExpandedHandoff = false
    @State private var isFullscreenPlayerPresented = false
    @State private var reuseCurrentPlayerForFullscreenSelection = false
    @State private var episodeListExpanded = true
    @State private var selectedSeasonId: String?
    @AppStorage("playerMuted") private var playerMuted = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager

    private var underPlayerPanelAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.88)
    }

    private var underPlayerPanelTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var isMovie: Bool {
        episode?.season.show?.isMovie ?? false
    }

    init(episodeId: String) {
        self.episodeId = episodeId
        _currentEpisodeId = State(initialValue: episodeId)
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if let ep = episode {
                mainContent(ep)
            } else if isLoading {
                if !miniPlayer.isExpansionHandoffActive {
                    ProgressView().tint(C.watch)
                }
            } else {
                VStack(spacing: 16) {
                    MediaverseIcon(name: "warning", fallbackSystemName: "exclamationmark.triangle")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(C.textMuted.opacity(0.4))
                    Text(loadError ?? "Failed to load episode")
                        .font(.system(size: 14))
                        .foregroundStyle(C.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        loadError = nil
                        isLoading = true
                        Task { await load() }
                    } label: {
                        Text("Retry")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(C.watch)
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .disablesInteractiveSwipeBack()
        .task(id: currentEpisodeId) { await load() }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear { handleDisappear() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, pendingCheckoutRefresh else { return }
            pendingCheckoutRefresh = false
            Task { await refreshAfterExternalCheckout() }
        }
        .sheet(isPresented: $showCommentsSheet) {
            StandardCommentsSheet(
                target: .episode(currentEpisodeId),
                initialComments: localComments,
                initialCount: localComments.totalCommentCount
            ) {
                showCommentsSheet = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            handlePlaybackEnded(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard UIDevice.current.orientation.isLandscape else { return }
            if prerollAdDecision != nil || midrollAdDecision != nil {
                presentAdFullscreenPlayerIfNeeded()
            } else {
                presentFullscreenPlayerIfNeeded()
            }
        }
        .navigationDestination(item: $autoplayDest) { route in
            routeDestination(route)
        }
        .navigationDestination(item: $markerRoute) { route in
            routeDestination(route)
        }
        .alert("Checkout", isPresented: Binding(
            get: { checkoutMessage != nil },
            set: { if !$0 { checkoutMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(checkoutMessage ?? "")
        }
    }

    // MARK: - Main

    private func mainContent(_ ep: EpisodeDetail) -> some View {
        GeometryReader { geo in
            let progress = collapseProgress(in: geo)
            VStack(spacing: 0) {
                episodePinnedPlayer(ep, geometry: geo, progress: progress)

                if let panel = underPlayerPanel {
                    episodeUnderPlayerPanelView(panel, episode: ep)
                        .id(panel.id)
                        .transition(underPlayerPanelTransition)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                    if let ad = activeInlineAdCreative {
                        NativeAdCompanionCard(ad: ad)
                            .padding(.bottom, 4)
                    }

                    // Show + season label
                    if let show = ep.season.show {
                        NavigationLink(value: AppRoute.show(show.id)) {
                            Text(show.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(C.watch)
                        }
                    }

                    // Episode title
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("S\(ep.season.seasonNumber) · E\(ep.episodeNumber)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(C.textMuted)
                            Text(ep.title)
                                .font(.headline)
                                .foregroundStyle(C.text)
                        }
                        Spacer()
                    }

                    // Rental info bar (PPV users only)
                    if let rental = ep.rentalInfo {
                        RentalInfoBar(info: rental)
                    }

                    // Views
                    if let views = ep.views, views > 0 {
                        Text(fmtCount(views) + " views")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }

                    // Like / Dislike row
                    if auth.isAuthenticated {
                        HStack(spacing: 8) {
                            // Like + Dislike pill (grouped, matching VideoWatchView)
                            HStack(spacing: 0) {
                                Button {
                                    Task { await toggleLike("like", episodeId: ep.id) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: userLike == "like" ? "heart.fill" : "heart")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(userLike == "like" ? C.watch : C.textMuted)
                                        Text(likeCount > 0 ? fmtCount(likeCount) : "Like")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(userLike == "like" ? .white : C.textMuted)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(C.surface)
                                }

                                Rectangle()
                                    .fill(C.border)
                                    .frame(width: 1, height: 20)

                                Button {
                                    Task { await toggleLike("dislike", episodeId: ep.id) }
                                } label: {
                                    Image(systemName: userLike == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(userLike == "dislike" ? .white : C.textMuted)
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(C.surface)
                                }
                            }
                            .clipShape(Capsule())
                            .overlay { Capsule().stroke(C.border, lineWidth: 1) }

                            Spacer()
                        }
                        .animation(.easeInOut(duration: 0.15), value: userLike)
                    }

                    Divider().background(C.border)

                    // Follow show
                    HStack {
                        if let show = ep.season.show {
                            NavigationLink(value: AppRoute.show(show.id)) {
                                HStack(spacing: 8) {
                                    CachedRemoteImage(
                                        url: C.mediaURL(show.coverUrl),
                                        targetSize: CGSize(width: 36, height: 36)
                                    ) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.white.opacity(0.08) }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(show.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(C.text)
                                        Text(fmtCount(followerCount) + " followers")
                                            .font(.caption2).foregroundStyle(C.textMuted)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await toggleFollow(showId: ep.season.show?.id ?? "") }
                        } label: {
                            Text(isFollowing ? "Following" : "Follow")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isFollowing ? C.textMuted : .black)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(isFollowing ? C.surface : C.watch)
                                .clipShape(Capsule())
                                .overlay {
                                    if isFollowing { Capsule().stroke(C.border, lineWidth: 1) }
                                }
                        }
                    }

                    Divider().background(C.border)

                    // Prev / Next navigation + Share + Fullscreen
                    HStack(spacing: 8) {
                        if let prev = ep.prevEp {
                            Button {
                                playEpisodeInPlace(prev.id)
                            } label: {
                                HStack(spacing: 4) {
                                    MediaverseIcon(name: "chevron-left", fallbackSystemName: "chevron.left")
                                        .frame(width: 11, height: 11)
                                    Text("E\(prev.episodeNumber)").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(C.textMuted)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(C.surface)
                                .clipShape(Capsule())
                                .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canNavigate(to: prev))
                            .opacity(canNavigate(to: prev) ? 1 : 0.55)
                        }
                        Spacer()
                        if let next = ep.nextEp {
                            Button {
                                playEpisodeInPlace(next.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("E\(next.episodeNumber)").font(.system(size: 13, weight: .semibold))
                                    MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                                        .frame(width: 11, height: 11)
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(C.watch)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canNavigate(to: next))
                            .opacity(canNavigate(to: next) ? 1 : 0.55)
                        }
                        // Share
                        Button {
                            shareEpisode(ep)
                        } label: {
                            MediaverseIcon(name: "share", fallbackSystemName: "square.and.arrow.up")
                                .frame(width: 13, height: 13)
                                .foregroundStyle(C.textMuted)
                                .frame(width: 36, height: 36)
                                .background(C.surface)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(C.border, lineWidth: 1) }
                        }
                    }

                    episodeListSection(ep)

                    // ── Clip reactions (PostSection) ──────────────────────────
                    PostSectionView(
                        target: .episode(ep.id),
                        reloadToken: clipReactionReloadToken,
                        insertedPostToken: insertedClipPostToken,
                        insertedPost: insertedClipPost,
                        previewLimit: 2,
                        onShowMore: { _ in setUnderPlayerPanel(.reactions) },
                        onSeek: { seekSeconds in
                            activeClipRange = nil
                            let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                            player?.seek(to: t, toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
                        },
                        onPlayClip: { post in
                            playClipPost(post)
                        }
                    )

                    // Comments
                    Divider().background(C.border)
                    episodeCommentsSection(episodeId: ep.id)
                        }
                        .padding(C.pagePad)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(underPlayerPanelAnimation, value: underPlayerPanel?.id)
            .background(C.bg)
            .simultaneousGesture(playerCollapseGesture)
        }
    }

    private func episodePinnedPlayer(_ ep: EpisodeDetail, geometry geo: GeometryProxy, progress: CGFloat) -> some View {
        ZStack {
            if ep.comingSoon == true {
                comingSoonOverlay(ep)
            } else if entitlement?.visible == false {
                notDistributedOverlay(ep)
            } else if C.mediaURL(ep.videoUrl) != nil, let p = player {
                if let prerollAdDecision {
                    NativeAdPlayerView(
                        decision: prerollAdDecision,
                        contentId: currentEpisodeId,
                        placement: "preroll",
                        breakId: "preroll",
                        onFullscreen: { presentAdFullscreenPlayerIfNeeded() },
                        preservePlaybackOnDisappear: isCollapsingAdToMiniPlayer,
                        externalPlayer: restoredAdPlayer,
                        initialAdIndex: restoredAdPresentation?.currentAdIndex ?? 0,
                        isPresentationOnly: restoredAdPlayer != nil,
                        brandCardPlacement: .hidden,
                        adPolicy: episodeAdPolicy,
                        adRemoval: episodeAdPolicy.adRemoval,
                        onActivePlayerChanged: { activeAdPlayer = $0 },
                        onActiveAdPresentationChanged: { activeAdPresentation = $0 },
                        onSkip: nil,
                        onFinish: nil
                    ) {
                        finishEpisodePreroll()
                    }
                    .frame(maxWidth: .infinity)
                } else if let midrollAdDecision, let activeAdBreak {
                    NativeAdPlayerView(
                        decision: midrollAdDecision,
                        contentId: currentEpisodeId,
                        placement: activeAdBreak.placement,
                        breakId: activeAdBreak.breakId,
                        onFullscreen: { presentAdFullscreenPlayerIfNeeded() },
                        preservePlaybackOnDisappear: isCollapsingAdToMiniPlayer,
                        externalPlayer: restoredAdPlayer,
                        initialAdIndex: restoredAdPresentation?.currentAdIndex ?? 0,
                        isPresentationOnly: restoredAdPlayer != nil,
                        brandCardPlacement: .hidden,
                        adPolicy: episodeAdPolicy,
                        adRemoval: episodeAdPolicy.adRemoval,
                        onActivePlayerChanged: { activeAdPlayer = $0 },
                        onActiveAdPresentationChanged: { activeAdPresentation = $0 },
                        onSkip: nil,
                        onFinish: nil
                    ) {
                        finishEpisodeAdBreak()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    WatchPlayerChrome(
                        player: p,
                        heatmapBuckets: heatmapBuckets,
                        likedSeconds: likedSeconds,
                        isAuthenticated: auth.isAuthenticated,
                        onLikeMoment: { sec in
                            Task { await likeMomentEpisode(id: ep.id, sec: sec) }
                        },
                        showSpoilerToggle: true,
                        onClipRequest: { markIn, markOut, caption, isSpoiler, thumbnailData in
                            let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                            let thumbnailUrl = try await uploadClipThumbnailIfNeeded(thumbnailData)
                            let post = try await APIClient.shared.createPost(
                                episodeId: ep.id,
                                markIn: markIn,
                                markOut: markOut,
                                caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                                isSpoiler: isSpoiler,
                                thumbnailUrl: thumbnailUrl
                            )
                            await MainActor.run {
                                insertedClipPost = post
                                insertedClipPostToken += 1
                            }
                        },
                        activeClipRange: $activeClipRange,
                        onPrevious: ep.prevEp.flatMap { previous in
                            canNavigate(to: previous) ? { playEpisodeInPlace(previous.id) } : nil
                        },
                        onNext: ep.nextEp.flatMap { next in
                            canNavigate(to: next) ? { playEpisodeInPlace(next.id) } : nil
                        },
                        onBack: { collapseToMiniPlayer() },
                        onFullscreen: { presentFullscreenPlayerIfNeeded() },
                        adBreaks: adBreaks,
                        watchedAdBreakIds: watchedAdBreakIds,
                        onAdBreakRequested: { adBreak, resumeTime in
                            Task { await startEpisodeAdBreak(adBreak, resumeTime: resumeTime) }
                        },
                        knownDuration: ep.duration,
                        controlsInitiallyVisible: !hideControlsForExpandedHandoff
                    ) {
                        playerMarkerOverlay
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if entitlement?.playable == false || ep.videoUrl == nil {
                paywallOverlay(ep)
            } else {
                Color.black
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay { ProgressView().tint(.white) }
            }
            if autoplayCountdown > 0, let next = ep.nextEp {
                episodeAutoplayOverlay(next: next)
            } else if showReplayPrompt {
                episodeReplayOverlay
            }
        }
        .frame(width: geo.size.width)
        .scaleEffect(x: collapseScale(progress), y: collapseScale(progress), anchor: .top)
        .offset(y: collapseYOffset(in: geo, progress: progress))
        .opacity(max(0.82, 1 - progress * 0.18))
        .frame(maxWidth: .infinity)
        .frame(height: playerVisibleHeight(in: geo, progress: progress), alignment: .topLeading)
        .background(Color.black)
        .zIndex(10)
    }

    private func collapseProgress(in geo: GeometryProxy) -> CGFloat {
        let distance = collapseDistance(in: geo)
        return min(max(playerDragOffset / distance, 0), 1)
    }

    private func collapseDistance(in geo: GeometryProxy) -> CGFloat {
        max(150, geo.size.height * 0.22)
    }

    private func collapseScale(_ progress: CGFloat) -> CGFloat {
        1 - progress * 0.54
    }

    private func collapseYOffset(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        let targetY = max(0, geo.size.height - 168)
        return targetY * progress
    }

    private func playerVisibleHeight(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        geo.size.width * 9 / 16
    }

    private var episodePlayerBackButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    MediaverseIcon(name: "chevron-down", fallbackSystemName: "chevron.down")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.36))
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 48)
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    private func collapseToMiniPlayer() {
        guard !isCollapsingToMiniPlayer, let episode else { return }
        let isAdActive = prerollAdDecision != nil || midrollAdDecision != nil
        guard canCollapseCurrentPlayer,
              let handoffPlayer = isAdActive ? activeAdPlayer : player else {
            resetPlayerDragOffset()
            return
        }
        isCollapsingToMiniPlayer = true
        if isAdActive {
            isCollapsingAdToMiniPlayer = true
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.94)) {
            playerDragOffset = 999
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if isAdActive {
                miniPlayer.presentAd(player: handoffPlayer, title: "Ad · \(episode.title)", route: .episode(episode.id), presentation: activeAdPresentation)
            } else {
                miniPlayer.present(player: handoffPlayer, title: episode.title, route: .episode(episode.id))
            }
            dismiss()
        }
    }

    private var canCollapseCurrentPlayer: Bool {
        if prerollAdDecision != nil || midrollAdDecision != nil {
            return activeAdPlayer != nil
        }
        guard let episode,
              player != nil,
              C.mediaURL(episode.videoUrl) != nil,
              episode.comingSoon != true,
              entitlement?.visible != false,
              entitlement?.playable != false else {
            return false
        }
        return true
    }

    private func resetPlayerDragOffset() {
        guard playerDragOffset != 0 else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            playerDragOffset = 0
        }
    }

    private var canDismissCurrentPlayerWithoutMiniPlayer: Bool {
        episode != nil && !canCollapseCurrentPlayer
    }

    private func dismissPlayerWithoutMiniPlayer() {
        guard !isCollapsingToMiniPlayer else { return }
        isCollapsingToMiniPlayer = true
        withAnimation(.spring(response: 0.24, dampingFraction: 0.94)) {
            playerDragOffset = 999
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            dismiss()
        }
    }

    private var playerCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCollapsingToMiniPlayer,
                      (canCollapseCurrentPlayer || canDismissCurrentPlayerWithoutMiniPlayer),
                      value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) * 1.15 else { return }
                let translation = min(190, value.translation.height)
                playerDragOffset = translation
                if translation > 118 {
                    if canCollapseCurrentPlayer {
                        collapseToMiniPlayer()
                    } else {
                        dismissPlayerWithoutMiniPlayer()
                    }
                }
            }
            .onEnded { value in
                guard !isCollapsingToMiniPlayer else { return }
                guard canCollapseCurrentPlayer || canDismissCurrentPlayerWithoutMiniPlayer else {
                    resetPlayerDragOffset()
                    return
                }
                let translation = max(0, value.translation.height)
                let predicted = max(0, value.predictedEndTranslation.height)
                let shouldMinimize = translation > 58 || predicted > 104
                if shouldMinimize {
                    if canCollapseCurrentPlayer {
                        collapseToMiniPlayer()
                    } else {
                        dismissPlayerWithoutMiniPlayer()
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        playerDragOffset = 0
                    }
                }
            }
    }

    private func episodeUnderPlayerPanelView(_ panel: WatchUnderPlayerPanel, episode ep: EpisodeDetail) -> some View {
        VStack(spacing: 0) {
            underPlayerPanelHeader(panel)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PostSectionView(
                        target: .episode(ep.id),
                        reloadToken: clipReactionReloadToken,
                        insertedPostToken: insertedClipPostToken,
                        insertedPost: insertedClipPost,
                        startsExpanded: true,
                        onSeek: { seekSeconds in
                            activeClipRange = nil
                            let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                            player?.seek(to: t, toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
                        },
                        onPlayClip: { post in
                            playClipPost(post)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .id(panel.id)
                .padding(C.pagePad)
            }
        }
    }

    private func underPlayerPanelHeader(_ panel: WatchUnderPlayerPanel) -> some View {
        HStack(spacing: 12) {
            Button {
                setUnderPlayerPanel(nil)
            } label: {
                MediaverseIcon(name: "chevron-left", fallbackSystemName: "chevron.left")
                    .frame(width: 15, height: 15)
                    .foregroundStyle(C.text)
                    .frame(width: 36, height: 36)
                    .background(C.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text("Clip reactions")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(C.text)
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.border).frame(height: 1)
        }
    }

    private func setUnderPlayerPanel(_ panel: WatchUnderPlayerPanel?) {
        withAnimation(underPlayerPanelAnimation) {
            underPlayerPanel = panel
        }
    }

    private var activeInlineAdCreative: AdCreative? {
        let decision = prerollAdDecision ?? midrollAdDecision
        let index = activeAdPresentation?.currentAdIndex
            ?? restoredAdPresentation?.currentAdIndex
            ?? 0
        guard let decision, decision.ads.indices.contains(index) else { return nil }
        return decision.ads[index]
    }

    // MARK: - Episode list

    private func episodeListSection(_ ep: EpisodeDetail) -> some View {
        let seasons = episodeSeasons(for: ep)
        let activeSeasonId = selectedSeasonId ?? ep.seasonId
        let activeSeason = seasons.first(where: { $0.id == activeSeasonId }) ?? seasons.first
        let episodes = activeSeason?.episodes.sorted { $0.episodeNumber < $1.episodeNumber } ?? []

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    episodeListExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "list.bullet.rectangle")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(C.watch)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isMovie ? "Movie" : "Episodes")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(C.text)
                        if let activeSeason {
                            Text(isMovie ? "Movie" : "Season \(activeSeason.seasonNumber)")
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    Spacer()
                    MediaverseIcon(name: episodeListExpanded ? "chevron-up" : "chevron-down", fallbackSystemName: episodeListExpanded ? "chevron.up" : "chevron.down")
                        .frame(width: 14, height: 14)
                        .foregroundStyle(C.textMuted)
                }
            }
            .buttonStyle(.plain)

            if episodeListExpanded {
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons) { season in
                                seasonChip(season, isSelected: season.id == activeSeasonId)
                            }
                        }
                    }
                }

                if episodes.isEmpty {
                    Text("No episodes in this season yet.")
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(episodes) { item in
                            episodeListRow(item, currentEpisodeId: ep.id, seasonNumber: activeSeason?.seasonNumber ?? ep.season.seasonNumber)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
    }

    private func seasonChip(_ season: EpisodeSeason, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedSeasonId = season.id
            }
        } label: {
            Text(isMovie ? "Movie" : "Season \(season.seasonNumber)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .black : C.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? C.watch : Color.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func episodeListRow(_ item: EpisodeListItem, currentEpisodeId: String, seasonNumber: Int) -> some View {
        let isCurrent = item.id == currentEpisodeId
        let isPlayable = item.comingSoon != true && item.videoUrl != nil

        Group {
            if isCurrent || !isPlayable {
                episodeListRowContent(item, isCurrent: isCurrent, isPlayable: isPlayable, seasonNumber: seasonNumber)
            } else {
                NavigationLink(value: AppRoute.episode(item.id)) {
                    episodeListRowContent(item, isCurrent: false, isPlayable: true, seasonNumber: seasonNumber)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeListRowContent(_ item: EpisodeListItem, isCurrent: Bool, isPlayable: Bool, seasonNumber: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                CachedRemoteImage(
                    url: C.mediaURL(item.thumbnailUrl),
                    targetSize: CGSize(width: 112, height: 63)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 112, height: 63)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 7))

                if isCurrent {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                if isCurrent || isPlayable {
                    MediaverseIcon(name: "play", fallbackSystemName: "play.fill")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(isCurrent ? C.watch : .white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(isCurrent ? 0.34 : 0.48), in: Circle())
                }

                if let duration = item.duration {
                    episodeDurationBadge(duration)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 112, height: 63)

            VStack(alignment: .leading, spacing: 4) {
                Text("S\(seasonNumber) · E\(item.episodeNumber)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isCurrent ? C.watch : C.textMuted)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isPlayable || isCurrent ? C.text : C.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            if isCurrent {
                Text("Now")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(C.watch)
                    .clipShape(Capsule())
            } else if !isPlayable {
                Text(item.comingSoon == true ? "Soon" : "Locked")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
            } else {
                MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                    .frame(width: 12, height: 12)
                    .foregroundStyle(C.textMuted)
            }
        }
        .padding(8)
        .background(isCurrent ? C.watch.opacity(0.10) : Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? C.watch.opacity(0.45) : Color.clear, lineWidth: 1)
        }
    }

    private func episodeDurationBadge(_ secs: Double) -> some View {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let label = h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"

        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .fontDesign(.monospaced)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(4)
    }

    private func episodeSeasons(for ep: EpisodeDetail) -> [EpisodeSeason] {
        var byId: [String: EpisodeSeason] = [:]
        byId[ep.season.id] = ep.season

        for season in ep.season.show?.seasons ?? [] {
            byId[season.id] = season
        }

        return byId.values
            .filter { !$0.episodes.isEmpty }
            .sorted { $0.seasonNumber < $1.seasonNumber }
    }

    // MARK: - Paywall overlay

    @ViewBuilder
    private func paywallOverlay(_ ep: EpisodeDetail) -> some View {
        let access = entitlement
        let offeredTypes = resolvedOfferedTypes(access: access)
        let subscribePaywall: PaywallInfo? = nil
        let rentPaywall = rentPaywallInfo(from: access, episode: ep)
        let showSignIn = !auth.isAuthenticated && !offeredTypes.isEmpty
        let canSubscribe = offeredTypes.contains("SVOD")
        let canRent = offeredTypes.contains("PPV")
        let shouldShowCTA = shouldShowEpisodeGateCTA(accessCode: access?.code, offeredTypes: offeredTypes)
        let rentColor = episodeRentalColor
        let gateTint = episodeGateTint(accessCode: access?.code, offeredTypes: offeredTypes)
        let title = paywallTitle(access: access, offeredTypes: offeredTypes)

        ZStack {
            // Blurred poster
            CachedRemoteImage(
                url: C.mediaURL(ep.thumbnailUrl),
                targetSize: CGSize(width: 390, height: 219)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.black }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .blur(radius: 12)
            .overlay { Color.black.opacity(0.6) }

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    if episodeGateUsesLock(accessCode: access?.code) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.8)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(gateTint)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(ep.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Text(paywallSubtitle(access: access, offeredTypes: offeredTypes))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                if let priceText = gatePriceText(subscribePaywall: subscribePaywall, rentPaywall: rentPaywall, offeredTypes: offeredTypes),
                   shouldShowCTA,
                   !showSignIn {
                    Text(priceText)
                        .font(.title3.bold()).foregroundStyle(C.watch)
                }

                if showSignIn && shouldShowCTA {
                    Button {
                        Task { try? await auth.signInWithGoogle() }
                    } label: {
                        Text("Sign in")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .background(C.listen)
                    .clipShape(Capsule())
                } else if shouldShowCTA {
                    HStack(spacing: 10) {
                        if canSubscribe {
                            Button {
                                Task { await runSubscribeCheckout(subscribePaywall) }
                            } label: {
                                if isCheckingOut {
                                    ProgressView().tint(.black)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Text("Subscribe")
                                }
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .frame(height: 52)
                            .background(C.listen)
                            .clipShape(Capsule())
                            .disabled(isCheckingOut)
                        }

                        if canRent, let pw = rentPaywall {
                            Button {
                                Task { await runPaywallCheckout(pw) }
                            } label: {
                                if isCheckingOut {
                                    ProgressView().tint(canSubscribe ? rentColor : .black)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Text(rentLabel(for: pw, episode: ep))
                                }
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(canSubscribe ? rentColor : .black)
                            .padding(.horizontal, 22)
                            .frame(height: 52)
                            .background(canSubscribe ? rentColor.opacity(0.10) : rentColor)
                            .overlay {
                                Capsule().stroke(rentColor.opacity(0.40), lineWidth: canSubscribe ? 1 : 0)
                            }
                            .clipShape(Capsule())
                            .disabled(isCheckingOut)
                        }
                    }
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private func notDistributedOverlay(_ ep: EpisodeDetail) -> some View {
        ZStack {
            CachedRemoteImage(
                url: C.mediaURL(ep.thumbnailUrl),
                targetSize: CGSize(width: 390, height: 219)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.black }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .blur(radius: 10)
            .overlay { Color.black.opacity(0.68) }

            VStack(spacing: 10) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Not available")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This episode is not distributed in your region.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private func resolvedOfferedTypes(access: EntitlementCheckResponse?) -> [String] {
        let types = access?.offeredTypes.map(normalizedEntitlementType).filter { $0 != "AVOD" } ?? []
        return Array(Set(types))
    }

    private func rentPaywallInfo(from access: EntitlementCheckResponse?, episode: EpisodeDetail) -> PaywallInfo? {
        guard access?.offers.canRent == true,
              let rentProduct = access?.rentProduct else {
            return nil
        }

        return PaywallInfo(
            productId: rentProduct.id,
            productName: rentProduct.name ?? (isMovie ? "Movie rental" : "Season rental"),
            entitlementType: "PPV",
            networkId: rentProduct.networkId,
            price: rentProduct.price,
            currency: rentProduct.currency,
            seasonId: rentProduct.seasonId ?? episode.seasonId,
            episodeId: episode.id,
            showId: episode.season.show?.id,
            showTitle: episode.season.show?.title
        )
    }

    private func normalizedEntitlementType(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SVOD", "SUBSCRIPTION":
            return "SVOD"
        case "PPV", "TVOD", "TRANSACTIONAL", "RENT":
            return "PPV"
        default:
            return "AVOD"
        }
    }

    private func shouldShowEpisodeGateCTA(accessCode: String?, offeredTypes: [String]) -> Bool {
        guard !offeredTypes.isEmpty else { return false }
        switch accessCode {
        case "NO_MEDIA", "NOT_YET_AVAILABLE", "NO_SCHEDULE", "SCHEDULE_ENDED":
            return false
        default:
            return true
        }
    }

    private var episodeRentalColor: Color {
        Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    }

    private func episodeGateTint(accessCode: String?, offeredTypes: [String]) -> Color {
        switch accessCode {
        case "NO_MEDIA", "NOT_YET_AVAILABLE", "NO_SCHEDULE", "SCHEDULE_ENDED":
            return C.watch
        default:
            if offeredTypes.count == 1, offeredTypes.contains("PPV") {
                return episodeRentalColor
            }
            return C.listen
        }
    }

    private func episodeGateUsesLock(accessCode: String?) -> Bool {
        switch accessCode {
        case "NO_MEDIA", "NOT_YET_AVAILABLE", "NO_SCHEDULE":
            return false
        default:
            return true
        }
    }

    private func gatePriceText(subscribePaywall: PaywallInfo?, rentPaywall: PaywallInfo?, offeredTypes: [String]) -> String? {
        if offeredTypes.count == 1,
           offeredTypes.contains("SVOD"),
           let price = subscribePaywall?.price {
            return formatPrice(price, currency: subscribePaywall?.currency ?? "USD")
        }
        if offeredTypes.count == 1,
           offeredTypes.contains("PPV"),
           let price = rentPaywall?.price {
            return formatPrice(price, currency: rentPaywall?.currency ?? "USD")
        }
        return nil
    }

    private func paywallTitle(access: EntitlementCheckResponse?, offeredTypes: [String]) -> String {
        switch access?.code {
        case "NO_MEDIA":
            return "Not available yet"
        case "NOT_YET_AVAILABLE", "NO_SCHEDULE":
            return "Coming Soon"
        case "SCHEDULE_ENDED":
            return "No longer available"
        default:
            if offeredTypes.contains("SVOD") && offeredTypes.contains("PPV") {
                return "Subscribe or rent to watch"
            }
            if offeredTypes.contains("SVOD") {
                return "Subscribe to watch"
            }
            if offeredTypes.contains("PPV") {
                return "Rent to watch"
            }
            return "Not available"
        }
    }

    private func paywallSubtitle(access: EntitlementCheckResponse?, offeredTypes: [String]) -> String {
        switch access?.code {
        case "NO_MEDIA":
            return "This episode doesn't have a video yet. Check back shortly."
        case "NOT_YET_AVAILABLE", "NO_SCHEDULE":
            return "This episode hasn't premiered yet. Check back when it's available."
        case "SCHEDULE_ENDED":
            return "The viewing window for this episode has ended."
        default:
            if !auth.isAuthenticated {
                return "Sign in to watch this episode with your subscription or rental."
            }
            if offeredTypes.contains("SVOD") && offeredTypes.contains("PPV") {
                return "Watch it with a subscription, or rent the whole season."
            }
            if offeredTypes.contains("SVOD") {
                return "This episode is included with a subscription."
            }
            if offeredTypes.contains("PPV") {
                return "This season is available to rent."
            }
            return "This episode isn't available to purchase yet."
        }
    }

    private func rentLabel(for paywall: PaywallInfo, episode: EpisodeDetail) -> String {
        let seasonNumber = episodeSeasons(for: episode)
            .first { $0.id == (paywall.seasonId ?? episode.seasonId) }?
            .seasonNumber
            ?? episode.season.seasonNumber
        return "Rent Season \(seasonNumber)"
    }

    private func comingSoonOverlay(_ ep: EpisodeDetail) -> some View {
        ZStack {
            CachedRemoteImage(
                url: C.mediaURL(ep.thumbnailUrl),
                targetSize: CGSize(width: 390, height: 219)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.black }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .blur(radius: 10)
            .overlay { Color.black.opacity(0.68) }

            VStack(spacing: 10) {
                Text("Coming Soon")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(C.watch)
                Text(ep.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                Text("This episode is scheduled but not available for playback yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    // MARK: - Load

    @MainActor
    private func runSubscribeCheckout(_ paywall: PaywallInfo?) async {
        if let paywall {
            await runPaywallCheckout(paywall)
            return
        }

        guard let url = URL(string: C.baseURL + "/subscribe") else {
            checkoutMessage = "Subscription checkout is unavailable."
            return
        }
        pendingCheckoutRefresh = true
        openURL(url)
    }

    @MainActor
    // R2: after an external (hosted) checkout, the entitlement is provisioned by a
    // provider webhook that can land a few seconds after the user returns. A single
    // refresh may run too early and leave the title gated. Poll a bounded number of
    // times until access opens, then stop.
    private func refreshAfterExternalCheckout() async {
        for attempt in 0..<5 {
            await load()
            if entitlement?.playable == true || C.mediaURL(episode?.videoUrl) != nil { return }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
    }

    private func runPaywallCheckout(_ paywall: PaywallInfo) async {
        guard auth.isAuthenticated else {
            checkoutMessage = "Sign in to continue checkout."
            return
        }

        guard !isCheckingOut else { return }
        isCheckingOut = true
        defer { isCheckingOut = false }

        do {
            let response: CheckoutResponse
            if paywall.entitlementType == "PPV" {
                response = try await APIClient.shared.checkoutPPV(
                    productId: paywall.productId,
                    networkId: paywall.networkId,
                    seasonId: paywall.seasonId,
                    episodeId: paywall.episodeId
                )
            } else {
                guard let networkId = paywall.networkId else {
                    checkoutMessage = "Subscription checkout is unavailable."
                    return
                }
                response = try await APIClient.shared.checkoutSVOD(
                    productId: paywall.productId,
                    networkId: networkId
                )
            }

            if let redirectUrl = response.redirectUrl, let url = URL(string: redirectUrl) {
                pendingCheckoutRefresh = true
                openURL(url)
                return
            }

            if response.clientSecret != nil && response.success == false {
                checkoutMessage = "This payment provider requires a hosted payment confirmation screen that is not available natively yet."
                return
            }

            checkoutMessage = paywall.entitlementType == "PPV" ? "Rental active." : "Subscription active."
            await load()
        } catch {
            // R3: a 409 means the user already holds this entitlement (rented on another
            // device, or a stale gate). That's not a failure — reveal the content.
            if case APIError.http(409) = error {
                checkoutMessage = paywall.entitlementType == "PPV" ? "You already have this rental." : "You're already subscribed."
                await load()
            } else {
                checkoutMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        let loadId = currentEpisodeId
        isLoading = true
        loadError = nil
        savedProgress = 0
        showReplayPrompt = false
        let resolvedAdConfig = loadEpisodeAdConfig()
        async let progressTask: ProgressItem? = auth.isAuthenticated
            ? (try? await APIClient.shared.fetchProgress(episodeId: loadId))
            : nil
        async let entitlementTask: EntitlementCheckResponse? = playbackAccess(episodeId: loadId)

        let ep: EpisodeDetail?
        do {
            ep = try await APIClient.shared.fetchEpisode(id: loadId)
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        guard loadId == currentEpisodeId else { return }
        guard let ep else { isLoading = false; return }
        let ent = await entitlementTask
        let policy = ep.adPolicy ?? .enabledFallback(reason: "policy_unavailable")
        episodeAdPolicy = policy
        episodeAdConfig = policy.applying(to: resolvedAdConfig)
        episode       = ep
        isFollowing   = ep.isFollowing
        followerCount = ep.followerCount
        localComments = ep.comments
        likeCount     = ep.likes.filter { $0.type == "like" }.count
        userLike      = ep.likes.first(where: { $0.userId == auth.currentUser?.id })?.type
        if selectedSeasonId == nil || !episodeSeasons(for: ep).contains(where: { $0.id == selectedSeasonId }) {
            selectedSeasonId = ep.seasonId
        }

        // Playback follows the server contract: visibility comes from the
        // entitlement check, while a concrete videoUrl is the source of truth for
        // whether the episode can actually play.
        let canPlay = ep.comingSoon != true
            && C.mediaURL(ep.videoUrl) != nil
            && (ent?.visible ?? true)
        entitlement = ent ?? mediaOnlyAccess(for: ep, canPlay: canPlay)

        if canPlay {
            if let item = await progressTask {
                savedProgress = item.progress
            }

            let expandedItem = miniPlayer.takeExpandedItem(for: .episode(loadId))
            hideControlsForExpandedHandoff = expandedItem.map { !$0.isAd } ?? false
            if let expandedItem, !expandedItem.isAd {
                attachPlayer(expandedItem.player, episodeId: loadId, autoplay: true)
                prerollAdDecision = nil
                Task { await loadEpisodeAdBreaks(contentId: loadId, duration: ep.duration) }
            } else if let url = C.mediaURL(ep.videoUrl) {
                let (asset, item) = makeStartupOptimizedPlayerItem(url: url)
                let shouldReuseFullscreenPlayer = reuseCurrentPlayerForFullscreenSelection
                reuseCurrentPlayerForFullscreenSelection = false

                let playbackPlayer: AVPlayer
                if shouldReuseFullscreenPlayer, let existingPlayer = player {
                    existingPlayer.replaceCurrentItem(with: item)
                    existingPlayer.isMuted = playerMuted
                    existingPlayer.volume = 1
                    playbackPlayer = existingPlayer
                } else {
                    let p = AVPlayer(playerItem: item)
                    p.automaticallyWaitsToMinimizeStalling = true
                    p.isMuted = playerMuted
                    p.volume = 1
                    playbackPlayer = p
                }

                if savedProgress > 0.05 && savedProgress < 0.95 {
                    var durationSeconds = ep.duration
                    if durationSeconds == nil {
                        durationSeconds = try? await asset.load(.duration).seconds
                    }
                    if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
                        let seekTo = CMTime(seconds: durationSeconds * savedProgress,
                                           preferredTimescale: 600)
                        await playbackPlayer.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }

                if let expandedItem, expandedItem.isAd, let presentation = expandedItem.adPresentation {
                    attachPlayer(playbackPlayer, episodeId: loadId, autoplay: false)
                    restoreExpandedAd(player: expandedItem.player, presentation: presentation)
                    Task { await loadEpisodeAdBreaks(contentId: loadId, duration: ep.duration) }
                } else {
                    let preroll = await prerollDecision(contentId: loadId, duration: ep.duration)
                    attachPlayer(playbackPlayer, episodeId: loadId, autoplay: preroll == nil)
                    prerollAdDecision = preroll
                    Task { await loadEpisodeAdBreaks(contentId: loadId, duration: ep.duration) }
                }
            }
        }

        isLoading = false
        miniPlayer.markExpandedPlayerAttached()
        Task { await loadSecondaryEpisodeData(episodeId: loadId) }
    }

    private func loadEpisodeAdConfig() -> PlatformShortsAdsConfig {
        platformConfig.config.ads.episode
    }

    private func episodeAdMaxAds(for placement: String) -> Int? {
        if placement == "preroll" {
            return episodeAdPolicy.pods?.prerollMaxAds ?? episodeAdConfig.maxAds
        }
        return episodeAdPolicy.pods?.midrollMaxAds ?? episodeAdConfig.maxAds
    }

    private func episodeAdMaxDurationSec(for placement: String, placementConfig: PlatformAdPlacementConfig) -> Int? {
        let podDuration = placement == "preroll"
            ? episodeAdPolicy.pods?.prerollMaxBreakSec
            : episodeAdPolicy.pods?.midrollMaxBreakSec
        return podDuration
            ?? placementConfig.maxDurationSec
            ?? episodeAdConfig.maxDurationSec
            ?? episodeAdPolicy.pods?.maxAdDurationSec
    }

    private func playbackAccess(episodeId: String) async -> EntitlementCheckResponse? {
        try? await APIClient.shared.checkEntitlement(episodeId: episodeId)
    }

    private func mediaOnlyAccess(for ep: EpisodeDetail, canPlay: Bool) -> EntitlementCheckResponse {
        EntitlementCheckResponse(
            hasAccess: canPlay,
            visible: true,
            playable: canPlay,
            code: ep.comingSoon == true ? "NOT_YET_AVAILABLE" : (C.mediaURL(ep.videoUrl) == nil ? "NO_MEDIA" : nil),
            entitlementType: nil,
            productId: nil
        )
    }

    private func loadSecondaryEpisodeData(episodeId: String) async {
        async let momentTask = APIClient.shared.fetchMomentLikes(episodeId: episodeId)
        async let markerTask = APIClient.shared.fetchPlayerMarkers(episodeId: episodeId)

        if let data = try? await momentTask, self.currentEpisodeId == episodeId {
            heatmapBuckets = data.buckets
            likedSeconds = data.userLikedSeconds
        }

        if let markers = try? await markerTask, self.currentEpisodeId == episodeId {
            playerMarkers = markers
            dismissedMarkerIds.removeAll()
        }
    }

    private func makeStartupOptimizedPlayerItem(url: URL) -> (AVURLAsset, AVPlayerItem) {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 12
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return (asset, item)
    }

    private func configureFullPlaybackBuffering(for player: AVPlayer) {
        player.currentItem?.preferredForwardBufferDuration = 12
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func attachPlayer(_ player: AVPlayer, episodeId: String, autoplay: Bool = true) {
        if let existing = momentObserver {
            momentObserverPlayer?.removeTimeObserver(existing)
            momentObserver = nil
            momentObserverPlayer = nil
        }

        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !time.seconds.isNaN else { return }
            currentPlayerSec = Int(time.seconds)
            if let adBreak = nextDueAdBreak(at: time.seconds) {
                Task { await startEpisodeAdBreak(adBreak) }
            }
        }
        momentObserver = token
        momentObserverPlayer = player

        configureFullPlaybackBuffering(for: player)
        self.player = player
        if autoplay {
            player.playImmediately(atRate: 1)
            startProgress(episodeId: episodeId, player: player)
            recordPPVPlaybackStartIfNeeded(episodeId: episodeId)
        }
    }

    private func recordPPVPlaybackStartIfNeeded(episodeId: String) {
        guard auth.isAuthenticated,
              episode?.rentalInfo != nil,
              !recordedPPVPlaybackEpisodeIds.contains(episodeId) else { return }
        recordedPPVPlaybackEpisodeIds.insert(episodeId)
        // Pass BOTH ids: rentals can be season-scoped (entitlement keyed by seasonId,
        // episodeId null), so episodeId alone would never match one on the server.
        let seasonId = episode?.seasonId
        Task {
            try? await APIClient.shared.recordPPVPlaybackStart(episodeId: episodeId, seasonId: seasonId)
        }
    }

    private func restoreExpandedAd(player adPlayer: AVPlayer, presentation: ActiveAdPresentation) {
        restoredAdPlayer = adPlayer
        restoredAdPresentation = presentation
        activeAdPlayer = adPlayer
        activeAdPresentation = presentation
        if presentation.placement == "preroll" || presentation.breakId == "preroll" {
            prerollAdDecision = presentation.decision
        } else {
            let breakId = presentation.breakId ?? presentation.placement ?? "midroll"
            activeAdBreak = AdBreak(
                id: "\(breakId)-restored",
                breakId: breakId,
                timeOffsetSec: Double(currentPlayerSec),
                placement: presentation.placement ?? "midroll"
            )
            midrollAdDecision = presentation.decision
        }
        adPlayer.play()
    }

    private func clearRestoredAd() {
        restoredAdPlayer = nil
        restoredAdPresentation = nil
        activeAdPlayer = nil
        activeAdPresentation = nil
        isCollapsingAdToMiniPlayer = false
    }

    private func shouldRestoreFullscreenAd(_ adPlayer: AVPlayer) -> Bool {
        guard let item = adPlayer.currentItem else { return false }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else {
            return item.status != .failed
        }
        return adPlayer.currentTime().seconds < max(0, duration - 0.25)
    }

    private func finishFullscreenAd(_ presentation: ActiveAdPresentation) {
        if presentation.placement == "preroll" || presentation.breakId == "preroll" {
            finishEpisodePreroll()
        } else {
            finishEpisodeAdBreak()
        }
    }

    private func finishEpisodePreroll() {
        prerollAdDecision = nil
        clearRestoredAd()
        guard let player else { return }
        player.play()
        startProgress(episodeId: currentEpisodeId, player: player)
        recordPPVPlaybackStartIfNeeded(episodeId: currentEpisodeId)
    }

    private func finishEpisodeAdBreak() {
        guard let activeAdBreak else { return }
        watchedAdBreakIds.insert(activeAdBreak.id)
        pendingAdBreakIds.remove(activeAdBreak.id)
        midrollAdDecision = nil
        self.activeAdBreak = nil
        clearRestoredAd()
        resumeContentAfterAdBreakIfNeeded()
    }

    private func prerollDecision(contentId: String, duration: Double?) async -> AdDecision? {
        let placementConfig = episodeAdConfig.placementConfig(for: "preroll")
        guard episodeAdConfig.enabled, placementConfig.enabled else { return nil }
        do {
            let decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: contentId,
                    contentType: "episode",
                    placement: nil,
                    durationSec: duration,
                    maxAds: episodeAdMaxAds(for: "preroll"),
                    maxDurationSec: episodeAdMaxDurationSec(for: "preroll", placementConfig: placementConfig),
                    skippable: placementConfig.skippable ?? episodeAdConfig.skippable,
                    skipAfterSec: placementConfig.skipAfterSec ?? episodeAdConfig.skipAfterSec,
                    orientation: "HORIZONTAL",
                    breakId: "preroll"
                )
            )
            guard decision.filled, !decision.ads.isEmpty else {
                debugAd("preroll no-fill contentId=\(contentId) reason=\(decision.noFillReason ?? "none")")
                return nil
            }
            return decision
        } catch {
            debugAd("preroll failed contentId=\(contentId): \(error.localizedDescription)")
            return nil
        }
    }

    private func loadEpisodeAdBreaks(contentId: String, duration: Double?) async {
        let placementConfig = episodeAdConfig.placementConfig(for: "midroll")
        guard episodeAdConfig.enabled, placementConfig.enabled else { return }
        do {
            let breaks = try await AdServerClient.shared.requestVMAP(
                AdRequestContext(
                    contentId: contentId,
                    contentType: "episode",
                    durationSec: duration,
                    maxAds: episodeAdMaxAds(for: "midroll"),
                    maxDurationSec: episodeAdMaxDurationSec(for: "midroll", placementConfig: placementConfig),
                    skippable: placementConfig.skippable ?? episodeAdConfig.skippable,
                    skipAfterSec: placementConfig.skipAfterSec ?? episodeAdConfig.skipAfterSec,
                    orientation: "HORIZONTAL"
                )
            )
            guard currentEpisodeId == contentId else { return }
            adBreaks = breaks
            debugAd("vmap loaded contentId=\(contentId) breaks=\(breaks.count)")
        } catch {
            debugAd("vmap failed contentId=\(contentId): \(error.localizedDescription)")
        }
    }

    private func nextDueAdBreak(at seconds: Double) -> AdBreak? {
        guard prerollAdDecision == nil, midrollAdDecision == nil else { return nil }
        return adBreaks
            .filter { !watchedAdBreakIds.contains($0.id) && !pendingAdBreakIds.contains($0.id) }
            .filter { seconds >= $0.timeOffsetSec && seconds < $0.timeOffsetSec + 1.5 }
            .sorted { $0.timeOffsetSec < $1.timeOffsetSec }
            .first
    }

    @MainActor
    private func startEpisodeAdBreak(_ adBreak: AdBreak, resumeTime: Double? = nil) async {
        guard !watchedAdBreakIds.contains(adBreak.id),
              !pendingAdBreakIds.contains(adBreak.id),
              midrollAdDecision == nil else { return }

        if let resumeTime {
            pendingContentSeekAfterAd = resumeTime
        }

        let placementConfig = episodeAdConfig.placementConfig(for: adBreak.placement)
        guard episodeAdConfig.enabled, placementConfig.enabled else {
            watchedAdBreakIds.insert(adBreak.id)
            resumeContentAfterAdBreakIfNeeded()
            return
        }

        pendingAdBreakIds.insert(adBreak.id)
        player?.pause()
        let decision: AdDecision?
        do {
            decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: currentEpisodeId,
                    contentType: "episode",
                    placement: nil,
                    durationSec: episode?.duration,
                    maxAds: episodeAdMaxAds(for: "midroll"),
                    maxDurationSec: episodeAdMaxDurationSec(for: "midroll", placementConfig: placementConfig),
                    skippable: placementConfig.skippable ?? episodeAdConfig.skippable,
                    skipAfterSec: placementConfig.skipAfterSec ?? episodeAdConfig.skipAfterSec,
                    orientation: "HORIZONTAL",
                    breakId: adBreak.breakId
                )
            )
        } catch {
            debugAd("midroll failed contentId=\(currentEpisodeId) breakId=\(adBreak.breakId): \(error.localizedDescription)")
            decision = nil
        }

        guard let decision, decision.filled, !decision.ads.isEmpty else {
            debugAd("midroll no-fill contentId=\(currentEpisodeId) breakId=\(adBreak.breakId) reason=\(decision?.noFillReason ?? "none")")
            watchedAdBreakIds.insert(adBreak.id)
            pendingAdBreakIds.remove(adBreak.id)
            resumeContentAfterAdBreakIfNeeded()
            return
        }

        activeAdBreak = adBreak
        midrollAdDecision = decision
    }

    private func resumeContentAfterAdBreakIfNeeded() {
        guard let player else { return }
        if let resumeTime = pendingContentSeekAfterAd {
            pendingContentSeekAfterAd = nil
            let target = CMTime(seconds: resumeTime, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    player.play()
                }
            }
        } else {
            player.play()
        }
    }

    private func debugAd(_ message: String) {
        #if DEBUG
        print("[Ads][Episode] \(message)")
        #endif
    }

    private func startProgress(episodeId: String, player: AVPlayer) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            guard let item = player.currentItem else { return }
            let cur = player.currentTime().seconds
            let tot = item.duration.seconds
            guard tot > 0, !tot.isNaN else { return }
            Task { try? await APIClient.shared.recordProgress(episodeId: currentEpisodeId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
        }
    }

    private func handleDisappear() {
        stopProgress()
        guard !isCollapsingToMiniPlayer,
              !miniPlayer.isExpansionHandoffActive,
              !isFullscreenPlayerPresented else { return }
        player?.pause()
        activeAdPlayer?.pause()
        restoredAdPlayer?.pause()
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        if let t = momentObserver {
            momentObserverPlayer?.removeTimeObserver(t)
            momentObserver = nil
            momentObserverPlayer = nil
        }
        cancelAutoplay()
        if let p = player, let item = p.currentItem {
            let cur = p.currentTime().seconds
            let tot = item.duration.seconds
            guard tot > 0 else { return }
            Task { try? await APIClient.shared.recordProgress(episodeId: currentEpisodeId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
        }
    }

    // MARK: - Moment like

    private func likeMomentEpisode(id: String, sec: Int) async {
        let wasLiked = likedSeconds.contains(sec)
        if wasLiked { likedSeconds.removeAll { $0 == sec } }
        else        { likedSeconds.append(sec) }

        guard let resp = try? await APIClient.shared.toggleMomentLike(episodeId: id, timestampSec: sec) else {
            if wasLiked { likedSeconds.append(sec) } else { likedSeconds.removeAll { $0 == sec } }
            return
        }
        if !resp.liked { likedSeconds.removeAll { $0 == sec } }
        else if !likedSeconds.contains(sec) { likedSeconds.append(sec) }

    }

    // MARK: - Comments

    private func episodeCommentsSection(episodeId: String) -> some View {
        CommentThreadView(
            target: .episode(episodeId),
            initialComments: localComments,
            previewLimit: 2,
            onShowMore: { _ in showCommentsSheet = true }
        )
    }

    // MARK: - Autoplay

    private func playEpisodeInPlace(_ id: String) {
        guard id != currentEpisodeId else { return }
        stopProgress()
        cancelAutoplay()
        showReplayPrompt = false
        underPlayerPanel = nil
        markerRoute = nil
        playerMarkers = []
        dismissedMarkerIds.removeAll()
        heatmapBuckets = []
        likedSeconds = []
        currentPlayerSec = 0
        localComments = []
        insertedClipPost = nil
        insertedClipPostToken = 0
        activeClipRange = nil
        entitlement = nil
        prerollAdDecision = nil
        midrollAdDecision = nil
        activeAdBreak = nil
        adBreaks = []
        watchedAdBreakIds = []
        pendingAdBreakIds = []
        pendingContentSeekAfterAd = nil
        reuseCurrentPlayerForFullscreenSelection = isFullscreenPlayerPresented && player != nil
        if !reuseCurrentPlayerForFullscreenSelection {
            player?.pause()
            player = nil
        }
        currentEpisodeId = id
    }

    private func handlePlaybackEnded(_ notification: Notification) {
        guard let currentItem = player?.currentItem,
              notification.object as? AVPlayerItem === currentItem else { return }

        let duration = currentItem.duration.seconds.validTime ?? episode?.duration ?? 0
        let current = player?.currentTime().seconds.validTime ?? currentItem.currentTime().seconds.validTime ?? 0
        guard duration > 0, current >= duration - 0.75 else { return }

        if let ep = episode,
           let next = ep.nextEp,
           canNavigate(to: next) {
            startAutoplay(next: next)
        } else {
            showReplayPrompt = true
        }
    }

    private func canNavigate(to item: EpisodeNavItem) -> Bool {
        item.comingSoon != true && item.videoUrl != nil
    }

    private func startAutoplay(next: EpisodeNavItem) {
        showReplayPrompt = false
        autoplayTask?.cancel()
        autoplayCountdown = 10
        let nextId = next.id
        let sourceId = currentEpisodeId
        autoplayTask = Task { @MainActor in
            while !Task.isCancelled, autoplayCountdown > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard currentEpisodeId == sourceId else {
                    cancelAutoplay()
                    return
                }
                autoplayCountdown -= 1
            }

            guard !Task.isCancelled else { return }
            guard currentEpisodeId == sourceId else {
                cancelAutoplay()
                return
            }
            cancelAutoplay()
            playEpisodeInPlace(nextId)
        }
    }

    private func cancelAutoplay(showReplay: Bool = false) {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayCountdown = 0
        if showReplay {
            showReplayPrompt = true
        }
    }

    @ViewBuilder
    private func episodeAutoplayOverlay(next: EpisodeNavItem) -> some View {
        let label = "E\(next.episodeNumber) — \(next.title)"
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("Playing next in")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("\(autoplayCountdown)")
                        .font(.system(size: 52, weight: .bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.easeInOut(duration: 0.3), value: autoplayCountdown)
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                HStack(spacing: 12) {
                    Button {
                        cancelAutoplay()
                        playEpisodeInPlace(next.id)
                    } label: {
                        Text("Play now")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(C.watch)
                            .clipShape(Capsule())
                    }
                    Button {
                        cancelAutoplay(showReplay: true)
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .overlay { Capsule().stroke(.white.opacity(0.25), lineWidth: 1) }
                    }
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private var episodeReplayOverlay: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 12) {
                MediaverseIcon(name: "refresh", fallbackSystemName: "arrow.counterclockwise")
                    .frame(width: 26, height: 26)
                    .foregroundStyle(C.watch)
                Text("Replay")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Button {
                    replayCurrentEpisode()
                } label: {
                    Text("Watch again")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(C.watch)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private func replayCurrentEpisode() {
        showReplayPrompt = false
        cancelAutoplay()
        let start = CMTime(seconds: 0, preferredTimescale: 600)
        player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player?.play()
        }
        currentPlayerSec = 0
        if auth.isAuthenticated {
            Task { try? await APIClient.shared.recordProgress(episodeId: currentEpisodeId, seconds: 0, percent: 0) }
        }
    }

    // MARK: - Player markers

    private func presentAdFullscreenPlayerIfNeeded() {
        guard !isFullscreenPlayerPresented,
              !miniPlayer.isExpansionHandoffActive,
              let adPlayer = activeAdPlayer ?? restoredAdPlayer,
              let presentation = activeAdPresentation ?? restoredAdPresentation else { return }
        var didCompleteAd = false
        isFullscreenPlayerPresented = true
        openFullscreenAdPlayer(
            adPlayer,
            presentation: presentation,
            onAdCompleted: {
                didCompleteAd = true
                finishFullscreenAd(presentation)
            },
            onDismiss: {
                if !didCompleteAd && shouldRestoreFullscreenAd(adPlayer) {
                    restoreExpandedAd(player: adPlayer, presentation: presentation)
                }
                isFullscreenPlayerPresented = false
                if didCompleteAd && UIDevice.current.orientation.isLandscape {
                    presentFullscreenPlayerIfNeeded()
                }
            }
        )
    }

    private func presentFullscreenPlayerIfNeeded() {
        guard !isFullscreenPlayerPresented,
              !miniPlayer.isExpansionHandoffActive,
              let ep = episode,
              let p = player else { return }
        isFullscreenPlayerPresented = true
        openFullscreenPlayer(
            p,
            heatmapBuckets: heatmapBuckets,
            likedSeconds: likedSeconds,
            isAuthenticated: auth.isAuthenticated,
            onLikeMoment: { sec in
                Task { await likeMomentEpisode(id: ep.id, sec: sec) }
            },
            showSpoilerToggle: true,
            onClipRequest: { markIn, markOut, caption, isSpoiler, thumbnailData in
                let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let thumbnailUrl = try await uploadClipThumbnailIfNeeded(thumbnailData)
                let post = try await APIClient.shared.createPost(
                    episodeId: ep.id,
                    markIn: markIn,
                    markOut: markOut,
                    caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                    isSpoiler: isSpoiler,
                    thumbnailUrl: thumbnailUrl
                )
                await MainActor.run {
                    insertedClipPost = post
                    insertedClipPostToken += 1
                }
            },
            activeClipRange: $activeClipRange,
            onPrevious: ep.prevEp.map { previous in
                { playEpisodeInPlace(previous.id) }
            },
            onNext: ep.nextEp.flatMap { next in
                next.comingSoon == true || next.videoUrl == nil ? nil : { playEpisodeInPlace(next.id) }
            },
            relatedItems: fullscreenRelatedItems(for: ep),
            onSelectRelated: { item in
                playEpisodeInPlace(item.id)
            },
            onDismiss: {
                isFullscreenPlayerPresented = false
            }
        ) {
            playerMarkerOverlay
        }
    }

    private func playClipPost(_ post: UserPost) {
        guard post.markOut > post.markIn else { return }
        activeClipRange = ClipPlaybackRange(markIn: Double(post.markIn), markOut: Double(post.markOut))
        let target = CMTime(seconds: Double(post.markIn), preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                player?.play()
            }
        }
    }

    private func uploadClipThumbnailIfNeeded(_ thumbnailData: Data?) async throws -> String? {
        guard let thumbnailData else { return nil }
        return try await APIClient.shared.uploadThumbnailImage(thumbnailData)
    }

    private func fullscreenRelatedItems(for episode: EpisodeDetail) -> [PlayerRelatedItem] {
        guard let next = episode.nextEp,
              next.comingSoon != true,
              next.videoUrl != nil else { return [] }
        return [
            PlayerRelatedItem(
                id: next.id,
                title: next.title,
                subtitle: isMovie ? next.title : "Episode \(next.episodeNumber)",
                thumbnailUrl: next.thumbnailUrl
            )
        ]
    }

    private var visiblePlayerMarkers: [PlayerMarker] {
        playerMarkers.filter { marker in
            !dismissedMarkerIds.contains(marker.id)
                && currentPlayerSec >= marker.timestampSec
                && currentPlayerSec < marker.timestampSec + 20
        }
    }

    @ViewBuilder
    private var playerMarkerOverlay: some View {
        let markers = visiblePlayerMarkers
        if !markers.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(markers) { marker in
                    HStack(spacing: 0) {
                        Button {
                            activateMarker(marker)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "rectangle.on.rectangle")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(C.watch)
                                Text(marker.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 9)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismissedMarkerIds.insert(marker.id)
                        } label: {
                            MediaverseIcon(name: "close", fallbackSystemName: "xmark")
                                .frame(width: 9, height: 9)
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                        }
                    }
                    .background(.black.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1) }
                    .frame(maxWidth: 230, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: markers.map(\.id))
        }
    }

    private func activateMarker(_ marker: PlayerMarker) {
        if let route = route(forMarkerURL: marker.url) {
            markerRoute = route
            return
        }
        if let url = URL(string: marker.url) {
            openURL(url)
        }
    }

    private func route(forMarkerURL value: String) -> AppRoute? {
        let path: String
        if let url = URL(string: value), let host = url.host, !host.isEmpty {
            path = url.path
        } else {
            path = value
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" {
            return .episode(parts[2])
        }
        if parts.count >= 2, parts[0] == "watch" {
            return .video(parts[1])
        }
        if parts.count >= 2, parts[0] == "shows" {
            return .show(parts[1])
        }
        if parts.count >= 2, parts[0] == "channels" {
            return .channel(parts[1])
        }
        if parts.count >= 2, parts[0] == "playlists" {
            return .playlist(parts[1])
        }
        if parts.count >= 2, parts[0] == "collections" {
            return .collection(parts[1])
        }
        return nil
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id): VideoWatchView(videoId: id).id(id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId, showsDismissControls: true)
        case .episode(let id): EpisodeWatchView(episodeId: id).id(id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .showAccess(let showId, let productId, let intent, let handoffId):
            ShowView(showId: showId, handoffProductId: productId, handoffIntent: intent, handoffPublicId: handoffId)
        case .handoff(let id): HandoffResolverView(publicId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        }
    }

    private func toggleFollow(showId: String) async {
        guard !showId.isEmpty else { return }
        isFollowing.toggle()
        followerCount += isFollowing ? 1 : -1
        do {
            let _ = try await APIClient.shared.toggleShowFollow(id: showId)
            NotificationCenter.default.post(name: .userFollowChanged, object: nil)
        } catch {
            isFollowing.toggle()
            followerCount += isFollowing ? 1 : -1
        }
    }

    private func shareEpisode(_ ep: EpisodeDetail) {
        guard let url = URL(string: "\(C.baseURL)/watch/episode/\(ep.id)") else { return }
        UIActivityViewController(activityItems: [url], applicationActivities: nil).presentFromRoot()
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }

    private func formatPrice(_ cents: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale.current
        let value = NSNumber(value: cents / 100)
        return formatter.string(from: value) ?? "\(currency) \(String(format: "%.2f", cents / 100))"
    }

    // MARK: - Like / Dislike

    private func toggleLike(_ type: String, episodeId: String) async {
        guard auth.isAuthenticated else { return }
        let was      = userLike
        let wasCount = likeCount
        // Optimistic update
        let sending = (userLike == type) ? "remove" : type
        if sending == "remove" {
            userLike = nil
            if type == "like" { likeCount = max(0, likeCount - 1) }
        } else {
            if userLike == "like" { likeCount = max(0, likeCount - 1) }
            userLike = type
            if type == "like" { likeCount += 1 }
        }
        do {
            let result = try await APIClient.shared.likeEpisode(episodeId: episodeId, type: sending)
            likeCount = result.likes
            userLike  = result.userLike
        } catch {
            // Rollback on failure
            userLike  = was
            likeCount = wasCount
        }
    }
}
