import SwiftUI
import AVKit

// MARK: - Feed enum

private enum ShortsFeed: String, CaseIterable {
    case forYou    = "recommended"
    case following = "following"
    var label: String { self == .forYou ? "For You" : "Following" }
}

// MARK: - ShortsView (root)

struct ShortsView: View {

    let initialShortId: String?
    let contextShowId: String?
    let contextChannelId: String?

    @State private var shorts:       [Short]     = []
    @State private var currentID:    String?     = nil   // scrollPosition id
    @State private var isMuted:      Bool        = true
    @State private var nextCursor:   String?     = nil
    @State private var isLoading:    Bool        = false
    @State private var feed:         ShortsFeed  = .forYou
    @State private var emptyReason:  String?     = nil
    @State private var loadError:    String?     = nil
    @EnvironmentObject private var auth: AuthManager

    init(initialShortId: String? = nil, contextShowId: String? = nil, contextChannelId: String? = nil) {
        self.initialShortId = initialShortId
        self.contextShowId = contextShowId
        self.contextChannelId = contextChannelId
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

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
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(shorts) { short in
                                ShortCardView(
                                    short:   short,
                                    isActive: short.id == currentID,
                                    isMuted:  $isMuted
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(short.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $currentID)
                    .ignoresSafeArea(edges: .top)
                    .onAppear {
                        if currentID == nil {
                            currentID = shorts.first?.id
                        }
                    }
                    .onChange(of: shorts.count) { _, _ in
                        if currentID == nil {
                            currentID = shorts.first?.id
                        }
                    }
                    .onChange(of: currentID) { _, id in
                        guard let id else { return }
                        // Pagination: load more when near end
                        if let idx = shorts.firstIndex(where: { $0.id == id }),
                           idx >= shorts.count - 2 {
                            Task { await loadMore() }
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)
            }

            // Feed tabs pinned at top
            feedTabs
        }
        .statusBar(hidden: true)
        .navigationBarHidden(true)
        .task { await loadInitial() }
    }

    // MARK: - Feed tabs

    private var feedTabs: some View {
        HStack(spacing: 28) {
            ForEach(ShortsFeed.allCases, id: \.self) { f in
                Button {
                    Task { await switchFeed(f) }
                } label: {
                    Text(f.label)
                        .font(.system(size: 13, weight: feed == f ? .bold : .medium))
                        .foregroundStyle(.white.opacity(feed == f ? 1 : 0.55))
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        .background(
                            feed == f
                            ? .white.opacity(0.18)
                            : .clear
                        )
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(
                                feed == f ? .white.opacity(0.12) : .clear,
                                lineWidth: 1
                            )
                        }
                }
            }
        }
        .padding(.top, 52) // below status bar
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
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

    private func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            let resp = try await APIClient.shared.fetchShorts(
                feed: feed.rawValue,
                limit: 10,
                channelId: contextChannelId,
                showId: contextShowId
            )
            let uniqueShorts = uniqueByID(resp.shorts)
            shorts = uniqueShorts
            nextCursor = resp.nextCursor
            emptyReason = uniqueShorts.isEmpty ? (resp.reason ?? "empty") : nil
            currentID = initialShortId.flatMap { id in
                uniqueShorts.contains(where: { $0.id == id }) ? id : nil
            } ?? uniqueShorts.first?.id
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        isLoading = true
        do {
            let resp = try await APIClient.shared.fetchShorts(
                feed: feed.rawValue,
                cursor: cursor,
                limit: 10,
                channelId: contextChannelId,
                showId: contextShowId
            )
            shorts = uniqueByID(shorts + resp.shorts)
            nextCursor = resp.nextCursor
        } catch {}
        isLoading = false
    }

    private func switchFeed(_ newFeed: ShortsFeed) async {
        guard newFeed != feed else { return }
        feed = newFeed
        shorts = []
        nextCursor = nil
        emptyReason = nil
        isLoading = true
        do {
            let resp = try await APIClient.shared.fetchShorts(
                feed: newFeed.rawValue,
                limit: 10,
                channelId: contextChannelId,
                showId: contextShowId
            )
            let uniqueShorts = uniqueByID(resp.shorts)
            shorts = uniqueShorts
            nextCursor = resp.nextCursor
            currentID = uniqueShorts.first?.id
            emptyReason = uniqueShorts.isEmpty ? (resp.reason ?? "empty") : nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func uniqueByID<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - ShortCardView

private struct ShortCardView: View {

    let short:    Short
    let isActive: Bool
    @Binding var isMuted: Bool

    @State private var player:          AVPlayer?
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
    @State private var lastTap:         Date     = .distantPast
    @State private var endObserver:     NSObjectProtocol?
    @State private var progressTask:    Task<Void, Never>?

    @EnvironmentObject private var auth: AuthManager

    init(short: Short, isActive: Bool, isMuted: Binding<Bool>) {
        self.short    = short
        self.isActive = isActive
        self._isMuted = isMuted
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let url = C.mediaURL(short.thumbnailUrl) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.black }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 40)
                    .scaleEffect(1.15)
                    .opacity(0.22)
                    .clipped()
                }

                cardContent
                    .frame(width: pillarSize(in: geo.size).width, height: pillarSize(in: geo.size).height)
                    .clipped()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .task {
            await setupPlayer()
            await loadFollowStatus()
        }
        .onDisappear { teardownPlayer() }
        .onChange(of: isActive) { _, active in
            if active { resumePlay() } else { player?.pause() }
        }
        .onChange(of: isMuted) { _, muted in player?.isMuted = muted }
    }

    private var cardContent: some View {
        ZStack(alignment: .bottom) {
            Color.black

            // ── AVPlayer ───────────────────────────────────────────────────
            if let p = player {
                ShortPlayerView(player: p)
            } else if let url = C.mediaURL(short.thumbnailUrl) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.black }
            }

            // ── Bottom gradient scrim ──────────────────────────────────────
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.5), .clear],
                startPoint: .bottom, endPoint: .init(x: 0.5, y: 0.32)
            )

            // ── Top gradient scrim ─────────────────────────────────────────
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)
            )
            .frame(maxHeight: .infinity, alignment: .top)

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
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 28))
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
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .padding(.trailing, 12).padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            actionColumn
                .padding(.trailing, 10)
                .padding(.bottom, 88)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            bottomInfo
                .padding(.leading, 12)
                .padding(.bottom, 60)
                .padding(.trailing, 68)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)

            if short.channel != nil {
                Button {
                    Task { await toggleFollow() }
                } label: {
                    Text(isFollowing ? "✓ Following" : "Follow")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isFollowing ? .white : .black)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(isFollowing ? .white.opacity(0.15) : .white)
                        .clipShape(Capsule())
                        .overlay {
                            if isFollowing { Capsule().stroke(.white.opacity(0.35), lineWidth: 1.5) }
                        }
                }
                .padding(.leading, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.18)
                    C.watch.frame(width: geo.size.width * CGFloat(progress.clampedProgress))
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            if showComments {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001)
                            .onTapGesture { showComments = false }
                        CommentsDrawer(videoId: short.id) {
                            showComments = false
                        }
                        .frame(height: geo.size.height * 0.76)
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(30)
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

    // MARK: - Action column

    private var actionColumn: some View {
        let likeRed = Color(red: 1, green: 0.28, blue: 0.34)
        return VStack(alignment: .center, spacing: 18) {
            // Like
            actionBtn(
                icon:       isLiked ? "heart.fill" : "heart",
                color:      isLiked ? likeRed : .white,
                bgColor:    isLiked ? likeRed.opacity(0.35) : .black.opacity(0.35),
                label:      likeCount > 0 ? fmtCount(likeCount) : nil,
                labelColor: isLiked ? likeRed : .white.opacity(0.85)
            ) { Task { await handleLike() } }

            // Dislike — matches web IcThumbDown
            actionBtn(
                icon:    isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                color:   isDisliked ? Color(white: 0.67) : .white,
                bgColor: .black.opacity(0.35),
                label:   nil
            ) { Task { await handleDislike() } }

            // Comment
            actionBtn(icon: "bubble.left.fill", color: .white, bgColor: .black.opacity(0.35), label: nil) {
                withAnimation(.spring(duration: 0.34)) { showComments = true }
            }

            // Share
            actionBtn(icon: "paperplane.fill", color: .white, bgColor: .black.opacity(0.35), label: "Share") {
                shareShort()
            }

            // Bookmark / Save — matches web IcBookmark
            actionBtn(
                icon:    isBookmarked ? "bookmark.fill" : "bookmark",
                color:   isBookmarked ? C.watch : .white,
                bgColor: isBookmarked ? C.watch.opacity(0.30) : .black.opacity(0.35),
                label:   "Save",
                labelColor: isBookmarked ? C.watch : .white.opacity(0.85)
            ) { isBookmarked.toggle() }
        }
    }

    private func actionBtn(icon: String, color: Color, bgColor: Color, label: String?, labelColor: Color = .white.opacity(0.85), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
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

    // MARK: - Bottom info

    private var bottomInfo: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Channel row
            HStack(spacing: 8) {
                Group {
                    if let nav = channelNav {
                        NavigationLink(value: nav) { avatarView }
                    } else {
                        avatarView
                    }
                }
                Text("@\(ownerHandle)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2)
            }

            // Title
            Text(short.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .shadow(color: .black.opacity(0.9), radius: 3)

            // Description
            if let desc = short.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
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

            // Linked clip banner
            if let clip = short.linkedClip {
                linkedBanner(
                    label: "Watch full clip",
                    title: clip.title,
                    thumbnail: clip.thumbnailUrl,
                    destination: clip.id,
                    isEpisode: false
                )
            }

            // Linked episode banner
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

            // Spinning music disc
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        RadialGradient(colors: [Color(white: 0.33), Color(white: 0.07)],
                                       center: .center, startRadius: 0, endRadius: 14)
                    )
                    .frame(width: 28, height: 28)
                    .overlay { Circle().stroke(.white.opacity(0.22), lineWidth: 3) }
                    .overlay { Text("♪").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)) }

                Text("Original sound · \(ownerName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    private var avatarView: some View {
        Group {
            if let url = C.mediaURL(ownerAvatar) {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.12) }
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
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
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
    private func setupPlayer() async {
        guard player == nil, let url = C.mediaURL(short.videoUrl) else { return }
        let item   = AVPlayerItem(url: url)
        let p      = AVPlayer(playerItem: item)
        p.isMuted  = isMuted
        p.actionAtItemEnd = .none
        player = p

        // Loop on end
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak p] _ in
            guard let p else { return }
            p.seek(to: .zero)
            if isActive { p.play() }
        }

        if isActive { resumePlay() }
    }

    @MainActor
    private func teardownPlayer() {
        progressTask?.cancel()
        progressTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        progress = 0
    }

    @MainActor
    private func resumePlay() {
        guard let p = player else { return }
        p.seek(to: .zero)
        p.play()
        isPaused = false

        // Start progress tracking
        progressTask?.cancel()
        progressTask = Task {
            while let p = player, isActive {
                if let item = p.currentItem {
                    let cur = p.currentTime().seconds
                    let tot = item.duration.seconds
                    if cur.isFinite, tot.isFinite, tot > 0 {
                        await MainActor.run { progress = (cur / tot).clampedProgress }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
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
        likeCount += nextLiked ? 1 : -1
        let type = nextLiked ? "like" : "remove"
        do {
            let result = try await APIClient.shared.likeVideo(videoId: short.id, type: type)
            likeCount = result.likes
            isLiked   = result.userLike == "like"
        } catch {
            // Revert
            isLiked    = wasLiked
            isDisliked = wasDisliked
            likeCount -= nextLiked ? 1 : -1
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
        } catch {
            isFollowing = wasFollowing
        }
    }

    private func shareShort() {
        guard let url = URL(string: "\(C.baseURL)/watch/\(short.id)") else { return }
        let av  = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.firstKeyWindow?.rootViewController?.present(av, animated: true)
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private extension Double {
    var clampedProgress: Double {
        guard isFinite else { return 0 }
        return min(max(self, 0), 1)
    }
}

// MARK: - HeartBurst animation

private struct HeartBurstView: View {
    @State private var scale:   CGFloat = 0
    @State private var opacity: Double  = 1
    @State private var offsetY: CGFloat = 0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 88))
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

// MARK: - Comments drawer

private struct CommentsDrawer: View {
    let videoId: String
    let onClose: () -> Void

    @State private var comments:         [Comment] = []
    @State private var commentText:      String    = ""
    @State private var isLoading:        Bool      = false
    @State private var isPostingComment: Bool      = false
    @State private var dragOffset:       CGFloat   = 0

    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
                .gesture(dragToCloseGesture)

            // Header
            HStack {
                Text("Comments")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .gesture(dragToCloseGesture)
            Divider().background(.white.opacity(0.07))

            CommentThreadView(
                target: .video(videoId),
                inputPosition: .bottom,
                showsHeader: false
            )
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.055).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .offset(y: max(0, dragOffset))
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88), value: dragOffset)
    }

    private var dragToCloseGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                if value.translation.height > 90 || projected > 160 {
                    onClose()
                } else {
                    dragOffset = 0
                }
            }
    }
}
