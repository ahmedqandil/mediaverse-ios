import Foundation

enum StoryFeedNormalizer {
    static func normalize(
        _ groups: [StoryGroup],
        now: Date = Date(),
        preservingSeenStoryIds: Set<String> = []
    ) -> [StoryGroup] {
        var normalized = [StoryGroup]()
        var groupIndexes = [String: Int]()
        var storyIdsByGroup = [String: Set<String>]()

        for group in groups {
            let publisherType = group.publisherType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let publisherId = group.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publisherType.isEmpty, !publisherId.isEmpty else { continue }
            let groupKey = "\(publisherType):\(publisherId)"
            let activeStories = group.stories.filter {
                !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.expiresAt > now
            }.map { story in
                guard preservingSeenStoryIds.contains(story.id), !story.seen else { return story }
                var seenStory = story
                seenStory.seen = true
                return seenStory
            }
            guard !activeStories.isEmpty else { continue }

            if let index = groupIndexes[groupKey] {
                var knownStoryIds = storyIdsByGroup[groupKey] ?? Set(normalized[index].stories.map(\.id))
                for story in activeStories where knownStoryIds.insert(story.id).inserted {
                    normalized[index].stories.append(story)
                }
                normalized[index].hasUnseen = normalized[index].stories.contains { !$0.seen }
                storyIdsByGroup[groupKey] = knownStoryIds
            } else {
                var knownStoryIds = Set<String>()
                let uniqueStories = activeStories.filter { knownStoryIds.insert($0.id).inserted }
                var cleanGroup = group
                cleanGroup.stories = uniqueStories
                cleanGroup.hasUnseen = uniqueStories.contains { !$0.seen }
                groupIndexes[groupKey] = normalized.count
                storyIdsByGroup[groupKey] = knownStoryIds
                normalized.append(cleanGroup)
            }
        }

        return normalized
    }
}

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
    private var refreshGeneration = 0

    init(client: StoriesAPIClient = .shared) {
        self.client = client
        self.groups = SessionStorage.token == nil
            ? []
            : StoryFeedNormalizer.normalize(StoryFeedDiskCache.loadCachedGroups())
        observeFollowChanges()
    }

    deinit {
        followChangesTask?.cancel()
        cacheSaveTask?.cancel()
        markViewedFlushTask?.cancel()
    }

    func refresh(force: Bool = false) async {
        guard SessionStorage.token != nil else {
            refreshGeneration += 1
            groups = []
            lastRefreshAt = nil
            lastError = nil
            isLoading = false
            return
        }

        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < cacheTTL, !groups.isEmpty {
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true

        do {
            let fetched = try await client.fetchGroups(myChannelId: activeStoryChannelId)
            guard generation == refreshGeneration else { return }
            let locallySeenStoryIds = Set(
                groups.flatMap(\.stories).filter(\.seen).map(\.id)
            ).union(pendingViewedStoryIds)
            groups = StoryFeedNormalizer.normalize(
                fetched,
                preservingSeenStoryIds: locallySeenStoryIds
            )
            saveCachedGroups()
            lastRefreshAt = Date()
            lastError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if groups.isEmpty {
                groups = StoryFeedNormalizer.normalize(StoryFeedDiskCache.loadCachedGroups())
            }
            lastError = error
        }
        if generation == refreshGeneration {
            isLoading = false
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

    func applyEnergy(storyId: String, aggregate: StoryEnergyAggregate) {
        for groupIndex in groups.indices {
            guard let storyIndex = groups[groupIndex].stories.firstIndex(where: { $0.id == storyId }) else { continue }
            groups[groupIndex].stories[storyIndex].energyCount = max(0, aggregate.count)
            groups[groupIndex].stories[storyIndex].energyTotal = Int(
                ((aggregate.avg ?? 0) * Double(max(0, aggregate.count))).rounded()
            )
            groups[groupIndex].stories[storyIndex].energyTags = aggregate.topTags
                .enumerated()
                .reduce(into: [String: Int]()) { result, item in
                    result[item.element] = 3 - min(item.offset, 2)
                }
            saveCachedGroups()
            return
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
