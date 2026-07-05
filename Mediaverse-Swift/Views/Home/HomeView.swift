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
        uiView.playerLayer?.player = player
    }
}

// MARK: - Render item (video or interleaved carousel)

private enum HomeItem: Identifiable {
    case video(FeedVideo)
    case carousel(HomeFeedConfig.CarouselSlotDef)   // data-driven from /api/feed-config

    var id: String {
        switch self {
        case .video(let v):    return "v-\(v.id)"
        case .carousel(let s): return "c-\(s.id)"
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

/// Mirrors the web homepage: hero → continue watching → "For You" feed with
/// interleaved carousels (Shows every 3 videos, then Shorts, then Microdramas).
struct HomeView: View {

    // MARK: State

    @State private var feed:               [FeedVideo]          = []
    @State private var continueItems:      [ProgressItem]       = []
    @State private var cursor:             String?              = nil
    @State private var isLoading                                = true
    @State private var isLoadingMore                            = false
    @State private var searchPresented                          = false
    @State private var didStartInitialLoad                      = false

    // Feed config — drives carousel ordering, interleave interval, and slot count.
    // Loaded from /api/feed-config on every refresh; falls back to .default offline.
    @State private var feedConfig: HomeFeedConfig = .default

    // Carousel data — fetched in parallel with the main feed.
    // "channels" and "videos" are derived from the feed response (zero extra API calls).
    @State private var featuredShows:      [ShowBrowseCard]     = []
    @State private var carouselShorts:     [Short]              = []
    @State private var carouselMicrodramas:[MicrodramaListShow] = []
    @State private var carouselChannels:   [ChannelStub]        = []   // derived from feed
    @State private var carouselVideos:     [FeedVideo]          = []   // derived from feed

    // Hero trailer player (muted loop — mirrors web opacity-60 video autoplay)
    @State private var heroPlayer: AVQueuePlayer? = nil
    @State private var heroLooper: AVPlayerLooper? = nil

    @EnvironmentObject private var auth: AuthManager

    // MARK: - Computed: interleaved render list

    /// Builds the feed list with carousels interleaved every mobileCarouselEvery
    /// videos, capped at mobileCarouselCount strips — all values come from
    /// /api/feed-config so the layout exactly matches the web HomeFeedClient.
    private var renderItems: [HomeItem] {
        var result  = [HomeItem]()
        var slotIdx = 0
        let everyN  = max(1, feedConfig.mobileCarouselEvery)
        let slotCap = max(0, feedConfig.mobileCarouselCount)
        let slots   = Array(feedConfig.carouselSlots.prefix(slotCap))

        for (i, video) in uniqueByID(feed).enumerated() {
            result.append(.video(video))
            if (i + 1) % everyN == 0, slotIdx < slots.count {
                let slot = slots[slotIdx]
                if hasCarouselData(for: slot.type) {
                    result.append(.carousel(slot))
                }
                slotIdx += 1
            }
        }

        if cursor == nil, slotIdx < slots.count {
            for slot in slots.dropFirst(slotIdx) where hasCarouselData(for: slot.type) {
                result.append(.carousel(slot))
            }
        }

        return result
    }

    /// True when we have at least one item to show for the given slot type.
    private func hasCarouselData(for type: String) -> Bool {
        switch type {
        case "shows":       return !featuredShows.isEmpty
        case "channels":    return !carouselChannels.isEmpty
        case "shorts":      return !carouselShorts.isEmpty
        case "videos":      return !carouselVideos.isEmpty
        case "microdramas": return !carouselMicrodramas.isEmpty
        default:            return false
        }
    }

    private func uniqueByID<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(C.watch)
                    .id("home-loading")
            } else {
                feedContent
                    .id("home-feed")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Mediaverse")
                    .font(.system(size: 17, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.watch)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { searchPresented = true } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(C.text)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .sheet(isPresented: $searchPresented) { SearchView() }
        .task { await loadInitialFeedIfNeeded() }
    }

    // MARK: - Main feed

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 48))
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
        let items = renderItems

        return ScrollView {
            VStack(spacing: 0) {
                feedBodyContent(items)
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func feedBodyContent(_ items: [HomeItem]) -> some View {
        if feed.isEmpty && featuredShows.isEmpty && continueItems.isEmpty {
            emptyState
        } else {
            heroSection

            if !continueItems.isEmpty {
                continueWatchingSection
            }

            if !feed.isEmpty {
                feedHeader
            }

            feedList(items)

            if cursor != nil {
                paginationSentinel
            }

            if cursor == nil && !feed.isEmpty {
                endOfFeedText
            }
        }
    }

    private var feedHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("For You")
                .font(.system(size: 20, weight: .bold))
                .fontDesign(.rounded)
                .foregroundStyle(C.text)
            Text("Recommended")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, C.pagePad)
        .padding(.top, 24)
        .padding(.bottom, 16)
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

    private func feedList(_ items: [HomeItem]) -> some View {
        ForEach(items, id: \.id) { item in
            feedItemView(item)
        }
    }

    @ViewBuilder
    private func feedItemView(_ item: HomeItem) -> some View {
        switch item {
        case .video(let v):
            NavigationLink(value: AppRoute.media(id: v.id, type: v.type, showId: v.show?.id, channelId: v.channel?.id)) {
                HomeVideoCard(video: v)
                    .padding(.horizontal, C.pagePad)
            }
            .buttonStyle(CardPressStyle())
            .padding(.bottom, 24)

        case .carousel(let slot):
            carouselRow(for: slot)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        if let show = featuredShows.first {
            // Show hero: cover/trailer + gradient + title + genre + buttons
            // Matches web page.tsx HeroCarousel exactly (opacity-60 video, gradient overlay)
            //
            // SIZING: aspectRatio(.fit) must be on the ZStack (outer), NOT on AsyncImage.
            // AsyncImage with contentMode: .fill inside a ScrollView receives an unbounded
            // proposed height and expands to fill it (effectively infinite). Putting the
            // aspectRatio on the outer ZStack with .fit gives a deterministic 16:9 height
            // (screenWidth × 9/16), and AsyncImage fills the ZStack with maxHeight: .infinity.
            NavigationLink(value: AppRoute.show(show.id)) {
                ZStack(alignment: .bottomLeading) {
                    // ── Background: static cover (always visible as base/fallback) ──
                    AsyncImage(url: C.mediaURL(show.coverUrl)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            C.bg
                        default:
                            LinearGradient(
                                colors: [C.watch.opacity(0.25), C.bg],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)  // fill the sized ZStack
                    .clipped()
                    // Dim the static image when no trailer (web uses opacity-50 on coverUrl)
                    .overlay {
                        if heroPlayer == nil { Color.black.opacity(0.5) }
                    }

                    // ── Trailer video overlay (opacity-60 matching web) ────────────
                    if let player = heroPlayer {
                        LoopingVideoLayer(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(0.6)   // web: className="… opacity-60"
                    }

                    // ── Gradient for text readability (web: from-black/90 via-black/30) ──
                    LinearGradient(
                        colors: [.black.opacity(0.92), .black.opacity(0.3), .clear],
                        startPoint: .bottom, endPoint: .top
                    )

                    // ── Text + buttons ─────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FEATURED SERIES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.watch)
                            .tracking(4)

                        Text(show.title)
                            .font(.system(size: 24, weight: .bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if let genre = show.genre {
                            Text(genre)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.white.opacity(0.65))
                        }

                        HStack(spacing: 12) {
                            // "Watch Trailer" when trailer exists, "Watch Now" otherwise — matches web
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.system(size: 11))
                                Text(show.trailerUrl != nil ? "Watch Trailer" : "Watch Now")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(C.watch)
                            .clipShape(Capsule())

                            // More Info
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
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Sizing: ZStack gets explicit 16:9 frame — children fill it.
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .background(C.bg)
            }
            .buttonStyle(.plain)

        } else if let v = feed.first {
            // Fallback: first feed video as hero
            NavigationLink(value: AppRoute.media(id: v.id, type: v.type, showId: v.show?.id, channelId: v.channel?.id)) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: C.mediaURL(v.thumbnailUrl ?? v.show?.coverUrl)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            LinearGradient(
                                colors: [C.watch.opacity(0.18), C.bg],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay { Color.black.opacity(0.35) }

                    LinearGradient(
                        colors: [.black.opacity(0.88), .clear],
                        startPoint: .bottom, endPoint: .center
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("FEATURED")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.watch)
                            .tracking(4)
                        Text(v.title)
                            .font(.system(size: 22, weight: .bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            Text("Watch Now").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(C.watch)
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .background(C.bg)
            }
            .buttonStyle(.plain)
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
                HStack(spacing: 12) {
                    ForEach(uniqueByID(continueItems)) { item in
                        if let vid = item.video {
                            NavigationLink(value: AppRoute.media(id: vid.id, type: vid.type, channelId: vid.channel?.id)) {
                                ContinueCard(
                                    title: vid.title,
                                    thumbnailUrl: vid.thumbnailUrl,
                                    progress: item.progress
                                )
                            }
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
    }

    // MARK: - Carousel rows

    /// Renders the correct carousel strip for each slot type from /api/feed-config.
    /// slot.label comes directly from the backend config (admin-controlled).
    /// slot.type drives which data source and card layout to use.
    @ViewBuilder
    private func carouselRow(for slot: HomeFeedConfig.CarouselSlotDef) -> some View {
        // microdramas uses the "listen" accent; everything else uses "watch"
        let accent: Color = slot.type == "microdramas" ? C.listen : C.watch

        switch slot.type {

        case "shows":
            CarouselWrapper(title: slot.label, accentColor: accent) {
                ForEach(uniqueByID(featuredShows).prefix(12)) { show in
                    NavigationLink(value: AppRoute.show(show.id)) {
                        ShowCarouselCard(show: show)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }

        case "channels":
            // Channel data is derived from feed video channel stubs — zero extra API call.
            CarouselWrapper(title: slot.label, accentColor: accent) {
                ForEach(uniqueByID(carouselChannels).prefix(12)) { ch in
                    NavigationLink(value: AppRoute.channel(ch.handle ?? ch.id)) {
                        ChannelCarouselCard(channel: ch)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }

        case "shorts":
            CarouselWrapper(title: slot.label, accentColor: accent) {
                ForEach(uniqueByID(carouselShorts).prefix(10)) { short in
                    NavigationLink(value: AppRoute.short(short.id, showId: short.showId, channelId: short.channelId ?? short.channel?.id)) {
                        ShortCarouselCard(short: short)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }

        case "videos":
            // Videos carousel shows a landscape strip of regular feed videos.
            CarouselWrapper(title: slot.label, accentColor: accent) {
                ForEach(uniqueByID(carouselVideos).prefix(8)) { video in
                    NavigationLink(value: AppRoute.media(id: video.id, type: video.type, showId: video.show?.id, channelId: video.channel?.id)) {
                        VideoCarouselCard(video: video)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }

        case "microdramas":
            CarouselWrapper(title: slot.label, accentColor: accent) {
                ForEach(uniqueByID(carouselMicrodramas).prefix(10)) { show in
                    NavigationLink(value: AppRoute.microdramaShow(show.id)) {
                        MicrodramaCarouselCard(show: show)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Data loading

    @MainActor
    private func loadInitialFeedIfNeeded() async {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true
        await load()
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        heroLooper = nil
        heroPlayer?.pause()
        heroPlayer = nil

        do {
            let response = try await APIClient.shared.fetchFeed()
            let videos = uniqueByID(response.videos)
            feed = videos
            cursor = response.nextCursor
            rebuildDerivedFeedCarousels(from: videos)
        } catch {
            print("Home feed failed:", error)
            feed = []
            cursor = nil
        }
    }

    @MainActor
    private func rebuildDerivedFeedCarousels(from videos: [FeedVideo]) {
        let neededTypes = Set(
            feedConfig.carouselSlots
                .prefix(feedConfig.mobileCarouselCount)
                .map(\.type)
        )

        if neededTypes.contains("channels") {
            var seen = Set<String>()
            carouselChannels = videos
                .compactMap(\.channel)
                .filter { seen.insert($0.id).inserted }
        }

        if neededTypes.contains("videos") {
            carouselVideos = Array(videos.prefix(8))
        }
    }

    @MainActor
    private func startHeroTrailerIfAvailable() {
        guard let url = C.mediaURL(featuredShows.first?.trailerUrl) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        heroLooper = AVPlayerLooper(player: player, templateItem: item)
        heroPlayer = player
        player.play()
    }

    @MainActor
    private func loadMore() async {
        guard let cur = cursor, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        if let r = try? await APIClient.shared.fetchFeed(cursor: cur) {
            feed = uniqueByID(feed + r.videos)
            cursor = r.nextCursor
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
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: initialsCircle
                        }
                    }
                } else {
                    initialsCircle
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1) }

            // ── Name + handle ─────────────────────────────────────────────────
            VStack(spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let handle = channel.handle {
                    Text("@\(handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 80)
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
                AsyncImage(url: C.mediaURL(video.thumbnailUrl ?? video.show?.coverUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.white.opacity(0.07)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

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
            .frame(width: 180, height: 101)   // 16:9 at 180pt wide
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()

            // ── Text ──────────────────────────────────────────────────────────
            Text(video.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let ch = video.channel {
                Text(ch.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(width: 180)
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 3) {
                    Text("See all")
                        .font(.system(size: 13))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(accentColor)
            }
            .padding(.horizontal, C.pagePad)
            .padding(.bottom, 14)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
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
// Static thumbnail card. Feed preview autoplay is disabled while launch freezes are isolated.

private struct HomeVideoCard: View {
    let video: FeedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Thumbnail / preview area ──────────────────────────────────────
            // SIZING: aspectRatio(.fit) on ZStack container; children fill ZStack with
            // maxHeight: .infinity. Using .fill on AsyncImage inside vertical ScrollView
            // proposes unbounded height, causing Liquid Glass compositor crash on iOS 26.
            ZStack(alignment: .bottomTrailing) {
                // Static thumbnail (fades out when video plays)
                AsyncImage(url: C.mediaURL(video.thumbnailUrl ?? video.show?.coverUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.white.opacity(0.07)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

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
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .clipped()
            // ── Avatar + text row ─────────────────────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                avatarView
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let ch = video.channel {
                        Text(ch.name)
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                    } else if let show = video.show {
                        Text(show.title)
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                    }

                    Text("\(fmtViews(video.views)) views")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Sub-views

    // Computed outside @ViewBuilder to avoid iOS 26 instability with `let` bindings
    // inside ViewBuilder closures (local `let` inside @ViewBuilder can confuse the
    // compiler's result-builder rewrite in Swift 6 / Xcode 26).
    private var avatarInitial: String {
        (video.channel?.name.first ?? video.show?.title.first).map(String.init) ?? "?"
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = C.mediaURL(video.channel?.avatarUrl ?? video.show?.coverUrl) {
            AsyncImage(url: url) { img in
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
}

// MARK: - Continue watching card

private struct ContinueCard: View {
    let title: String
    let thumbnailUrl: String?
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: C.mediaURL(thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                // Progress bar
                GeometryReader { geo in
                    Rectangle()
                        .fill(C.watch)
                        .frame(width: geo.size.width * min(progress, 1.0), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 160, alignment: .leading)
        }
        .frame(width: 160)
    }
}

// MARK: - Show carousel card (portrait 2:3)

private struct ShowCarouselCard: View {
    let show: ShowBrowseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.07)
            }
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            }

            Text(show.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 100, alignment: .leading)

            if let year = show.productionYear {
                Text(year)
                    .font(.system(size: 10))
                    .foregroundStyle(C.textMuted)
            } else if show.seasonCount > 0 {
                Text("\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 100)
    }
}

// MARK: - Short carousel card (portrait 9:16)

private struct ShortCarouselCard: View {
    let short: Short

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: C.mediaURL(short.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .aspectRatio(9 / 16, contentMode: .fill)
                .frame(width: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                // "Short" badge
                Text("Short")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(6)

                // Duration badge (bottom right)
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
            .frame(width: 100)

            Text(short.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 100, alignment: .leading)

            if let ch = short.channel {
                Text(ch.name)
                    .font(.system(size: 10))
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 100)
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
            AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [C.listen.opacity(0.25), C.bg],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .aspectRatio(9 / 16, contentMode: .fill)
            .frame(width: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()

            // Bottom gradient
            LinearGradient(
                colors: [.black.opacity(0.85), .clear],
                startPoint: .bottom, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
