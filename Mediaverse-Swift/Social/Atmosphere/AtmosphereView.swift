import SwiftUI
import AVKit

struct AtmosphereView: View {
    @AppStorage("playerMuted") private var playerMuted = false
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @StateObject private var model = AtmosphereViewModel()
    @StateObject private var previewManager = FeedPreviewPlayerManager()
    @State private var activePreviewVideoId: String?
    @State private var previewFrames: [String: CGRect] = [:]
    @State private var previewIdleTask: Task<Void, Never>?
    @State private var suppressedPreviewVideoId: String?
    @State private var isPreservingPreviewHandoff = false
    @State private var showsCreateVibe = false
    private let socialFeatures = SocialFeatureConfiguration.runtime()

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
        .background(C.bg.ignoresSafeArea())
        .task { await model.loadIfNeeded() }
        .onChange(of: model.selectedTab) { _, tab in
            if tab != .atmosphere {
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
    }

    private var header: some View {
        HStack {
            Text("The Atmosphere")
                .font(.title2.bold())
                .foregroundStyle(C.text)
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(C.bg)
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
            LazyVStack(spacing: 12) {
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
        ScrollView {
            LazyVStack(spacing: 12) {
                atmosphereBoundaryListings(model.beforeFeedListings)
                if socialFeatures.rippleComposerEnabled {
                    RippleComposer(destination: .personal) {
                        model.prepend($0)
                    }
                    .padding(.horizontal, C.pagePad)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    switch item {
                    case .ripple(let ripple):
                        RippleCard(
                            ripple: ripple,
                            allowsEngagement: socialFeatures.rippleEngagementEnabled
                        )
                        .padding(.horizontal, C.pagePad)
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
            schedulePreviewUpdate(frames: frames, videos: feedVideos(from: items))
        }
        .refreshable { await model.reload(.atmosphere) }
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

    private func atmosphereVideoCard(_ video: AtmosphereVideo) -> some View {
        let feedVideo = video.feedVideo
        let mediaRoute = AppRoute.video(video.id)
        let sourceRoute: AppRoute? = video.channel.map { .channel($0.handle) }
            ?? video.show.map { .show($0.id) }
        return HomeVideoCard(
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
            } : nil
        )
        .padding(.bottom, C.sectionSpacing)
    }

    private var isAutoplayBlocked: Bool {
        miniPlayer.item != nil || miniPlayer.isExpansionHandoffActive
    }

    private func canHandoff(_ video: FeedVideo) -> Bool {
        C.mediaURL(video.videoUrl) != nil
    }

    private func handoffToWatch(_ video: FeedVideo, sourceFrame: CGRect?) {
        guard let url = C.mediaURL(video.videoUrl) else { return }
        let player = previewManager.handoffActivePlayer(for: video.id, muted: playerMuted)
            ?? AVPlayer(url: url)
        player.isMuted = playerMuted
        player.volume = 1
        miniPlayer.replaceAndExpand(
            player: player,
            title: video.title,
            route: .video(video.id),
            sourceFrame: sourceFrame,
            entrySurface: .atmosphere
        )
    }

    private func feedVideos(from items: [AtmosphereFeedItem]) -> [FeedVideo] {
        items.compactMap {
            guard case .video(let video) = $0 else { return nil }
            return video.feedVideo
        }
    }

    private func schedulePreviewUpdate(frames: [String: CGRect], videos: [FeedVideo]) {
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
            guard !Task.isCancelled, model.selectedTab == .atmosphere else { return }
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
        ScrollView {
            LazyVStack(spacing: 12) {
                atmosphereBoundaryListings(model.beforeFeedListings)
                ForEach(ripples) {
                    RippleCard(
                        ripple: $0,
                        allowsEngagement: socialFeatures.rippleEngagementEnabled
                    )
                }
                atmosphereBoundaryListings(model.afterFeedListings)
            }
            .padding(C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .refreshable { await model.reload(.discover) }
    }

    private func simpleVibes(_ vibes: [VibeSummary]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
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
