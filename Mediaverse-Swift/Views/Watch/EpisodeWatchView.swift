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
    @State private var isFollowing   = false
    @State private var followerCount = 0
    @State private var savedProgress: Double = 0

    // ── Like / dislike (optimistic)
    @State private var userLike:  String?  // "like" | "dislike" | nil
    @State private var likeCount: Int = 0

    // ── Comments
    @State private var localComments:    [Comment] = []
    @State private var commentText:      String    = ""
    @State private var isPostingComment            = false

    // ── Autoplay
    @State private var autoplayCountdown: Int  = 0
    @State private var autoplayTimer:     Timer?
    @State private var autoplayDest:      AppRoute?
    @State private var showReplayPrompt         = false

    // ── Moment likes (heatmap)
    @State private var heatmapBuckets:   [Int]  = []
    @State private var likedSeconds:     [Int]  = []
    @State private var currentPlayerSec: Int    = 0
    @State private var momentObserver:   Any?   = nil

    // ── Timed player markers
    @State private var playerMarkers: [PlayerMarker] = []
    @State private var dismissedMarkerIds: Set<String> = []
    @State private var markerRoute: AppRoute?
    @State private var isCheckingOut = false
    @State private var checkoutMessage: String?
    @State private var clipReactionReloadToken = 0
    @State private var insertedClipPostToken = 0
    @State private var insertedClipPost: UserPost?
    @State private var underPlayerPanel: WatchUnderPlayerPanel?
    @State private var playerDragOffset: CGFloat = 0
    @State private var isFullscreenPlayerPresented = false
    @State private var episodeListExpanded = true
    @State private var selectedSeasonId: String?
    @AppStorage("playerMuted") private var playerMuted = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager

    private var underPlayerPanelAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.88)
    }

    private var underPlayerPanelTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    init(episodeId: String) {
        self.episodeId = episodeId
        _currentEpisodeId = State(initialValue: episodeId)
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                if !miniPlayer.isExpansionHandoffActive {
                    ProgressView().tint(C.watch)
                }
            } else if let ep = episode {
                mainContent(ep)
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
        .toolbar(.hidden, for: .navigationBar)
        .task(id: currentEpisodeId) { await load() }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear { stopProgress() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            if let ep = episode,
               let next = ep.nextEp,
               next.comingSoon != true,
               next.videoUrl != nil {
                startAutoplay(next: next)
            } else {
                showReplayPrompt = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard UIDevice.current.orientation.isLandscape else { return }
            presentFullscreenPlayerIfNeeded()
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
                        rentalInfoBar(rental)
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
                                    AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
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
                        let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
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
            if entitlement?.hasAccess == true, let p = player {
                if miniPlayer.isExpansionHandoffActive {
                    Color.black
                        .aspectRatio(16/9, contentMode: .fit)
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
                        onClipRequest: { markIn, markOut, caption, isSpoiler in
                            let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                            let post = try await APIClient.shared.createPost(
                                episodeId: ep.id,
                                markIn: markIn,
                                markOut: markOut,
                                caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                                isSpoiler: isSpoiler
                            )
                            await MainActor.run {
                                insertedClipPost = post
                                insertedClipPostToken += 1
                            }
                        },
                        onPrevious: ep.prevEp.map { previous in
                            { playEpisodeInPlace(previous.id) }
                        },
                        onNext: ep.nextEp.flatMap { next in
                            next.comingSoon == true || next.videoUrl == nil ? nil : { playEpisodeInPlace(next.id) }
                        },
                        onBack: { collapseToMiniPlayer() },
                        onFullscreen: { presentFullscreenPlayerIfNeeded() }
                    ) {
                        playerMarkerOverlay
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if entitlement?.hasAccess == false {
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
        min(max(playerDragOffset / max(240, geo.size.height * 0.34), 0), 1)
    }

    private func collapseScale(_ progress: CGFloat) -> CGFloat {
        1 - progress * 0.58
    }

    private func collapseYOffset(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        let targetY = max(0, geo.size.height - 176)
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
        guard let player, let episode else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            playerDragOffset = 999
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            miniPlayer.present(player: player, title: episode.title, route: .episode(episode.id))
            dismiss()
        }
    }

    private var playerCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                playerDragOffset = min(180, value.translation.height)
            }
            .onEnded { value in
                let shouldMinimize = value.translation.height > 78 || value.predictedEndTranslation.height > 160
                if shouldMinimize {
                    collapseToMiniPlayer()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
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
                    switch panel {
                    case .comments:
                        CommentThreadView(target: .episode(ep.id), initialComments: localComments)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    case .reactions:
                        PostSectionView(
                            target: .episode(ep.id),
                            reloadToken: clipReactionReloadToken,
                            insertedPostToken: insertedClipPostToken,
                            insertedPost: insertedClipPost,
                            startsExpanded: true,
                            onSeek: { seekSeconds in
                            let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                            player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
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

            Text(panel == .comments ? "Comments" : "Clip reactions")
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
                        Text("Episodes")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(C.text)
                        if let activeSeason {
                            Text("Season \(activeSeason.seasonNumber)")
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
            Text("Season \(season.seasonNumber)")
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
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: C.mediaURL(item.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 112, height: 63)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 7))

                if let duration = item.duration {
                    episodeDurationBadge(duration)
                }

                if isCurrent {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    MediaverseIcon(name: "play", fallbackSystemName: "play.fill")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(C.watch)
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
                Text("Soon")
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

    // MARK: - Rental info bar

    @ViewBuilder
    private func rentalInfoBar(_ info: RentalInfo) -> some View {
        // Mirror web's RentalInfoBar component exactly
        let activeExpiry: String? = info.firstPlayedAt != nil
            ? info.playbackExpiresAt
            : info.validTo
        let started = info.firstPlayedAt != nil
        let playsLeft: Int? = info.maxPlays.map { $0 - info.playsUsed }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // "Rental · ProductName" badge
                Text("Rental · \(info.productName)")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(C.watch)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(C.watch.opacity(0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()
            }
            .padding(.bottom, 6)

            // Expiry countdown
            if let expiry = activeExpiry, let date = parseISO(expiry) {
                let remaining = max(0, date.timeIntervalSinceNow)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(started ? "Playback window:" : "Rental expires in")
                        .font(.system(size: 11))
                    Text(fmtDuration(Int(remaining)))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            } else if started && activeExpiry == nil {
                Text("Unlimited playback window")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            // Plays remaining
            if let left = playsLeft {
                HStack(spacing: 4) {
                    MediaverseIcon(name: "play", fallbackSystemName: "play")
                        .frame(width: 9, height: 9)
                    if left > 0 {
                        Text("\(left) play\(left == 1 ? "" : "s") left")
                            .font(.system(size: 11))
                    } else {
                        Text("No plays remaining")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(C.watch.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(C.watch.opacity(0.20), lineWidth: 1) }
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func fmtDuration(_ seconds: Int) -> String {
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return "\(h)h \(m)m"
    }

    // MARK: - Paywall overlay

    private func paywallOverlay(_ ep: EpisodeDetail) -> some View {
        ZStack {
            // Blurred poster
            AsyncImage(url: C.mediaURL(ep.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.black }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            .blur(radius: 12)
            .overlay { Color.black.opacity(0.6) }

            // Lock icon + subscribe prompt
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.7))
                if let pw = ep.paywallInfo {
                    Text(pw.entitlementType == "SVOD" ? "Subscription Required" : "Rental Required")
                        .font(.headline).foregroundStyle(.white)
                    Text(pw.productName)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    if let price = pw.price {
                        Text(formatPrice(price, currency: pw.currency ?? "USD"))
                            .font(.title3.bold()).foregroundStyle(C.watch)
                    }
                    Button {
                        Task { await runPaywallCheckout(pw) }
                    } label: {
                        if isCheckingOut {
                            ProgressView().tint(.black)
                                .frame(width: 18, height: 18)
                        } else {
                            Text(pw.entitlementType == "SVOD" ? "Subscribe to watch" : "Rent now")
                        }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 42)
                    .background(C.watch)
                    .clipShape(Capsule())
                    .disabled(isCheckingOut)
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    // MARK: - Load

    @MainActor
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
                response = try await APIClient.shared.checkoutSVOD(
                    productId: paywall.productId,
                    networkId: paywall.networkId
                )
            }

            if let redirectUrl = response.redirectUrl, let url = URL(string: redirectUrl) {
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
            checkoutMessage = error.localizedDescription
        }
    }

    private func load() async {
        let loadId = currentEpisodeId
        isLoading = true
        loadError = nil
        savedProgress = 0
        showReplayPrompt = false
        async let entitlementTask: EntitlementCheckResponse? = auth.isAuthenticated
            ? (try? await APIClient.shared.checkEntitlement(episodeId: loadId))
            : nil
        async let progressTask: ProgressItem? = auth.isAuthenticated
            ? (try? await APIClient.shared.fetchProgress(episodeId: loadId))
            : nil

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
        episode       = ep
        isFollowing   = ep.isFollowing
        followerCount = ep.followerCount
        localComments = ep.comments
        likeCount     = ep.likes.filter { $0.type == "like" }.count
        userLike      = ep.likes.first(where: { $0.userId == auth.currentUser?.id })?.type
        if selectedSeasonId == nil || !episodeSeasons(for: ep).contains(where: { $0.id == selectedSeasonId }) {
            selectedSeasonId = ep.seasonId
        }

        // The episode detail endpoint already mirrors the web SSR entitlement gate:
        // locked content returns paywallInfo and no videoUrl. The separate entitlement
        // check requires auth, so unauthenticated AVOD must not get stuck on a spinner.
        let ent = await entitlementTask
        let canPlay = ep.paywallInfo == nil && ep.videoUrl != nil && (ent?.hasAccess ?? true)
        entitlement = ent ?? EntitlementCheckResponse(
            hasAccess: canPlay,
            code: ep.videoUrl == nil ? "NO_MEDIA" : nil,
            entitlementType: ep.paywallInfo?.entitlementType ?? "AVOD",
            productId: ep.paywallInfo?.productId
        )

        if canPlay {
            if let item = await progressTask {
                savedProgress = item.progress
            }

            if let resumedPlayer = miniPlayer.takeExpandedPlayer(for: .episode(loadId)) {
                attachPlayer(resumedPlayer, episodeId: loadId)
            } else if let url = C.mediaURL(ep.videoUrl) {
                let asset = AVURLAsset(url: url)
                let item  = AVPlayerItem(asset: asset)
                let p     = AVPlayer(playerItem: item)
                p.isMuted = playerMuted
                p.volume = 1

                if savedProgress > 0.05 && savedProgress < 0.95 {
                    if let dur = try? await asset.load(.duration), dur.isNumeric {
                        let seekTo = CMTime(seconds: dur.seconds * savedProgress,
                                           preferredTimescale: 600)
                        await p.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }

                attachPlayer(p, episodeId: loadId)
            }
        }

        isLoading = false
        miniPlayer.markExpandedPlayerAttached()
        Task { await loadSecondaryEpisodeData(episodeId: loadId) }
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

    private func attachPlayer(_ player: AVPlayer, episodeId: String) {
        if let existing = momentObserver {
            self.player?.removeTimeObserver(existing)
            momentObserver = nil
        }

        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !time.seconds.isNaN else { return }
            currentPlayerSec = Int(time.seconds)
        }
        momentObserver = token

        self.player = player
        player.play()
        startProgress(episodeId: episodeId, player: player)
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

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        if let t = momentObserver { player?.removeTimeObserver(t); momentObserver = nil }
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

        try? await Task.sleep(for: .milliseconds(400))
        if let data = try? await APIClient.shared.fetchMomentLikes(episodeId: id) {
            heatmapBuckets = data.buckets
        }
    }

    // MARK: - Comments

    private func episodeCommentsSection(episodeId: String) -> some View {
        CommentThreadView(
            target: .episode(episodeId),
            initialComments: localComments,
            previewLimit: 2,
            onShowMore: { _ in setUnderPlayerPanel(.comments) }
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
        entitlement = nil
        player?.pause()
        player = nil
        currentEpisodeId = id
    }

    private func startAutoplay(next: EpisodeNavItem) {
        showReplayPrompt = false
        autoplayCountdown = 10
        autoplayTimer?.invalidate()
        let nextId = next.id
        autoplayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if autoplayCountdown > 1 {
                    autoplayCountdown -= 1
                } else {
                    cancelAutoplay()
                    playEpisodeInPlace(nextId)
                }
            }
        }
    }

    private func cancelAutoplay(showReplay: Bool = false) {
        autoplayTimer?.invalidate()
        autoplayTimer = nil
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
            onClipRequest: { markIn, markOut, caption, isSpoiler in
                let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let post = try await APIClient.shared.createPost(
                    episodeId: ep.id,
                    markIn: markIn,
                    markOut: markOut,
                    caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                    isSpoiler: isSpoiler
                )
                await MainActor.run {
                    insertedClipPost = post
                    insertedClipPostToken += 1
                }
            },
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

    private func fullscreenRelatedItems(for episode: EpisodeDetail) -> [PlayerRelatedItem] {
        guard let next = episode.nextEp,
              next.comingSoon != true,
              next.videoUrl != nil else { return [] }
        return [
            PlayerRelatedItem(
                id: next.id,
                title: next.title,
                subtitle: "Episode \(next.episodeNumber)",
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
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id): EpisodeWatchView(episodeId: id).id(id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
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
        let val = cents / 100
        return String(format: "%@ %.2f", currencySymbol(currency), val)
    }

    private func currencySymbol(_ code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code)
            ?? code
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
