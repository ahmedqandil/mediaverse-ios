import SwiftUI
import AVKit

struct VideosBrowseView: View {
    let isBrowseActive: Bool

    @AppStorage("playerMuted") private var playerMuted = false
    @EnvironmentObject private var miniPlayer: MiniPlayerManager

    @State private var videos = [FeedVideo]()
    @State private var selectedSectionID: String? = nil
    @State private var curationSections = [PageSection]()
    @State private var curationListings = [AssembledListing]()
    @State private var cursor: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var activePreviewVideoId: String?
    @State private var latestPreviewFrames: [String: CGRect] = [:]
    @State private var suppressedPreviewVideoId: String?
    @State private var previewIdleTask: Task<Void, Never>?
    @State private var didStartPreviewScroll = false
    @State private var isPreservingPreviewHandoff = false
    @State private var loadGeneration = 0
    @StateObject private var previewPlayerManager = FeedPreviewPlayerManager()

    init(isBrowseActive: Bool = true) {
        self.isBrowseActive = isBrowseActive
    }

    private var videoIdsInOrder: [String] {
        videos.map(\.id)
    }

    private var isAutoplayBlocked: Bool {
        miniPlayer.item != nil || miniPlayer.isExpansionHandoffActive
    }

    private var heroListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType == "hero" }
    }

    private var contentListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType != "hero" }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(heroListings) { listing in
                        NativeCurationListingView(listing: listing)
                            .padding(.bottom, C.sectionSpacing)
                    }

                    if !curationSections.isEmpty {
                        sectionTabs
                            .padding(.bottom, C.sectionSpacing)
                    }

                    if isLoading && videos.isEmpty {
                        loadingList
                    } else if let loadError, videos.isEmpty && curationListings.isEmpty {
                        errorState(loadError)
                    } else if videos.isEmpty && curationListings.isEmpty {
                        emptyState
                    } else {
                        curatedContent
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .coordinateSpace(name: "homeFeedScroll")
            .refreshable {
                C.lightHaptic()
                await load(reset: true)
            }
            .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
                scheduleActivePreviewUpdate(from: frames)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard isBrowseActive else { return }
            await load(reset: true)
        }
        .onChange(of: isBrowseActive) { _, isActive in
            if isActive, isLoading, videos.isEmpty {
                Task { await load(reset: true) }
            } else if !isActive {
                previewIdleTask?.cancel()
                previewIdleTask = nil
                activePreviewVideoId = nil
                previewPlayerManager.pause()
            }
        }
        .onDisappear {
            previewIdleTask?.cancel()
            previewIdleTask = nil
            isPreservingPreviewHandoff = false
            activePreviewVideoId = nil
            previewPlayerManager.pause()
        }
        .onChange(of: isAutoplayBlocked) { _, isBlocked in
            if isBlocked {
                previewIdleTask?.cancel()
                previewIdleTask = nil
                isPreservingPreviewHandoff = false
                activePreviewVideoId = nil
                previewPlayerManager.pause()
            }
        }
    }

    private var curatedContent: some View {
        Group {
            if curationListings.isEmpty {
                videoFeedContent
            } else {
                ForEach(contentListings) { listing in
                    switch listing.normalizedTemplateType {
                    case "video_feed":
                        videoFeedContent
                    case "shorts_feed", "stories", "continue_watching":
                        EmptyView()
                    default:
                        NativeCurationListingView(listing: listing)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(curationSections) { section in
                    GenrePill(label: section.name, selected: selectedSectionID == section.id) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSectionID = section.id
                        }
                        Task { await load(reset: true) }
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.top, 12)
    }

    private var videoFeedContent: some View {
        Group {
            videoList

            if cursor != nil {
                paginationSentinel
            }
        }
    }

    private var videoList: some View {
        ForEach(videos, id: \.id) { video in
            HomeVideoCard(
                video: video,
                mediaRoute: route(for: video),
                sourceRoute: sourceRoute(for: video),
                activePreviewVideoId: $activePreviewVideoId,
                previewManager: previewPlayerManager,
                isAutoplayBlocked: isAutoplayBlocked,
                isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                onPreviewPaused: { playNextPreview(afterPaused: video.id) },
                openMediaAction: { NotificationCenter.default.post(name: .mentionNavigationRequested, object: route(for: video)) },
                replaceMediaAction: canReplaceMiniPlayer(with: video) ? { sourceFrame in replaceMiniPlayerAndExpand(with: video, sourceFrame: sourceFrame) } : nil
            )
            .padding(.bottom, C.sectionSpacing)
        }
    }

    private var loadingList: some View {
        ForEach(0..<4, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: UIScreen.main.bounds.width / C.mediaAspectRatio(forContentType: "video"))
                    .shimmering()

                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 36, height: 36)
                        .shimmering()

                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 240, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.045))
                            .frame(width: 150, height: 12)
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.bottom, C.sectionSpacing)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            MediaverseIcon(name: "play", fallbackSystemName: "play.rectangle")
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.white.opacity(0.2))
            Text("No videos yet")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Published videos will appear here.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, C.pagePad)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button {
                Task { await load(reset: true) }
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(C.watch)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.horizontal, C.pagePad)
    }

    private var paginationSentinel: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await loadMore() } }
            if isLoadingMore {
                ProgressView()
                    .tint(C.watch)
                    .padding(.vertical, 20)
            }
        }
    }

    private func scheduleActivePreviewUpdate(from frames: [String: CGRect]) {
        latestPreviewFrames = frames
        previewIdleTask?.cancel()
        previewPlayerManager.warm(videos: videos, currentID: activePreviewVideoId)

        guard !isAutoplayBlocked else {
            isPreservingPreviewHandoff = false
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        if activePreviewVideoId != nil {
            isPreservingPreviewHandoff = true
            activePreviewVideoId = nil
            previewPlayerManager.pausePreservingHandoff()
        }

        previewPlayerManager.prebufferBottomCandidates(videos: videos, frames: frames)
        previewIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            didStartPreviewScroll = true
            updateActivePreview(from: latestPreviewFrames)
            previewIdleTask = nil
        }
    }

    private func updateActivePreview(from frames: [String: CGRect]) {
        isPreservingPreviewHandoff = false

        guard !isAutoplayBlocked else {
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        let autoplayPolicy = FeedPreviewAutoplayPolicy()

        var videosById = [String: FeedVideo]()
        videos.forEach { videosById[$0.id] = $0 }

        if !didStartPreviewScroll,
           let topCandidate = videoIdsInOrder.compactMap({ id -> (id: String, url: URL)? in
               guard id != suppressedPreviewVideoId,
                     let frame = frames[id],
                     let url = C.mediaURL(videosById[id]?.videoUrl),
                     autoplayPolicy.isInitialTopCandidate(frame: frame) else { return nil }
               return (id, url)
           }).first {
            suppressedPreviewVideoId = nil
            activePreviewVideoId = topCandidate.id
            previewPlayerManager.warm(videos: videos, currentID: topCandidate.id)
            previewPlayerManager.play(videoId: topCandidate.id, url: topCandidate.url)
            return
        }

        let candidate = videoIdsInOrder.compactMap { id -> (id: String, url: URL, score: CGFloat)? in
            guard id != suppressedPreviewVideoId,
                  let frame = frames[id],
                  let url = C.mediaURL(videosById[id]?.videoUrl),
                  let score = autoplayPolicy.candidateScore(for: frame) else { return nil }
            return (id, url, score)
        }
        .max { $0.score < $1.score }

        guard let candidate else {
            activePreviewVideoId = nil
            previewPlayerManager.pause()
            return
        }

        suppressedPreviewVideoId = nil
        activePreviewVideoId = candidate.id
        previewPlayerManager.warm(videos: videos, currentID: candidate.id)
        previewPlayerManager.play(videoId: candidate.id, url: candidate.url)
    }

    private func playNextPreview(afterPaused pausedId: String) {
        guard activePreviewVideoId == nil || activePreviewVideoId == pausedId else { return }
        suppressedPreviewVideoId = pausedId
        updateActivePreview(from: latestPreviewFrames)
    }

    private func route(for video: FeedVideo) -> AppRoute {
        AppRoute.media(id: video.id, type: video.type, showId: video.show?.id, channelId: video.channel?.id)
    }

    private func sourceRoute(for video: FeedVideo) -> AppRoute? {
        if let channel = video.channel {
            return .channel(channel.handle ?? channel.id)
        }
        if let show = video.show {
            return .show(show.id)
        }
        return nil
    }

    private func canReplaceMiniPlayer(with video: FeedVideo) -> Bool {
        guard C.mediaURL(video.videoUrl) != nil else { return false }
        if case .video = route(for: video) {
            return true
        }
        return false
    }

    private func replaceMiniPlayerAndExpand(with video: FeedVideo, sourceFrame: CGRect? = nil) {
        guard let url = C.mediaURL(video.videoUrl) else { return }
        let player = previewPlayerManager.handoffActivePlayer(for: video.id, muted: playerMuted) ?? AVPlayer(url: url)
        player.isMuted = playerMuted
        player.volume = 1
        miniPlayer.replaceAndExpand(player: player, title: video.title, route: route(for: video), sourceFrame: sourceFrame, entrySurface: .videosFeed)
    }

    @MainActor
    private func load(reset: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedCursor = reset ? nil : cursor
        if reset {
            loadError = nil
            cursor = nil
            previewIdleTask?.cancel()
            previewIdleTask = nil
            isPreservingPreviewHandoff = false
            activePreviewVideoId = nil
            didStartPreviewScroll = false

            if let cachedPage = CurationManager.shared.cachedPage(key: "videos", section: selectedSectionID, allowExpired: true), cachedPage.hasCurationSurface {
                applyCuratedVideoPage(cachedPage)
                isLoading = false
            } else if let cachedVideos = cachedCuratedInitialVideos(), !cachedVideos.isEmpty {
                curationListings = []
                videos = uniqueByID(cachedVideos)
                cursor = cachedVideos.last?.id
                isLoading = false
            } else {
                isLoading = videos.isEmpty && curationListings.isEmpty
            }
        }

        do {
            let refreshedPage = reset ? try? await CurationManager.shared.fetchPage(key: "videos", section: selectedSectionID) : nil
            guard generation == loadGeneration else { return }
            if let page = refreshedPage, page.hasCurationSurface {
                applyCuratedVideoPage(page)
            } else if reset {
                let curationVideos = try? await fetchCuratedInitialVideos()
                guard generation == loadGeneration else { return }
                if let curationVideos, !curationVideos.isEmpty {
                    curationListings = []
                    videos = uniqueByID(curationVideos)
                    cursor = curationVideos.last?.id
                } else {
                    let response = try await APIClient.shared.fetchFeed(cursor: nil)
                    guard generation == loadGeneration else { return }
                    let filtered = response.videos.filter(isRegularVideo)
                    curationSections = []
                    selectedSectionID = nil
                    curationListings = []
                    videos = uniqueByID(filtered)
                    cursor = response.nextCursor
                }
            } else {
                let response = try await APIClient.shared.fetchFeed(cursor: requestedCursor)
                guard generation == loadGeneration else { return }
                let filtered = response.videos.filter(isRegularVideo)
                videos = uniqueByID(videos + filtered)
                cursor = response.nextCursor
            }
            previewPlayerManager.warm(videos: videos, currentID: activePreviewVideoId)
        } catch {
            guard generation == loadGeneration else { return }
            if videos.isEmpty && curationListings.isEmpty {
                loadError = "Unable to load videos."
            }
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    @MainActor
    private func applyCuratedVideoPage(_ page: AssembledPage) {
        let sections = page.sortedSections
        curationSections = sections
        if let selectedSectionID,
           !sections.contains(where: { $0.id == selectedSectionID }) {
            self.selectedSectionID = sections.first?.id
        } else if selectedSectionID == nil {
            selectedSectionID = sections.first?.id
        }
        let listings = page.listings(forSectionID: selectedSectionID)
        curationListings = listings
        guard let feedListing = listings.first(where: { $0.normalizedTemplateType == "video_feed" }) else {
            videos = []
            cursor = nil
            return
        }
        let curatedVideos = feedListing.items
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" }
            .map(\.asFeedVideo)
            .filter(isRegularVideo)
        videos = uniqueByID(curatedVideos)
        cursor = feedListing.infiniteLoad ? curatedVideos.last?.id : nil
    }

    @MainActor
    private func loadMore() async {
        guard cursor != nil, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        await load(reset: false)
        isLoadingMore = false
    }

    @MainActor
    private func cachedCuratedInitialVideos() -> [FeedVideo]? {
        guard let page = CurationManager.shared.cachedPage(key: "videos", allowExpired: true) else { return nil }
        let feedListing = page.activeListings.first { $0.normalizedTemplateType == "video_feed" }
            ?? page.listings.first { $0.normalizedTemplateType == "video_feed" }
        guard let feedListing else { return nil }
        return feedListing.items
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" }
            .map(\.asFeedVideo)
            .filter(isRegularVideo)
    }

    private func fetchCuratedInitialVideos() async throws -> [FeedVideo] {
        let page = try await CurationManager.shared.fetchPage(key: "videos")
        guard let feedListing = page.activeListings.first(where: { $0.normalizedTemplateType == "video_feed" })
            ?? page.listings.first(where: { $0.normalizedTemplateType == "video_feed" }) else { return [] }
        return feedListing.items
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" }
            .map(\.asFeedVideo)
            .filter(isRegularVideo)
    }

    private func isRegularVideo(_ video: FeedVideo) -> Bool {
        let type = C.normalizedContentType(video.type)
        return !type.contains("short") && !type.contains("movie")
    }

    private func uniqueByID(_ items: [FeedVideo]) -> [FeedVideo] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
