import AVKit
import SwiftUI

struct StoryViewerView: View {
    @ObservedObject var repository: StoriesRepository
    let initialGroupId: String

    @Environment(\.dismiss) private var dismiss
    @State private var groupIndex = 0
    @State private var storyIndex = 0
    @State private var elapsed: TimeInterval = 0
    @State private var isPaused = false
    @State private var player: AVPlayer?
    @State private var tickTask: Task<Void, Never>?
    @State private var viewedTask: Task<Void, Never>?
    @State private var videoRetryTask: Task<Void, Never>?
    @State private var videoTimeObserver: Any?
    @State private var videoEndObserver: NSObjectProtocol?
    @State private var videoStallObserver: NSObjectProtocol?
    @State private var videoRetryCount = 0
    @State private var videoErrorText: String?

    private var groups: [StoryGroup] { repository.groups.filter { !$0.stories.isEmpty } }
    private var currentGroup: StoryGroup? { groups.indices.contains(groupIndex) ? groups[groupIndex] : nil }
    private var currentStory: StoryItem? {
        guard let group = currentGroup, group.stories.indices.contains(storyIndex) else { return nil }
        return group.stories[storyIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let group = currentGroup, let story = currentStory {
                storyMedia(story)
                    .ignoresSafeArea()

                topGradient
                bottomGradient
                tapNavigationLayer

                VStack(spacing: 0) {
                    progressBars(group: group, story: story)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)

                    header(group: group, story: story)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    Spacer()

                    bottomContent(story: story)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 34)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(C.watch)
            }
        }
        .statusBarHidden()
        .gesture(dismissDrag)
        .simultaneousGesture(pauseGesture)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: repository.groups) { _, _ in
            clampIndexes()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func storyMedia(_ story: StoryItem) -> some View {
        if story.mediaType.lowercased() == "video" {
            if let player {
                VideoPlayer(player: player)
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
            AsyncImage(url: C.mediaURL(story.mediaUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    C.elevated
                }
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

    private func progressBars(group: StoryGroup, story: StoryItem) -> some View {
        HStack(spacing: 4) {
            ForEach(group.stories.indices, id: \.self) { index in
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * progress(for: index, story: story))
                        }
                }
                .frame(height: 2)
                .accessibilityLabel("Story \(index + 1) progress")
                .accessibilityValue("\(Int(progress(for: index, story: story) * 100)) percent")
            }
        }
    }

    private func header(group: StoryGroup, story: StoryItem) -> some View {
        HStack(spacing: 9) {
            StoryHeaderAvatar(group: group)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.publisherName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(relativeTime(from: story.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Close stories")
        }
    }

    @ViewBuilder
    private func bottomContent(story: StoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let caption = story.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(caption)
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
                if value.translation.height > 90 && abs(value.translation.height) > abs(value.translation.width) {
                    dismiss()
                } else if value.translation.width < -70 {
                    nextGroup()
                } else if value.translation.width > 70 {
                    previousGroup()
                }
            }
    }

    private var pauseGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .onChanged { _ in setPaused(true) }
            .onEnded { _ in setPaused(false) }
    }

    private func start() {
        if let startIndex = groups.firstIndex(where: { $0.id == initialGroupId }) {
            groupIndex = startIndex
        }
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
    }

    private func beginCurrentStory() {
        elapsed = 0
        videoRetryCount = 0
        videoErrorText = nil
        clearVideoObservers()
        player?.pause()
        player = nil
        tickTask?.cancel()
        viewedTask?.cancel()
        videoRetryTask?.cancel()

        guard let story = currentStory else { return }
        if story.mediaType.lowercased() == "video" {
            prepareVideo(story)
        } else {
            startImageProgressTimer(for: story)
        }

        viewedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let id = currentStory?.id, id == story.id else { return }
            await repository.markViewed(storyId: id)
        }

    }

    private func startImageProgressTimer(for story: StoryItem) {
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                if !isPaused {
                    elapsed += 0.05
                    if elapsed >= TimeInterval(max(story.duration, 1)) {
                        nextStory()
                    }
                }
            }
        }
    }

    private func prepareVideo(_ story: StoryItem) {
        guard let url = C.mediaURL(story.mediaUrl) else { return }
        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.actionAtItemEnd = .none
        nextPlayer.volume = 1
        player = nextPlayer
        attachVideoObservers(player: nextPlayer, item: item, story: story)
        if !isPaused { nextPlayer.play() }
        scheduleVideoRetryCheck(for: story, item: item)
    }

    private func attachVideoObservers(player: AVPlayer, item: AVPlayerItem, story: StoryItem) {
        videoTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard currentStory?.id == story.id else { return }
            elapsed = max(time.seconds, 0)
            if elapsed >= TimeInterval(max(story.duration, 1)) {
                nextStory()
            }
        }

        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            guard currentStory?.id == story.id, elapsed < TimeInterval(max(story.duration, 1)) else { return }
            player.seek(to: .zero)
            if !isPaused { player.play() }
        }

        videoStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            guard currentStory?.id == story.id else { return }
            retryVideoIfPossible(story)
        }
    }

    private func scheduleVideoRetryCheck(for story: StoryItem, item: AVPlayerItem) {
        videoRetryTask?.cancel()
        videoRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, currentStory?.id == story.id else { return }
            if item.status == .failed || (item.status == .unknown && elapsed <= 0.05) {
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
        prepareVideo(story)
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            player?.pause()
        } else {
            player?.play()
        }
    }

    private func nextStory() {
        guard let group = currentGroup else { return }
        if storyIndex + 1 < group.stories.count {
            storyIndex += 1
        } else if groupIndex + 1 < groups.count {
            groupIndex += 1
            storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        } else {
            dismiss()
            return
        }
        beginCurrentStory()
    }

    private func previousStory() {
        if elapsed > 0.8 {
            beginCurrentStory()
            return
        }

        if storyIndex > 0 {
            storyIndex -= 1
        } else if groupIndex > 0 {
            groupIndex -= 1
            storyIndex = max((currentGroup?.stories.count ?? 1) - 1, 0)
        } else {
            beginCurrentStory()
            return
        }
        beginCurrentStory()
    }

    private func nextGroup() {
        guard groupIndex + 1 < groups.count else { return }
        groupIndex += 1
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
    }

    private func previousGroup() {
        guard groupIndex > 0 else { return }
        groupIndex -= 1
        storyIndex = firstUnseenStoryIndex(in: currentGroup) ?? 0
        beginCurrentStory()
    }

    private func stop() {
        tickTask?.cancel()
        viewedTask?.cancel()
        videoRetryTask?.cancel()
        clearVideoObservers()
        player?.pause()
        player = nil
    }

    private func clearVideoObservers() {
        if let videoTimeObserver, let player {
            player.removeTimeObserver(videoTimeObserver)
        }
        videoTimeObserver = nil

        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
        }
        videoEndObserver = nil

        if let videoStallObserver {
            NotificationCenter.default.removeObserver(videoStallObserver)
        }
        videoStallObserver = nil
    }

    private func clampIndexes() {
        guard !groups.isEmpty else {
            dismiss()
            return
        }
        groupIndex = min(max(groupIndex, 0), groups.count - 1)
        let storyCount = groups[groupIndex].stories.count
        storyIndex = min(max(storyIndex, 0), max(storyCount - 1, 0))
    }

    private func firstUnseenStoryIndex(in group: StoryGroup?) -> Int? {
        group?.stories.firstIndex { !$0.seen }
    }

    private func progress(for index: Int, story: StoryItem) -> Double {
        if index < storyIndex { return 1 }
        if index > storyIndex { return 0 }
        return min(max(elapsed / TimeInterval(max(story.duration, 1)), 0), 1)
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

    private func openCTA(_ value: String?) {
        guard let value, let url = URL(string: value) else { return }
        UIApplication.shared.open(url)
    }
}

private struct StoryHeaderAvatar: View {
    let group: StoryGroup

    var body: some View {
        Group {
            if let url = C.mediaURL(group.publisherImageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: fallback
                    }
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
