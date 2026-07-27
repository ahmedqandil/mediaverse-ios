import SwiftUI
import AVKit
import UIKit

struct AtmosphereView: View {
    @AppStorage("playerMuted") private var playerMuted = false
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = AtmosphereViewModel()
    @StateObject private var previewManager = FeedPreviewPlayerManager()
    @State private var activePreviewVideoId: String?
    @State private var previewFrames: [String: CGRect] = [:]
    @State private var previewIdleTask: Task<Void, Never>?
    @State private var suppressedPreviewVideoId: String?
    @State private var isPreservingPreviewHandoff = false
    @State private var showsCreateVibe = false
    @State private var searchPresented = false
    @State private var notificationsPresented = false
    @State private var unreadNotificationCount = 0
    @State private var isHorizontalCarouselInteracting = false
    private let socialFeatures = SocialFeatureConfiguration.runtime()

    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    private var feedCardInset: CGFloat { isCompactWidth ? 0 : C.pagePad }

    var body: some View {
        VStack(spacing: 0) {
            header
            MediaverseUnderlineTabStrip(
                items: AtmosphereViewModel.Tab.allCases.map {
                    MediaverseTabItem(id: $0.id, label: $0.title)
                },
                selectedID: model.selectedTab.id,
                fillsWidth: true,
                horizontalPadding: 0
            ) { id in
                guard let tab = AtmosphereViewModel.Tab(rawValue: id) else { return }
                model.select(tab)
            }
            content
        }
        .simultaneousGesture(tabSwipeGesture)
        .background(C.bg.ignoresSafeArea())
        .task { await model.loadIfNeeded() }
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .myVibes {
                previewIdleTask?.cancel()
                activePreviewVideoId = nil
                previewManager.pause()
            }
        }
        .onDisappear {
            previewIdleTask?.cancel()
            activePreviewVideoId = nil
            previewManager.pause()
        }
        .sheet(isPresented: $showsCreateVibe) {
            CreateVibeView { _ in
                Task { await model.reload(.myVibes) }
            }
        }
        .sheet(isPresented: $searchPresented) { SearchView() }
        .sheet(isPresented: $notificationsPresented) {
            NotificationsView { unreadCount in
                unreadNotificationCount = unreadCount
            }
        }
        .onAppear {
            Task { await loadNotificationCount() }
        }
        .onChange(of: notificationsPresented) { _, isPresented in
            if !isPresented {
                Task { await loadNotificationCount() }
            }
        }
        .onChange(of: auth.isAuthenticated) { _, _ in
            Task { await loadNotificationCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rippleCreated)) { notification in
            guard let ripple = notification.object as? Ripple else { return }
            model.prepend(ripple)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notificationCountsDidChange)) { notification in
            if let count = notification.object as? Int {
                unreadNotificationCount = count
            } else {
                Task { await loadNotificationCount() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await loadNotificationCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .horizontalCarouselInteractionChanged)) { notification in
            isHorizontalCarouselInteracting = (notification.object as? Bool) == true
        }
    }

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                guard !isHorizontalCarouselInteracting else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let predictedHorizontal = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(vertical) * 1.15,
                      abs(horizontal) > 48 || abs(predictedHorizontal) > 80 else { return }
                let tabs = AtmosphereViewModel.Tab.allCases
                guard let index = tabs.firstIndex(of: model.selectedTab) else { return }
                let direction = abs(predictedHorizontal) > abs(horizontal) ? predictedHorizontal : horizontal
                if direction > 0, model.selectedTab == .atmosphere {
                    guard auth.isAuthenticated else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    NotificationCenter.default.post(name: .uploadRequested, object: nil)
                    return
                }

                let nextIndex = direction < 0 ? index + 1 : index - 1
                guard tabs.indices.contains(nextIndex) else { return }
                C.lightHaptic()
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.select(tabs[nextIndex])
                }
            }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 12) {
                uploadButton
                Spacer()
                headerActions
            }

            brandTitle
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
        )
    }

    private var brandTitle: some View {
        HStack(spacing: 7) {
            HStack(spacing: 0) {
                Text("We").foregroundStyle(C.text)
                Text("Streem").foregroundStyle(C.watch)
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
    private var uploadButton: some View {
        if auth.isAuthenticated {
            Button {
                NotificationCenter.default.post(name: .uploadRequested, object: nil)
            } label: {
                headerIcon("upload", fallback: "plus.circle")
            }
            .accessibilityLabel("Upload")
        }
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            Button { notificationsPresented = true } label: {
                notificationBell
            }
            .disabled(!auth.isAuthenticated)
            .opacity(auth.isAuthenticated ? 1 : 0.45)
            .accessibilityLabel("Notifications")

            Button { searchPresented = true } label: {
                headerIcon("search", fallback: "magnifyingglass")
            }
            .accessibilityLabel("Search")
        }
    }

    private func headerIcon(_ iconName: String, fallback: String) -> some View {
        MediaverseIcon(name: iconName, fallbackSystemName: fallback)
            .frame(width: 20, height: 20)
            .foregroundStyle(C.text)
            .frame(width: 34, height: 34)
    }

    private var notificationBell: some View {
        headerIcon("notification", fallback: "bell")
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

    @ViewBuilder
    private var content: some View {
        switch model.stateByTab[model.selectedTab] ?? .idle {
        case .idle, .loading:
            loading
        case .failed(let message):
            unavailable(message)
        case .loaded:
            loadedTab
        }
    }

    private var loading: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: C.cardRadius)
                        .fill(C.surface)
                        .frame(height: 180)
                }
            }
            .padding(C.pagePad)
        }
        .accessibilityLabel("Loading \(model.selectedTab.title)")
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load \(model.selectedTab.title)", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await model.reload() }
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
        }
        .foregroundStyle(C.text)
    }

    @ViewBuilder
    private var loadedTab: some View {
        switch model.selectedTab {
        case .atmosphere:
            simpleFeed(model.atmosphereItems)
        case .discover:
            simpleRipples(model.discoveredRipples)
        case .myVibes:
            simpleVibes(model.myVibes)
        }
    }

    private func simpleFeed(_ items: [AtmosphereFeedItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 0).id("atmosphere-feed-top")
                    atmosphereBoundaryListings(model.beforeFeedListings)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        switch item {
                        case .ripple(let ripple):
                            RippleCard(
                                ripple: ripple,
                                allowsEngagement: socialFeatures.rippleEngagementEnabled,
                                activePreviewVideoId: $activePreviewVideoId,
                                previewManager: previewManager,
                                isAutoplayBlocked: isAutoplayBlocked,
                                isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                                onPreviewPaused: { videoID in
                                    suppressedPreviewVideoId = videoID
                                    updatePreview(videos: feedVideos(from: model.atmosphereItems))
                                },
                                onVideoHandoff: { video, frame in
                                    handoffToWatch(video, sourceFrame: frame)
                                }
                            )
                            .padding(.horizontal, feedCardInset)
                        case .video(let video):
                            atmosphereVideoCard(video)
                        case .excludedEpisode, .excludedShort, .unsupported:
                            EmptyView()
                        }
                        if let listing = inlineListing(after: index) {
                            NativeCurationListingView(listing: listing)
                                .padding(.vertical, 6)
                        }
                    }
                    atmosphereBoundaryListings(model.afterFeedListings)
                }
                .padding(.vertical, C.pagePad)
                .padding(.bottom, C.bottomMenuClearance)
            }
            .coordinateSpace(name: "homeFeedScroll")
            .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
                schedulePreviewUpdate(
                    frames: frames,
                    videos: feedVideos(from: items),
                    expectedTab: .atmosphere
                )
            }
            .refreshable { await model.reload(.atmosphere) }
            .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
                guard notification.object as? String == "home" else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo("atmosphere-feed-top", anchor: .top)
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "Your Atmosphere is quiet",
                        systemImage: "wind",
                        description: Text("Follow people and Vibes to see their Ripples here.")
                    )
                }
            }
        }
    }

    private func atmosphereVideoCard(_ video: AtmosphereVideo) -> some View {
        let feedVideo = video.feedVideo
        let mediaRoute = AppRoute.video(video.id)
        let sourceRoute: AppRoute? = video.channel.map { .channel($0.handle) }
            ?? video.show.map { .show($0.id) }
        return AtmospherePublishedVideoCard(video: video, sourceRoute: sourceRoute) {
            HomeVideoCard(
                video: feedVideo,
                mediaRoute: mediaRoute,
                sourceRoute: sourceRoute,
                activePreviewVideoId: $activePreviewVideoId,
                previewManager: previewManager,
                isAutoplayBlocked: isAutoplayBlocked,
                isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                onPreviewPaused: {
                    suppressedPreviewVideoId = video.id
                    updatePreview(videos: feedVideos(from: model.atmosphereItems))
                },
                openMediaAction: {
                    NotificationCenter.default.post(
                        name: .mentionNavigationRequested,
                        object: mediaRoute
                    )
                },
                replaceMediaAction: canHandoff(feedVideo) ? { sourceFrame in
                    handoffToWatch(feedVideo, sourceFrame: sourceFrame)
                } : nil,
                horizontalContentInset: 0
            )
        }
    }

    private var isAutoplayBlocked: Bool {
        miniPlayer.item != nil || miniPlayer.isExpansionHandoffActive
    }

    private func canHandoff(_ video: FeedVideo) -> Bool {
        C.mediaURL(video.videoUrl) != nil
    }

    private func handoffToWatch(_ video: FeedVideo, sourceFrame: CGRect?) {
        let route = AppRoute.media(id: video.id, type: video.type)
        if case .short = route {
            previewManager.pauseIfActive(videoId: video.id)
            activePreviewVideoId = nil
            NotificationCenter.default.post(
                name: .mentionNavigationRequested,
                object: route
            )
            return
        }
        guard let url = C.mediaURL(video.videoUrl) else { return }
        let player = previewManager.handoffActivePlayer(for: video.id, muted: playerMuted)
            ?? AVPlayer(url: url)
        player.isMuted = playerMuted
        player.volume = 1
        miniPlayer.replaceAndExpand(
            player: player,
            title: video.title,
            route: route,
            sourceFrame: sourceFrame,
            entrySurface: .atmosphere
        )
    }

    private func feedVideos(from items: [AtmosphereFeedItem]) -> [FeedVideo] {
        items.flatMap { item -> [FeedVideo] in
            switch item {
            case .video(let video):
                return [video.feedVideo]
            case .ripple(let ripple):
                return ripple.attachments.compactMap { $0.video?.feedVideo }
            case .excludedEpisode, .excludedShort, .unsupported:
                return []
            }
        }
    }

    private func feedVideos(from ripples: [Ripple]) -> [FeedVideo] {
        ripples.flatMap { ripple in
            ripple.attachments.compactMap { $0.video?.feedVideo }
        }
    }

    private func schedulePreviewUpdate(
        frames: [String: CGRect],
        videos: [FeedVideo],
        expectedTab: AtmosphereViewModel.Tab
    ) {
        previewFrames = frames
        previewIdleTask?.cancel()
        previewManager.warm(videos: videos, currentID: activePreviewVideoId)
        guard !isAutoplayBlocked else {
            isPreservingPreviewHandoff = false
            activePreviewVideoId = nil
            previewManager.pause()
            return
        }
        if activePreviewVideoId != nil {
            isPreservingPreviewHandoff = true
            activePreviewVideoId = nil
            previewManager.pausePreservingHandoff()
        }
        previewManager.prebufferBottomCandidates(videos: videos, frames: frames)
        previewIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled, model.selectedTab == expectedTab else { return }
            updatePreview(videos: videos)
            previewIdleTask = nil
        }
    }

    private func updatePreview(videos: [FeedVideo]) {
        isPreservingPreviewHandoff = false
        let policy = FeedPreviewAutoplayPolicy()
        let videosByID = videos.reduce(into: [String: FeedVideo]()) { result, video in
            result[video.id] = video
        }
        let orderedIDs = videos.map(\.id)
        let candidate = orderedIDs.compactMap { id -> (String, URL, CGFloat)? in
            guard id != suppressedPreviewVideoId,
                  let frame = previewFrames[id],
                  let url = C.mediaURL(videosByID[id]?.videoUrl),
                  let score = policy.candidateScore(for: frame)
            else { return nil }
            return (id, url, score)
        }
        .max { $0.2 < $1.2 }

        guard let candidate else {
            activePreviewVideoId = nil
            previewManager.pause()
            return
        }
        suppressedPreviewVideoId = nil
        activePreviewVideoId = candidate.0
        previewManager.warm(videos: videos, currentID: candidate.0)
        previewManager.play(videoId: candidate.0, url: candidate.1)
    }

    private func simpleRipples(_ ripples: [Ripple]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 0).id("atmosphere-discover-top")
                    atmosphereBoundaryListings(model.beforeFeedListings)
                    ForEach(ripples) {
                        RippleCard(
                            ripple: $0,
                            allowsEngagement: socialFeatures.rippleEngagementEnabled,
                            activePreviewVideoId: $activePreviewVideoId,
                            previewManager: previewManager,
                            isAutoplayBlocked: isAutoplayBlocked,
                            isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                            onPreviewPaused: { videoID in
                                suppressedPreviewVideoId = videoID
                                updatePreview(videos: feedVideos(from: ripples))
                            },
                            onVideoHandoff: { video, frame in
                                handoffToWatch(video, sourceFrame: frame)
                            }
                        )
                    }
                    atmosphereBoundaryListings(model.afterFeedListings)
                }
                .padding(.vertical, C.pagePad)
                .padding(.horizontal, feedCardInset)
                .padding(.bottom, C.bottomMenuClearance)
            }
            .coordinateSpace(name: "homeFeedScroll")
            .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
                schedulePreviewUpdate(
                    frames: frames,
                    videos: feedVideos(from: ripples),
                    expectedTab: .discover
                )
            }
            .refreshable { await model.reload(.discover) }
            .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
                guard notification.object as? String == "home" else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo("atmosphere-discover-top", anchor: .top)
                }
            }
        }
    }

    private func simpleVibes(_ vibes: [VibeSummary]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Color.clear.frame(height: 0).id("atmosphere-vibes-top")
                    atmosphereBoundaryListings(model.beforeFeedListings)
                    Button {
                        showsCreateVibe = true
                    } label: {
                        Label("Create Vibe", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    ForEach(vibes) { vibe in
                        NavigationLink(value: AppRoute.vibe(vibe.slug)) {
                            HStack(spacing: 12) {
                                SocialIdentityAvatar(
                                    image: vibe.avatarURL,
                                    name: vibe.name,
                                    size: 48
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vibe.name).font(.headline)
                                    if let description = vibe.description?
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                       !description.isEmpty {
                                        Text(description)
                                            .font(.subheadline)
                                            .foregroundStyle(C.textMuted)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text("\(vibe.memberCount) members · \(vibe.postCount) Ripples")
                                        .font(.caption)
                                        .foregroundStyle(C.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(C.textMuted)
                            }
                            .padding(12)
                            .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
                        }
                        .buttonStyle(.plain)
                    }
                    atmosphereBoundaryListings(model.afterFeedListings)
                }
                .padding(C.pagePad)
                .padding(.bottom, C.bottomMenuClearance)
            }
            .refreshable { await model.reload(.myVibes) }
            .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
                guard notification.object as? String == "home" else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo("atmosphere-vibes-top", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func atmosphereBoundaryListings(_ listings: [AssembledListing]) -> some View {
        ForEach(listings) { listing in
            NativeCurationListingView(listing: listing)
                .padding(.vertical, 6)
        }
    }

    private func inlineListing(after zeroBasedIndex: Int) -> AssembledListing? {
        let every = model.inlineEvery
        guard every > 0, (zeroBasedIndex + 1).isMultiple(of: every) else { return nil }
        let injectionIndex = ((zeroBasedIndex + 1) / every) - 1
        guard model.inlineListings.indices.contains(injectionIndex) else { return nil }
        return model.inlineListings[injectionIndex]
    }
}

private struct AtmospherePublishedVideoCard<MediaCard: View>: View {
    let video: AtmosphereVideo
    let sourceRoute: AppRoute?
    @ViewBuilder let mediaCard: () -> MediaCard

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showEnergy = false
    @State private var showComments = false
    @State private var showEcho = false
    @State private var energyCount: Int
    @State private var commentCount: Int
    @State private var echoCount: Int
    @State private var energyAggregate: ContentEnergyAggregate?

    init(
        video: AtmosphereVideo,
        sourceRoute: AppRoute?,
        @ViewBuilder mediaCard: @escaping () -> MediaCard
    ) {
        self.video = video
        self.sourceRoute = sourceRoute
        self.mediaCard = mediaCard
        _energyCount = State(initialValue: video.contentRatings?.count ?? 0)
        _commentCount = State(initialValue: video.counts?.comments ?? 0)
        _echoCount = State(initialValue: video.counts?.fanClubAttachments ?? 0)
    }

    private var ownerName: String {
        video.channel?.name ?? video.show?.title ?? "WeStreem"
    }

    private var ownerImage: String? {
        video.channel?.avatarURL ?? video.show?.coverURL
    }

    private var ownerKind: String {
        video.channel != nil ? "Channel" : video.show != nil ? "Show" : "publisher"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            publisherHeader
            mediaCard()
                .padding(.bottom, 10)
            actionBar
        }
        .background(C.surface.opacity(0.82))
        .clipShape(
            RoundedRectangle(
                cornerRadius: horizontalSizeClass == .compact ? 0 : 16,
                style: .continuous
            )
        )
        .overlay {
            if horizontalSizeClass == .compact {
                VStack(spacing: 0) {
                    Rectangle().fill(C.borderSubtle).frame(height: 1)
                    Spacer()
                    Rectangle().fill(C.borderSubtle).frame(height: 1)
                }
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(C.borderSubtle, lineWidth: 1)
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 0 : C.pagePad)
        .task(id: video.id) {
            guard let response = try? await APIClient.shared.fetchContentEnergy(
                contentPath: "videos",
                id: video.id
            ) else { return }
            energyAggregate = response.aggregate
            energyCount = response.aggregate.count
        }
        .sheet(isPresented: $showEnergy) {
            ContentEnergySheet(kind: .video, contentID: video.id) { aggregate in
                energyAggregate = aggregate
                energyCount = aggregate.count
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showComments) {
            StandardCommentsSheet(
                target: .video(video.id),
                initialCount: commentCount,
                autoFocusComposer: true,
                onClose: { showComments = false },
                onCountChange: { commentCount = $0 }
            )
        }
        .sheet(isPresented: $showEcho) {
            EchoVibeSheet(
                content: .video(
                    id: video.id,
                    title: video.title,
                    thumbnailURL: video.thumbnailURL,
                    sourceName: ownerName
                )
            ) { added in
                echoCount += added
            }
        }
    }

    private var publisherHeader: some View {
        HStack(spacing: 10) {
            sourceTarget {
                SocialIdentityAvatar(image: ownerImage, name: ownerName, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                sourceTarget {
                    Text(ownerName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                }
                Text("From a \(ownerKind) you follow")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var actionBar: some View {
        WestreemHorizontalScrollView(showsIndicators: false) {
            HStack(spacing: 0) {
                actionButton(
                    title: "Add Energy",
                    count: energyCount,
                    systemImage: "bolt",
                    highlighted: energyAggregate?.count ?? 0 > 0
                ) {
                    guard auth.isAuthenticated else { return }
                    showEnergy = true
                }
                actionButton(title: "Comment", count: commentCount, systemImage: "bubble.left") {
                    showComments = true
                }
                actionButton(title: "Echo", count: echoCount, systemImage: "wave.3.right") {
                    guard auth.isAuthenticated else { return }
                    showEcho = true
                }
                actionButton(title: "Share", count: 0, systemImage: "square.and.arrow.up") {
                    share()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(C.borderSubtle).frame(height: 1)
        }
    }

    private func actionButton(
        title: String,
        count: Int,
        systemImage: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                if count > 0 {
                    Text(count.formatted())
                        .foregroundStyle(C.textTertiary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(highlighted ? Color.orange.opacity(0.9) : C.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    @ViewBuilder
    private func sourceTarget<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let sourceRoute {
            NavigationLink(value: sourceRoute) {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private func share() {
        guard let url = URL(string: "\(C.baseURL)/watch/\(C.pathSegment(video.id))?src=atmosphere") else {
            return
        }
        UIActivityViewController(activityItems: [url], applicationActivities: nil).presentFromRoot()
    }
}

private extension AtmosphereVideo {
    var feedVideo: FeedVideo {
        FeedVideo(
            id: id,
            title: title,
            thumbnailUrl: thumbnailURL,
            videoUrl: videoURL,
            duration: duration,
            aspectRatio: nil,
            width: nil,
            height: nil,
            views: views,
            type: type,
            publishedAt: publishedAt,
            createdAt: createdAt,
            channel: channel.map {
                ChannelStub(
                    id: $0.id,
                    name: $0.name,
                    handle: $0.handle,
                    avatarUrl: $0.avatarURL
                )
            },
            show: show.map {
                ShowStub(
                    id: $0.id,
                    title: $0.title,
                    coverUrl: $0.coverURL,
                    showType: nil
                )
            }
        )
    }
}
