import SwiftUI
import AVKit

// MARK: - VideoWatchView
// Mirrors /src/app/watch/WatchClient.tsx for the "video" type on mobile.
// Features: AVPlayer + progress restore/record, like/dislike, channel/show follow,
// share sheet, linked clip/episode banners, description expand, comments, up-next.

enum WatchUnderPlayerPanel: Identifiable {
    case comments
    case reactions

    var id: String {
        switch self {
        case .comments: return "comments"
        case .reactions: return "reactions"
        }
    }
}

struct VideoWatchView: View {

    let videoId: String

    // ── Data
    @State private var video:         VideoDetail?
    @State private var isLoading                = true
    @State private var loadError:     String?

    // ── Player
    @State private var player:        AVPlayer?
    @State private var savedProgress: Double    = 0
    @State private var progressTimer: Timer?

    // ── Engagement (optimistic)
    @State private var userLike:      String?   // "like" | "dislike" | nil
    @State private var likeCount:     Int       = 0
    @State private var isSubscribed:  Bool      = false
    @State private var isFollowingShow: Bool    = false
    @State private var showFollowerCount: Int   = 0

    // ── UI
    @State private var showDescription          = false
    @State private var shareCopied              = false
    @State private var localComments:  [Comment]          = []
    @State private var commentText:    String             = ""
    @State private var isPostingComment                   = false

    // ── Autoplay
    @State private var autoplayCountdown: Int   = 0
    @State private var autoplayTimer:     Timer?
    @State private var autoplayDest:      AppRoute?
    @State private var showReplayPrompt          = false

    // ── Save to collection
    @State private var showSaveSheet:     Bool   = false
    @State private var clipReactionReloadToken   = 0
    @State private var insertedClipPostToken      = 0
    @State private var insertedClipPost: UserPost?
    @State private var underPlayerPanel: WatchUnderPlayerPanel?
    @State private var playerDragOffset: CGFloat = 0

    // ── Moment likes (heatmap)
    @State private var heatmapBuckets:   [Int]   = []
    @State private var likedSeconds:     [Int]   = []
    @State private var currentPlayerSec: Int     = 0
    @State private var momentObserver:   Any?    = nil

    // ── Timed player markers
    @State private var playerMarkers: [PlayerMarker] = []
    @State private var dismissedMarkerIds: Set<String> = []
    @State private var markerRoute: AppRoute?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager

    // MARK: - Body

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                watchSkeleton
            } else if let v = video {
                mainContent(v)
            } else {
                // Load failed — show retry
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
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
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onDisappear { stopProgress() }
        .sheet(isPresented: $showSaveSheet) {
            if let vid = video {
                SaveToCollectionSheet(videoId: vid.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            if let v = video, let next = v.upNext.first {
                startAutoplay(next: next)
            } else {
                showReplayPrompt = true
            }
        }
        .navigationDestination(item: $autoplayDest) { route in
            routeDestination(route)
        }
        .navigationDestination(item: $markerRoute) { route in
            routeDestination(route)
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
                pinnedPlayer(v, geometry: geo, progress: progress)

                if let panel = underPlayerPanel {
                    underPlayerPanelView(panel, video: v)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            videoDetailsContent(v)

                            if !v.upNext.isEmpty {
                                upNextSection(v.upNext)
                            }
                        }
                    }
                }
            }
            .background(C.bg)
        }
    }

    private func pinnedPlayer(_ v: VideoDetail, geometry geo: GeometryProxy, progress: CGFloat) -> some View {
        ZStack {
            playerArea
            if autoplayCountdown > 0, let next = v.upNext.first {
                autoplayOverlay(title: next.title)
            } else if showReplayPrompt {
                replayOverlay
            }
        }
        .frame(width: geo.size.width)
        .scaleEffect(x: collapseScale(progress), y: collapseScale(progress), anchor: .topLeading)
        .offset(x: collapseXOffset(in: geo, progress: progress), y: collapseYOffset(in: geo, progress: progress))
        .opacity(max(0.82, 1 - progress * 0.18))
        .gesture(playerCollapseGesture)
        .frame(maxWidth: .infinity)
        .frame(height: playerVisibleHeight(in: geo, progress: progress), alignment: .topLeading)
        .background(Color.black)
        .zIndex(10)
        .ignoresSafeArea(edges: .top)
    }

    private func collapseProgress(in geo: GeometryProxy) -> CGFloat {
        min(max(playerDragOffset / max(240, geo.size.height * 0.34), 0), 1)
    }

    private func collapseScale(_ progress: CGFloat) -> CGFloat {
        1 - progress * 0.58
    }

    private func collapseXOffset(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        let targetWidth = geo.size.width * collapseScale(1)
        let targetX = geo.size.width - targetWidth - 12
        return targetX * progress
    }

    private func collapseYOffset(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        let targetY = max(0, geo.size.height - 176)
        return targetY * progress
    }

    private func playerVisibleHeight(in geo: GeometryProxy, progress: CGFloat) -> CGFloat {
        geo.size.width * 9 / 16
    }

    private var playerBackButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
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

    private var playerCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                playerDragOffset = min(180, value.translation.height)
            }
            .onEnded { value in
                let shouldMinimize = value.translation.height > 78 || value.predictedEndTranslation.height > 160
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    playerDragOffset = 0
                }
                if shouldMinimize, let player, let video {
                    miniPlayer.present(player: player, title: video.title, route: .video(video.id))
                    dismiss()
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

            PostSectionView(
                target: .video(v.id),
                reloadToken: clipReactionReloadToken,
                insertedPostToken: insertedClipPostToken,
                insertedPost: insertedClipPost,
                previewLimit: 2,
                onShowMore: { _ in underPlayerPanel = .reactions },
                onSeek: { seekSeconds in
                let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            )

            commentsSection(videoId: v.id)
        }
        .padding(C.pagePad)
    }

    private func underPlayerPanelView(_ panel: WatchUnderPlayerPanel, video v: VideoDetail) -> some View {
        VStack(spacing: 0) {
            underPlayerPanelHeader(panel)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch panel {
                    case .comments:
                        CommentThreadView(target: .video(v.id), initialComments: localComments)
                    case .reactions:
                        PostSectionView(
                            target: .video(v.id),
                            reloadToken: clipReactionReloadToken,
                            insertedPostToken: insertedClipPostToken,
                            insertedPost: insertedClipPost,
                            startsExpanded: true,
                            onSeek: { seekSeconds in
                            let t = CMTime(seconds: seekSeconds, preferredTimescale: 600)
                            player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        )
                    }
                }
                .padding(C.pagePad)
            }
        }
    }

    private func underPlayerPanelHeader(_ panel: WatchUnderPlayerPanel) -> some View {
        HStack(spacing: 12) {
            Button {
                underPlayerPanel = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
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

    // MARK: - Player area

    @ViewBuilder
    private var playerArea: some View {
        if let p = player {
            WatchPlayerChrome(
                player: p,
                heatmapBuckets: heatmapBuckets,
                likedSeconds: likedSeconds,
                isAuthenticated: auth.isAuthenticated,
                onLikeMoment: { sec in
                    Task { await likeMomentVideo(id: videoId, sec: sec) }
                },
                showSpoilerToggle: video?.show != nil,
                onClipRequest: { markIn, markOut, caption, _ in
                    let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                    let post = try await APIClient.shared.createPost(
                        videoId: videoId,
                        markIn: markIn,
                        markOut: markOut,
                        caption: normalizedCaption.isEmpty ? nil : normalizedCaption
                    )
                    await MainActor.run {
                        insertedClipPost = post
                        insertedClipPostToken += 1
                    }
                },
                onBack: { dismiss() },
                onFullscreen: { openFullscreenPlayer(p) }
            ) {
                playerMarkerOverlay
            }
            .frame(maxWidth: .infinity)
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

            // Action pill row: Like / Dislike / Share. Labels stay single-line under compression.
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button {
                        Task { await toggleLike("like", videoId: v.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: userLike == "like" ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(userLike == "like" ? C.watch : C.textMuted)
                            Text(likeCount > 0 ? fmtCount(likeCount) : "Like")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(userLike == "like" ? .white : C.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(C.surface)
                    }

                    Divider()
                        .frame(width: 1, height: 22)
                        .background(C.border)

                    Button {
                        Task { await toggleLike("dislike", videoId: v.id) }
                    } label: {
                        Image(systemName: userLike == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(userLike == "dislike" ? .white : C.textMuted)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(C.surface)
                    }
                }
                .layoutPriority(1)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(C.border, lineWidth: 1) }

                Button {
                    shareVideo(v)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: shareCopied ? "checkmark" : "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text(shareCopied ? "Copied!" : "Share")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(C.surface)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                }

                if auth.isAuthenticated {
                    Button {
                        showSaveSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 12))
                            Text("Save")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(C.textMuted)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(C.surface)
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                    }
                }

                Spacer(minLength: 0)
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
        if let url = ch.avatarUrl.flatMap(URL.init) {
            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
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
            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
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
                    NavigationLink(value: AppRoute.video(clip.id)) {
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
            AsyncImage(url: thumbnailUrl.flatMap(URL.init)) { img in
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
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
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
            onShowMore: { _ in underPlayerPanel = .comments }
        )
    }

    // MARK: - Up Next

    private func upNextSection(_ items: [VideoUpNext]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.text)
                .padding(.horizontal, C.pagePad)

            ForEach(items) { next in
                NavigationLink(value: AppRoute.video(next.id)) {
                    UpNextRow(video: next)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, C.pagePad)
    }

    // MARK: - Data loading

    private func load() async {
        isLoading = true
        loadError = nil
        savedProgress = 0
        showReplayPrompt = false
        do {
            let v = try await APIClient.shared.fetchVideo(id: videoId)
            video             = v
            userLike          = v.userLike
            likeCount         = v.likes.filter { $0.type == "like" }.count
            isSubscribed      = v.isSubscribed
            isFollowingShow   = v.isFollowingShow
            showFollowerCount = v.showFollowerCount
            localComments     = v.comments

            // Restore progress position
            if auth.isAuthenticated,
               let item = try? await APIClient.shared.fetchProgress(videoId: videoId) {
                savedProgress = item.progress
            }

            // Build AVPlayer
            if let url = C.mediaURL(v.videoUrl) {
                let asset = AVURLAsset(url: url)
                let item  = AVPlayerItem(asset: asset)
                let p     = AVPlayer(playerItem: item)

                // Seek to saved position
                if savedProgress > 0.05 && savedProgress < 0.95 {
                    if let dur = try? await asset.load(.duration), dur.isNumeric {
                        let seekTo = CMTime(seconds: dur.seconds * savedProgress,
                                           preferredTimescale: 600)
                        await p.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                // Periodic time observer — drives heatmap needle + moment button state
                if let existing = momentObserver { p.removeTimeObserver(existing) }
                let token = p.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                    queue: .main
                ) { time in
                    guard !time.seconds.isNaN else { return }
                    currentPlayerSec = Int(time.seconds)
                }
                momentObserver = token

                player = p
                p.play()
                startProgress(videoId: videoId, player: p)
            }

            // Fetch moment likes + timed player markers (fire-and-forget alongside load)
            if let data = try? await APIClient.shared.fetchMomentLikes(videoId: videoId) {
                heatmapBuckets = data.buckets
                likedSeconds   = data.userLikedSeconds
            }
            if let markers = try? await APIClient.shared.fetchPlayerMarkers(videoId: videoId) {
                playerMarkers = markers
                dismissedMarkerIds.removeAll()
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func startProgress(videoId: String, player: AVPlayer) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            guard let item = player.currentItem else { return }
            let cur = player.currentTime().seconds
            let tot = item.duration.seconds
            guard tot > 0, !tot.isNaN else { return }
            Task { try? await APIClient.shared.recordProgress(videoId: videoId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
        }
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        if let t = momentObserver { player?.removeTimeObserver(t); momentObserver = nil }
        cancelAutoplay()
        guard let p = player, let item = p.currentItem else { return }
        let cur = p.currentTime().seconds
        let tot = item.duration.seconds
        guard tot > 0 else { return }
        Task { try? await APIClient.shared.recordProgress(videoId: videoId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
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

        // Refresh heatmap buckets shortly after
        try? await Task.sleep(for: .milliseconds(400))
        if let data = try? await APIClient.shared.fetchMomentLikes(videoId: id) {
            heatmapBuckets = data.buckets
        }
    }

    // MARK: - Autoplay

    private func startAutoplay(next: VideoUpNext) {
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
                    autoplayDest = .video(nextId)
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
                        autoplayDest = .video(next.id)
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
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 26, weight: .bold))
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
            Task { try? await APIClient.shared.recordProgress(videoId: videoId, seconds: 0, percent: 0) }
        }
    }

    // MARK: - Player markers

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
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
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
        case .video(let id): VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id): EpisodeWatchView(episodeId: id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
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
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: C.mediaURL(video.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { C.surface }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                if let dur = video.duration {
                    Text(fmtDur(dur))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let ch = video.channel {
                    Text(ch.name)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textMuted)
                }
                if video.views > 0 {
                    Text(fmtViews(video.views) + " views")
                        .font(.system(size: 11))
                        .foregroundStyle(C.textMuted.opacity(0.6))
                }
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 6)
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
