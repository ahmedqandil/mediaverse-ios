import SwiftUI
import AVKit

struct EpisodeWatchView: View {

    let episodeId: String

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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(C.watch)
            } else if let ep = episode {
                mainContent(ep)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
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
        .task { await load() }
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
                            NavigationLink(value: AppRoute.episode(prev.id)) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                                    Text("E\(prev.episodeNumber)").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(C.textMuted)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(C.surface)
                                .clipShape(Capsule())
                                .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                            }
                        }
                        Spacer()
                        if let next = ep.nextEp {
                            NavigationLink(value: AppRoute.episode(next.id)) {
                                HStack(spacing: 4) {
                                    Text("E\(next.episodeNumber)").font(.system(size: 13, weight: .semibold))
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(C.watch)
                                .clipShape(Capsule())
                            }
                        }
                        // Share
                        Button {
                            shareEpisode(ep)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13))
                                .foregroundStyle(C.textMuted)
                                .frame(width: 36, height: 36)
                                .background(C.surface)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(C.border, lineWidth: 1) }
                        }
                    }

                    // ── Clip reactions (PostSection) ──────────────────────────
                    PostSectionView(
                        target: .episode(ep.id),
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

                    // Comments
                    Divider().background(C.border)
                    episodeCommentsSection(episodeId: ep.id)
                        }
                        .padding(C.pagePad)
                    }
                }
            }
            .background(C.bg)
        }
    }

    private func episodePinnedPlayer(_ ep: EpisodeDetail, geometry geo: GeometryProxy, progress: CGFloat) -> some View {
        ZStack {
            if entitlement?.hasAccess == true, let p = player {
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
                    onBack: { dismiss() },
                    onFullscreen: { openFullscreenPlayer(p) }
                ) {
                    playerMarkerOverlay
                }
                .frame(maxWidth: .infinity)
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

    private var episodePlayerBackButton: some View {
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
                if shouldMinimize, let player, let episode {
                    miniPlayer.present(player: player, title: episode.title, route: .episode(episode.id))
                    dismiss()
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
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
        isLoading = true
        loadError = nil
        savedProgress = 0
        showReplayPrompt = false
        let ep: EpisodeDetail?
        do {
            ep = try await APIClient.shared.fetchEpisode(id: episodeId)
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        guard let ep else { isLoading = false; return }
        episode       = ep
        isFollowing   = ep.isFollowing
        followerCount = ep.followerCount
        localComments = ep.comments
        likeCount     = ep.likes.filter { $0.type == "like" }.count
        userLike      = ep.likes.first(where: { $0.userId == auth.currentUser?.id })?.type

        // The episode detail endpoint already mirrors the web SSR entitlement gate:
        // locked content returns paywallInfo and no videoUrl. The separate entitlement
        // check requires auth, so unauthenticated AVOD must not get stuck on a spinner.
        let ent = auth.isAuthenticated ? try? await APIClient.shared.checkEntitlement(episodeId: episodeId) : nil
        let canPlay = ep.paywallInfo == nil && ep.videoUrl != nil && (ent?.hasAccess ?? true)
        entitlement = ent ?? EntitlementCheckResponse(
            hasAccess: canPlay,
            code: ep.videoUrl == nil ? "NO_MEDIA" : nil,
            entitlementType: ep.paywallInfo?.entitlementType ?? "AVOD",
            productId: ep.paywallInfo?.productId
        )

        if canPlay, let url = C.mediaURL(ep.videoUrl) {
            // Restore saved position
            if auth.isAuthenticated,
               let item = try? await APIClient.shared.fetchProgress(episodeId: episodeId) {
                savedProgress = item.progress
            }

            let asset = AVURLAsset(url: url)
            let item  = AVPlayerItem(asset: asset)
            let p     = AVPlayer(playerItem: item)

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
            startProgress(episodeId: episodeId, player: p)
        }

        // Fetch moment likes + timed player markers
        if let data = try? await APIClient.shared.fetchMomentLikes(episodeId: episodeId) {
            heatmapBuckets = data.buckets
            likedSeconds   = data.userLikedSeconds
        }
        if let markers = try? await APIClient.shared.fetchPlayerMarkers(episodeId: episodeId) {
            playerMarkers = markers
            dismissedMarkerIds.removeAll()
        }

        isLoading = false
    }

    private func startProgress(episodeId: String, player: AVPlayer) {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            guard let item = player.currentItem else { return }
            let cur = player.currentTime().seconds
            let tot = item.duration.seconds
            guard tot > 0, !tot.isNaN else { return }
            Task { try? await APIClient.shared.recordProgress(episodeId: episodeId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
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
            Task { try? await APIClient.shared.recordProgress(episodeId: episodeId, seconds: Int(cur), percent: min(1.0, cur / tot)) }
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
            onShowMore: { _ in underPlayerPanel = .comments }
        )
    }

    // MARK: - Autoplay

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
                    autoplayDest = .episode(nextId)
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
                        autoplayDest = .episode(next.id)
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
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 26, weight: .bold))
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
            Task { try? await APIClient.shared.recordProgress(episodeId: episodeId, seconds: 0, percent: 0) }
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
