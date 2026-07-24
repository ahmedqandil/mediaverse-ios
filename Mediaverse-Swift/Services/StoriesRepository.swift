import Foundation

@MainActor
final class StoriesRepository: ObservableObject {
    @Published private(set) var groups: [StoryGroup] = []
    @Published private(set) var isLoading = false
    @Published var lastError: Error?

    private let client: StoriesAPIClient
    private var lastRefreshAt: Date?
    private let cacheTTL: TimeInterval = 30
    private var followChangesTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?
    private var markViewedFlushTask: Task<Void, Never>?
    private var pendingViewedStoryIds = Set<String>()

    init(client: StoriesAPIClient = .shared) {
        self.client = client
        self.groups = SessionStorage.token == nil ? [] : StoryFeedDiskCache.loadCachedGroups()
        observeFollowChanges()
    }

    deinit {
        followChangesTask?.cancel()
        cacheSaveTask?.cancel()
        markViewedFlushTask?.cancel()
    }

    func refresh(force: Bool = false) async {
        guard SessionStorage.token != nil else {
            groups = []
            lastRefreshAt = nil
            lastError = nil
            return
        }

        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < cacheTTL, !groups.isEmpty {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await client.fetchGroups(myChannelId: activeStoryChannelId)
            groups = fetched.filter { !$0.stories.isEmpty }
            saveCachedGroups()
            lastRefreshAt = Date()
            lastError = nil
        } catch {
            if groups.isEmpty {
                groups = StoryFeedDiskCache.loadCachedGroups()
            }
            lastError = error
        }
    }

    private var activeStoryChannelId: String? {
        guard let activeContext = SessionStorage.activeContext else { return nil }
        if let channelId = activeContext.channelId, !channelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return channelId
        }
        return activeContext.type == "channel" ? activeContext.id : nil
    }

    private func observeFollowChanges() {
        followChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .userFollowChanged) {
                await self?.refresh(force: true)
            }
        }
    }

    func markViewed(storyId: String) async {
        applySeen(storyId: storyId)
        enqueueMarkViewed(storyId: storyId)
    }

    func toggleLike(storyId: String) async {
        guard let previous = storyLikeState(storyId: storyId) else { return }
        let optimisticLiked = !previous.userLiked
        applyLike(storyId: storyId, liked: optimisticLiked, likeCount: max(0, previous.likeCount + (optimisticLiked ? 1 : -1)))

        do {
            let response = try await client.toggleLike(storyId: storyId)
            applyLike(
                storyId: storyId,
                liked: response.liked ?? optimisticLiked,
                likeCount: response.likeCount ?? max(0, previous.likeCount + (optimisticLiked ? 1 : -1))
            )
            lastError = nil
        } catch StoriesError.notFound {
            removeStory(id: storyId)
            lastError = nil
        } catch {
            applyLike(storyId: storyId, liked: previous.userLiked, likeCount: previous.likeCount)
            lastError = error
        }
    }

    func deleteStory(id: String) async throws {
        do {
            try await client.deleteStory(id: id)
            removeStory(id: id)
        } catch StoriesError.notFound {
            removeStory(id: id)
        }
    }

    func removeStory(id: String) {
        for index in groups.indices {
            groups[index].stories.removeAll { $0.id == id }
            groups[index].hasUnseen = groups[index].stories.contains { !$0.seen }
        }
        groups.removeAll { $0.stories.isEmpty }
        saveCachedGroups()
    }

    private func applySeen(storyId: String) {
        for groupIndex in groups.indices {
            guard let storyIndex = groups[groupIndex].stories.firstIndex(where: { $0.id == storyId }) else { continue }
            groups[groupIndex].stories[storyIndex].seen = true
            groups[groupIndex].hasUnseen = groups[groupIndex].stories.contains { !$0.seen }
            return
        }
    }

    private func storyLikeState(storyId: String) -> (userLiked: Bool, likeCount: Int)? {
        for group in groups {
            if let story = group.stories.first(where: { $0.id == storyId }) {
                return (story.userLiked, story.likeCount)
            }
        }
        return nil
    }

    private func applyLike(storyId: String, liked: Bool, likeCount: Int) {
        for groupIndex in groups.indices {
            guard let storyIndex = groups[groupIndex].stories.firstIndex(where: { $0.id == storyId }) else { continue }
            groups[groupIndex].stories[storyIndex].userLiked = liked
            groups[groupIndex].stories[storyIndex].likeCount = max(0, likeCount)
            saveCachedGroups()
            return
        }
    }

    private func saveCachedGroups() {
        let snapshot = groups
        cacheSaveTask?.cancel()
        cacheSaveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            try? await StoryFeedDiskCache.shared.store(snapshot)
        }
    }

    private func enqueueMarkViewed(storyId: String) {
        pendingViewedStoryIds.insert(storyId)
        guard markViewedFlushTask == nil else { return }
        markViewedFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushPendingViewedStories()
        }
    }

    private func flushPendingViewedStories() async {
        let storyIds = pendingViewedStoryIds
        pendingViewedStoryIds.removeAll()
        markViewedFlushTask = nil

        for storyId in storyIds {
            do {
                try await client.markViewed(storyId: storyId)
                lastError = nil
            } catch StoriesError.notFound {
                removeStory(id: storyId)
                lastError = nil
            } catch {
                pendingViewedStoryIds.insert(storyId)
                lastError = error
            }
        }

        if !pendingViewedStoryIds.isEmpty {
            enqueueMarkViewed(storyId: pendingViewedStoryIds.removeFirst())
        }
    }
}
