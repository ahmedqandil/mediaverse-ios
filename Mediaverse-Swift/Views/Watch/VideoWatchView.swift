import SwiftUI
import AVKit

// MARK: - VideoWatchView
// Mirrors /src/app/watch/WatchClient.tsx for the "video" type on mobile.
// Features: AVPlayer + progress restore/record, like/dislike, channel/show follow,
// share sheet, linked clip/episode banners, description expand, comments, up-next.

enum WatchUnderPlayerPanel: Identifiable {
    case reactions

    var id: String {
        switch self {
        case .reactions: return "reactions"
        }
    }
}

enum WatchContentTab: String, Identifiable {
    case playlist
    case episodes
    case upNext
    case clips
    case comments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlist: return "Playlist"
        case .episodes: return "Episodes"
        case .upNext: return "Up next"
        case .clips: return "Clippings"
        case .comments: return "Comments"
        }
    }
}

struct WatchPinnedTabBar: View {
    let tabs: [WatchContentTab]
    @Binding var selection: WatchContentTab
    let count: (WatchContentTab) -> Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.title)
                            if let value = count(tab), value > 0 {
                                Text(compactCount(value))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(selection == tab ? C.bg : C.textMuted)
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == tab ? C.bg : C.textMuted)
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(selection == tab ? C.watch : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 8)
        }
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.border).frame(height: 1)
        }
    }

    private func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
                .replacingOccurrences(of: ".0", with: "")
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
                .replacingOccurrences(of: ".0", with: "")
        }
        return "\(value)"
    }
}

struct WatchActionItem: View {
    let title: String
    let systemImage: String
    var count: String? = nil
    var isPrimary = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isPrimary ? C.watch : C.text)
                .frame(width: 46, height: 46)
                .background(C.surface, in: Circle())
                .overlay { Circle().stroke(isPrimary ? C.watch.opacity(0.45) : C.border, lineWidth: 1) }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.text)
                .lineLimit(1)

            if let count, !count.isEmpty {
                Text(count)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: 74, alignment: .top)
        .contentShape(Rectangle())
    }
}

struct VideoWatchView: View {

    let videoId: String
    let playlistId: String?
    let initialClipRange: ClipPlaybackRange?

    // ── Data
    @State private var video:         VideoDetail?
    @State private var currentVideoId: String
    @State private var previousVideoIds: [String] = []
    @State private var isLoading                = true
    @State private var loadError:     String?

    // ── Player
    @State private var player:        AVPlayer?
    @State private var savedProgress: Double    = 0
    @State private var progressTimer: Timer?
    @State private var prerollAdDecision: AdDecision?
    @State private var midrollAdDecision: AdDecision?
    @State private var activeAdBreak: AdBreak?
    @State private var adBreaks: [AdBreak] = []
    @State private var watchedAdBreakIds: Set<String> = []
    @State private var pendingAdBreakIds: Set<String> = []
    @State private var pendingContentSeekAfterAd: Double?
    @State private var isSeekEnforcedAdBreak = false
    @State private var lastObservedContentTime: Double = 0
    @State private var activeAdPlayer: AVPlayer?
    @State private var activeAdPresentation: ActiveAdPresentation?
    @State private var restoredAdPlayer: AVPlayer?
    @State private var restoredAdPresentation: ActiveAdPresentation?
    @State private var isCollapsingAdToMiniPlayer = false
    @State private var videoAdConfig: PlatformShortsAdsConfig = .videoDefault
    @State private var videoAdPolicy: EffectiveAdPolicy = .disabled(reason: "not_resolved")
    @State private var adDeliveryMode: AdDeliveryMode = .none
    @State private var serverInterstitialMonitor: AVPlayerInterstitialEventMonitor?
    @StateObject private var serverAdCoordinator = ServerAdPlaybackCoordinator()
    @State private var serverFallbackSourceURL: URL?
    @State private var serverPlaybackWatchdogTask: Task<Void, Never>?
    @State private var playbackLoadGeneration = UUID()
    @State private var playbackSessionId = UUID().uuidString
    @State private var playbackEntryContext: PlaybackEntryContext = .direct

    // ── Engagement (optimistic)
    @State private var userLike:      String?   // "like" | "dislike" | nil
    @State private var likeCount:     Int       = 0
    @State private var showEnergy               = false
    @State private var energyAggregate: ContentEnergyAggregate?
    @State private var isSubscribed:  Bool      = false
    @State private var isFollowingShow: Bool    = false
    @State private var showFollowerCount: Int   = 0

    // ── UI
    @State private var showDescription          = false
    @State private var shareCopied              = false
    @State private var localComments:  [Comment]          = []
    @State private var showCommentsSheet                  = false

    // ── Autoplay
    @State private var autoplayCountdown: Int   = 0
    @State private var autoplayTask:      Task<Void, Never>?
    @State private var showReplayPrompt          = false

    // ── Save to collection
    @State private var showSaveSheet:     Bool   = false
    @State private var showEchoSheet:     Bool   = false
    @State private var showPlaylistSheet: Bool   = false
    @State private var clipReactionReloadToken   = 0
    @State private var insertedClipPostToken      = 0
    @State private var insertedClipPost: UserPost?
    @State private var activeClipRange: ClipPlaybackRange?
    @State private var underPlayerPanel: WatchUnderPlayerPanel?
    @State private var playerDragOffset: CGFloat = 0
    @State private var isCollapsingToMiniPlayer = false
    @State private var isPlayerTimelineScrubbing = false
    @State private var hideControlsForExpandedHandoff = false
    @State private var isFullscreenPlayerPresented = false
    @State private var reuseCurrentPlayerForFullscreenSelection = false
    @State private var playlistPanel: PlaylistDetail?
    @State private var relatedPlaylists: [ChannelPlaylist] = []
    @State private var relatedPlaylistsExpanded = true
    @State private var selectedContentTab: WatchContentTab = .upNext
    @State private var clippingCount = 0
    @AppStorage("playerMuted") private var playerMuted = false

    // ── Moment likes (heatmap)
    @State private var heatmapBuckets:   [Int]   = []
    @State private var likedSeconds:     [Int]   = []
    @State private var currentPlayerSec: Int     = 0
    @State private var momentObserver:   Any?    = nil
    @State private var momentObserverPlayer: AVPlayer? = nil

    // ── Timed player markers
    @State private var playerMarkers: [PlayerMarker] = []
    @State private var dismissedMarkerIds: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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

    init(
        videoId: String,
        playlistId: String? = nil,
        initialClipRange: ClipPlaybackRange? = nil
    ) {
        self.videoId = videoId
        self.playlistId = playlistId
        self.initialClipRange = initialClipRange
        _currentVideoId = State(initialValue: videoId)
        _activeClipRange = State(initialValue: initialClipRange)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if let v = video {
                mainContent(v)
            } else if isLoading {
                if !miniPlayer.isExpansionHandoffActive {
                    watchSkeleton
                }
            } else {
                // Load failed — show retry
                VStack(spacing: 16) {
                    MediaverseIcon(name: "warning", fallbackSystemName: "exclamationmark.triangle")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(C.textMuted.opacity(0.4))
                    Text(loadError ?? "Failed to load video")
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
        .task(id: currentVideoId) { await load() }
        .task(id: currentVideoId) {
            energyAggregate = try? await APIClient.shared
                .fetchContentEnergy(contentPath: "videos", id: currentVideoId)
                .aggregate
        }
        .task(id: currentVideoId) {
            clippingCount = (try? await APIClient.shared.fetchPosts(videoId: currentVideoId).count) ?? 0
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear { handleDisappear() }
        .sheet(isPresented: $showSaveSheet) {
            if let vid = video {
                SaveToCollectionSheet(videoId: vid.id)
            }
        }
        .sheet(isPresented: $showEchoSheet) {
            if let vid = video {
                EchoVibeSheet(
                    content: .video(
                        id: vid.id,
                        title: vid.title,
                        thumbnailURL: vid.thumbnailUrl
                    )
                )
            }
        }
        .sheet(isPresented: $showPlaylistSheet) {
            if let vid = video {
                SaveToPlaylistSheet(videoId: vid.id, videoType: vid.type)
            }
        }
        .sheet(isPresented: $showCommentsSheet) {
            StandardCommentsSheet(
                target: .video(currentVideoId),
                initialComments: localComments,
                initialCount: localComments.totalCommentCount
            ) {
                showCommentsSheet = false
            }
        }
        .sheet(isPresented: $showEnergy) {
            ContentEnergySheet(kind: .video, contentID: currentVideoId) {
                energyAggregate = $0
            }
            .presentationDetents([.height(610), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            handlePlaybackEnded(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { notification in
            guard notification.object as? AVPlayerItem === player?.currentItem else { return }
            Task { await fallbackFromServerDelivery() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard UIDevice.current.orientation.isLandscape else { return }
            if prerollAdDecision != nil || midrollAdDecision != nil {
                presentAdFullscreenPlayerIfNeeded()
            } else if serverAdCoordinator.presentation != nil {
                openFullscreenServerAdPlayer(serverAdCoordinator)
            } else {
                presentFullscreenPlayerIfNeeded()
            }
        }
    }

    // MARK: - Loading skeleton

    private var watchSkeleton: some View {
        VStack(spacing: 0) {
            // 16:9 player placeholder
            Color.white.opacity(0.05)
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                // Title placeholder
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)).frame(height: 22)
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(width: 160, height: 16)
                Divider().background(C.border)
                // Channel row placeholder
                HStack(spacing: 10) {
                    Circle().fill(Color.white.opacity(0.07)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)).frame(width: 120, height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(width: 80, height: 11)
                    }
                    Spacer()
                }
            }
            .padding(C.pagePad)
            Spacer()
        }
    }

    // MARK: - Main content

    private func mainContent(_ v: VideoDetail) -> some View {
        GeometryReader { geo in
            let progress = collapseProgress(in: geo)
            VStack(spacing: 0) {
                pinnedPlayer(v, geometry: geo)

                if let ad = standardAdCompanionCreative {
                    NativeAdCompanionCard(ad: ad)
                        .padding(.horizontal, C.pagePad)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .background(C.bg)
                }

                videoTabbedContent(v)
            }
            .animation(underPlayerPanelAnimation, value: underPlayerPanel?.id)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(C.bg)
            .scaleEffect(x: collapseScale(progress), y: collapseScale(progress), anchor: .top)
            .offset(y: collapseYOffset(in: geo, progress: progress))
            .opacity(max(0.86, 1 - progress * 0.14))
            .simultaneousGesture(playerCollapseGesture)
            .onChange(of: playlistPanel?.id) { _, newValue in
                if newValue != nil {
                    selectedContentTab = .playlist
                }
            }
        }
    }

    private var availableVideoTabs: [WatchContentTab] {
        var tabs: [WatchContentTab] = [.upNext, .playlist]
        if clippingCount > 0 { tabs.append(.clips) }
        tabs.append(.comments)
        return tabs
    }

    private func videoTabbedContent(_ v: VideoDetail) -> some View {
        let tabs = availableVideoTabs
        return VStack(spacing: 0) {
            WatchPinnedTabBar(tabs: tabs, selection: $selectedContentTab) { tab in
                switch tab {
                case .playlist: return playlistPanel?.items.count ?? relatedPlaylists.count
                case .upNext: return v.upNext.count
                case .clips: return clippingCount
                case .comments: return localComments.totalCommentCount
                default: return nil
                }
            }

            TabView(selection: $selectedContentTab) {
                ForEach(tabs) { tab in
                    videoTabPage(tab, video: v)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .onChange(of: tabs.map(\.id).joined(separator: "|")) { _, _ in
            if !tabs.contains(selectedContentTab) {
                selectedContentTab = tabs.first ?? .upNext
            }
        }
    }

    @ViewBuilder
    private func videoTabPage(_ tab: WatchContentTab, video v: VideoDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch tab {
                case .playlist:
                    if let playlistPanel {
                        playlistPlaybackPanel(playlistPanel)
                        let otherPlaylists = relatedPlaylists.filter { $0.id != playlistPanel.id }
                        if !otherPlaylists.isEmpty {
                            relatedPlaylistsPanel(otherPlaylists)
                        }
                    } else if !relatedPlaylists.isEmpty {
                        relatedPlaylistsPanel(relatedPlaylists)
                    } else {
                        ContentUnavailableView(
                            "No playlists available",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Playlists related to this video will appear here.")
                        )
                    }
                case .upNext:
                    videoDetailsContent(v)
                    commentsPreview(videoId: v.id)
                    if !v.upNext.isEmpty {
                        upNextSection(v.upNext)
                    } else {
                        ContentUnavailableView("Nothing queued", systemImage: "play.rectangle")
                    }
                case .clips:
                    PostSectionView(
                        target: .video(v.id),
                        reloadToken: clipReactionReloadToken,
                        insertedPostToken: insertedClipPostToken,
                        insertedPost: insertedClipPost,
                        startsExpanded: true,
                        presentation: .fullWidthClippings,
                        onAvailabilityChanged: { clippingCount = $0 },
                        onPlayClip: { playClipPost($0) }
                    )
                case .comments:
                    CommentThreadView(
                        target: .video(v.id),
                        initialComments: localComments
                    )
                case .episodes:
                    EmptyView()
                }
            }
            .padding(C.pagePad)
            .padding(.bottom, 24)
        }
    }

    private func commentsPreview(videoId: String) -> some View {
        CommentThreadView(
            target: .video(videoId),
            initialComments: localComments,
            previewLimit: 2,
            onShowMore: { _ in selectedContentTab = .comments }
        )
    }

    private func pinnedPlayer(_ v: VideoDetail, geometry geo: GeometryProxy) -> some View {
        ZStack {
            playerArea
                .frame(maxWidth: .infinity, alignment: .top)
            if autoplayCountdown > 0, let next = v.upNext.first {
                autoplayOverlay(title: next.title)
            } else if showReplayPrompt {
                replayOverlay
            }
#if DEBUG
            VStack {
                HStack {
                    AdDeliveryDebugBadge(mode: adDeliveryMode)
                    Spacer()
                }
                Spacer()
            }
            .padding(8)
            .allowsHitTesting(false)
#endif
        }
        .frame(width: geo.size.width)
        .frame(maxWidth: .infinity)
        .frame(height: playerVisibleHeight(in: geo), alignment: .topLeading)
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

    private func playerVisibleHeight(in geo: GeometryProxy) -> CGFloat {
        geo.size.width * 9 / 16
    }

    private func isPlayerTimelineDragStart(_ point: CGPoint) -> Bool {
        let playerHeight = UIScreen.main.bounds.width * 9 / 16
        return point.y >= playerHeight - 64 && point.y <= playerHeight + 16
    }

    private func isPlayerHorizontalDismiss(_ value: DragGesture.Value) -> Bool {
        let playerHeight = UIScreen.main.bounds.width * 9 / 16
        guard value.startLocation.y >= 0,
              value.startLocation.y < playerHeight - 64,
              !isPlayerTimelineScrubbing else { return false }
        return abs(value.translation.width) > 64
            || abs(value.predictedEndTranslation.width) > 118
    }

    private var playerBackButton: some View {
        VStack {
            HStack {
                PlatformBackButton { dismiss() }
                Spacer()
            }
            .padding(.top, 48)
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    private func collapseToMiniPlayer() {
        guard !isCollapsingToMiniPlayer, let video else { return }
        let nativeAdActive = prerollAdDecision != nil || midrollAdDecision != nil
        let serverAdPresentation = serverAdCoordinator.activeFullscreenPresentation()
        let serverAdActive = serverAdPresentation != nil
        let isAdActive = nativeAdActive || serverAdActive
        let handoffPlayer = nativeAdActive
            ? activeAdPlayer
            : (serverAdActive ? serverAdCoordinator.interstitialPlayer : player)
        guard let handoffPlayer else { return }
        isCollapsingToMiniPlayer = true
        if isAdActive {
            isCollapsingAdToMiniPlayer = true
        }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.94)) {
            playerDragOffset = 999
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if isAdActive {
                miniPlayer.presentAd(player: handoffPlayer, title: "Ad · \(video.title)", route: .video(video.id), presentation: nativeAdActive ? activeAdPresentation : serverAdPresentation, playbackSessionId: playbackSessionId, entryContext: playbackEntryContext)
            } else {
                miniPlayer.present(player: handoffPlayer, title: video.title, route: .video(video.id), playbackSessionId: playbackSessionId, entryContext: playbackEntryContext)
            }
            dismiss()
        }
    }

    private var playerCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCollapsingToMiniPlayer,
                      !isPlayerTimelineScrubbing,
                      !isPlayerTimelineDragStart(value.startLocation),
                      value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) * 1.15 else { return }
                let translation = min(190, value.translation.height)
                playerDragOffset = translation
                if translation > 118 {
                    collapseToMiniPlayer()
                }
            }
            .onEnded { value in
                guard !isCollapsingToMiniPlayer else { return }
                if isPlayerHorizontalDismiss(value) {
                    collapseToMiniPlayer()
                    return
                }
                guard !isPlayerTimelineScrubbing,
                      !isPlayerTimelineDragStart(value.startLocation) else {
                    playerDragOffset = 0
                    return
                }
                let translation = max(0, value.translation.height)
                let predicted = max(0, value.predictedEndTranslation.height)
                let shouldMinimize = translation > 58 || predicted > 104
                if shouldMinimize {
                    collapseToMiniPlayer()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        playerDragOffset = 0
                    }
                }
            }
    }

    private func videoDetailsContent(_ v: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(v.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if v.views > 0 {
                        Text(fmtCount(v.views) + " views")
                            .font(.system(size: 13))
                            .foregroundStyle(C.textMuted)
                    }
                    if v.views > 0, let pub = v.publishedAt {
                        Text("·").foregroundStyle(C.textMuted.opacity(0.4))
                        Text(timeAgo(pub))
                            .font(.system(size: 13))
                            .foregroundStyle(C.textMuted)
                    }
                }
            }

            if let desc = v.description, !desc.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDescription.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundStyle(C.text.opacity(0.65))
                            .lineLimit(showDescription ? nil : 2)
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                        if desc.count > 120 {
                            Text(showDescription ? "Show less" : "...more")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(C.watch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Divider().background(C.border)
            sourceAndActions(v)
            Divider().background(C.border)
            linkedBanners(v)

        }
    }

    private func underPlayerPanelView(_ panel: WatchUnderPlayerPanel, video v: VideoDetail) -> some View {
        VStack(spacing: 0) {
            underPlayerPanelHeader(panel)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PostSectionView(
                        target: .video(v.id),
                        reloadToken: clipReactionReloadToken,
                        insertedPostToken: insertedClipPostToken,
                        insertedPost: insertedClipPost,
                        startsExpanded: true,
                        onSeek: { seekSeconds in
                            seekContentRespectingAds(to: seekSeconds)
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
            PlatformBackButton { setUnderPlayerPanel(nil) }

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

    private var standardAdCompanionCreative: AdCreative? {
        activeInlineAdCreative ?? serverAdCoordinator.activeCreative
    }

    // MARK: - Player area

    @ViewBuilder
    private var playerArea: some View {
        if let p = player {
            if let prerollAdDecision {
                NativeAdPlayerView(
                    decision: prerollAdDecision,
                    contentId: currentVideoId,
                    placement: "preroll",
                    userId: restoredAdPresentation?.userId ?? auth.currentUser?.id,
                    breakId: "preroll",
                    onFullscreen: { presentAdFullscreenPlayerIfNeeded() },
                    preservePlaybackOnDisappear: isCollapsingAdToMiniPlayer,
                    externalPlayer: restoredAdPlayer,
                    initialAdIndex: restoredAdPresentation?.currentAdIndex ?? 0,
                    isPresentationOnly: restoredAdPlayer != nil,
                    brandCardPlacement: .hidden,
                    initialImpressionTracked: restoredAdPresentation?.hasTrackedImpression ?? false,
                    initialStartTracked: restoredAdPresentation?.hasTrackedStart ?? false,
                    adPolicy: videoAdPolicy,
                    adRemoval: videoAdPolicy.adRemoval,
                    onActivePlayerChanged: { activeAdPlayer = $0 },
                    onActiveAdPresentationChanged: { activeAdPresentation = $0 },
                    onSkip: nil,
                    onFinish: nil
                ) {
                    finishVideoPreroll()
                }
                .frame(maxWidth: .infinity)
            } else if let midrollAdDecision, let activeAdBreak {
                NativeAdPlayerView(
                    decision: midrollAdDecision,
                    contentId: currentVideoId,
                    placement: activeAdBreak.placement,
                    userId: restoredAdPresentation?.userId ?? auth.currentUser?.id,
                    breakId: activeAdBreak.breakId,
                    onFullscreen: { presentAdFullscreenPlayerIfNeeded() },
                    preservePlaybackOnDisappear: isCollapsingAdToMiniPlayer,
                    externalPlayer: restoredAdPlayer,
                    initialAdIndex: restoredAdPresentation?.currentAdIndex ?? 0,
                    isPresentationOnly: restoredAdPlayer != nil,
                    brandCardPlacement: .hidden,
                    initialImpressionTracked: restoredAdPresentation?.hasTrackedImpression ?? false,
                    initialStartTracked: restoredAdPresentation?.hasTrackedStart ?? false,
                    adPolicy: videoAdPolicy,
                    adRemoval: videoAdPolicy.adRemoval,
                    overrideSkippable: isSeekEnforcedAdBreak ? false : nil,
                    onActivePlayerChanged: { activeAdPlayer = $0 },
                    onActiveAdPresentationChanged: { activeAdPresentation = $0 },
                    onSkip: nil,
                    onFinish: nil
                ) {
                    finishVideoAdBreak()
                }
                .frame(maxWidth: .infinity)
            } else if serverAdCoordinator.presentation != nil {
                ServerGuidedAdPlayerView(
                    coordinator: serverAdCoordinator,
                    brandCardPlacement: .hidden,
                    onFullscreen: {
                        openFullscreenServerAdPlayer(serverAdCoordinator)
                    }
                )
                .frame(maxWidth: .infinity)
            } else {
                WatchPlayerChrome(
                    player: p,
                    heatmapBuckets: heatmapBuckets,
                    likedSeconds: likedSeconds,
                    isAuthenticated: auth.isAuthenticated,
                    onLikeMoment: { sec in
                        Task { await likeMomentVideo(id: currentVideoId, sec: sec) }
                    },
                    showSpoilerToggle: video?.show != nil,
                    onClipRequest: { markIn, markOut, caption, _, thumbnailData in
                        let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                        let thumbnailUrl = try await uploadClipThumbnailIfNeeded(thumbnailData)
                        let post = try await APIClient.shared.createPost(
                            videoId: currentVideoId,
                            markIn: markIn,
                            markOut: markOut,
                            caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                            thumbnailUrl: thumbnailUrl
                        )
                        await MainActor.run {
                            insertedClipPost = post
                            insertedClipPostToken += 1
                        }
                    },
                    activeClipRange: $activeClipRange,
                    onPrevious: previousVideoIds.isEmpty ? nil : { playPreviousVideo() },
                    onBack: { collapseToMiniPlayer() },
                    onFullscreen: { presentFullscreenPlayerIfNeeded() },
                    adBreaks: adBreaks,
                    watchedAdBreakIds: watchedAdBreakIds,
                    onAdBreakRequested: { adBreak, resumeTime in
                        Task { await startVideoAdBreak(adBreak, resumeTime: resumeTime) }
                    },
                    knownDuration: video?.duration,
                    controlsInitiallyVisible: !hideControlsForExpandedHandoff,
                    onScrubbingChanged: { isScrubbing in
                        isPlayerTimelineScrubbing = isScrubbing
                        if isScrubbing {
                            cancelAutoplay()
                            showReplayPrompt = false
                        }
                    }
                ) {
                    playerMarkerOverlay
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Color.black
                .aspectRatio(16/9, contentMode: .fit)
                .overlay { ProgressView().tint(.white) }
        }
    }

    // MARK: - Source + action buttons (mirrors web source row + action cluster)

    private func sourceAndActions(_ v: VideoDetail) -> some View {
        VStack(spacing: 12) {
            // Source row
            HStack(spacing: 12) {
                // Avatar / cover
                if let ch = v.channel {
                    NavigationLink(value: AppRoute.channel(ch.handle ?? ch.id)) {
                        channelAvatar(ch)
                    }
                } else if let show = v.show {
                    NavigationLink(value: AppRoute.show(show.id)) {
                        showAvatar(show)
                    }
                }

                // Name + follower count
                VStack(alignment: .leading, spacing: 2) {
                    if let ch = v.channel {
                        NavigationLink(value: AppRoute.channel(ch.handle ?? ch.id)) {
                            Text(ch.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(C.text)
                        }
                        if let fc = ch.followerCount, fc > 0 {
                            Text(fmtCount(fc) + " followers")
                                .font(.system(size: 12))
                                .foregroundStyle(C.textMuted)
                        }
                    } else if let show = v.show {
                        NavigationLink(value: AppRoute.show(show.id)) {
                            Text(show.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(C.text)
                        }
                        if showFollowerCount > 0 {
                            Text(fmtCount(showFollowerCount) + " followers")
                                .font(.system(size: 12))
                                .foregroundStyle(C.textMuted)
                        }
                    }
                }

                Spacer()

                // Follow button
                if v.channel != nil {
                    Button {
                        Task { await toggleSubscribe(v) }
                    } label: {
                        followLabel(isSubscribed)
                    }
                } else if v.show != nil {
                    Button {
                        Task { await toggleShowFollow(v) }
                    } label: {
                        followLabel(isFollowingShow)
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
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View Vibe Meter")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    Button {
                        if auth.isAuthenticated {
                            showEnergy = true
                        } else {
                            NotificationCenter.default.post(name: .profileTabRequested, object: nil)
                        }
                    } label: {
                        WatchActionItem(
                            title: "Add Energy",
                            systemImage: "bolt.fill",
                            count: energyAggregate.flatMap { $0.count > 0 ? fmtCount($0.count) : nil },
                            isPrimary: true
                        )
                    }

                    Button {
                        if auth.isAuthenticated {
                            showEchoSheet = true
                        } else {
                            NotificationCenter.default.post(name: .profileTabRequested, object: nil)
                        }
                    } label: {
                        WatchActionItem(title: "Echo", systemImage: "dot.radiowaves.left.and.right")
                    }

                    if auth.isAuthenticated {
                        Button { showSaveSheet = true } label: {
                            WatchActionItem(title: "Save", systemImage: "bookmark")
                        }
                        Button { showPlaylistSheet = true } label: {
                            WatchActionItem(title: "Save", systemImage: "list.bullet.rectangle.badge.plus")
                        }
                    }

                    Button { shareVideo(v) } label: {
                        WatchActionItem(
                            title: shareCopied ? "Copied!" : "Share",
                            systemImage: shareCopied ? "checkmark" : "square.and.arrow.up"
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Playlist panel

    private func playlistPlaybackPanel(_ playlist: PlaylistDetail) -> some View {
        let playlistItems = playlist.items.compactMap { item -> (PlaylistDetailItem, PlaylistDetailVideo)? in
            guard let video = item.video else { return nil }
            return (item, video)
        }

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "list.bullet.rectangle")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(C.watch)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)
                        Text("\(playlistItems.count) \(playlist.type == "short" ? "shorts" : "videos")")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }

                    Spacer()
                }

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button {
                        if let first = playlistItems.first?.1 {
                            playVideoInPlace(first.id)
                        }
                    } label: {
                        Label("Play all", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(C.watch, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(playlistItems.isEmpty)

                    Button {
                        if let random = playlistItems.map(\.1).filter({ $0.id != currentVideoId }).randomElement()
                            ?? playlistItems.first?.1 {
                            playVideoInPlace(random.id)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.text)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(C.surface, in: Capsule())
                            .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .disabled(playlistItems.isEmpty)
                }
            }

            LazyVStack(spacing: 20) {
                ForEach(Array(playlistItems.enumerated()), id: \.element.0.id) { index, pair in
                    playlistPanelRow(
                        item: pair.0,
                        video: pair.1,
                        position: index + 1,
                        isCurrent: pair.1.id == currentVideoId
                    )
                }
            }
        }
    }

    private func playlistPanelRow(item: PlaylistDetailItem, video: PlaylistDetailVideo, position: Int, isCurrent: Bool) -> some View {
        Button {
            playVideoInPlace(video.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    CachedRemoteImage(
                        url: C.mediaURL(video.thumbnailUrl),
                        targetSize: CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.width * 9 / 16)
                    ) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if isCurrent {
                        Text("NOW PLAYING")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(C.watch, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(10)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.58), in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }

                    if let duration = video.duration {
                        playlistDurationBadge(duration)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("\(position)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isCurrent ? C.watch : C.textMuted)
                        .frame(width: 24, height: 24)
                        .background(C.surface, in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                    if let views = video.views, views > 0 {
                        Text("\(fmtCount(views)) views")
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                    }
                    }
                    Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityHint(isCurrent ? "Currently playing" : "Plays this video without autoplay preview")
    }

    private func playlistDurationBadge(_ secs: Double) -> some View {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let label = h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"

        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .fontDesign(.monospaced)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(4)
    }

    // MARK: - Related playlists drawer

    private func relatedPlaylistsPanel(_ playlists: [ChannelPlaylist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    relatedPlaylistsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "list.bullet.rectangle")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(C.watch)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playlists")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(C.text)
                        Text("\(playlists.count) from this \(video?.show == nil ? "channel" : "show")")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }

                    Spacer()

                    MediaverseIcon(name: relatedPlaylistsExpanded ? "chevron-up" : "chevron-down", fallbackSystemName: relatedPlaylistsExpanded ? "chevron.up" : "chevron.down")
                        .frame(width: 14, height: 14)
                        .foregroundStyle(C.textMuted)
                }
            }
            .buttonStyle(.plain)

            if relatedPlaylistsExpanded {
                LazyVStack(spacing: 8) {
                    ForEach(playlists) { playlist in
                        Button {
                            Task { await loadPlaylistIntoPlayer(playlist.id) }
                        } label: {
                            relatedPlaylistRow(playlist)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this playlist directly under the player")
                    }
                }
            }
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
    }

    private func relatedPlaylistRow(_ playlist: ChannelPlaylist) -> some View {
        HStack(spacing: 10) {
            relatedPlaylistMosaic(playlist)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text("\(playlist._count.items) \(playlist.type == "short" ? "short" : "video")\(playlist._count.items == 1 ? "" : "s")")
                    if let description = playlist.description, !description.isEmpty {
                        Text("·")
                            .foregroundStyle(C.textMuted.opacity(0.35))
                        Text(description)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(C.textMuted)
            }

            Spacer()

            MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                .frame(width: 11, height: 11)
                .foregroundStyle(C.textMuted)
        }
        .padding(8)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func relatedPlaylistMosaic(_ playlist: ChannelPlaylist) -> some View {
        let thumbnails = playlist.items.compactMap { $0.video?.thumbnailUrl }

        if thumbnails.count >= 4 {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                spacing: 0
            ) {
                ForEach(Array(thumbnails.prefix(4).enumerated()), id: \.offset) { _, thumbnail in
                    CachedRemoteImage(
                        url: C.mediaURL(thumbnail),
                        targetSize: CGSize(width: 56, height: 32)
                    ) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        C.surfaceAlt
                    }
                    .frame(width: 56, height: 32)
                    .clipped()
                }
            }
        } else if let thumbnail = thumbnails.first {
            CachedRemoteImage(
                url: C.mediaURL(thumbnail),
                targetSize: CGSize(width: 112, height: 63)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                C.surfaceAlt
            }
            .frame(width: 112, height: 63)
            .clipped()
        } else {
            C.surfaceAlt
                .overlay {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "list.bullet.rectangle")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(C.textMuted.opacity(0.45))
                }
        }
    }

    private func followLabel(_ following: Bool) -> some View {
        Text(following ? "✓ Following" : "Follow")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(following ? C.textMuted : .black)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(following ? C.surface : C.watch)
            .clipShape(Capsule())
            .overlay {
                if following { Capsule().stroke(C.border, lineWidth: 1) }
            }
    }

    @ViewBuilder
    private func channelAvatar(_ ch: VideoChannel) -> some View {
        if let url = C.mediaURL(ch.avatarUrl) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: 40, height: 40)
            ) { img in img.resizable().scaledToFill() }
                placeholder: { Circle().fill(C.surface) }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(C.surface)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String((ch.name.first ?? "?").uppercased()))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.watch)
                }
        }
    }

    @ViewBuilder
    private func showAvatar(_ show: ShowStub) -> some View {
        if let url = show.coverUrl.flatMap(URL.init) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: 40, height: 40)
            ) { img in img.resizable().scaledToFill() }
                placeholder: { RoundedRectangle(cornerRadius: 6).fill(C.surface) }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(C.surface)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String((show.title.first ?? "?").uppercased()))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.watch)
                }
        }
    }

    // MARK: - Linked clip / episode banners

    @ViewBuilder
    private func linkedBanners(_ v: VideoDetail) -> some View {
        if v.linkedClip != nil || v.linkedEpisode != nil {
            VStack(spacing: 8) {
                if let clip = v.linkedClip {
                    Button {
                        playVideoInPlace(clip.id)
                    } label: {
                        linkedBannerCard(
                            label: "Watch full clip",
                            title: clip.title,
                            subtitle: clip.duration.map(fmtDuration),
                            thumbnailUrl: clip.thumbnailUrl
                        )
                    }
                    .buttonStyle(.plain)
                }
                if let ep = v.linkedEpisode {
                    NavigationLink(value: AppRoute.episode(ep.id)) {
                        linkedBannerCard(
                            label: "Watch episode",
                            title: ep.title,
                            subtitle: ep.season.flatMap { s in
                                s.show.map { "\($0.title) · S\(s.seasonNumber)" }
                            },
                            thumbnailUrl: ep.thumbnailUrl
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func linkedBannerCard(label: String, title: String, subtitle: String?, thumbnailUrl: String?) -> some View {
        HStack(spacing: 12) {
            // Thumbnail
            CachedRemoteImage(
                url: thumbnailUrl.flatMap(URL.init),
                targetSize: CGSize(width: 72, height: 40)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                C.surface
            }
            .frame(width: 72, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .clipped()

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(C.watch)
                    .tracking(1)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                .frame(width: 12, height: 12)
                .foregroundStyle(C.textMuted.opacity(0.4))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(C.border, lineWidth: 1)
        }
    }

    // MARK: - Comments

    private func commentsSection(videoId: String) -> some View {
        CommentThreadView(
            target: .video(videoId),
            initialComments: localComments,
            previewLimit: 2,
            onShowMore: { _ in showCommentsSheet = true }
        )
    }

    // MARK: - Up Next

    private func upNextSection(_ items: [VideoUpNext]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.text)

            ForEach(items) { next in
                Button {
                    playVideoInPlace(next.id)
                    selectedContentTab = .upNext
                } label: {
                    UpNextRow(video: next)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data loading

    private func load() async {
        SGAIConnectionWarmer.warm()
        let loadGeneration = UUID()
        playbackLoadGeneration = loadGeneration
        let loadId = currentVideoId
        let loadUserId = auth.currentUser?.id
        isLoading = true
        loadError = nil
        savedProgress = 0
        showReplayPrompt = false
        do {
            let resolvedAdConfig = loadVideoAdConfig()
            async let progressTask: ProgressItem? = auth.isAuthenticated
                ? (try? await APIClient.shared.fetchProgress(videoId: loadId))
                : nil

            let v = try await APIClient.shared.fetchVideo(id: loadId)
            guard playbackLoadGeneration == loadGeneration,
                  currentVideoId == loadId,
                  auth.currentUser?.id == loadUserId else { return }
            // Ad eligibility is entitlement-sensitive and must come from the backend.
            // Missing policy data must not re-enable ads for an ad-free user.
            let policy = v.adPolicy ?? .disabled(reason: "policy_unavailable")
            videoAdPolicy = policy
            videoAdConfig = policy.applying(to: resolvedAdConfig)
            video             = v
            userLike          = v.userLike
            likeCount         = v.likes.filter { $0.type == "like" }.count
            isSubscribed      = v.isSubscribed
            isFollowingShow   = v.isFollowingShow
            showFollowerCount = v.showFollowerCount
            localComments     = v.comments

            let expandedItem = miniPlayer.takeExpandedItem(for: .video(loadId))
            if let mediaURL = C.mediaURL(v.videoUrl) {
                let resolvedMode = AdDeliveryResolver.resolve(policy: policy)
                adDeliveryMode = (resolvedMode == .sgai || resolvedMode == .ssai)
                    && mediaURL.pathExtension.lowercased() != "m3u8"
                    ? .csai
                    : resolvedMode
                debugAd(
                    "delivery configured=\(policy.deliveryMode ?? "missing") "
                    + "native=\(policy.deliveryByDevice?["nativeApp"] ?? "missing") "
                    + "resolved=\(adDeliveryMode.rawValue)"
                )
            } else {
                adDeliveryMode = .none
            }
            let isInitialFeedContinuation = expandedItem.map {
                !$0.isAd
                    && $0.sourceFrame != nil
                    && $0.entryContext.mode == .autoplayPreview
            } ?? false
            let shouldRequestPreroll = expandedItem == nil || isInitialFeedContinuation
            let prerollTask = Task {
                shouldRequestPreroll
                    ? await prerollDecision(contentId: loadId, contentType: "video", duration: v.duration)
                    : nil
            }

            // Progress restoration and preroll decisioning are independent. The
            // decision is already running while this request completes.
            if let item = await progressTask {
                guard playbackLoadGeneration == loadGeneration,
                      currentVideoId == loadId,
                      auth.currentUser?.id == loadUserId else {
                    prerollTask.cancel()
                    return
                }
                savedProgress = item.progress
            }
            if loadId == videoId,
               let initialClipRange,
               initialClipRange.markOut > initialClipRange.markIn,
               let duration = v.duration,
               duration > 0 {
                activeClipRange = initialClipRange
                savedProgress = min(max(initialClipRange.markIn / duration, 0), 0.999)
            }

            if let expandedItem {
                playbackSessionId = expandedItem.playbackSessionId
                playbackEntryContext = expandedItem.entryContext
            } else {
                playbackSessionId = UUID().uuidString
                playbackEntryContext = savedProgress > 0.05
                    ? PlaybackEntryContext(surface: .direct, mode: .resume, contentStartSec: max(0, (v.duration ?? 0) * savedProgress), previewSessionId: nil)
                    : .direct
            }
            if adDeliveryMode != .sgai {
                serverInterstitialMonitor = nil
                serverAdCoordinator.reset()
            }
            if adDeliveryMode != .sgai && adDeliveryMode != .ssai {
                serverFallbackSourceURL = nil
            }
            hideControlsForExpandedHandoff = expandedItem.map { !$0.isAd } ?? false
            if let expandedItem, !expandedItem.isAd,
               adDeliveryMode != .sgai, adDeliveryMode != .ssai {
                if isInitialFeedContinuation {
                    // Feed previews are deliberately raw/non-monetized. Preserve their
                    // player and position, but let the server decide whether deliberate
                    // watch playback owes a preroll before content continues.
                    expandedItem.player.pause()
                    attachPlayer(expandedItem.player, videoId: loadId, autoplay: false)
                    let preroll = await prerollTask.value
                    guard playbackLoadGeneration == loadGeneration,
                          currentVideoId == loadId,
                          auth.currentUser?.id == loadUserId else { return }
                    prerollAdDecision = preroll
                    if preroll == nil {
                        expandedItem.player.playImmediately(atRate: 1)
                        startProgress(videoId: loadId, player: expandedItem.player)
                    }
                } else {
                    // Expanding an existing mini-player is presentation-only: keep the
                    // same player/session and never request a second preroll.
                    attachPlayer(expandedItem.player, videoId: loadId, autoplay: true)
                    prerollAdDecision = nil
                }
                Task { await loadVideoAdBreaks(contentId: loadId, duration: v.duration) }
            } else if let originalURL = C.mediaURL(v.videoUrl) {
                let playbackContext = SGAIPlaybackContext(
                    contentId: loadId,
                    contentType: "video",
                    sessionId: playbackSessionId,
                    userId: loadUserId,
                    deviceId: AdPlaybackDevice.stableId,
                    country: nil,
                    orientation: "HORIZONTAL",
                    entry: playbackEntryContext
                )
                let deliveryPlan = WatchAdDeliveryPlan.resolve(
                    policy: policy,
                    mediaURL: originalURL,
                    context: playbackContext
                )
                adDeliveryMode = deliveryPlan.mode
                serverFallbackSourceURL = deliveryPlan.usesServerDelivery ? originalURL : nil
                let bootstrapStartedAt = Date()
                let bootstrapTask = deliveryPlan.mode == .sgai
                    ? Task {
                        await SGAIBootstrapClient.load(
                            streamMaster: originalURL,
                            context: playbackContext,
                            policy: policy
                        )
                    }
                    : nil
                let url = deliveryPlan.playbackURL
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
                if deliveryPlan.mode == .sgai {
                    let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: playbackPlayer)
                    serverInterstitialMonitor = monitor
                    serverAdCoordinator.configure(
                        player: playbackPlayer,
                        monitor: monitor,
                        context: playbackContext,
                        policy: policy,
                        bootstrap: nil
                    )
                    Task {
                        let bootstrapLoad = await bootstrapTask?.value
                        guard playbackLoadGeneration == loadGeneration,
                              currentVideoId == loadId,
                              auth.currentUser?.id == loadUserId else { return }
                        let elapsedMs = Int(Date().timeIntervalSince(bootstrapStartedAt) * 1_000)
                        let bootstrap = bootstrapLoad?.payload
                        debugAd(
                            "sgai bootstrap ready=\(bootstrap?.ready == true) "
                            + "assets=\(bootstrap?.assets.count ?? 0) elapsedMs=\(elapsedMs) "
                            + "serverTiming=\(bootstrapLoad?.serverTiming ?? "missing") "
                            + "cfRay=\(bootstrapLoad?.cfRay ?? "missing") "
                            + "\(bootstrapLoad?.networkTiming ?? "networkMetrics=missing")"
                        )
                        if let bootstrap {
                            serverAdCoordinator.acceptBootstrap(bootstrap, context: playbackContext)
                            Task {
                                for timing in await SGAICreativeWarmer.warm(bootstrap.assets) {
                                    debugAd(timing)
                                }
                            }
                        }
                    }
                } else if deliveryPlan.mode == .ssai {
                    serverInterstitialMonitor = nil
                    serverAdCoordinator.configureSSAI(
                        player: playbackPlayer,
                        context: playbackContext,
                        policy: policy,
                        durationSec: v.duration
                    )
                } else {
                    serverInterstitialMonitor = nil
                    serverAdCoordinator.reset()
                }

                if savedProgress > 0.05 && savedProgress < 0.95 {
                    var durationSeconds = v.duration
                    if durationSeconds == nil {
                        durationSeconds = try? await asset.load(.duration).seconds
                        guard playbackLoadGeneration == loadGeneration,
                              currentVideoId == loadId,
                              auth.currentUser?.id == loadUserId else { return }
                    }
                    if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
                        let contentTime = durationSeconds * savedProgress
                        let playbackTime = deliveryPlan.mode == .ssai
                            ? serverAdCoordinator.stitchedTime(forContentTime: contentTime)
                            : contentTime
                        let seekTo = CMTime(seconds: playbackTime,
                                           preferredTimescale: 600)
                        await playbackPlayer.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero)
                        guard playbackLoadGeneration == loadGeneration,
                              currentVideoId == loadId,
                              auth.currentUser?.id == loadUserId else { return }
                    }
                }

                if let expandedItem, expandedItem.isAd, let presentation = expandedItem.adPresentation {
                    attachPlayer(playbackPlayer, videoId: loadId, autoplay: false)
                    restoreExpandedAd(player: expandedItem.player, presentation: presentation)
                    Task { await loadVideoAdBreaks(contentId: loadId, duration: v.duration) }
                } else {
                    // Attach the content player immediately so its asset can begin
                    // preparing while the bounded CSAI preroll decision races.
                    attachPlayer(playbackPlayer, videoId: loadId, autoplay: false)
                    let preroll = await prerollTask.value
                    guard playbackLoadGeneration == loadGeneration,
                          currentVideoId == loadId,
                          auth.currentUser?.id == loadUserId else { return }
                    prerollAdDecision = preroll
                    if preroll == nil {
                        playbackPlayer.playImmediately(atRate: 1)
                        startProgress(videoId: loadId, player: playbackPlayer)
                        scheduleServerPlaybackWatchdog(playbackPlayer)
                    }
                    Task { await loadVideoAdBreaks(contentId: loadId, duration: v.duration) }
                }
            }

            isLoading = false
            miniPlayer.markExpandedPlayerAttached()
            Task { await loadSecondaryVideoData(for: v, loadId: loadId) }
        } catch {
            guard playbackLoadGeneration == loadGeneration,
                  currentVideoId == loadId,
                  auth.currentUser?.id == loadUserId else { return }
            loadError = error.localizedDescription
            isLoading = false
            miniPlayer.markExpandedPlayerAttached()
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

    @MainActor
    private func fallbackFromServerDelivery() async {
        guard adDeliveryMode == .sgai || adDeliveryMode == .ssai,
              let originalURL = serverFallbackSourceURL,
              let player else { return }
        let failedMode = adDeliveryMode
        let failedPlaybackTime = max(0, player.currentTime().seconds.validTime ?? 0)
        let resumeTime = failedMode == .ssai
            ? serverAdCoordinator.contentTime(forStitchedTime: failedPlaybackTime)
            : failedPlaybackTime
        serverPlaybackWatchdogTask?.cancel()
        serverPlaybackWatchdogTask = nil
        serverFallbackSourceURL = nil
        serverInterstitialMonitor = nil
        serverAdCoordinator.reset()
        adDeliveryMode = .none
        adBreaks = []
        let (_, item) = makeStartupOptimizedPlayerItem(url: originalURL)
        player.replaceCurrentItem(with: item)
        if resumeTime > 0 {
            await player.seek(
                to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        prerollAdDecision = nil
        attachPlayer(player, videoId: currentVideoId, autoplay: true)
    }

    private func loadVideoAdConfig() -> PlatformShortsAdsConfig {
        platformConfig.config.ads.video
    }

    private func videoAdMaxAds(for placement: String) -> Int? {
        if placement == "preroll" {
            return videoAdPolicy.pods?.prerollMaxAds ?? videoAdConfig.maxAds
        }
        return videoAdPolicy.pods?.midrollMaxAds ?? videoAdConfig.maxAds
    }

    private func videoAdMaxDurationSec(for placement: String, placementConfig: PlatformAdPlacementConfig) -> Int? {
        let podDuration = placement == "preroll"
            ? videoAdPolicy.pods?.prerollMaxBreakSec
            : videoAdPolicy.pods?.midrollMaxBreakSec
        return podDuration
            ?? placementConfig.maxDurationSec
            ?? videoAdConfig.maxDurationSec
            ?? videoAdPolicy.pods?.maxAdDurationSec
    }

    private func loadSecondaryVideoData(for video: VideoDetail, loadId: String) async {
        async let momentTask = APIClient.shared.fetchMomentLikes(videoId: loadId)
        async let markerTask = APIClient.shared.fetchPlayerMarkers(videoId: loadId)

        if let data = try? await momentTask, currentVideoId == loadId {
            heatmapBuckets = data.buckets
            likedSeconds = data.userLikedSeconds
        }

        if let markers = try? await markerTask, currentVideoId == loadId {
            playerMarkers = markers
            dismissedMarkerIds.removeAll()
        }

        if let playlistId, playlistPanel == nil || playlistPanel?.id != playlistId {
            let detail = try? await APIClient.shared.fetchPlaylistDetail(id: playlistId)
            if currentVideoId == loadId {
                playlistPanel = detail
            }
        }

        guard currentVideoId == loadId else { return }
        await loadRelatedPlaylists(for: video)
    }

    private func loadRelatedPlaylists(for video: VideoDetail) async {
        let playlists: [ChannelPlaylist]?
        if let show = video.show {
            playlists = try? await APIClient.shared.fetchShowPlaylists(id: show.id)
        } else if let handle = video.channel?.handle, !handle.isEmpty {
            playlists = try? await APIClient.shared.fetchChannelPlaylists(handle: handle)
        } else {
            playlists = nil
        }

        relatedPlaylists = (playlists ?? [])
            .filter { $0.type == "video" && $0._count.items > 0 }
            .filter { $0.id != playlistId }
    }

    @MainActor
    private func loadPlaylistIntoPlayer(_ id: String) async {
        guard playlistPanel?.id != id else {
            selectedContentTab = .playlist
            return
        }
        guard let detail = try? await APIClient.shared.fetchPlaylistDetail(id: id) else { return }
        playlistPanel = detail
        selectedContentTab = .playlist
    }

    private func configureFullPlaybackBuffering(for player: AVPlayer) {
        player.currentItem?.preferredForwardBufferDuration = 12
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func attachPlayer(_ player: AVPlayer, videoId: String, autoplay: Bool = true) {
        if let existing = momentObserver {
            momentObserverPlayer?.removeTimeObserver(existing)
            momentObserver = nil
            momentObserverPlayer = nil
        }

        lastObservedContentTime = max(0, player.currentTime().seconds.validTime ?? 0)
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !time.seconds.isNaN else { return }
            let previousTime = lastObservedContentTime
            lastObservedContentTime = max(0, time.seconds)
            currentPlayerSec = Int(time.seconds)
            if let adBreak = nextDueAdBreak(from: previousTime, to: time.seconds) {
                Task { await startVideoAdBreak(adBreak) }
            }
        }
        momentObserver = token
        momentObserverPlayer = player

        configureFullPlaybackBuffering(for: player)
        self.player = player
        if autoplay {
            player.playImmediately(atRate: 1)
            startProgress(videoId: videoId, player: player)
            scheduleServerPlaybackWatchdog(player)
        }
    }

    private func scheduleServerPlaybackWatchdog(_ watchedPlayer: AVPlayer) {
        serverPlaybackWatchdogTask?.cancel()
        guard serverFallbackSourceURL != nil,
              adDeliveryMode == .sgai || adDeliveryMode == .ssai else { return }
        let watchedItem = watchedPlayer.currentItem
        serverPlaybackWatchdogTask = Task { @MainActor in
            for _ in 0..<14 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled,
                      player === watchedPlayer,
                      watchedPlayer.currentItem === watchedItem,
                      serverFallbackSourceURL != nil else { return }
                if serverAdCoordinator.presentation != nil
                    || watchedPlayer.currentTime().seconds > 0.05 {
                    serverPlaybackWatchdogTask = nil
                    return
                }
                if watchedItem?.status == .failed { break }
            }
            debugAd(
                "server playback stalled mode=\(adDeliveryMode.rawValue) "
                + "status=\(String(describing: watchedItem?.status)) "
                + "waiting=\(watchedPlayer.reasonForWaitingToPlay?.rawValue ?? "none"); failing open"
            )
            serverPlaybackWatchdogTask = nil
            await fallbackFromServerDelivery()
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
            finishVideoPreroll()
        } else {
            finishVideoAdBreak()
        }
    }

    private func finishVideoPreroll() {
        prerollAdDecision = nil
        clearRestoredAd()
        guard let player else { return }
        player.play()
        startProgress(videoId: currentVideoId, player: player)
    }

    private func finishVideoAdBreak() {
        guard let activeAdBreak else { return }
        watchedAdBreakIds.insert(activeAdBreak.id)
        pendingAdBreakIds.remove(activeAdBreak.id)
        midrollAdDecision = nil
        self.activeAdBreak = nil
        clearRestoredAd()
        isSeekEnforcedAdBreak = false
        resumeContentAfterAdBreakIfNeeded()
    }

    private func prerollDecision(contentId: String, contentType: String, duration: Double?) async -> AdDecision? {
        guard adDeliveryMode == .csai else { return nil }
        let placementConfig = videoAdConfig.placementConfig(for: "preroll")
        guard videoAdPolicy.adsEnabled else { return nil }
        do {
            let decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: contentId,
                    contentType: contentType,
                    placement: nil,
                    durationSec: duration,
                    maxAds: videoAdMaxAds(for: "preroll"),
                    maxDurationSec: videoAdMaxDurationSec(for: "preroll", placementConfig: placementConfig),
                    skippable: videoAdPolicy.skippable,
                    skipAfterSec: videoAdPolicy.skipAfterSec,
                    orientation: "HORIZONTAL",
                    breakId: "preroll",
                    userId: auth.currentUser?.id
                ),
                timeout: 1.5
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

    private func loadVideoAdBreaks(contentId: String, duration: Double?) async {
        guard adDeliveryMode == .csai else {
            adBreaks = []
            return
        }
        let requestGeneration = playbackLoadGeneration
        let requestUserId = auth.currentUser?.id
        let placementConfig = videoAdConfig.placementConfig(for: "midroll")
        guard videoAdPolicy.adsEnabled else { return }
        do {
            let breaks = try await AdServerClient.shared.requestVMAP(
                AdRequestContext(
                    contentId: contentId,
                    contentType: "video",
                    placement: nil,
                    durationSec: duration,
                    maxAds: videoAdMaxAds(for: "midroll"),
                    maxDurationSec: videoAdMaxDurationSec(for: "midroll", placementConfig: placementConfig),
                    skippable: videoAdPolicy.skippable,
                    skipAfterSec: videoAdPolicy.skipAfterSec,
                    orientation: "HORIZONTAL",
                    userId: requestUserId
                )
            )
            guard playbackLoadGeneration == requestGeneration,
                  currentVideoId == contentId,
                  auth.currentUser?.id == requestUserId else { return }
            adBreaks = breaks
            debugAd("vmap loaded contentId=\(contentId) scheduledNonPrerollBreaks=\(breaks.count) (preroll is requested separately)")
        } catch {
            debugAd("vmap failed contentId=\(contentId): \(error.localizedDescription)")
        }
    }

    private func nextDueAdBreak(from previousSeconds: Double, to seconds: Double) -> AdBreak? {
        guard adDeliveryMode == .csai else { return nil }
        guard prerollAdDecision == nil, midrollAdDecision == nil else { return nil }
        return AdBreakScheduler.nextDue(
            in: adBreaks,
            watchedIds: watchedAdBreakIds,
            pendingIds: pendingAdBreakIds,
            from: previousSeconds,
            to: seconds
        )
    }

    @MainActor
    private func startVideoAdBreak(_ adBreak: AdBreak, resumeTime: Double? = nil) async {
        guard adDeliveryMode == .csai else { return }
        guard !watchedAdBreakIds.contains(adBreak.id),
              !pendingAdBreakIds.contains(adBreak.id),
              midrollAdDecision == nil else { return }

        if let resumeTime {
            pendingContentSeekAfterAd = resumeTime
            isSeekEnforcedAdBreak = true
        }

        let placementConfig = videoAdConfig.placementConfig(for: adBreak.placement)
        guard videoAdPolicy.adsEnabled else {
            watchedAdBreakIds.insert(adBreak.id)
            resumeContentAfterAdBreakIfNeeded()
            return
        }

        pendingAdBreakIds.insert(adBreak.id)
        let requestGeneration = playbackLoadGeneration
        let requestContentId = currentVideoId
        let requestUserId = auth.currentUser?.id
        let decision: AdDecision?
        do {
            decision = try await AdServerClient.shared.requestAd(
                AdRequestContext(
                    contentId: requestContentId,
                    contentType: "video",
                    placement: nil,
                    durationSec: video?.duration,
                    maxAds: videoAdMaxAds(for: "midroll"),
                    maxDurationSec: videoAdMaxDurationSec(for: "midroll", placementConfig: placementConfig),
                    skippable: videoAdPolicy.skippable,
                    skipAfterSec: videoAdPolicy.skipAfterSec,
                    orientation: "HORIZONTAL",
                    breakId: adBreak.breakId,
                    userId: requestUserId
                ),
                timeout: 1.0
            )
        } catch {
            debugAd("midroll failed contentId=\(requestContentId) breakId=\(adBreak.breakId): \(error.localizedDescription)")
            decision = nil
        }

        guard playbackLoadGeneration == requestGeneration,
              currentVideoId == requestContentId,
              auth.currentUser?.id == requestUserId else { return }
        guard let decision, decision.filled, !decision.ads.isEmpty else {
            debugAd("midroll no-fill contentId=\(requestContentId) breakId=\(adBreak.breakId) reason=\(decision?.noFillReason ?? "none")")
            watchedAdBreakIds.insert(adBreak.id)
            pendingAdBreakIds.remove(adBreak.id)
            resumeContentAfterAdBreakIfNeeded()
            return
        }

        // Content remains active while decisioning. Switch only after a filled
        // decision is ready, eliminating a network-sized midroll freeze.
        player?.pause()
        activeAdBreak = adBreak
        midrollAdDecision = decision
    }

    private func resumeContentAfterAdBreakIfNeeded() {
        guard let player else { return }
        if let resumeTime = pendingContentSeekAfterAd {
            let current = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : lastObservedContentTime)
            if let nextBreak = nextDueAdBreak(from: current, to: resumeTime) {
                Task { await startVideoAdBreak(nextBreak, resumeTime: resumeTime) }
                return
            }
            pendingContentSeekAfterAd = nil
            isSeekEnforcedAdBreak = false
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

    private func seekContentRespectingAds(to seconds: Double, autoplay: Bool = false) {
        guard let player else { return }
        let target = max(0, seconds)
        let playerTime = player.currentTime().seconds
        let current = max(0, playerTime.isFinite ? playerTime : lastObservedContentTime)
        if let adBreak = nextDueAdBreak(from: current, to: target) {
            player.pause()
            Task { await startVideoAdBreak(adBreak, resumeTime: target) }
            return
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) { _ in
            if autoplay {
                Task { @MainActor in player.play() }
            }
        }
    }

    private func debugAd(_ message: String) {
        #if DEBUG
        print("[Ads][Video] \(message)")
        #endif
    }

    private func startProgress(videoId: String, player: AVPlayer) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                guard let item = player.currentItem else { return }
                let stitchedTime = player.currentTime().seconds
                let cur = adDeliveryMode == .ssai
                    ? serverAdCoordinator.contentTime(forStitchedTime: stitchedTime)
                    : stitchedTime
                let tot = adDeliveryMode == .ssai
                    ? (video?.duration ?? item.duration.seconds)
                    : item.duration.seconds
                guard tot > 0, !tot.isNaN else { return }
                try? await APIClient.shared.recordProgress(videoId: videoId, seconds: Int(cur), percent: min(1.0, cur / tot))
            }
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
        guard let p = player, let item = p.currentItem else { return }
        let stitchedTime = p.currentTime().seconds
        let cur = adDeliveryMode == .ssai
            ? serverAdCoordinator.contentTime(forStitchedTime: stitchedTime)
            : stitchedTime
        let tot = adDeliveryMode == .ssai
            ? (video?.duration ?? item.duration.seconds)
            : item.duration.seconds
        guard tot > 0 else { return }
        Task { try? await APIClient.shared.recordProgress(videoId: currentVideoId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
    }

    // MARK: - Moment like

    private func likeMomentVideo(id: String, sec: Int) async {
        // Optimistic: toggle likedSeconds immediately
        let wasLiked = likedSeconds.contains(sec)
        if wasLiked { likedSeconds.removeAll { $0 == sec } }
        else        { likedSeconds.append(sec) }

        guard let resp = try? await APIClient.shared.toggleMomentLike(videoId: id, timestampSec: sec) else {
            // Revert
            if wasLiked { likedSeconds.append(sec) } else { likedSeconds.removeAll { $0 == sec } }
            return
        }
        if !resp.liked { likedSeconds.removeAll { $0 == sec } }
        else if !likedSeconds.contains(sec) { likedSeconds.append(sec) }

    }

    // MARK: - Autoplay

    private func handlePlaybackEnded(_ notification: Notification) {
        guard let currentItem = player?.currentItem,
              notification.object as? AVPlayerItem === currentItem else { return }

        let playerDuration = currentItem.duration.seconds.validTime ?? 0
        let serverDuration = video?.duration ?? 0
        let duration = max(playerDuration, serverDuration)
        let current = player?.currentTime().seconds.validTime ?? currentItem.currentTime().seconds.validTime ?? 0
        guard duration > 0, current >= duration - 0.75, current / duration >= 0.95 else { return }

        if let v = video, let next = v.upNext.first {
            startAutoplay(next: next)
        } else {
            showReplayPrompt = true
        }
    }

    private func playVideoInPlace(_ id: String, recordPrevious: Bool = true) {
        guard id != currentVideoId else { return }
        stopProgress()
        if recordPrevious {
            previousVideoIds.append(currentVideoId)
        }
        cancelAutoplay()
        isLoading = true
        loadError = nil
        video = nil
        playerDragOffset = 0
        showReplayPrompt = false
        showDescription = false
        shareCopied = false
        showCommentsSheet = false
        underPlayerPanel = nil
        selectedContentTab = playlistPanel == nil ? .upNext : .playlist
        clippingCount = 0
        playerMarkers = []
        dismissedMarkerIds.removeAll()
        heatmapBuckets = []
        likedSeconds = []
        currentPlayerSec = 0
        insertedClipPost = nil
        insertedClipPostToken = 0
        activeClipRange = nil
        relatedPlaylists = []
        prerollAdDecision = nil
        midrollAdDecision = nil
        activeAdBreak = nil
        adBreaks = []
        watchedAdBreakIds = []
        pendingAdBreakIds = []
        pendingContentSeekAfterAd = nil
        isSeekEnforcedAdBreak = false
        lastObservedContentTime = 0
        reuseCurrentPlayerForFullscreenSelection = isFullscreenPlayerPresented && player != nil
        if !reuseCurrentPlayerForFullscreenSelection {
            player?.pause()
            player = nil
        }
        currentVideoId = id
    }

    private func playPreviousVideo() {
        guard let previousId = previousVideoIds.popLast() else { return }
        playVideoInPlace(previousId, recordPrevious: false)
    }

    private func startAutoplay(next: VideoUpNext) {
        showReplayPrompt = false
        autoplayTask?.cancel()
        autoplayCountdown = 10
        let nextId = next.id
        let sourceId = currentVideoId
        autoplayTask = Task { @MainActor in
            while !Task.isCancelled, autoplayCountdown > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard currentVideoId == sourceId else {
                    cancelAutoplay()
                    return
                }
                autoplayCountdown -= 1
            }

            guard !Task.isCancelled else { return }
            guard currentVideoId == sourceId else {
                cancelAutoplay()
                return
            }
            cancelAutoplay()
            playVideoInPlace(nextId)
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
    private func autoplayOverlay(title: String) -> some View {
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
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                HStack(spacing: 12) {
                    Button {
                        guard let next = video?.upNext.first else { return }
                        cancelAutoplay()
                        playVideoInPlace(next.id)
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

    private var replayOverlay: some View {
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
                    replayCurrentVideo()
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

    private func replayCurrentVideo() {
        showReplayPrompt = false
        cancelAutoplay()
        let start = CMTime(seconds: 0, preferredTimescale: 600)
        player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player?.play()
        }
        currentPlayerSec = 0
        if auth.isAuthenticated {
            Task { try? await APIClient.shared.recordProgress(videoId: currentVideoId, seconds: 0, percent: 0) }
        }
    }

    // MARK: - Player markers

    private func presentAdFullscreenPlayerIfNeeded() {
        guard !isFullscreenPlayerPresented,
              !miniPlayer.isExpansionHandoffActive,
              let adPlayer = activeAdPlayer ?? restoredAdPlayer,
              let presentation = activeAdPresentation ?? restoredAdPresentation else { return }
        var didCompleteAd = false
        var didAdvanceAd = false
        isFullscreenPlayerPresented = true
        openFullscreenAdPlayer(
            adPlayer,
            presentation: presentation,
            onAdCompleted: {
                didCompleteAd = true
            },
            onAdFinished: {
                didAdvanceAd = true
            },
            onDismiss: {
                if !didAdvanceAd && shouldRestoreFullscreenAd(adPlayer) {
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
              let p = player else { return }
        isFullscreenPlayerPresented = true
        openFullscreenPlayer(
            p,
            heatmapBuckets: heatmapBuckets,
            likedSeconds: likedSeconds,
            isAuthenticated: auth.isAuthenticated,
            onLikeMoment: { sec in
                Task { await likeMomentVideo(id: currentVideoId, sec: sec) }
            },
            showSpoilerToggle: video?.show != nil,
            onClipRequest: { markIn, markOut, caption, _, thumbnailData in
                let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let thumbnailUrl = try await uploadClipThumbnailIfNeeded(thumbnailData)
                let post = try await APIClient.shared.createPost(
                    videoId: currentVideoId,
                    markIn: markIn,
                    markOut: markOut,
                    caption: normalizedCaption.isEmpty ? nil : normalizedCaption,
                    thumbnailUrl: thumbnailUrl
                )
                await MainActor.run {
                    insertedClipPost = post
                    insertedClipPostToken += 1
                }
            },
            activeClipRange: $activeClipRange,
            onPrevious: previousVideoIds.isEmpty ? nil : { playPreviousVideo() },
            relatedItems: fullscreenRelatedItems,
            onSelectRelated: { item in
                playVideoInPlace(item.id)
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
        seekContentRespectingAds(to: Double(post.markIn), autoplay: true)
    }

    private func uploadClipThumbnailIfNeeded(_ thumbnailData: Data?) async throws -> String? {
        guard let thumbnailData else { return nil }
        return try await APIClient.shared.uploadThumbnailImage(thumbnailData)
    }

    private var fullscreenRelatedItems: [PlayerRelatedItem] {
        (video?.upNext ?? []).map { item in
            PlayerRelatedItem(
                id: item.id,
                title: item.title,
                subtitle: item.channel?.name,
                thumbnailUrl: item.thumbnailUrl
            )
        }
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
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
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
        case .showSeason(let showId, let seasonId): ShowView(showId: showId, initialSeasonId: seasonId)
        case .showAccess(let showId, let productId, let intent, let handoffId):
            ShowView(showId: showId, handoffProductId: productId, handoffIntent: intent, handoffPublicId: handoffId)
        case .handoff(let id): HandoffResolverView(publicId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        case .vibe(let slug): VibeDetailView(slug: slug)
        case .vibeWave(let vibeSlug, let waveSlug): VibeDetailView(slug: vibeSlug, initialWaveSlug: waveSlug)
        case .vibeManagement(let slug, let tab): VibeDetailView(slug: slug, initialManagementTab: tab)
        case .vibeInvite(let token): VibeInviteAcceptView(token: token)
        case .event(let slug): VibeEventDetailView(slug: slug)
        case .eventInvite(let token): VibeEventInviteView(token: token)
        case .ripple(let postId): RippleDetailView(postId: postId)
        case .flash(let storyId): FlashDeepLinkView(storyId: storyId)
        case .atmo(let handle): AtmoProfileView(handle: handle)
        case .search(let query): SearchView(initialQuery: query)
        }
    }

    // MARK: - Actions

    private func toggleLike(_ type: String, videoId: String) async {
        let was = userLike
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
            let result = try await APIClient.shared.likeVideo(videoId: videoId, type: sending)
            likeCount = result.likes
            userLike  = result.userLike
        } catch {
            userLike  = was
            likeCount = wasCount
        }
    }

    private func toggleSubscribe(_ v: VideoDetail) async {
        guard let ch = v.channel else { return }
        let was = isSubscribed
        isSubscribed.toggle()
        do {
            // Use handle if available, else fall back to id (server accepts both)
            let key = ch.handle ?? ch.id
            let result = try await APIClient.shared.toggleChannelFollow(handle: key)
            isSubscribed = result.subscribed
            NotificationCenter.default.post(name: .userFollowChanged, object: nil)
        } catch {
            isSubscribed = was
        }
    }

    private func toggleShowFollow(_ v: VideoDetail) async {
        guard let show = v.show else { return }
        let was = isFollowingShow
        isFollowingShow.toggle()
        showFollowerCount += isFollowingShow ? 1 : -1
        do {
            let result = try await APIClient.shared.toggleShowFollow(id: show.id)
            showFollowerCount = result.count
            isFollowingShow   = result.subscribed
            NotificationCenter.default.post(name: .userFollowChanged, object: nil)
        } catch {
            isFollowingShow   = was
            showFollowerCount += was ? 1 : -1
        }
    }

    private func shareVideo(_ v: VideoDetail) {
        guard let url = URL(string: "\(C.baseURL)/watch/\(v.id)") else { return }
        let vc  = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.presentFromRoot()
    }

    // MARK: - Helpers

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }

    private func fmtDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func timeAgo(_ iso: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        guard let d = df.date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60  { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        if s < 86400 { return "\(s/3600)h ago" }
        if s < 86400*7 { return "\(s/86400)d ago" }
        if s < 86400*30 { return "\(s/(86400*7))w ago" }
        if s < 86400*365 { return "\(s/(86400*30))mo ago" }
        return "\(s/(86400*365))y ago"
    }
}

// MARK: - Up Next row (shared)

struct UpNextRow: View {
    let video: VideoUpNext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(video.thumbnailUrl),
                    targetSize: CGSize(
                        width: UIScreen.main.bounds.width,
                        height: UIScreen.main.bounds.width * 9 / 16
                    )
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.07) }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()

                if let dur = video.duration {
                    Text(fmtDur(dur))
                        .font(.system(size: 10, weight: .semibold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.80))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .padding(.horizontal, -C.pagePad)

            HStack(alignment: .top, spacing: 10) {
                if let channel = video.channel {
                    CachedRemoteImage(
                        url: C.mediaURL(channel.avatarUrl),
                        targetSize: CGSize(width: 36, height: 36)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(C.surface)
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let channel = video.channel {
                        Text(channel.name)
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                    }
                    if video.views > 0 {
                        Text(fmtViews(video.views) + " views")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .accessibilityHint("Plays this video in the current player")
    }

    private func fmtDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
    private func fmtViews(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
}
