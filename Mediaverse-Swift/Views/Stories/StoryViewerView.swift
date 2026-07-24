import AVKit
import SwiftUI
import UIKit

struct StoryViewerView: View {
    @ObservedObject var repository: StoriesRepository
    let initialGroupId: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inAppBrowser: InAppBrowserManager
    @State private var groupIndex = 0
    @State private var storyIndex = 0
    @State private var elapsed: TimeInterval = 0
    @State private var isPaused = false
    @State private var player: AVPlayer?
    @State private var tickTask: Task<Void, Never>?
    @State private var viewedTask: Task<Void, Never>?
    @State private var videoRetryTask: Task<Void, Never>?
    @State private var preloadTask: Task<Void, Never>?
    @State private var backendRefreshTask: Task<Void, Never>?
    @State private var activeStoryId: String?
    @State private var preloadedStoryIds = Set<String>()
    @State private var cachedStoryMediaURLs = [String: URL]()
    @State private var prewarmedVideoPlayers = [String: AVPlayer]()
    @State private var prewarmedVideoOrder = [String]()
    @State private var preloadedVideoDurations = [String: TimeInterval]()
    @State private var effectiveStoryDurations = [String: TimeInterval]()
    @State private var videoEndObserver: NSObjectProtocol?
    @State private var videoStallObserver: NSObjectProtocol?
    @State private var videoStatusObserver: NSKeyValueObservation?
    @State private var playerStatusObserver: NSKeyValueObservation?
    @State private var videoRetryCount = 0
    @State private var videoErrorText: String?
    @State private var groupTransitionDirection = 1
    @State private var storyPendingDelete: StoryItem?
    @State private var isDeletingStory = false
    @State private var storyDeleteError: String?
    @State private var viewersSheetStory: StoryItem?
    @State private var viewerPreviewResponses = [String: StoryViewersResponse]()
    @State private var viewerPreviewAvatars = [String: [ViewerUser]]()
    @State private var viewerAccessDeniedStoryIds = Set<String>()
    @State private var likingStoryIds = Set<String>()

    private let videoPrewarmLimit = 3

    private var groups: [StoryGroup] { repository.groups.filter { !$0.stories.isEmpty } }
    private var currentGroup: StoryGroup? { groups.indices.contains(groupIndex) ? groups[groupIndex] : nil }
    private var currentStory: StoryItem? {
        guard let group = currentGroup, group.stories.indices.contains(storyIndex) else { return nil }
        return group.stories[storyIndex]
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 720
            let horizontalPadding: CGFloat = proxy.size.width < 380 ? 12 : 18
            let topPadding = max(proxy.safeAreaInsets.top + 8, compact ? 10 : 12)
            let bottomPadding = max(proxy.safeAreaInsets.bottom + (compact ? 10 : 18), compact ? 16 : 34)

            ZStack {
                Color.black.ignoresSafeArea()

                if let group = currentGroup, let story = currentStory {
                    storyPage(
                        group: group,
                        story: story,
                        viewportSize: proxy.size,
                        compact: compact,
                        horizontalPadding: horizontalPadding,
                        topPadding: topPadding,
                        bottomPadding: bottomPadding
                    )
                    .id(group.id)
                    .transition(groupTransition)
                } else {
                    ProgressView()
                        .tint(C.watch)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .statusBarHidden()
        .gesture(dismissDrag)
        .simultaneousGesture(pauseGesture)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: repository.groups) { _, _ in
            reconcileAfterRepositoryChange()
        }
        .alert("Delete story?", isPresented: Binding(
            get: { storyPendingDelete != nil },
            set: {
                if !$0 {
                    storyPendingDelete = nil
                    if !isDeletingStory { setPaused(false) }
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                guard let story = storyPendingDelete else { return }
                Task { await deleteStory(story) }
            }
            Button("Cancel", role: .cancel) {
                storyPendingDelete = nil
                setPaused(false)
            }
        } message: {
            Text("This removes the story immediately for every viewer.")
        }
        .sheet(item: $viewersSheetStory, onDismiss: {
            viewersSheetStory = nil
            setPaused(false)
        }) { story in
            viewersSheet(for: story)
        }
        .accessibilityElement(children: .contain)
    }

    private func viewersSheet(for story: StoryItem) -> some View {
        let viewModel = StoryViewersViewModel(
            storyId: story.id,
            initialResponse: viewerPreviewResponses[story.id]
        )

        return ViewersSheet(viewModel: viewModel, story: story)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(.dark)
    }

    private var groupTransition: AnyTransition {
        let insertion: Edge = groupTransitionDirection >= 0 ? .trailing : .leading
        let removal: Edge = groupTransitionDirection >= 0 ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertion), removal: .move(edge: removal))
            .combined(with: .opacity)
    }

    private func storyPage(
        group: StoryGroup,
        story: StoryItem,
        viewportSize: CGSize,
        compact: Bool,
        horizontalPadding: CGFloat,
        topPadding: CGFloat,
        bottomPadding: CGFloat
    ) -> some View {
        ZStack {
            storyMedia(story, viewportSize: viewportSize)
                .ignoresSafeArea()

            topGradient
            bottomGradient
            tapNavigationLayer

            overlayStickers(story: story, viewportSize: viewportSize)

            VStack(spacing: 0) {
                topChrome(
                    group: group,
                    story: story,
                    compact: compact,
                    horizontalPadding: horizontalPadding,
                    topPadding: topPadding
                )

                Spacer(minLength: compact ? 18 : 28)

                bottomContent(group: group, story: story)
                    .padding(.horizontal, horizontalPadding)
            }
            .padding(.bottom, bottomPadding)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .foregroundStyle(.white)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .task(id: story.id) {
            await prefetchViewerPreviewIfNeeded(for: story, group: group)
        }
    }

    @ViewBuilder
    private func storyMedia(_ story: StoryItem, viewportSize: CGSize) -> some View {
        if story.isVideoMedia {
            if let player {
                StoryViewerPlayerView(player: player)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
                    .disabled(true)
                    .onAppear { if !isPaused { player.play() } }
                    .overlay {
                        if let videoErrorText {
                            Text(videoErrorText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.62))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(24)
                        }
                    }
            } else {
                Color.black.overlay(ProgressView().tint(C.watch))
            }
        } else {
            CachedRemoteImage(
                url: mediaURL(for: story),
                targetSize: viewportSize
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: viewportSize.width, height: viewportSize.height)
            } placeholder: {
                C.elevated
                    .frame(width: viewportSize.width, height: viewportSize.height)
            }
        }
    }

    private var topGradient: some View {
        LinearGradient(colors: [.black.opacity(0.78), .black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
            .frame(maxHeight: 190, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }

    private var bottomGradient: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            .frame(maxHeight: 260, alignment: .bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
    }

    private func topChrome(
        group: StoryGroup,
        story: StoryItem,
        compact: Bool,
        horizontalPadding: CGFloat,
        topPadding: CGFloat
    ) -> some View {
        VStack(spacing: compact ? 6 : 7) {
            progressBars(group: group, story: story)
                .padding(.horizontal, max(horizontalPadding - 8, 6))

            header(group: group, story: story, compact: compact)
                .padding(.horizontal, horizontalPadding)
        }
        .padding(.top, max(topPadding - 8, compact ? 4 : 6))
    }

    private func progressBars(group: StoryGroup, story: StoryItem) -> some View {
        HStack(spacing: 4) {
            ForEach(group.stories.indices, id: \.self) { index in
                GeometryReader { proxy in
                    let width = max(1, proxy.size.width)
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: width * progress(for: index, story: story), height: 4)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    seekStoryProgress(index: index, progress: Double(value.location.x / width), commit: false)
                                }
                                .onEnded { value in
                                    seekStoryProgress(index: index, progress: Double(value.location.x / width), commit: true)
                                }
                        )
                }
                .frame(height: 24)
                .accessibilityLabel("Story \(index + 1) progress")
                .accessibilityValue("\(Int(progress(for: index, story: story) * 100)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        seekStoryProgress(index: index, progress: progress(for: index, story: story) + 0.05, commit: true)
                    case .decrement:
                        seekStoryProgress(index: index, progress: progress(for: index, story: story) - 0.05, commit: true)
                    default:
                        break
                    }
                }
            }
        }
    }

    private func header(group: StoryGroup, story: StoryItem, compact: Bool) -> some View {
        HStack(spacing: 9) {
            Button {
                navigateToPublisher(group)
            } label: {
                HStack(spacing: 9) {
                    StoryHeaderAvatar(group: group)
                        .frame(width: compact ? 32 : 34, height: compact ? 32 : 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.publisherName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(relativeTime(from: story.createdAt))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(group.publisherName)")

            Spacer()

            Menu {
                Button(role: .destructive) {
                    storyPendingDelete = story
                    setPaused(true)
                } label: {
                    Label("Delete story", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: compact ? 34 : 36, height: compact ? 34 : 36)
            }
            .foregroundStyle(.white)
            .disabled(isDeletingStory)
            .accessibilityLabel("Story options")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: compact ? 34 : 36, height: compact ? 34 : 36)
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Close stories")
        }
    }

    private func navigateToPublisher(_ group: StoryGroup) {
        let route: AppRoute
        switch group.publisherType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "show":
            route = .show(group.publisherId)
        case "channel":
            let channelHandle = group.publisherHandle?.trimmingCharacters(in: .whitespacesAndNewlines)
            route = .channel(channelHandle?.isEmpty == false ? channelHandle ?? group.publisherId : group.publisherId)
        default:
            route = .channel(group.publisherHandle ?? group.publisherId)
        }

        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
        }
    }

    @ViewBuilder
    private func bottomContent(group: StoryGroup, story: StoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let storyDeleteError {
                Text(storyDeleteError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let caption = story.caption, !caption.isEmpty {
                MentionText(
                    plain: caption,
                    html: story.captionHtml,
                    font: .system(size: 15, weight: .medium),
                    color: .white
                )
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(caption)
            }

            HStack(spacing: 10) {
                storyLikeButton(story)

                if canShowViewersChip(for: story, group: group) {
                    ViewerCountChip(
                        viewCount: story.viewCount,
                        previewAvatars: viewerPreviewAvatars[story.id] ?? [],
                        onTap: { presentViewersSheet(for: story) }
                    )
                }
            }

            if let label = story.ctaLabel, !label.isEmpty {
                Button {
                    openCTA(story.ctaUrl)
                } label: {
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.system(size: 15, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(C.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(C.watch)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(label)
            }
        }
    }

    private func storyLikeButton(_ story: StoryItem) -> some View {
        Button {
            Task { await toggleLike(story) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: story.userLiked ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(story.userLiked ? .red : .white)
                    .scaleEffect(story.userLiked ? 1.08 : 1)
                Text(story.likeCount > 0 ? compactCount(story.likeCount) : "Like")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.black.opacity(0.42))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.16), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(likingStoryIds.contains(story.id))
        .opacity(likingStoryIds.contains(story.id) ? 0.7 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: story.userLiked)
        .accessibilityLabel(story.userLiked ? "Unlike story" : "Like story")
        .accessibilityValue(story.likeCount > 0 ? "\(story.likeCount) likes" : "No likes")
    }

    // MARK: - Overlay sticker layer

    @ViewBuilder
    private func overlayStickers(story: StoryItem, viewportSize: CGSize) -> some View {
        if !story.overlays.isEmpty {
            let canvas = CanvasSpec.storyDefault
            let stickerScale = StoryOverlayLayout.stickerPresentationScale(for: canvas, in: viewportSize)
            ZStack {
                ForEach(Array(story.overlays.enumerated()), id: \.offset) { index, overlay in
                    StoryOverlayStickerView(
                        overlay: overlay,
                        storyId: story.id,
                        overlayIndex: index,
                        isInteractive: true,
                        onMentionNavigate: { dismiss() },
                        setPaused: setPaused(_:)
                    )
                        .fixedSize(horizontal: true, vertical: true)
                        .scaleEffect((overlay.base.scale ?? 1.0) * stickerScale)
                        .rotationEffect(.degrees(overlay.base.rotation ?? 0))
                        .position(StoryOverlayLayout.position(for: overlay.base, canvas: canvas, in: viewportSize))
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
        }
    }

    private var tapNavigationLayer: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { previousStory() }
                    .accessibilityLabel("Previous story")
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { nextStory() }
                    .accessibilityLabel("Next story")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                if value.translation.height > 90 {
                    dismiss()
                    return
                }
                guard abs(value.translation.width) > 80,
                      abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    if value.translation.width < 0 {
                        nextGroup()
                    } else {
                        previousGroup()
                    }
                }
            }
    }

    private var pauseGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.18)
            .onChanged { _ in setPaused(true) }
            .onEnded { _ in setPaused(false) }
    }

    private func start() {
        if let startIndex = groups.firstIndex(where: { $0.id == initialGroupId }) {
            groupIndex = startIndex
        }
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
        startBackendRefreshLoop()
    }

    private func startBackendRefreshLoop() {
        backendRefreshTask?.cancel()
        backendRefreshTask = Task { @MainActor in
            await repository.refresh(force: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                await repository.refresh(force: true)
            }
        }
    }

    private func reconcileAfterRepositoryChange() {
        guard !groups.isEmpty else {
            dismiss()
            return
        }

        if let activeStoryId,
           let groupIndex = groups.firstIndex(where: { group in group.stories.contains { $0.id == activeStoryId } }),
           let storyIndex = groups[groupIndex].stories.firstIndex(where: { $0.id == activeStoryId }) {
            self.groupIndex = groupIndex
            self.storyIndex = storyIndex
            scheduleStoryPreload()
            return
        }

        clampIndexes()
        beginCurrentStory()
    }

    private func beginCurrentStory() {
        elapsed = 0
        isPaused = viewersSheetStory != nil
        videoRetryCount = 0
        videoErrorText = nil
        clearVideoObservers()
        player?.pause()
        player = nil
        tickTask?.cancel()
        viewedTask?.cancel()
        videoRetryTask?.cancel()
        tickTask = nil
        viewedTask = nil
        videoRetryTask = nil

        guard let story = currentStory else { return }
        activeStoryId = story.id
        scheduleStoryPreload()
        if story.isVideoMedia {
            prepareVideo(story)
        } else {
            startStoryProgressTimer(for: story)
        }

        viewedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let id = currentStory?.id, id == story.id else { return }
            await repository.markViewed(storyId: id)
        }

    }

    private func startStoryProgressTimer(for story: StoryItem) {
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, currentStory?.id == story.id else { break }
                if !isPaused {
                    elapsed += 0.05
                    if elapsed >= displayDuration(for: story) {
                        nextStory()
                    }
                }
            }
        }
    }

    private func scheduleStoryPreload() {
        preloadTask?.cancel()
        let candidates = preloadCandidates()
        let pending = candidates.filter { !preloadedStoryIds.contains($0.id) }
        trimStoryPreloadState(keeping: candidates)
        guard !pending.isEmpty else { return }
        pending.forEach { preloadedStoryIds.insert($0.id) }

        preloadTask = Task {
            for story in pending {
                guard !Task.isCancelled else { return }
                await preloadStory(story, priority: preloadPriority(for: story))
            }
        }
    }

    private func preloadCandidates() -> [StoryItem] {
        var candidates = [StoryItem]()
        guard groups.indices.contains(groupIndex) else { return candidates }

        let group = groups[groupIndex]
        for index in [storyIndex, storyIndex + 1, storyIndex + 2, storyIndex + 3, storyIndex - 1] where group.stories.indices.contains(index) {
            candidates.append(group.stories[index])
        }

        if groups.indices.contains(groupIndex + 1) {
            candidates.append(contentsOf: groups[groupIndex + 1].stories.prefix(2))
        }
        if groups.indices.contains(groupIndex - 1) {
            candidates.append(contentsOf: groups[groupIndex - 1].stories.prefix(2))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func preloadStory(_ story: StoryItem, priority: CacheWarmupPriority) async {
        guard let url = C.mediaURL(story.mediaUrl) else { return }

        do {
            let localURL = try await StoryMediaCache.shared.cachedURL(for: url, priority: priority)
            if story.isVideoMedia {
                let asset = AVURLAsset(url: localURL)
                let loadedDuration: CMTime? = try? await asset.load(.duration)
                let duration = loadedDuration?.seconds
                await MainActor.run {
                    cachedStoryMediaURLs[story.id] = localURL
                    if let duration, duration.isFinite, duration > 0 {
                        preloadedVideoDurations[story.id] = max(duration, 1)
                    }
                    prewarmVideoPlayer(for: story, localURL: localURL)
                }
            } else {
                await MainActor.run {
                    cachedStoryMediaURLs[story.id] = localURL
                }
            }
        } catch {
            await MainActor.run {
                _ = preloadedStoryIds.remove(story.id)
            }
        }
    }

    private func preloadPriority(for story: StoryItem) -> CacheWarmupPriority {
        guard let currentStory else { return .background }
        if story.id == currentStory.id {
            return .immediate
        }
        guard let currentGroup else { return .background }
        if currentGroup.stories.dropFirst(storyIndex + 1).prefix(2).contains(where: { $0.id == story.id }) {
            return .high
        }
        return .background
    }

    private func prepareVideo(_ story: StoryItem) {
        if let prewarmedPlayer = consumePrewarmedVideoPlayer(for: story) {
            guard let item = prewarmedPlayer.currentItem else {
                videoErrorText = "Video failed to prepare."
                return
            }
            clearVideoObservers()
            player?.pause()
            prewarmedPlayer.isMuted = false
            prewarmedPlayer.volume = 1
            attachVideoObservers(player: prewarmedPlayer, item: item, story: story)
            player = prewarmedPlayer
            updateEffectiveDuration(for: story, item: item)
            if item.status == .readyToPlay, tickTask == nil {
                startStoryProgressTimer(for: story)
            }
            if !isPaused {
                prewarmedPlayer.play()
            }
            scheduleVideoRetryCheck(for: story, item: item)
            return
        }

        guard let url = mediaURL(for: story) else {
            videoErrorText = "Video URL is invalid."
            return
        }
        clearVideoObservers()
        player?.pause()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["tracks", "duration", "playable"]
        )
        item.preferredForwardBufferDuration = 0.75
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.actionAtItemEnd = .none
        nextPlayer.automaticallyWaitsToMinimizeStalling = false
        nextPlayer.volume = 1
        attachVideoObservers(player: nextPlayer, item: item, story: story)
        player = nextPlayer
        if !isPaused {
            nextPlayer.play()
        }
        scheduleVideoRetryCheck(for: story, item: item)
    }

    private func mediaURL(for story: StoryItem) -> URL? {
        cachedStoryMediaURLs[story.id] ?? C.mediaURL(story.mediaUrl)
    }

    private func prewarmVideoPlayer(for story: StoryItem, localURL: URL) {
        guard prewarmedVideoPlayers[story.id] == nil else { return }

        let asset = AVURLAsset(url: localURL)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["tracks", "duration", "playable"]
        )
        item.preferredForwardBufferDuration = 1.5
        let warmPlayer = AVPlayer(playerItem: item)
        warmPlayer.actionAtItemEnd = .none
        warmPlayer.automaticallyWaitsToMinimizeStalling = false
        warmPlayer.isMuted = true
        warmPlayer.volume = 0
        prewarmedVideoPlayers[story.id] = warmPlayer
        prewarmedVideoOrder.removeAll { $0 == story.id }
        prewarmedVideoOrder.append(story.id)
        trimPrewarmedVideoPlayers()
    }

    private func consumePrewarmedVideoPlayer(for story: StoryItem) -> AVPlayer? {
        guard let player = prewarmedVideoPlayers.removeValue(forKey: story.id) else { return nil }
        prewarmedVideoOrder.removeAll { $0 == story.id }
        return player
    }

    private func trimPrewarmedVideoPlayers() {
        while prewarmedVideoOrder.count > videoPrewarmLimit {
            let storyId = prewarmedVideoOrder.removeFirst()
            prewarmedVideoPlayers[storyId]?.pause()
            prewarmedVideoPlayers[storyId] = nil
        }
    }

    private func trimStoryPreloadState(keeping stories: [StoryItem]) {
        var ids = Set(stories.map(\.id))
        if let activeStoryId {
            ids.insert(activeStoryId)
        }
        preloadedStoryIds = preloadedStoryIds.intersection(ids)
        cachedStoryMediaURLs = cachedStoryMediaURLs.filter { ids.contains($0.key) }
        preloadedVideoDurations = preloadedVideoDurations.filter { ids.contains($0.key) }
        effectiveStoryDurations = effectiveStoryDurations.filter { ids.contains($0.key) }
        for storyId in prewarmedVideoPlayers.keys where !ids.contains(storyId) {
            prewarmedVideoPlayers[storyId]?.pause()
            prewarmedVideoPlayers[storyId] = nil
        }
        prewarmedVideoOrder.removeAll { !ids.contains($0) }
    }

    private func clearPrewarmedVideoPlayers() {
        prewarmedVideoPlayers.values.forEach { $0.pause() }
        prewarmedVideoPlayers.removeAll()
        prewarmedVideoOrder.removeAll()
    }

    private func attachVideoObservers(player: AVPlayer, item: AVPlayerItem, story: StoryItem) {
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            guard currentStory?.id == story.id else { return }
            nextStory()
        }

        videoStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            guard currentStory?.id == story.id else { return }
            retryVideoIfPossible(story)
        }

        videoStatusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Task { @MainActor in
                guard currentStory?.id == story.id else { return }
                switch item.status {
                case .failed:
                    videoErrorText = item.error?.localizedDescription ?? "Video failed to load."
                    retryVideoIfPossible(story)
                case .readyToPlay:
                    videoErrorText = nil
                    updateEffectiveDuration(for: story, item: item)
                    if tickTask == nil {
                        startStoryProgressTimer(for: story)
                    }
                    if !isPaused { player.play() }
                default:
                    break
                }
            }
        }

        playerStatusObserver = player.observe(\.status, options: [.new]) { player, _ in
            Task { @MainActor in
                guard currentStory?.id == story.id, player.status == .failed else { return }
                videoErrorText = player.error?.localizedDescription ?? "Video failed to play."
                retryVideoIfPossible(story)
            }
        }
    }

    private func scheduleVideoRetryCheck(for story: StoryItem, item: AVPlayerItem) {
        videoRetryTask?.cancel()
        videoRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, currentStory?.id == story.id else { return }
            if item.status == .failed {
                retryVideoIfPossible(story)
            }
        }
    }

    private func retryVideoIfPossible(_ story: StoryItem) {
        guard videoRetryCount < 5 else {
            videoErrorText = "Video is still processing. Try again shortly."
            return
        }
        videoRetryCount += 1
        videoErrorText = nil
        elapsed = 0
        tickTask?.cancel()
        tickTask = nil
        prepareVideo(story)
    }

    private func seekStoryProgress(index: Int, progress rawProgress: Double, commit: Bool) {
        guard let group = currentGroup, group.stories.indices.contains(index) else { return }
        let targetStory = group.stories[index]
        let targetProgress = min(max(rawProgress, 0), 1)

        if index != storyIndex {
            storyIndex = index
            beginCurrentStory()
        }

        let duration = displayDuration(for: targetStory)
        elapsed = duration * targetProgress

        guard commit else { return }

        if targetStory.isVideoMedia, currentStory?.id == targetStory.id {
            let target = CMTime(seconds: elapsed, preferredTimescale: 600)
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            if !isPaused {
                player?.play()
            }
        }
    }

    private func canShowViewersChip(for story: StoryItem, group: StoryGroup) -> Bool {
        story.viewCount > 0
            && isCurrentPublisher(group)
            && !viewerAccessDeniedStoryIds.contains(story.id)
    }

    private func presentViewersSheet(for story: StoryItem) {
        viewersSheetStory = story
        setPaused(true)
    }

    private func prefetchViewerPreviewIfNeeded(for story: StoryItem, group: StoryGroup) async {
        guard canShowViewersChip(for: story, group: group),
              viewerPreviewResponses[story.id] == nil else { return }

        do {
            let response = try await StoriesAPIClient.shared.fetchViewers(storyId: story.id, limit: 3)
            guard currentStory?.id == story.id else { return }
            let previewUsers = Array(response.viewers.prefix(3).map(\.user))
            await preloadViewerPreviewImages(previewUsers)
            guard currentStory?.id == story.id else { return }
            viewerPreviewResponses[story.id] = response
            viewerPreviewAvatars[story.id] = previewUsers
        } catch StoriesError.notAllowed {
            viewerAccessDeniedStoryIds.insert(story.id)
        } catch StoriesError.serverMessage(_) {
            viewerAccessDeniedStoryIds.insert(story.id)
        } catch {
            // The full sheet can retry; preview avatars are optional.
        }
    }

    private func preloadViewerPreviewImages(_ users: [ViewerUser]) async {
        for user in users.prefix(3) {
            guard let image = user.image, let url = C.mediaURL(image) else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func isCurrentPublisher(_ group: StoryGroup) -> Bool {
        guard let context = SessionStorage.activeContext else { return false }
        let publisherType = group.publisherType.lowercased()
        let contextType = context.type.lowercased()

        if contextType == publisherType, context.id == group.publisherId {
            return true
        }

        if publisherType == "channel", context.channelId == group.publisherId {
            return true
        }

        return false
    }

    private func setPaused(_ paused: Bool) {
        let shouldPause = paused || viewersSheetStory != nil || storyPendingDelete != nil || isDeletingStory
        isPaused = shouldPause
        if shouldPause {
            player?.pause()
        } else {
            player?.play()
        }
    }

    private func nextStory() {
        guard let group = currentGroup else { return }
        if storyIndex + 1 < group.stories.count {
            storyIndex += 1
            beginCurrentStory()
            return
        }

        if groupIndex + 1 < groups.count {
            withAnimation(.easeInOut(duration: 0.22)) {
                nextGroup()
            }
        } else {
            dismiss()
        }
    }

    private func previousStory() {
        if elapsed > 0.8 {
            beginCurrentStory()
            return
        }

        if storyIndex > 0 {
            storyIndex -= 1
        } else {
            beginCurrentStory()
            return
        }
        beginCurrentStory()
    }

    private func nextGroup() {
        guard groupIndex + 1 < groups.count else { return }
        groupTransitionDirection = 1
        groupIndex += 1
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
    }

    private func previousGroup() {
        guard groupIndex > 0 else { return }
        groupTransitionDirection = -1
        groupIndex -= 1
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
    }

    private func stop() {
        tickTask?.cancel()
        viewedTask?.cancel()
        videoRetryTask?.cancel()
        preloadTask?.cancel()
        backendRefreshTask?.cancel()
        tickTask = nil
        viewedTask = nil
        videoRetryTask = nil
        preloadTask = nil
        backendRefreshTask = nil
        activeStoryId = nil
        clearVideoObservers()
        player?.pause()
        player = nil
        clearPrewarmedVideoPlayers()
    }

    private func deleteStory(_ story: StoryItem) async {
        guard !isDeletingStory else { return }
        isDeletingStory = true
        storyDeleteError = nil
        do {
            try await repository.deleteStory(id: story.id)
            NotificationCenter.default.post(name: .storiesDidChange, object: nil)
            storyPendingDelete = nil
            isDeletingStory = false
            guard !groups.isEmpty else {
                dismiss()
                return
            }
            clampIndexes()
            beginCurrentStory()
        } catch {
            storyDeleteError = error.localizedDescription
            storyPendingDelete = nil
            isDeletingStory = false
            setPaused(false)
        }
    }

    private func clearVideoObservers() {
        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
        }
        videoEndObserver = nil
        if let videoStallObserver {
            NotificationCenter.default.removeObserver(videoStallObserver)
        }
        videoStallObserver = nil
        videoStatusObserver?.invalidate()
        videoStatusObserver = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
    }

    private func clampIndexes() {
        guard !groups.isEmpty else {
            groupIndex = 0
            storyIndex = 0
            return
        }
        groupIndex = min(max(groupIndex, 0), groups.count - 1)
        let storyCount = groups[groupIndex].stories.count
        storyIndex = min(max(storyIndex, 0), max(storyCount - 1, 0))
    }

    private func firstUnseenStoryIndex(in group: StoryGroup?) -> Int? {
        group?.stories.firstIndex { !$0.seen }
    }

    private func displayDuration(for story: StoryItem) -> TimeInterval {
        if story.isVideoMedia {
            if let duration = effectiveStoryDurations[story.id] ?? preloadedVideoDurations[story.id], duration.isFinite, duration > 0 {
                return max(duration, 1)
            }
        }
        return TimeInterval(max(story.duration, 1))
    }

    private func updateEffectiveDuration(for story: StoryItem, item: AVPlayerItem) {
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        effectiveStoryDurations[story.id] = max(duration, 1)
    }

    private func progress(for index: Int, story: StoryItem) -> Double {
        if index < storyIndex { return 1 }
        if index > storyIndex { return 0 }
        return min(max(elapsed / displayDuration(for: story), 0), 1)
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func toggleLike(_ story: StoryItem) async {
        guard !likingStoryIds.contains(story.id) else { return }
        likingStoryIds.insert(story.id)
        defer { likingStoryIds.remove(story.id) }
        await repository.toggleLike(storyId: story.id)
    }

    private func compactCount(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }
        let divisor = value >= 1_000_000 ? 1_000_000.0 : 1_000.0
        let suffix = value >= 1_000_000 ? "M" : "K"
        let scaled = Double(value) / divisor
        let text = scaled >= 10 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return "\(text.replacingOccurrences(of: ".0", with: ""))\(suffix)"
    }

    private func openCTA(_ value: String?) {
        guard let value, let url = URL(string: value) else { return }
        inAppBrowser.open(url)
    }
}

private struct StoryViewerPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.videoGravity = .resizeAspect
        uiView.playerLayer.player = player
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private extension StoryItem {
    var isVideoMedia: Bool {
        let type = mediaType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "video"
            || type.hasPrefix("video/")
            || type.contains("video")
            || type.contains("mp4")
            || type.contains("quicktime")
            || type.contains("mpegurl") {
            return true
        }

        guard let url = C.mediaURL(mediaUrl) else { return false }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains(".mp4")
            || absolute.contains(".mov")
            || absolute.contains(".m4v")
            || absolute.contains(".webm")
            || absolute.contains(".m3u8") {
            return true
        }

        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm", "m3u8":
            return true
        default:
            return false
        }
    }
}

// MARK: - Sticker views

/// Shared pill/card backdrop
private struct StickerBacking: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.86))
            .shadow(color: C.watch.opacity(0.16), radius: 12, y: 4)
    }
}

private struct MentionStickerView: View {
    let data: MentionOverlayData
    var onNavigate: () -> Void = {}

    var body: some View {
        Button {
            navigate()
        } label: {
            HStack(spacing: 6) {
                if let avatarStr = data.avatarUrl, let url = C.mediaURL(avatarStr) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: 22, height: 22)
                    ) { img in img.resizable().scaledToFill() } placeholder: {
                        Circle().fill(C.watch)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(C.watch)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Text(String(data.displayName.prefix(1)).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                        }
                }
                Text("@\(data.handle)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StickerBacking())
        }
        .buttonStyle(.plain)
    }

    private func navigate() {
        let route: AppRoute?
        switch data.entityType.lowercased() {
        case "channel":
            route = .channel(data.handle.isEmpty ? data.entityId : data.handle)
        case "show":
            route = .show(data.entityId)
        default:
            route = .channel(data.handle.isEmpty ? data.entityId : data.handle)
        }

        if let route {
            onNavigate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
            }
        }
    }
}

private struct LocationStickerView: View {
    let data: LocationOverlayData

    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    var body: some View {
        Button {
            openInMaps()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(C.watch)
                Text(data.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StickerBacking())
        }
        .buttonStyle(.plain)
    }

    private func openInMaps() {
        guard let lat = data.lat, let lng = data.lng else { return }
        let encoded = data.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://maps.apple.com/?q=\(encoded)&ll=\(lat),\(lng)") else { return }
        inAppBrowser.open(url)
    }
}

private struct PollStickerView: View {
    let data: PollOverlayData
    let storyId: String
    let overlayIndex: Int

    @State private var votes: [Int]
    @State private var userVote: Int?
    @State private var isSubmitting = false

    init(data: PollOverlayData, storyId: String, overlayIndex: Int) {
        self.data = data
        self.storyId = storyId
        self.overlayIndex = overlayIndex
        _votes = State(initialValue: Self.normalizedVotes(data.votes, optionCount: data.options.count))
        _userVote = State(initialValue: data.userVote)
    }

    private var totalVotes: Int {
        votes.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.question)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            ForEach(data.options.indices, id: \.self) { i in
                Button { vote(for: i) } label: {
                    pollOption(index: i)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(StickerBacking())
    }

    private func pollOption(index: Int) -> some View {
        let isSelected = userVote == index
        let percent = totalVotes > 0 && votes.indices.contains(index) ? Double(votes[index]) / Double(totalVotes) : 0
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(C.watch.opacity(0.18))

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? C.watch.opacity(0.65) : C.watch.opacity(0.30))
                    .frame(width: userVote != nil ? proxy.size.width * percent : 0)
                    .animation(.easeOut(duration: 0.28), value: percent)
            }
            .frame(height: 38)

            HStack {
                Text(data.options[index])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if userVote != nil {
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }

    private func vote(for optionIndex: Int) {
        guard !isSubmitting, votes.indices.contains(optionIndex) else { return }
        let previousVote = userVote
        let previousVotes = votes
        if let previousVote, votes.indices.contains(previousVote) {
            votes[previousVote] = max(0, votes[previousVote] - 1)
        }
        votes[optionIndex] += 1
        userVote = optionIndex
        isSubmitting = true

        Task {
            do {
                let response = try await StoriesAPIClient.shared.pollVote(
                    storyId: storyId,
                    overlayIndex: overlayIndex,
                    optionIndex: optionIndex
                )
                await MainActor.run {
                    votes = Self.normalizedVotes(response.votes, optionCount: data.options.count)
                    userVote = response.userVote
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    votes = previousVotes
                    userVote = previousVote
                    isSubmitting = false
                }
            }
        }
    }

    private static func normalizedVotes(_ votes: [Int]?, optionCount: Int) -> [Int] {
        var normalized = votes ?? []
        if normalized.count < optionCount {
            normalized.append(contentsOf: Array(repeating: 0, count: optionCount - normalized.count))
        }
        return Array(normalized.prefix(optionCount))
    }
}

private struct QuizStickerView: View {
    let data: QuizOverlayData
    let storyId: String
    let overlayIndex: Int

    @State private var userAnswer: Int?
    @State private var correctIndex: Int
    @State private var isSubmitting = false

    init(data: QuizOverlayData, storyId: String, overlayIndex: Int) {
        self.data = data
        self.storyId = storyId
        self.overlayIndex = overlayIndex
        _userAnswer = State(initialValue: data.userAnswer)
        _correctIndex = State(initialValue: data.correctIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(C.watch)
                    .font(.system(size: 12))
                Text("QUIZ")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(C.watch)
            }

            Text(data.question)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            ForEach(data.options.indices, id: \.self) { i in
                Button { submit(selectedIndex: i) } label: {
                    optionRow(index: i)
                }
                .buttonStyle(.plain)
                .disabled(userAnswer != nil || isSubmitting)
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(StickerBacking())
    }

    private func optionRow(index: Int) -> some View {
        let answered = userAnswer != nil
        let isCorrect = index == correctIndex
        let isChosen = userAnswer == index
        return HStack {
            Text(data.options[index])
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if answered {
                if isCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(C.watch)
                } else if isChosen {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(optionBackground(index: index))
        )
        .animation(.easeOut(duration: 0.25), value: answered)
    }

    private func optionBackground(index: Int) -> Color {
        guard let userAnswer else { return C.watch.opacity(0.14) }
        if index == correctIndex { return C.watch.opacity(0.55) }
        if index == userAnswer { return Color.black.opacity(0.92) }
        return C.watch.opacity(0.14)
    }

    private func submit(selectedIndex: Int) {
        guard userAnswer == nil, !isSubmitting else { return }
        userAnswer = selectedIndex
        isSubmitting = true
        Task {
            do {
                let response = try await StoriesAPIClient.shared.quizAnswer(
                    storyId: storyId,
                    overlayIndex: overlayIndex,
                    selectedIndex: selectedIndex
                )
                await MainActor.run {
                    userAnswer = response.selectedIndex
                    correctIndex = response.correctIndex
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    userAnswer = nil
                    isSubmitting = false
                }
            }
        }
    }
}

private struct CountdownStickerView: View {
    let data: CountdownOverlayData

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            Text(data.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)

            Text(timeString)
                .font(.system(size: 22, weight: .black).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(StickerBacking())
        .onReceive(timer) { t in now = t }
    }

    private var timeString: String {
        let remaining = max(data.endsAt.timeIntervalSince(now), 0)
        if remaining <= 0 { return "00:00:00" }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct LinkStickerView: View {
    let data: LinkOverlayData

    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    var body: some View {
        Button {
            guard let url = URL(string: data.url) else { return }
            inAppBrowser.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                Text(data.label ?? shortenedHost ?? data.url)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StickerBacking())
        }
        .buttonStyle(.plain)
    }

    private var shortenedHost: String? {
        guard let host = URL(string: data.url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private struct QuestionStickerView: View {
    let data: QuestionOverlayData
    let storyId: String
    let overlayIndex: Int
    let setPaused: (Bool) -> Void

    @State private var showingReply = false
    @State private var userReplied: Bool

    init(data: QuestionOverlayData, storyId: String, overlayIndex: Int, setPaused: @escaping (Bool) -> Void) {
        self.data = data
        self.storyId = storyId
        self.overlayIndex = overlayIndex
        self.setPaused = setPaused
        _userReplied = State(initialValue: data.userReplied ?? false)
    }

    var body: some View {
        Button {
            setPaused(true)
            showingReply = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(C.watch)
                    Text(userReplied ? "EDIT REPLY" : "ASK ME")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(C.watch)
                }

                Text(data.prompt)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let replyCount = data.replyCount, replyCount > 0 {
                    Text("\(replyCount) repl\(replyCount == 1 ? "y" : "ies")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(12)
            .frame(minWidth: 180, maxWidth: 240)
            .background(StickerBacking())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingReply, onDismiss: { setPaused(false) }) {
            QuestionReplySheet(
                prompt: data.prompt,
                storyId: storyId,
                overlayIndex: overlayIndex
            ) {
                userReplied = true
                showingReply = false
            }
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct QuestionReplySheet: View {
    let prompt: String
    let storyId: String
    let overlayIndex: Int
    let onSent: () -> Void

    @State private var text = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let maxLength = 500

    var body: some View {
        VStack(spacing: 16) {
            Text(prompt)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 8)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your reply...")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .frame(height: 92)
                    .scrollContentBackground(.hidden)
                    .onChange(of: text) { _, value in
                        if value.count > maxLength {
                            text = String(value.prefix(maxLength))
                        }
                    }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("\(text.count)/\(maxLength)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isSubmitting ? "Sending..." : "Send") { submit() }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            do {
                _ = try await StoriesAPIClient.shared.questionReply(
                    storyId: storyId,
                    overlayIndex: overlayIndex,
                    text: trimmed
                )
                await MainActor.run { onSent() }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

private struct StoryHeaderAvatar: View {
    let group: StoryGroup

    var body: some View {
        Group {
            if let url = C.mediaURL(group.publisherImageUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 36, height: 36)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .clipShape(Circle())
        .overlay { Circle().stroke(Color.white.opacity(0.35), lineWidth: 1) }
    }

    private var fallback: some View {
        Circle()
            .fill(Color.white.opacity(0.18))
            .overlay {
                Text(group.publisherName.first.map(String.init)?.uppercased() ?? "?")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}
